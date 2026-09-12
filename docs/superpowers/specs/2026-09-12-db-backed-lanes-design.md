# DB-backed lanes in one Symphony process

Date: 2026-09-12
Status: approved design, awaiting implementation plan
Sub-project 1 of 3 (see "Roadmap context")

## Roadmap context

Both clients (Trazadera on Hetzner, Tyrell on EC2) run Symphony the same way: three lanes
(features, bugs, qa), each a separate systemd unit of the same binary, each fed a WORKFLOW.md
rendered by Ansible from a Jinja template, all on one VM with `max_concurrent_agents: 1`.
A shared change means three playbooks run in order while each lane's agent is idle, and a
restart kills in-flight work that can take hours. Neither client uses remote or managed
execution today.

The target is: Symphony orchestrates, ephemeral Kubernetes workers ("minions") do the ticket
work and own the agent loop, and lanes are configured in a UI without a deploy. That splits
into three sub-projects, each with its own spec and plan:

1. **This spec.** One daemon runs many lanes from a database, editable live in a web UI.
   Executor is `local` only. Removes the three-unit, deploy-to-change operating model.
2. **Minion executor.** `symphony run-issue` entrypoint reusing AgentRunner inside a pod,
   a Kubernetes Job executor per lane, per-run tokens, a minion-to-Symphony event API, and
   re-adoption of running Jobs after a Symphony restart.
3. **Operator UI beyond CRUD.** Cross-lane runs board, blocked queue, manual retry/stop/unpark,
   prompt diff and rollback.

Decisions fixed for the whole roadmap:

- One Symphony installation per client. Clients are fully isolated and share nothing. No
  tenant concept in the data model.
- The database is the source of truth for lane configuration. WORKFLOW.md survives only as
  an import/export format and as the file the agent-side MCP server reads.
- The minion owns the agent loop in sub-project 2; a Symphony restart must not stop a run.
- Minions report turn events and usage to Symphony so the dashboard keeps its live feed.
- Authentication is one shared operator credential per installation. Installations live on
  private networks.
- Executor is a per-lane choice (`local` now, `kubernetes` later) so clients migrate lane by
  lane.
- The UI is Phoenix LiveView in the existing Endpoint, no JS build step.

## Goals

- One `symphony serve` process runs N lanes, each with its own Orchestrator, Task.Supervisor,
  tracker scope, workspace root, agent settings, and prompt.
- A lane is created, edited, enabled, disabled, and rolled back in a web UI. A save applies
  live: running agents finish on the old config, new dispatches use the new one.
- Every save is a new immutable version. Rollback is a pointer move.
- Run attempts and their events are recorded durably for the dashboard and for the minion
  work in sub-project 2.
- Both clients can migrate by importing their three rendered WORKFLOW.md files and replacing
  three units with one.
- Configuration errors are shown to the operator where they typed them, never silently
  ignored.

## Non-goals

- Users, roles, audit of who changed what, tenants, per-lane tracker credentials.
- Any Kubernetes or remote executor (sub-project 2).
- Manual run controls, prompt diff view, cross-lane runs board (sub-project 3).
- Making the database the scheduler's source of truth. In-memory Orchestrator state is still
  rebuilt from the tracker on restart, as SPEC.md 2.1 requires.
- Replacing the TUI status board.

## Runtime architecture

### Supervision tree

```
Application (:one_for_one)
├── Phoenix.PubSub
├── Repo                        Ecto + ecto_sqlite3; file under --data-root
├── LaneStore                   GenServer; loads lanes, owns the ETS table of parsed
│                               Config.Schema per lane, publishes changes
├── LaneRegistry                Registry; keys {lane_id, role}
├── LaneSupervisor              DynamicSupervisor; one child per enabled lane
│   └── AgentRuntimeSupervisor  :one_for_all (unchanged), named via LaneRegistry
│       ├── Task.Supervisor     {:via, Registry, {LaneRegistry, {lane_id, :tasks}}}
│       └── Orchestrator        {:via, Registry, {LaneRegistry, {lane_id, :orchestrator}}}
├── HttpServer                  always started; the UI is the product
└── StatusDashboard             TUI; one block per lane
```

- `WorkflowStore` is removed; `LaneStore` replaces it.
- The `:one_for_all` coupling between an Orchestrator and its Task.Supervisor is preserved
  per lane. One lane crashing tears down only that lane's agents.
- `AgentRuntimeSupervisor` and `Orchestrator` already accept `orchestrator_name` /
  `task_supervisor_name` options; they gain a `lane_id` option and register via the Registry
  instead of module names.
- `HttpServer` is always started. `server.port` moves from the lane front matter to the CLI
  (`--port`, default 4000) since it is per installation, not per lane. The `server` section
  is accepted on import and ignored with a warning.
- `Codex.AppServer`, `Agent.Claude`, `Workspace`, `PromptBuilder`, tracker clients, and the
  managed-environment modules are unchanged in behaviour.

### Config resolution

`SymphonyElixir.Config.settings!/0` stays the single access point (77 call sites in 17 files
are untouched). It resolves the current lane from process context instead of asking a global
store:

1. `Process.get(:symphony_lane_id)` on the calling process; else
2. walk `Process.get(:"$callers")` (nearest first) and use the first process that has the
   tag; else
3. raise `SymphonyElixir.Config.NoLaneContext` naming the calling module and function.

Then read that lane's parsed `Config.Schema` from the LaneStore ETS table. The lookup is one
small module, `SymphonyElixir.LaneContext`, with `put/1`, `current/0`, and `current!/0`.

- Each lane's Orchestrator calls `LaneContext.put(lane_id)` in `init/1`.
- `Task.Supervisor` children inherit `$callers`, so AgentRunner, Workspace, agent backends,
  and tracker clients resolve the right lane without signature changes.
- Long-lived helpers started from inside a lane (the Codex app-server session process, the
  Linear MCP server port, per-run GenServers) copy the tag at start via `LaneContext.put/1`
  so they do not depend on their starter staying alive.
- The TUI, LiveViews, controllers, and the import CLI address a lane explicitly through
  `LaneStore.settings!(lane_id)`; they never call `Config.settings!/0`.

This is the same mechanism Ecto dynamic repos and ExUnit allowances use.

### Hot apply

When a lane version becomes current (save or rollback):

1. LaneStore parses the version through `Config.Schema`. Invalid input never reaches ETS.
2. LaneStore swaps the ETS entry and sends `{:lane_updated, lane_id}` to that Orchestrator.
3. The Orchestrator applies the new settings on its next tick, with the reload semantics of
   SPEC.md 6.2: running agents continue with the config they started with; new dispatches,
   polling interval, concurrency caps, and hooks use the new config.
4. The managed-environment identity guard (`ExecutionEnvironment.Config.identity/1`) is kept
   per lane. A save that changes a guarded field while the lane owns environments or has
   unresolved operations is rejected at validation with the same reason the file reload logs
   today.

Toggling `enabled`:

- Disable: `DynamicSupervisor.terminate_child/2` on the lane's runtime. Its agents stop, as a
  restart stops them today. The card shows the lane as disabled with the time.
- Enable: start the runtime; tracker preflight runs before the first poll.

### Tracker credentials

Stay in the environment (`LINEAR_API_KEY`, `GH_TOKEN`, and so on), one set per
installation, read through each adapter's existing `secret_environment_names/1`. Nothing
secret is stored in the database or shown in the UI.

## Data model

Four tables. Integer primary keys, UTC timestamps.

### `lanes`

| column | type | notes |
|---|---|---|
| `id` | integer pk | |
| `slug` | text, unique | `^[a-z][a-z0-9-]{1,40}$`; used in URLs, logs, Registry keys, workspace directory names |
| `name` | text | display name |
| `enabled` | boolean | drives LaneSupervisor |
| `executor` | text | check constraint: `local` (sub-project 2 adds `kubernetes`) |
| `current_version_id` | fk → `lane_versions.id`, nullable until first version | version the runtime uses |
| `deleted_at` | utc datetime, nullable | soft delete |
| `inserted_at`, `updated_at` | utc datetime | |

### `lane_versions`

Immutable, append-only.

| column | type | notes |
|---|---|---|
| `id` | integer pk | |
| `lane_id` | fk → `lanes.id` | |
| `front_matter` | text | YAML, exactly today's WORKFLOW.md front matter |
| `prompt` | text | the Markdown body |
| `note` | text, nullable | operator's one-line change note |
| `inserted_at` | utc datetime | |

The YAML is stored as text, not decomposed into columns: import and export are a copy, diffs
are readable, and `Config.Schema` stays the only validator. Rollback sets
`lanes.current_version_id` to an older row; no new row is written.

### `runs`

One row per agent attempt: the durable half of what the Orchestrator holds in memory.

| column | type | notes |
|---|---|---|
| `id` | integer pk | |
| `lane_id` | fk | |
| `lane_version_id` | fk | config the attempt ran with |
| `issue_id`, `issue_identifier` | text | tracker ids, per `docs/logging.md` |
| `issue_state` | text | state at dispatch |
| `attempt_id` | text, unique | the existing url-safe random id from AgentRunner |
| `attempt` | integer | retry count at dispatch |
| `executor` | text | `local` / `kubernetes` |
| `worker_ref` | text, nullable | host label now; Job name in sub-project 2 |
| `status` | text | `running`, `done`, `blocked`, `failed`, `turns_exhausted`, `stopped` |
| `started_at`, `finished_at` | utc datetime | `finished_at` null while running |
| `turns` | integer | |
| `input_tokens`, `output_tokens`, `cached_tokens` | integer | totals, updated from `usage` events |

### `run_events`

The live feed and usage ledger. Written by the local executor now; minions add a second
writer in sub-project 2.

| column | type | notes |
|---|---|---|
| `id` | integer pk | |
| `run_id` | fk → `runs.id` | |
| `at` | utc datetime | |
| `kind` | text | `turn_started`, `turn_finished`, `agent_message`, `usage`, `blocked`, `hook`, `error` |
| `payload` | text (JSON) | shape per kind; `usage` carries token deltas |

Indexes: `runs(lane_id, started_at)`, `runs(issue_id)`, `run_events(run_id, id)`.

### Retention and authority

- A daily task deletes `run_events` older than `--events-retention-days` (default 30).
  `runs` rows are kept.
- The Orchestrator's `running`, `claimed`, `completed`, `blocked`, `retry_attempts`, and
  `turn_exhaustions` remain in memory and are rebuilt from the tracker on restart. The
  database records history; it never drives scheduling. This keeps the concurrency-sensitive
  code out of this change.

### Not modelled

Users, tenants, secrets, tracker credentials, per-lane keys, blocked-issue persistence.

## Web UI and HTTP surface

All LiveView in the existing Endpoint with the vendored assets.

| route | view | content |
|---|---|---|
| `/` | `LanesLive` | one card per lane: enabled toggle, executor, running/claimed/blocked counts, last poll, last error or restart reason. Replaces the single-lane landing page. |
| `/lanes/new`, `/lanes/:slug/edit` | `LaneEditorLive` | name, slug, enabled, executor, YAML textarea (front matter), Markdown textarea (prompt), change note. Validate on change through `Config.Schema`; errors inline with the field path. Save inserts a version and applies live. |
| `/lanes/:slug` | `LaneLive` | today's dashboard scoped to one lane: running issues with live activity, blocked, retries, usage totals, rate limits. Subscribes to `lane:<slug>`. |
| `/lanes/:slug/versions` | `LaneVersionsLive` | versions with note and date; "make current" button. |
| `/runs/:attempt_id` | `RunLive` | status, timings, token totals, the `run_events` stream, tail-follows while running. Subscribes to `run:<attempt_id>`. |
| `/login` | controller | single password field. |

### Authentication

- One environment variable, `SYMPHONY_OPERATOR_TOKEN`. Missing or blank: the server refuses
  to start with a message naming the variable, because the UI can now change configuration.
- A plug on the browser pipeline requires a session set by `/login`, which compares the
  submitted value with `Plug.Crypto.secure_compare/2`.
- The same plug accepts `Authorization: Bearer <token>` on every route for scripted use.
- `/api/v1/*` is behind the token too. Response shapes are unchanged except: `state` lists
  all lanes, and `state` and issue responses gain a `lane` field (slug).

### Write API

For automation and the import CLI. All validation errors use the same field-path shape the
form shows.

| method and path | body / result |
|---|---|
| `GET /api/v1/lanes` | list of lanes with current version id, enabled, executor |
| `POST /api/v1/lanes` | `{slug, name, enabled, executor, front_matter, prompt, note}` → 201 with the lane |
| `PUT /api/v1/lanes/:slug` | same fields, all optional; any of `front_matter`/`prompt` present inserts a version |
| `POST /api/v1/lanes/:slug/versions/:id/activate` | rollback / roll forward |
| `GET /api/v1/lanes/:slug/export` | `text/markdown`; the current version as a WORKFLOW.md file |
| `DELETE /api/v1/lanes/:slug` | soft delete; 409 unless disabled with no running agents |

### Live updates

- Orchestrator snapshots publish on `lane:<slug>` through the existing `ObservabilityPubSub`.
- `run_events` inserts broadcast on `run:<attempt_id>`.
- `StatusDashboard` reads snapshots from every Orchestrator registered in `LaneRegistry` and
  renders one block per lane; its `Scope:` line is per lane.

## CLI

```
symphony serve [--data-root <dir>] [--port <port>] [--events-retention-days <n>] \
               --i-understand-that-this-will-be-running-without-the-usual-guardrails
symphony lanes import <WORKFLOW.md> --slug <slug> [--name <name>] [--note <text>] [--data-root <dir>]
symphony lanes export <slug> [--data-root <dir>]
symphony --linear-mcp --workflow <path>        # unchanged: the agent-side MCP server
```

- `--data-root` defaults to the current directory and holds `symphony.sqlite3` and `log/`.
  It replaces `--logs-root`.
- `serve` runs pending migrations, then starts every enabled lane.
- `lanes import` creates the lane if the slug is new (disabled by default, `executor: local`)
  or adds a version and makes it current if the slug exists. It validates through
  `Config.Schema` and exits non-zero with the field errors on failure.
- The `--linear-mcp` mode still takes a workflow file because the agent process needs the
  tracker config without database access. The local executor writes the current lane
  version to `<workspace.root>/.symphony/<slug>/WORKFLOW.md` before spawning the agent and
  passes that path to the MCP command. The minion image does the same in sub-project 2.
- The positional WORKFLOW.md argument to the daemon is removed. Running `symphony <path>`
  prints the new usage and exits non-zero.

## Client migration

Each client today renders three templates and runs three units. After this change:

1. Render the three files as today.
2. Run `symphony lanes import` once per file (`features`, `bugs`, `qa`).
3. Run one `symphony serve` unit with `SYMPHONY_OPERATOR_TOKEN` and the tracker secrets in its
   `EnvironmentFile`.
4. Change the Ansible converge so a prompt or config change calls
   `PUT /api/v1/lanes/:slug` with the token instead of re-rendering and restarting. A config
   change never kills a running agent again.

Workspace roots: each imported lane keeps the `workspace.root` from its file, so existing
per-lane workspace directories keep working and the path-safety checks are unchanged.

## Error handling

- **Invalid lane on save:** rejected with field errors, no version inserted, runtime
  untouched. Closes the "silent rejection, orchestrator looks idle" failure both runbooks
  describe.
- **Invalid current version at boot** (schema changed across upgrades): that lane starts
  disabled with the error on its card and in the log; the other lanes start. Boot is no
  longer halted by one bad config.
- **Tracker preflight** (scope resolution, the existing `preflight/1` callback) runs when a
  lane's runtime starts and after any save that changes the `tracker` section. Failure
  disables the lane and shows the adapter's message. Closes the "wrong slug, zero issues,
  no log" trap.
- **Lane runtime crash:** DynamicSupervisor restarts it with default intensity; the card shows
  restart count and last reason. Repeated crashes exceeding intensity leave the lane stopped
  and marked, not the whole application down.
- **Database unavailable or locked:** `runs` and `run_events` writes are best-effort and
  logged at warning; scheduling never waits on the database. Lane config is read from ETS, so
  a database hiccup cannot stall a poll.
- **Delete:** requires `enabled = false` and no running agents; otherwise 409. Rows are
  soft-deleted so run history keeps its foreign keys. A deleted slug can be reused only after
  a hard purge command, which is out of scope.
- **Guarded field change with active environments:** rejected at save with the identity-guard
  reason, per "Hot apply" above.

## Testing

- **LaneContext:** direct tag, Task.Supervisor child, nested Task, process without a tag
  raising `NoLaneContext`, and two lanes in one VM resolving independently and concurrently.
- **LaneStore and Repo:** a SQLite file in a temp dir per test; no Ecto sandbox needed.
  Import of an invalid file inserts nothing.
- **Orchestrator:** the existing suite runs unchanged against one lane. One new multi-lane
  test proves one lane's crash leaves another's running agents alive and that a save on
  lane A never changes lane B's ETS entry.
- **Hot apply:** a save mid-run leaves the running attempt's settings unchanged and the next
  dispatch on the new ones.
- **LiveView:** Floki tests per view. The editor test round-trips both clients' real rendered
  WORKFLOW.md files (checked in as fixtures with secrets stripped) through import, save,
  export, and asserts byte equality.
- **Auth:** unauthenticated browser and API requests redirect or 401; wrong token 401; boot
  without the token fails.
- **Coverage** stays at 100%. New dependencies: `ecto_sql`, `ecto_sqlite3`. Only generated
  migration modules join the ignore list in `mix.exs`.

## Documentation in the same change

- `SPEC.md`: new section for multi-lane, database-backed configuration and the lane
  lifecycle; drop "rich web UI" from 2.2 Non-Goals; 5.1 file discovery becomes the import
  format contract.
- `elixir/WORKFLOW.md`: becomes the import format reference.
- `elixir/README.md`: `serve`, `lanes import/export`, `SYMPHONY_OPERATOR_TOKEN`, `--data-root`.
- `.claude/docs/architecture.md`, `.claude/docs/configuration.md`: LaneStore, LaneContext,
  LaneSupervisor, hot apply.
- `.claude/docs/deployment.md`: the client migration recipe and the API-driven converge.

## Open items deferred to later sub-projects

- Minion entrypoint, Kubernetes Job executor, per-run tokens, minion event API, re-adoption
  (sub-project 2).
- Manual retry/stop/unpark, prompt diff, cross-lane runs board, hard purge of deleted lanes
  (sub-project 3).
