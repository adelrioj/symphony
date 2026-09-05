# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches the configured agent backend inside the workspace
4. Sends a workflow prompt to the agent
5. Keeps the agent working on the issue until the work is done

The default backend is Codex in
[App Server mode](https://developers.openai.com/codex/app-server/). Symphony also has an optional
Claude backend that runs `claude -p --output-format stream-json`.

During Codex app-server sessions, the selected tracker adapter may advertise provider-native tools.
Linear serves `linear_graphql` and `linear_fetch_attachment`, GitHub Issues serves `github_api`, Jira Cloud serves `jira_rest`,
Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those tools with
configured host-side auth and removes declared tracker-token environment variables from the Codex
child, so the agent does not need a second tracker login. The Claude backend exposes the selected
adapter's tools through Symphony's standalone MCP mode.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If the active backend reports a normalized blocked result, Symphony asks the selected tracker
adapter to post a deterministic comment and move the issue to `agent.blocked_state`; the included
Linear and memory adapters support these writes. Codex app-server approval, input, and MCP
elicitation events instead keep the issue claimed and expose it as blocked in runtime state, the
JSON API, and the dashboard. Those runtime blocked entries are in memory only; restarting the
orchestrator clears them.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` tool for raw Linear GraphQL operations
     such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## Run in Docker (OrbStack-compatible)

One Symphony instance drives one repo. Its Linear read scope is selected by
`tracker.provider.team_keys`, `tracker.provider.current_cycle`, `tracker.provider.project_slug`, or
a combination, optionally narrowed by `tracker.required_labels` / `tracker.any_labels`; at least one
of the three container selectors is required. You may still run one container per project if you
want the isolation. Everything below works as-is with [OrbStack](https://orbstack.dev/) (native
arm64, no platform pins) or Docker Desktop.

### Deploying a project

Deployments live in their own private repos, not in this one. Copy
[`deploy/client-template/`](../deploy/client-template) into a new repo and follow the README in
it: it pulls the published image `ghcr.io/adelrioj/symphony` (built and pushed by
[`.github/workflows/docker-publish.yml`](../.github/workflows/docker-publish.yml)), mounts that
repo's own `workflow.md`, and needs no clone of this repo. Prerequisites, hot reload,
private-repo cloning, GHCR authentication and the security model are documented there; this
section does not repeat them.

### Local development

The repo-root `docker-compose.yml` is local dev only: it builds the image from source and runs
the sanitized `workflows/example.md` in a single `symphony-example` service.

All commands below run **from the repo root** — `cd ..` if you followed the `## Run` section
above, which leaves you in `symphony/elixir`.

1. **Log in to Codex once** on the host — the container mounts the `~/.codex` directory
   read-write, so it shares this login and can refresh the token itself:
   ```bash
   codex login
   ```
2. **Set your Linear key** (git-ignored; `docker compose` auto-loads `.env`):
   ```bash
   cp .env.example .env      # then edit LINEAR_API_KEY
   ```
3. **Edit `workflows/example.md`** — at minimum a scope selector (`tracker.provider.project_slug`,
   `tracker.provider.team_keys`, or `tracker.provider.current_cycle` with `team_keys`) and the
   `hooks.after_create` clone URL. Keep `workspace.root: /workspaces` (it must match the volume
   mount in compose) and `server.host: 0.0.0.0` (see the port note below).
4. **Launch:**
   ```bash
   docker compose up --build          # first build compiles OTP once, then caches it
   ```
   Dashboard: <http://localhost:4000>.

The `workflows/` directory is mounted read-only at `/config` as a *directory*, never as a single
file: a single-file bind mount pins the inode, so an editor's rename-replace on the host stops
propagating and hot reload dies. Editing `workflows/example.md` on the host reloads it in the
running container within about a second.

Compose runs the daemon with the acknowledgement flag Symphony requires in order to start:

```
/config/example.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000 --logs-root /app/elixir
```

Notes:

- **Ports:** the dashboard and JSON API have no authentication, so compose publishes
  `127.0.0.1:4000:4000` — host-side loopback only. Inside the container `server.host` stays
  `0.0.0.0`, which is not a contradiction: Docker forwards the published port to the container's
  network interface, not to its loopback, so a container-side loopback bind would be
  unreachable. Do not widen the host side.
- **Private repos:** `after_create` clones over HTTPS. For a private repo, forward a token into
  the container (add `env_file: .env` to the service) and use it in the clone URL. Symphony runs
  the hook itself through the container's own shell (`sh -lc`), which inherits the container
  environment, so a token in `.env` is expanded in the clone URL. Codex is not involved in the
  clone.
- **The `claude` backend** is not installed in the image; it ships the Codex CLI only. Add the
  `claude` CLI and its auth if you route states to it via `agent.backend_by_state`.

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Required flag:

- `--i-understand-that-this-will-be-running-without-the-usual-guardrails` — daemon mode refuses to
  start without it; it acknowledges that Codex runs with no guardrails. Not required for
  `--linear-mcp`, which serves the Linear MCP tools instead of starting the daemon.

Optional flags:

- `--logs-root` sets the directory Symphony creates `log/` under; it writes
  `<root>/log/symphony.log*` (default root: the working directory, so `./log/symphony.log`).
  Pass the parent, not the log directory itself, or the logs land one level deeper than intended
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
agent session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_turn_exhaustions: 3
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility. `team_keys` and
  `current_cycle` have no flat aliases and are read only from `tracker.provider`.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running.
- `tracker.any_labels` is optional. When set, an issue must have at least one
  configured label to dispatch or continue running. It combines with
  `required_labels` as a conjunction: an issue must satisfy both.
- Both label lists are trimmed, lowercased, and deduplicated when the workflow is loaded, and
  matching ignores case and surrounding whitespace. A blank configured label matches no issue, and
  an empty list imposes no constraint.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back agent turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.max_turn_exhaustions` caps how many agent invocations in a row may end at `agent.max_turns`
  while the issue stays in the same active state. When the cap is hit, Symphony posts a comment and
  moves the issue to `agent.blocked_state` instead of restarting the agent again. This is what stops
  an issue that is too large for its turn budget from looping forever. Default: `3`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Agent backends

`agent.backend` selects the default backend. Supported values are `codex` and `claude`; the default
is `codex`. `agent.backend_by_state` overrides the backend for a tracker state after trimming and
lowercasing the state key. `agent.blocked_state` is where Symphony parks a blocked backend result
after posting the blocked comment when the selected adapter supports tracker writes.

```yaml
agent:
  backend: codex
  backend_by_state:
    implemented: claude
  blocked_state: "Blocked / Needs Attention"
```

The Claude backend is optional. Install and authenticate the `claude` CLI on the orchestrator host
and on any SSH worker that may run Claude-routed issues. Tracker credentials are required only on
the orchestrator host. Claude-specific settings live under the top-level `claude:` block:

```yaml
claude:
  command: claude
  args: []
  linear_mcp_command: /absolute/path/to/symphony
  linear_mcp_args: []
  allowed_tools:
    - mcp__symphony__linear_graphql
    - Read
    - Grep
    - Glob
    - Bash
    - Edit
    - Write
  extra_mcp_servers: {}
```

`extra_mcp_servers` merges additional MCP servers into the generated config, keyed by server name
and holding Claude's own server object (`command`, `args`, `env`). Symphony passes
`--strict-mcp-config`, so this block is the only way to reach a second server and `~/.claude.json`
is ignored. The `symphony` key wins a name collision, so this block cannot displace the tracker
server. Tools from an added server must also be listed in `allowed_tools`, because that list is
passed as `--allowedTools`. `WORKFLOW.md` is the prompt itself, so pass a credential to an added
server through a wrapper script rather than writing it here.

`linear_mcp_command` is an executable path only. Symphony appends the required
`--linear-mcp --workflow <absolute WORKFLOW.md>` flags itself. Claude permission prompts are routed
through `--permission-prompt-tool mcp__symphony__approval_prompt`, not through the normal
`allowed_tools` list.

Claude currently uses the shared `codex.turn_timeout_ms` and `codex.stall_timeout_ms` settings for
turn and stall timeouts.

For SSH workers, each worker must be able to resolve `claude.command` and either
`claude.linear_mcp_command` or `symphony` on `PATH`; worker-side tracker environment variables are
not required. At session start the orchestrator captures adapter-declared tracker secret values and
writes them only into the MCP server `env` inside a private mode-0600 config. The Claude process
inherits those secret names unset and receives no credential in argv, but a compromised Claude
process can read its `--mcp-config` file for the session lifetime. For a remote turn, Symphony sends
the workflow snapshot, MCP config, and prompt as length-prefixed SSH stdin. The remote shell writes
the workflow and config to mode-0600 temporary files, unsets the adapter-declared secret names
before launching Claude, and trap-removes both files on exit. `claude.linear_mcp_args` is inserted
before Symphony's required `--linear-mcp --workflow <worker-temp-WORKFLOW.md>` flags.

The helper mode can also be run directly when debugging MCP wiring:

```bash
./bin/symphony --linear-mcp --workflow /absolute/path/to/WORKFLOW.md
```

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), and optional `assignee` (a Linear user ID or `me`, defaulting to `LINEAR_ASSIGNEE`).
  The read scope comes from `tracker.provider.team_keys` (list of Linear team keys),
  `tracker.provider.current_cycle` (boolean; requires `team_keys`), and
  `tracker.provider.project_slug` (string), plus the core `tracker.required_labels` /
  `tracker.any_labels` lists. At least one of those three container selectors is required —
  labels narrow a container, they do not define one. `team_keys` must be a list of non-empty
  strings and `current_cycle` must be a boolean; `current_cycle: true` without `team_keys` is
  rejected, because an unqualified active-cycle filter would match the active cycle of every team
  the token can see.
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported; `team_keys` and `current_cycle` have none. `required_labels`, `any_labels`,
  `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured scope and the requested state names,
  following Linear pages of 50 (nested relation pages of 50, attachment pages of 25). ID refreshes
  apply no scope at all — they filter on the requested IDs only — and batch up to 50 IDs per
  request. Empty state/ID lists return `{:ok, []}` without a Linear request. Team keys, label
  names, and state names are matched case-insensitively (`eqIgnoreCase`), several team keys are an
  `or` list, `any_labels` is one `or` list, and each `required_labels` entry is its own mandatory
  conjunct. `project_slug` is trimmed before it is queried and before it is displayed, so a
  configured slug with stray whitespace resolves to the trimmed value instead of silently matching
  nothing.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, the label policy, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. The configured scope governs scheduler reads, not raw tool calls; the tool can
  access whatever the configured Linear token can access.
- Attachments: the poll query also fetches issue `attachments` (title + url) onto the normalized
  `Issue`, and the default prompt lists them. The adapter advertises `linear_fetch_attachment`,
  which downloads an `https://uploads.linear.app/...` attachment with the configured token and
  returns its UTF-8 contents to the agent. It rejects non-Linear hosts, caps downloads at 1 MiB,
  and rejects non-text payloads (`{:error, :missing_url}`, `{:error, :invalid_attachment_url}`,
  `{:error, :attachment_too_large}`, `{:error, :attachment_not_text}`, plus the shared
  `{:error, :missing_linear_api_token}` / `{:error, {:linear_api_status, status}}` /
  `{:error, {:linear_api_request, reason}}`).
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_scope}`,
  `{:error, :missing_linear_team_keys}`, `{:error, :invalid_linear_team_keys}`,
  `{:error, :invalid_linear_current_cycle}`, `{:error, {:linear_preflight_failed, reasons}}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, scope, team keys, current cycle, endpoint,
  assignee, or viewer errors to `tracker_config` or `tracker_auth` — `:missing_linear_scope`,
  `:missing_linear_team_keys`, `:invalid_linear_team_keys`, `:invalid_linear_current_cycle`, and
  `{:linear_preflight_failed, reasons}` are all `tracker_config` — request failures to
  `tracker_transport`, non-200 responses to `tracker_response` (`429` is `tracker_rate_limited`),
  GraphQL/unknown payload failures to `tracker_payload`, and missing cursors to
  `tracker_pagination`; logs and tool responses carry the human-readable provider detail.
- Startup preflight: when `team_keys` is configured, the adapter resolves the scope against Linear
  once before the scheduling loop starts, in at most two requests regardless of how many values are
  configured — one `teams` query carrying each team's `activeCycle` and workflow states, and, only
  when a label list is non-empty, one `issueLabels` query filtered by the configured label names.
  `activeCycle` is a single object rather than a connection, so selecting it is free against
  Linear's complexity budget; only its `id` is read, purely as a presence marker.
  Every unresolved value is reported together in one `{:linear_preflight_failed, reasons}` error
  rather than one per boot. The one exception: when *no* configured team key resolves at all, the
  error lists only the team keys, because every state and label would then be reported absent too
  and would bury the single actionable reason.
  An unresolvable team key fails the boot, because that is a typo rather
  than a state. A configured state name or label absent from *all* listed teams also fails the boot,
  because it can never match; absent from only *some* listed teams is a warning naming those teams,
  because those conjuncts are ANDed with the team conjunct and the remaining teams still match. A
  `required_labels` warning says explicitly that the named teams will contribute no issues at all,
  since a required label is a mandatory conjunct; an `any_labels` warning says only that those
  teams match nothing for it. A team whose workflow-states page comes back full — the page size is
  pinned by a named module attribute, currently 50, because Linear's query complexity is
  multiplicative across nested connections — makes absence unprovable, so that warns instead of
  failing. A listed team with no active cycle warns and boots: an absent active cycle is a normal
  Linear state during sprint cooldown, and refusing to start would turn a routine condition into an
  outage. With `project_slug` as the only selector there is nothing to resolve and preflight makes
  no request — an unknown slug still fails silently, because Linear returns zero issues for it.
- No active cycle at runtime: the poll simply returns zero issues and the instance idles. No
  per-tick probe is spent and no repeated warning is emitted, because cycles legitimately end.
  Operator visibility is the boot warning plus the status board's `Scope:` line.
- Scope on the status board: the adapter implements the optional `Tracker.scope_summary/1`
  callback, so the board renders an unconditional `Scope:` line — for example
  `teams ENG, OPS · current cycle · required labels agent`. Label names render lowercase because
  both label lists are normalized when the workflow is loaded. A tracker that reports no scope
  renders the sentinel `n/a`. There is no project link: a real Linear project URL is
  workspace-prefixed and no workspace slug exists anywhere in the config, so the old
  `https://linear.app/project/<slug>/issues` line was always broken and has been removed.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- **Known deviation from `SPEC.md` §11.1, fix pending.** §11.1 requires that an ID refresh apply no
  configured scope selection as a filter, and exempts only an adapter that cannot produce a complete
  normalized snapshot outside its container. This adapter fits neither: the bulk-fetch request is
  already unscoped and its `issue.id` is Jira's global immutable ID, yet the response is then
  filtered by project key. Consequence: an issue moved out of the configured project while an agent
  is running on it is reported as missing rather than as still-live, so the orchestrator releases
  the claim and stops the run. Candidate-read scoping is correct and unaffected. The fix is a code
  change outside the scope of the change that amended §11.1, so it is recorded here per §11.2 rather
  than left as an undocumented conflict.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes. That omission is `SPEC.md` §11.1's
  container-bound case rather than a deviation: a task's normalized `state` is the name of its
  section *within the configured project*, so outside that project there is no state to report and
  no complete snapshot to return.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
