# Per-stage Claude agent backend for Symphony — Design

**Date:** 2026-06-21
**Status:** Design (approved for planning)
**Author:** adelrio

## Problem

Symphony launches exactly one agent: it runs the single global `codex.command`
via `bash -lc` and drives it over the Codex app-server JSON-RPC protocol
(`lib/symphony_elixir/codex/app_server.ex`). Per-status behavior is achieved
only by injecting `{{ issue.state }}` into the prompt and letting that one codex
agent branch internally (confirmed in `docs/superpowers/plans/spike-findings.md`,
Q1).

The autonomous PR pipeline wants a stage (`Implemented` → review-pr) to run
**Claude Code** (`claude -p`) instead of codex. The spike's interim workaround
was "codex shells out to `claude -p` as a subprocess." This design replaces that
workaround with **per-stage agent choice**: Symphony itself selects codex *or*
claude as a first-class backend based on the ticket's current status.

## Goal & shape

A **pluggable agent layer** with two adapters behind one behaviour, selected
per issue state via config. Both adapters return the same normalized result, so
the orchestrator, dashboard, and `AgentRunner` are agnostic to which agent ran.
Explicitly **not** a generic registry for arbitrary future agents (YAGNI) and
**not** codex-wrapping-claude.

The Claude adapter reaches **full parity** with the codex path: live token
tracking, blocked/elicitation detection, and access to the `linear_graphql`
tool — achieved without Symphony hosting a live in-process tool bridge.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Abstraction | **`SymphonyElixir.Agent` behaviour + `Agent.Result` struct** | Mirrors the existing `Tracker` behaviour idiom already in the repo. One normalized result shape keeps callers backend-agnostic. |
| Backend selection | **`agent.backend` + `agent.backend_by_state` config** | Copies the existing `Config.max_concurrent_agents_for_state/1` per-state pattern. No prompt-routing hacks, no shell-out. |
| Codex path | **Refactor `Codex.AppServer` behind an `Agent.Codex` adapter** | It already produces tokens/session/result; the adapter only normalizes the return shape. Minimal change. |
| Claude path | **New `Agent.Claude` adapter launching `claude -p --output-format stream-json`** | Parses Claude's event stream into `Agent.Result`. All Claude-specific logic isolated in one testable module. |
| `linear_graphql` for Claude | **Standalone MCP server (a mode of the `symphony` escript), wired via `--mcp-config`** | `DynamicTool`/`linear_graphql` is stateless (just forwards `{query, variables}` to `Linear.Client.graphql/3` with `LINEAR_API_KEY`). No shared session state to bridge, so an in-process MCP bridge buys nothing. |
| Blocked detection (Claude) | **A deny-by-default `approval_prompt` MCP tool + `--permission-prompt-tool`, observed via stream-json** | Claude routes every permission request to that tool; the resulting `tool_use` in the stream is Symphony's blocked signal. Keeps Symphony out of live tool routing while preserving parity. |

## Architecture

### The `Agent` boundary

New behaviour `SymphonyElixir.Agent`:

```elixir
@callback run(workspace :: Path.t(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
            {:ok, Agent.Result.t()} | {:error, term()}
```

Normalized result — the single shape every caller consumes regardless of backend:

```elixir
%SymphonyElixir.Agent.Result{
  status: :done | :blocked | :error,   # :blocked = needs human/approval (parked, NOT failed)
  session_id: String.t() | nil,
  tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
  seconds_running: non_neg_integer(),
  summary: String.t() | nil            # text used for the Linear audit comment
}
```

`:blocked` is first-class because Symphony already separates "parked / needs
human" (neither active nor terminal — workspace preserved) from "failed". The
result type makes that distinction explicit at the boundary instead of leaving
it implicit in codex event handling.

### Backend selection

`AgentRunner.run` resolves a backend module by the issue's current state and
calls `backend.run(workspace, prompt, issue, opts)` instead of calling
`Codex.AppServer` directly. Resolution reuses the
`Config.max_concurrent_agents_for_state/1` pattern:

- `agent.backend` — global default, `"codex"`.
- `agent.backend_by_state` — per-state override map (e.g. `{"implemented": "claude"}`),
  normalized with the same `Schema.normalize_issue_state/1` helper.
- `Config.agent_backend_for_state/1` returns `"codex" | "claude"`;
  `AgentRunner` maps that to `Agent.Codex` / `Agent.Claude`. An unknown backend
  name is a config error surfaced at validation time, not at dispatch.

```
WORKFLOW.md:
agent:
  backend: codex
  backend_by_state:
    implemented: claude
```

### Component layout

```
AgentRunner.run
  └─ backend = Config.agent_backend_for_state(issue.state)   # "codex" | "claude"
       ├─ Agent.Codex.run   ── wraps existing Codex.AppServer, returns Agent.Result
       └─ Agent.Claude.run  ── launches `claude -p`, parses stream-json → Agent.Result
                                 ├─ standalone linear_graphql MCP server (escript mode) via --mcp-config
                                 └─ approval_prompt MCP tool via --permission-prompt-tool (blocked signal)
```

## The Claude adapter (`Agent.Claude`)

### Launch

Launches Claude in headless streaming mode in the issue workspace (local via
`bash -lc`, remote via the existing `SSH.start_port`, exactly as
`Codex.AppServer.start_port/2` already branches on `worker_host`):

```
claude -p "<prompt>" \
  --output-format stream-json --verbose \
  --mcp-config <symphony-linear-mcp.json> \
  --permission-prompt-tool mcp__symphony__approval_prompt \
  --allowedTools mcp__symphony__linear_graphql ...
```

`--input-format`/prompt delivery and the exact `--allowedTools` set are confirmed
against the installed Claude CLI during implementation (see Open items).

### Stream parsing → `Agent.Result`

Claude emits newline-delimited JSON events. The adapter folds them into a result:

- **`assistant` / `user` events** — accumulate text for `summary`; detect
  `tool_use` blocks.
- **`tool_use` for `mcp__symphony__approval_prompt`** — Claude asked for a
  permission Symphony denies → mark `status: :blocked` with the requested action
  in `summary`.
- **final `result` event** — `usage` → `tokens`; `duration_ms` → `seconds_running`;
  `is_error` / `subtype` → status:
  - `subtype: "success"`, `is_error: false`, not already blocked → `:done`
  - `subtype: "error_max_turns"` or `"error_during_execution"`, or `is_error: true` → `:error`
- **process exit** — nonzero exit with no parseable `result` → `:error` with the
  captured tail of stderr.

Token totals feed the same orchestrator `codex_totals` accumulator the dashboard
already renders (the field stays named as-is to avoid churn; it now means
"agent totals").

### Timeouts

Reuse the existing codex timeout knobs (`turn_timeout_ms`, `read_timeout_ms`,
`stall_timeout_ms`) as shared agent timeouts rather than introducing parallel
claude-specific ones.

## The `linear_graphql` MCP server

A new escript mode of the existing `symphony` binary, e.g.
`./bin/symphony --linear-mcp`, that speaks the MCP stdio protocol and exposes:

- **`linear_graphql`** — same name/description/input schema as
  `Codex.DynamicTool.tool_specs/0`; forwards `{query, variables}` to
  `Linear.Client.graphql/3` using `LINEAR_API_KEY`. The tool body is the existing
  `DynamicTool.execute/3` logic, reused — not reimplemented.
- **`approval_prompt`** — deny-by-default. Returns a denial and is the marker
  Symphony watches for in the stream to set `:blocked`.

Because the tool is stateless, this standalone server is functionally identical
to what codex gets in-process, and is independently testable. (Future
convergence — pointing codex at this same MCP server and deleting the in-process
`DynamicTool` path — is explicitly out of scope here.)

`Agent.Claude` writes the `--mcp-config` JSON (pointing at
`./bin/symphony --linear-mcp` with `LINEAR_API_KEY` in its env) into the
workspace before launching Claude.

## Config changes (`config/schema.ex`)

Add to the `Agent` embedded schema:

- `backend` — string, default `"codex"`, validated in `["codex", "claude"]`.
- `backend_by_state` — map, default `%{}`, normalized + validated like
  `max_concurrent_agents_by_state` (state names normalized; values in the allowed
  backend set).

Add to the `Codex` schema or a shared spot a `claude` command override (default
`"claude"`) so the Claude binary/flags are configurable the way `codex.command`
is, including `$VAR` expansion through the launched shell.

Semantic validation (`Config.validate!`): every value in `backend_by_state` and
`backend` must be a known backend; fail boot on an unknown name with a clear
message, consistent with existing `format_config_error/1`.

## Error handling & blocked semantics

- `:done` → `AgentRunner`/workflow advances status as today.
- `:blocked` → workflow sets a parked status (`Blocked / Needs Attention` /
  `Human Review` per the pipeline design) and posts the requested action as a
  Linear comment. Workspace preserved (already how neither-states behave).
- `:error` → existing orchestrator retry/backoff applies; the agent run raises
  as it does now so supervised retry semantics are unchanged.
- Audit trail unchanged: `summary` becomes the Linear progress comment for both
  backends. Logging follows `docs/logging.md` — include `issue_id`,
  `issue_identifier`, and `session_id` for Claude runs (use Claude's
  `session_id` from the stream-json `system`/`result` event).

## Testing

- **`Agent.Claude` stream parsing** — unit tests over recorded stream-json
  fixtures (under `test/fixtures/`): success, max-turns error, mid-run
  `approval_prompt` (blocked), malformed/truncated stream, nonzero exit. Assert
  the resulting `Agent.Result` for each. No real Claude process.
- **Backend selection** — `Config.agent_backend_for_state/1` unit tests
  (default, per-state override, normalization, unknown-name validation error)
  mirroring the existing `max_concurrent_agents_for_state` tests.
- **`linear_graphql` MCP server** — reuse/extend `Codex.DynamicTool` tests
  against the shared execute logic; an MCP-protocol smoke test for the stdio
  framing.
- **`AgentRunner`** — with the `memory` tracker and a stub `Agent` implementation,
  assert it selects the configured backend per state and maps `Agent.Result`
  status to the right outcome.
- **Coverage** — the project enforces 100%; add the new modules to tests rather
  than to `mix.exs`'s `ignore_modules`. Public `def`s in `lib/` get `@spec`
  (enforced by `mix specs.check`).
- **Live e2e (opt-in)** — extend `make e2e` with a scenario whose
  `backend_by_state` routes one state to claude, gated behind the existing
  `SYMPHONY_RUN_LIVE_E2E` flag and requiring a local `claude` CLI + auth.

## Docs & spec alignment

Per `elixir/AGENTS.md` "Docs Update Policy", in the same change:

- **`SPEC.md`** — document the agent-backend abstraction and `agent.backend` /
  `agent.backend_by_state` config. The implementation must stay a non-conflicting
  superset of the spec.
- **`elixir/README.md`** — `agent.backend*` config keys; the `claude` CLI as an
  optional dependency; `--linear-mcp` escript mode.
- **`elixir/WORKFLOW.md`** — example `backend_by_state` routing.
- **Pipeline plan** — note that this **supersedes Plan B Task 6's
  codex-shells-out-to-claude step**: `review-pr` now runs by setting
  `backend_by_state: {implemented: claude}`.

## Open items (verify during build, not design blockers)

1. **Claude CLI flags** — confirm exact `--output-format stream-json` event
   schema, prompt delivery, `--mcp-config` shape, `--permission-prompt-tool`
   contract, and `--allowedTools` syntax against the installed Claude CLI version.
   Highest-priority verification.
2. **Blocked fidelity** — confirm Claude reliably routes permission requests to
   the `approval_prompt` tool in `-p` mode (vs. silently proceeding or erroring).
   If not, fall back to mapping `result.subtype`/`is_error` to `:blocked` for the
   review stage and record the reduced fidelity.
3. **Remote (SSH) Claude** — confirm `claude` + auth (`~/.claude`) are available
   on SSH worker hosts the way codex auth is, since `start_port` branches on
   `worker_host`.
4. **MCP server lifecycle** — whether Claude spawns the `--mcp-config` stdio
   server itself (preferred) so Symphony need not supervise an extra process.

## Decomposition

Single implementation plan, sequenced:
1. `Agent` behaviour + `Agent.Result` + refactor `Codex.AppServer` behind
   `Agent.Codex` (no behavior change; all existing tests green).
2. Config: `agent.backend` / `backend_by_state` + selection + validation.
3. `linear_graphql` MCP server escript mode (reusing `DynamicTool`).
4. `Agent.Claude` adapter + stream-json parsing + blocked mapping.
5. `AgentRunner` wiring + tests + docs/spec updates.
6. (Opt-in) live e2e scenario.
