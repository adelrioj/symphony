# Architecture

Paged out of the root `CLAUDE.md`. Read this when touching the supervision tree, the
orchestrator, tracker adapters, agent backends, or the repo-local Codex skills.

`SymphonyElixir.Application` (in `lib/symphony_elixir.ex`, not its own file) starts a `:one_for_one` tree:
`Phoenix.PubSub` → `WorkflowStore` → `AgentRuntimeSupervisor` → `HttpServer` → `StatusDashboard`.

`AgentRuntimeSupervisor` is **`:one_for_all`** over `Task.Supervisor` + `Orchestrator`. That coupling is deliberate: agent tasks must not outlive the orchestrator that tracks them, so an orchestrator crash tears down every in-flight agent. Don't "fix" it to `:one_for_one` — you would strand running agents with no claim authority.

`Application.start/2` also branches on `__BURRITO=1`: inside a packaged binary it runs `CLI.main/2` rather than the runtime directly.

Request/work flow:

1. **`Orchestrator`** (`lib/symphony_elixir/orchestrator.ex`) — the heart of the system. A single stateful `GenServer` running a polling loop. It holds all live state in its `State` struct (`running`, `claimed`, `completed`, `blocked`, `retry_attempts`, `codex_totals`/`codex_rate_limits`), dispatches issues up to `max_concurrent_agents`, and owns retry/reconciliation/cleanup. **This state is concurrency-sensitive** — preserve retry, reconciliation, and cleanup semantics when editing. Blocked entries live in memory only and are cleared on restart.
2. **`Tracker`** (`lib/symphony_elixir/tracker.ex`) — the tracker behaviour. `Config.tracker.kind` selects from the `@adapters` map: `asana`, `github`, `gitlab`, `jira`, `linear`, and `memory` (tests). Add tracker capabilities via this behaviour, not direct calls. The orchestrator depends only on the read callbacks (`fetch_issues_by_states/1`, `fetch_issues_by_ids/1`); agent-side mutations stay behind the optional provider-native tool callbacks (`agent_tool_specs/0`, `execute_agent_tool/3`) so tracker specifics never leak into scheduler policy.
3. **`Agent`** (`lib/symphony_elixir/agent.ex`) — the coding-agent behaviour: `start_session/2`, `run_turn/4`, `stop_session/1`, normalized into `Agent.Result` (`:done | :blocked`, tokens, `blocked_action`). `Agent.module_for/1` maps `agent.backend` → `Agent.Codex` (thin wrapper over `Codex.AppServer`) or `Agent.Claude` (spawns the Claude Code CLI and parses its stream in `agent/claude/stream.ex`). `agent.backend_by_state` overrides the backend per issue state. **Add a backend here** — never by branching inside `AgentRunner`.
4. **`AgentRunner`** (`lib/symphony_elixir/agent_runner.ex`) — runs one issue end-to-end: selects a worker host from `worker.ssh_hosts`, creates the workspace, runs `before_run`/`after_run` hooks, and drives turns (`max_turns` cap per invocation). It owns the multi-turn continuation loop; backends only execute single turns. One worker lifetime never hops machines — the orchestrator owns host retries.
5. **`Workspace`** (`lib/symphony_elixir/workspace.ex`) — creates/cleans per-issue workspaces and runs lifecycle hooks (`after_create`, `before_remove`). **Safety-critical:** workspaces must stay under the configured workspace root, and a turn's cwd must never be the source repo. Path checks live in `path_safety.ex`. `elixir/WORKFLOW.md` wires `mix workspace.before_remove` into the `before_remove` hook to close the branch's open PRs; that task defaults to the hardcoded repo `openai/symphony`, so any other deployment must pass `--repo`.
6. **`Codex.AppServer`** (`lib/symphony_elixir/codex/app_server.ex`) — JSON-RPC 2.0 client over the Codex app-server stdio stream. Manages session/thread/turn lifecycle and sandbox/approval policy, and serves client-side tools via `codex/dynamic_tool.ex`. **That dispatcher is tracker-agnostic** — it forwards to whichever adapter is configured; `linear_graphql` is simply the tool Linear's adapter exposes (`linear/agent_tool.ex`). Workers may be local or remote over SSH (`ssh.ex`).
7. **`SymphonyElixirWeb`** (`lib/symphony_elixir_web/`) — optional Phoenix/Bandit observability layer: LiveView dashboard at `/`, JSON API under `/api/v1/*`. Only started when a port is configured.

## Repo-local Codex skills

`.codex/skills/` holds repo-local skills (`commit`, `push`, `pull`, `land`, `linear`, `debug`, `release`) that the running Codex agent uses. The `linear` skill depends on the `linear_graphql` tool described above, so it works only when the configured tracker is `linear`.
