# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

This repo is two things:

- **`SPEC.md`** (repo root) — the language-agnostic specification of Symphony. It is the source of truth.
- **`elixir/`** — the reference implementation (Elixir/OTP). It may be a *superset* of the spec but must never *conflict* with it. When an implementation change meaningfully alters intended behavior, update `SPEC.md` in the same change.

Symphony orchestrates autonomous coding work: it polls an issue tracker (Linear), creates an isolated workspace per issue, and runs Codex in [app-server mode](https://developers.openai.com/codex/app-server/) inside that workspace until the issue reaches a terminal state.

**Nearly all development happens in `elixir/`.** Read `elixir/AGENTS.md` first — it carries the authoritative implementation rules (the most important ones are summarized below).

## Commands

Run all `mix` commands from the `elixir/` directory. Toolchain (Elixir 1.19.x / OTP 28) is pinned via `mise` (`mise.toml`); prefix with `mise exec --` if not using a mise-activated shell.

```bash
mix setup                 # install deps (alias for deps.get)
mix build                 # escript.build -> bin/symphony
mix test                  # full suite
mix test path/to/file_test.exs            # single file
mix test path/to/file_test.exs:42         # single test by line number
mix test --cover          # coverage (threshold is 100% — see mix.exs)
mix lint                  # specs.check + credo --strict
mix format                # apply formatting (line_length: 200)
mix specs.check           # enforce @spec on public functions (see rule below)
```

The `make` targets wrap these. The full quality gate before handoff:

```bash
make all        # == make ci: setup, build, fmt-check, lint, coverage, dialyzer
```

CI runs `make all` (`.github/workflows/make-all.yml`). PR descriptions are linted against `.github/pull_request_template.md` (`pr-description-lint.yml`); validate locally with `mix pr_body.check --file <path>`.

The live external end-to-end test is opt-in (it creates real Linear resources and launches a real Codex session):

```bash
export LINEAR_API_KEY=...
make e2e        # SYMPHONY_RUN_LIVE_E2E=1; targets test/symphony_elixir/live_e2e_test.exs
```

## Running the service

```bash
./bin/symphony ./WORKFLOW.md          # defaults to ./WORKFLOW.md if no path given
./bin/symphony ./WORKFLOW.md --port 4000   # also start the Phoenix dashboard + JSON API
```

`LINEAR_API_KEY` must be set for the `linear` tracker. `--logs-root` overrides the log directory (default `./log`).

One instance drives one project (a single `tracker.project_slug` + one repo). To run several projects, run one container per project via the repo-root Docker Compose setup (`docker/Dockerfile`, `docker-compose.yml`, `workflows/*.md`, `.env.example`) — one service per `WORKFLOW.md`, each with its own port and workspace/log volumes. OrbStack-compatible (no platform pins). Steps are in `elixir/README.md` ("Run several projects"). The image pins its toolchain from `elixir/mise.toml`; keep those two in sync.

## Architecture

The OTP supervision tree (`SymphonyElixir.Application`, `:one_for_one`) starts, in order:
`Phoenix.PubSub` → `Task.Supervisor` → `WorkflowStore` → `Orchestrator` → `HttpServer` → `StatusDashboard`.

Request/work flow:

1. **`Orchestrator`** (`lib/symphony_elixir/orchestrator.ex`) — the heart of the system. A single stateful `GenServer` running a polling loop. It holds all live state in its `State` struct (`running`, `claimed`, `completed`, `blocked`, `retry_attempts`, token/rate-limit totals), dispatches issues up to `max_concurrent_agents`, and owns retry/reconciliation/cleanup. **This state is concurrency-sensitive** — preserve retry, reconciliation, and cleanup semantics when editing. Blocked entries live in memory only and are cleared on restart.
2. **`Tracker`** (`lib/symphony_elixir/tracker.ex`) — a behaviour defining the tracker boundary. `Config.tracker.kind` selects the adapter: `"linear"` → `Linear.Adapter` (`lib/symphony_elixir/linear/`), `"memory"` → `Tracker.Memory` (used in tests). Add tracker capabilities via this behaviour, not direct calls.
3. **`AgentRunner`** (`lib/symphony_elixir/agent_runner.ex`) — runs one issue end-to-end: selects a worker host, creates the workspace, runs `before_run`/`after_run` hooks, and drives Codex turns (`max_turns` cap per invocation).
4. **`Workspace`** (`lib/symphony_elixir/workspace.ex`) — creates/cleans per-issue workspaces and runs lifecycle hooks (`after_create`, `before_remove`). **Safety-critical:** workspaces must stay under the configured workspace root, and a Codex turn cwd must never be the source repo. Path checks live in `path_safety.ex`.
5. **`Codex.AppServer`** (`lib/symphony_elixir/codex/app_server.ex`) — JSON-RPC 2.0 client over the Codex app-server stdio stream. Manages session/thread/turn lifecycle, sandbox/approval policy, and serves a client-side `linear_graphql` dynamic tool (`codex/dynamic_tool.ex`) so repo skills can make raw Linear GraphQL calls. Workers may be local or remote over SSH (`ssh.ex`).
6. **`SymphonyElixirWeb`** (`lib/symphony_elixir_web/`) — optional Phoenix/Bandit observability layer: LiveView dashboard at `/`, JSON API under `/api/v1/*`. Only started when a port is configured.

### Configuration system

Runtime config is **not** read from env ad hoc. `WORKFLOW.md` is parsed as YAML front matter + a Markdown prompt body:

`Workflow` (loads/reloads the file) → `Config` (`config.ex`, the access layer) → `Config.Schema` (`config/schema.ex`, parse + validation + defaults).

- Always add config access through `SymphonyElixir.Config`, never ad-hoc env reads.
- Front matter covers `tracker`, `polling`, `workspace`, `hooks`, `agent`, `codex`, `server`. The Markdown body is the Codex session prompt (Solid/Liquid templating, e.g. `{{ issue.identifier }}`); a default template is used if blank.
- Safer Codex defaults apply when policy fields are omitted (see `elixir/README.md` "Configuration"). Workflows running package managers must set `networkAccess: true` in `codex.turn_sandbox_policy`.
- On startup, invalid/missing `WORKFLOW.md` halts boot. On hot reload, a bad file is ignored and the last-known-good config is kept (the BEAM hot-reloads without stopping active agents).

## Key implementation rules (from `elixir/AGENTS.md`)

- Every public function (`def`) in `lib/` needs an adjacent `@spec`. `defp` and `@impl` callbacks are exempt. Enforced by `mix specs.check`.
- Keep changes narrowly scoped; avoid unrelated refactors. Match existing patterns in `lib/symphony_elixir/*`.
- Follow `docs/logging.md` (under `elixir/`): include `issue_id` + `issue_identifier` for issue events and `session_id` for Codex lifecycle events.
- Coverage threshold is 100% (`mix.exs` lists explicitly ignored modules — prefer adding tests over expanding that list).
- When behavior/config changes, update docs in the same PR: root `README.md` (concept), `elixir/README.md` (run instructions), `elixir/WORKFLOW.md` (workflow/config contract).

## Repo-local Codex skills

`.codex/skills/` holds repo-local skills (`commit`, `push`, `pull`, `land`, `linear`, `debug`) that the running Codex agent uses. The `linear` skill depends on the `linear_graphql` app-server tool described above.
