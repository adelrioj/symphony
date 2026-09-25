# Architecture

Paged out of the root `CLAUDE.md`. Read this when touching the supervision tree, the
orchestrator, tracker adapters, agent backends, or the repo-local Codex skills.

`SymphonyElixir.Application` (in `lib/symphony_elixir.ex`) starts a **`:rest_for_one`** tree, in order:
`Phoenix.PubSub` → `Repo` → `Runs` (`Writer` → `Retention`) → `LaneRegistry` →
`LaneSupervisor` → `LaneStore` → `HttpServer` → `StatusDashboard`.
`Runs` also uses `:rest_for_one`, keeping the ordered writer ahead of retention.

`LaneSupervisor` dynamically owns one temporary `AgentRuntimeSupervisor` per enabled lane.
Each runtime is **`:one_for_all`** over `Task.Supervisor` + `Orchestrator`: agent tasks must not
outlive their claim authority. Registry keys are `{lane_id, :runtime | :tasks | :orchestrator}`.
A runtime failure tears down that lane's agents, not other lanes. `LaneStore`, not the dynamic
supervisor, monitors/restarts temporary children; the fifth abnormal runtime death within 60 seconds
persistently disables the lane and publishes its error. Explicit stops do not consume this allowance.
Stops drain accepted supervisor start requests before resolving and terminating a runtime, including
requests from a dead store authority. A monitored `:shutdown` is a failure; administrative stops flush monitors.
Crash-window counters are in memory; the disabled flag is durable.

`ExecutionProfiles` persists reusable worker, credential-reference, and workspace-base settings.
`LaneStore` owns validated ETS entries plus serialized lane/profile mutation and atomic batch
publication. It reserves dispatch locations before workspace creation and guards local, SSH, and
managed identities until authoritative cleanup. Startup validates all restored locations together and
keeps legacy overlaps disabled for repair. It also owns asynchronous preflight generations and runtime
monitoring; stale checks cannot start, disable, or attach a runtime.

`LaneContext.put/1` tags long-lived lane processes. Ordinary lane reads use the current store entry;
the orchestrator captures a complete immutable entry before each dispatch, including retries, and
installs it in the worker and attempt helpers. Deferred completion work also keeps that attempt's
settings. `Config` and `Workflow.current/0` resolve through this context; there is no default lane.
Claude's private MCP workflow snapshot comes from `Workflow.current_content/0`, not a watched file.

`Application.start/2` also branches on `__BURRITO=1`: inside a packaged binary it runs `CLI.main/2` rather than the runtime directly.

Request/work flow:

1. **`Orchestrator`** (`lib/symphony_elixir/orchestrator.ex`) — one stateful polling `GenServer` per lane. Its `State` owns `running`, `claimed`, `completed`, `blocked`, `retry_attempts`, `turn_exhaustions`, and `codex_totals`/`codex_rate_limits`. It dispatches up to the lane's concurrency limit and owns retry/reconciliation/cleanup. **This state is concurrency-sensitive.** Scheduler state is in memory and rebuilt from the tracker on restart, never replayed from run history. Turn-budget exhaustion parks stuck issues via `BlockedIssue`.
2. **`Tracker`** (`lib/symphony_elixir/tracker.ex`) — the tracker behaviour selects `asana`, `github`, `gitlab`, `jira`, `linear`, or `memory` (tests). Scheduling uses `fetch_issues_by_states/1` and `fetch_issues_by_ids/1`; agent mutations use `agent_tool_specs/0` and `execute_agent_tool/3`. Optional `preflight/1` runs before a lane runtime starts and after tracker edits; failure disables only that lane. Optional `scope_summary/1` supplies the status scope, falling back to `n/a`. Do not branch on adapters in scheduler policy.
3. **`Agent`** (`lib/symphony_elixir/agent.ex`) — the coding-agent behaviour: `start_session/2`, `run_turn/4`, `stop_session/1`, normalized into `Agent.Result` (`:done | :blocked`, tokens, `blocked_action`). `Agent.module_for/1` maps `agent.backend` → `Agent.Codex` (thin wrapper over `Codex.AppServer`) or `Agent.Claude` (spawns the Claude Code CLI and parses its stream in `agent/claude/stream.ex`). `agent.backend_by_state` overrides the backend per issue state. **Add a backend here** — never by branching inside `AgentRunner`.
4. **`AgentRunner`** (`lib/symphony_elixir/agent_runner.ex`) — runs one issue end-to-end: selects a worker host from `worker.ssh_hosts`, creates the workspace, runs `before_run`/`after_run` hooks, and drives turns (`max_turns` cap per invocation). It owns the multi-turn continuation loop; backends only execute single turns. When it hits that cap with the issue still active it sends `{:agent_turns_exhausted, issue_id, state}` to the orchestrator, which owns the cross-run give-up policy. One worker lifetime never hops machines — the orchestrator owns host retries.
5. **`Workspace`** (`lib/symphony_elixir/workspace.ex`) — creates/cleans per-issue workspaces and runs lifecycle hooks (`after_create`, `before_remove`). **Safety-critical:** workspaces must stay under the configured workspace root, and a turn's cwd must never be the source repo. Path checks live in `path_safety.ex`. `elixir/WORKFLOW.md` wires `mix workspace.before_remove` into the `before_remove` hook to close the branch's open PRs; that task defaults to the hardcoded repo `openai/symphony`, so any other deployment must pass `--repo`.
6. **`Codex.AppServer`** (`lib/symphony_elixir/codex/app_server.ex`) — JSON-RPC 2.0 client over the Codex app-server stdio stream. Manages session/thread/turn lifecycle and sandbox/approval policy, and serves client-side tools via `codex/dynamic_tool.ex`. **That dispatcher is tracker-agnostic** — it forwards to whichever adapter is configured; `linear_graphql` is simply the tool Linear's adapter exposes (`linear/agent_tool.ex`). Workers may be local or remote over SSH (`ssh.ex`).
7. **`SymphonyElixirWeb`** (`lib/symphony_elixir_web/`) — Phoenix/Bandit with lane list/detail/editor/history views, execution-profile list/detail/editor views under `/execution-profiles`, `RunLive`, and authenticated lane/profile JSON APIs. `Plugs.Authenticate` protects browser/API requests, `LiveAuth` gates LiveView sessions, and `/login` exchanges the operator credential for a signed session. Cookie writes/login require CSRF; explicit bearer API calls do not. `serve` starts HTTP on port 4000 by default.
8. **`Runs`** (`lib/symphony_elixir/runs.ex`) — ordered asynchronous writes persist attempts and events without blocking the scheduler. Attempts capture lane version/executor at dispatch. Disable finalizes running attempts as stopped; abnormal runtime death as failed. Database failures are logged and pending writes are volatile, not retried. `Runs.Retention` prunes only old events (first pass after one minute, then daily); run summaries and versions remain.

## Repo-local Codex skills

`.codex/skills/` holds repo-local skills (`commit`, `push`, `pull`, `land`, `linear`, `debug`, `release`) that the running Codex agent uses. The `linear` skill depends on the `linear_graphql` tool described above, so it works only when the configured tracker is `linear`.
