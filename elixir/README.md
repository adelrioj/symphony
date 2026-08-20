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

One Symphony instance is scoped to one repo, and its Linear scope is either a single
`tracker.provider.project_slug` or one or more `tracker.provider.team_keys` plus optional
`tracker.any_labels`. Team scoping lets tickets from any project qualify without a config
change; project scoping does not. To orchestrate several repos, run one container per repo.
Everything below works as-is with [OrbStack](https://orbstack.dev/) (native arm64, no platform
pins) or Docker Desktop.

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
3. **Edit `workflows/example.md`** — at minimum `tracker.provider.project_slug` and the
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
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- `tracker.any_labels` is optional. When set, an issue must have at least one of the
  configured labels to dispatch or continue running. It composes with `required_labels` as
  a conjunction: all required labels AND at least one of these. Matching ignores case and
  surrounding whitespace.
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
```

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
  `$VAR`), a scope — `team_keys` (list of Linear team keys such as `["MDZ"]`, the prefix in
  issue identifiers like `MDZ-14`), `project_slug`, or both, at least one required — and
  optional `assignee` (a Linear user ID or `me`, defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported; `team_keys` is provider-only. `required_labels`, `any_labels`, `active_states`, and
  `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured scope and requested state names,
  following Linear pages of 50. Scope is `provider.team_keys`, `provider.project_slug`, or both;
  at least one is required, and both together are a conjunction. Team keys, label names, and
  state names are compared case-insensitively. ID refreshes apply the same scope and batch up to
  50 IDs. Empty state/ID lists return `{:ok, []}` without a Linear request.
- Preflight: at startup the adapter resolves the configured team keys, `active_states`,
  `terminal_states`, and label names against Linear and fails startup listing every value that
  does not resolve, not just the first. This exists because an unknown scope selector returns an
  empty result set rather than an error. Label resolution is scoped to the listed teams: a label
  present in at least one of them resolves, a label that exists only in some other team does not,
  and a workspace-level label (belonging to no team) counts as present in every team. This check
  runs only when `team_keys` is set; project-only deploys are unaffected.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `team_keys` and `project_slug` scope scheduler reads, not raw tool calls; the tool
  can access whatever the configured Linear token can access.
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
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`,
  `{:error, {:linear_preflight_failed, reasons}}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

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
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
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
