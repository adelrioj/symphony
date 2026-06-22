# Per-stage Claude agent backend for Symphony — Design

**Date:** 2026-06-21
**Status:** Design (approved for planning)
**Author:** adelrio

> **Path convention:** all repo paths in this spec are relative to the repository
> root `/Users/adelrioj/development/symphony`. The Elixir implementation lives
> under `elixir/`, so source paths carry the `elixir/` prefix (e.g.
> `elixir/lib/symphony_elixir/codex/app_server.ex`).

## Problem

Symphony launches exactly one agent: it runs the single global `codex.command`
via `bash -lc` and drives it over the Codex app-server JSON-RPC protocol
(`elixir/lib/symphony_elixir/codex/app_server.ex`). Per-status behavior is
achieved only by injecting `{{ issue.state }}` into the prompt and letting that
one codex agent branch internally (confirmed in
`docs/superpowers/plans/spike-findings.md`, Q1).

The autonomous PR pipeline wants a stage (`Implemented` → review-pr) to run
**Claude Code** (`claude -p`) instead of codex. The spike's interim workaround
was "codex shells out to `claude -p` as a subprocess." This design replaces that
workaround with **per-stage agent choice**: Symphony itself selects codex *or*
claude as a first-class backend based on the ticket's current status.

## Goal & shape

A **pluggable agent layer** with two adapters behind one behaviour, selected
per issue state via config. Both adapters conform to the same `run/4` contract
and emit the same normalized events, so the orchestrator, dashboard, and
`AgentRunner` are agnostic to which agent ran. Explicitly **not** a generic
registry for arbitrary future agents (YAGNI) and **not** codex-wrapping-claude.

**Scope note on `:blocked`.** Normalized `{:ok, %Result{status: :blocked}}` plus
`AgentRunner`-owned Linear writes is **introduced for the Claude backend in this
change**. `Agent.Codex` preserves its *current* blocking behavior unchanged —
codex approval/input/MCP-elicitation blockers keep flowing through the existing
orchestrator in-memory blocked path (`orchestrator.ex`), and `Agent.Codex`
returns `{:ok, %Result{status: :done}}` / `{:error, reason}` only. Mapping codex
blockers onto the normalized `:blocked` result is a deliberate **follow-up**, so
"no behavior change; existing tests green" holds for the codex path here. (See
the Codex mapping note under Error handling.)

The Claude adapter reaches **full parity** with the codex path: live token
tracking (via a streamed event callback), blocked/elicitation detection, and
access to the `linear_graphql` tool — achieved without Symphony hosting a live
in-process tool bridge.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Abstraction | **`SymphonyElixir.Agent` behaviour + `SymphonyElixir.Agent.Result` struct** | Mirrors the existing `Tracker` behaviour idiom. One normalized result + event stream keeps callers backend-agnostic. |
| Backend selection | **`agent.backend` + `agent.backend_by_state` config, resolved once per run** | Copies the existing `Config.max_concurrent_agents_for_state/1` per-state pattern. No prompt-routing hacks, no shell-out. |
| Selection vs. continuation | **A run stops after any successful active-state transition; the next poll reselects** | Matches the pipeline's "one stage per poll tick". Multi-turn continuation persists only while the issue stays in the *same* state, so a backend switch never happens mid-session. |
| Codex path | **Refactor `Codex.AppServer` behind an `Agent.Codex` adapter** | It already produces tokens/session/result and emits `emit_message` events; the adapter only normalizes shapes. Minimal change. |
| Claude path | **New `Agent.Claude` adapter launching `claude -p --output-format stream-json`** | Parses Claude's event stream into normalized events + `Agent.Result`. All Claude-specific logic in one testable module. |
| Prompt delivery | **argv/stdin, never shell-interpolated** | The prompt embeds untrusted Linear issue text; interpolating it into `bash -lc` is command injection. |
| `linear_graphql` for Claude | **Standalone MCP server (`symphony --linear-mcp --workflow <abs path>`), wired via `--mcp-config`** | `DynamicTool`/`linear_graphql` is stateless. No shared session state to bridge, so an in-process MCP bridge buys nothing. |
| Secret handling | **MCP-config temp file outside the workspace, mode `0600`, secret via process env, deleted in an `after` block once Claude exits** | The per-issue workspace is persistent (possibly a git worktree); a token written there can leak into branches/logs/retained dirs. Deleting only after process exit avoids a race where Claude hasn't yet read `--mcp-config`. |
| Blocked detection (Claude) | **A deny-by-default `approval_prompt` MCP tool + `--permission-prompt-tool`, observed via stream-json** | Claude routes every permission request to that tool; the resulting `tool_use` in the stream is Symphony's blocked signal. Keeps Symphony out of live tool routing. |
| Error contract | **`{:ok, %Result{status: :done \| :blocked}}` for handled outcomes; `{:error, reason}` for failures** | One channel. `AgentRunner` raises on `{:error, reason}` exactly as it raises on codex failure today. |
| Tracker writes on blocked | **`AgentRunner` owns them: comment then state-update to `agent.blocked_state`** | Single owner; deterministic order; explicit partial-failure handling. |

## Architecture

### The `Agent` boundary

**The boundary is session-aware, not a single `run/4`.** `Codex.AppServer`
already exposes `start_session/2`, `run_turn/4`, `stop_session/1`, and
`AgentRunner` already owns the multi-turn continuation loop (issue-state refresh,
`max_turns`, continuation-prompt construction). The behaviour therefore mirrors
those three callbacks so `AgentRunner` keeps owning continuation and neither
adapter has to re-implement the loop:

```elixir
@type on_message :: (event :: SymphonyElixir.Agent.Event.t() -> any())

@callback start_session(workspace :: Path.t(), opts :: keyword()) ::
            {:ok, session :: term()} | {:error, reason :: term()}

@callback run_turn(session :: term(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
            {:ok, SymphonyElixir.Agent.Result.t()} | {:error, reason :: term()}

@callback stop_session(session :: term()) :: :ok
```

- `opts` carries `:worker_host` and `:on_message` (normalized event callback;
  defaults to no-op).
- **Continuation ownership stays in `AgentRunner`**: it calls `start_session`
  once, loops `run_turn` while the refreshed issue state is unchanged (up to
  `max_turns`), and calls `stop_session` in an `after` block. Because the backend
  is resolved once before the session starts (see Backend selection), the backend
  never switches mid-session.
- **Codex** implements the callbacks over its existing session (essentially a
  rename/wrap of today's functions — behavior-preserving).
- **Claude** is stateless per turn: `start_session` prepares the MCP-config temp
  file + returns a lightweight session struct; `run_turn` launches one
  `claude -p` (using `--continue`/`--resume` across same-session turns *if* the
  CLI supports it, else a fresh stateless invocation — Open items #1);
  `stop_session` deletes the temp file.

**Normalized event** (`SymphonyElixir.Agent.Event`) — the backend-neutral analogue
of the codex `emit_message` events. It is an **adapter-internal** shape;
`AgentRunner` translates it to the existing orchestrator message (see bridge
note) so the orchestrator and dashboard are untouched:

```elixir
%SymphonyElixir.Agent.Event{
  kind: :session_started | :usage_updated | :blocked | :completed | :error,
  session_id: String.t() | nil,
  tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()} | nil,
  seconds_running: non_neg_integer() | nil,
  detail: map()              # kind-specific extras (e.g. blocked action text, error reason)
}
```

**Orchestrator event bridge (explicit).** The orchestrator today processes
`{:codex_worker_update, issue_id, %{event: _, timestamp: _, ...}}` maps and reads
Codex-style usage fields (`input_tokens`, `output_tokens`, `total_tokens`).
`AgentRunner` converts each `%Agent.Event{}` into **that existing map shape** —
`%{event: kind, timestamp: <now>, session_id: ..., usage: %{input_tokens: tokens.input, output_tokens: tokens.output, total_tokens: tokens.total}}` —
before forwarding. The orchestrator and dashboard are **not** changed; only
`AgentRunner` learns the translation. This keeps Claude token totals, session
IDs, and activity timestamps flowing through the existing path.

**Normalized result** (`SymphonyElixir.Agent.Result`) — returned on a handled run:

```elixir
%SymphonyElixir.Agent.Result{
  status: :done | :blocked,                  # :error is NOT a result status — failures use {:error, reason}
  session_id: String.t() | nil,
  tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
  seconds_running: non_neg_integer(),
  summary: String.t() | nil,                 # text used for the Linear audit comment
  blocked_action: String.t() | nil           # populated only when status == :blocked
}
```

`:blocked` is first-class because Symphony already separates "parked / needs
human" (neither active nor terminal — workspace preserved) from "failed".

### Backend selection (timing is explicit)

The backend is resolved **once, in the orchestrator's dispatch decision, before
the issue is claimed/spawned** — not inside `AgentRunner` after a worker exists.
This matters because `AgentRunner.run` runs in an already-claimed, already-spawned
worker, so a late "skip" there would look like a normal completion and trigger the
active-state continuation path. Resolving at dispatch means an invalid backend
simply **prevents the claim** (the issue is logged and left unclaimed for a later
poll, exactly like any other not-yet-dispatchable issue — no worker, no fake
completion, no continuation retry). The resolved backend module is then passed to
the worker, which calls `start_session`/`run_turn`/`stop_session` on it. Resolution
reuses the `Config.max_concurrent_agents_for_state/1` pattern:

- `agent.backend` — global default, `"codex"`.
- `agent.backend_by_state` — per-state override map (e.g. `{"implemented": "claude"}`),
  normalized with the same `Schema.normalize_issue_state/1` helper. The schema
  validates *structure* only (string → string); it does **not** enumerate-validate
  values at parse time, so a typo'd backend never globally invalidates the
  workflow or discards last-known-good config on reload.
- `Config.agent_backend_for_state/1` returns
  `{:ok, "codex" | "claude"} | {:error, {:invalid_agent_backend, state, value}}`.
  The **orchestrator** calls this during its dispatch decision and maps
  `{:ok, backend}` to `Agent.Codex` / `Agent.Claude`. On
  `{:error, {:invalid_agent_backend, state, value}}` it **logs the config error
  (with `issue_id`/`issue_identifier`) and does not claim/dispatch that issue**,
  leaving it for a later poll once the config is fixed. Other issues/states are
  unaffected; the daemon and loaded config are untouched.

**Interaction with the existing continuation loop.** Today `AgentRunner` may run
multiple codex turns while the issue stays active (`max_turns` cap), refreshing
issue state between turns. This design narrows that: **a run continues turns only
while the refreshed state is unchanged. On any successful transition to a
*different* active state, the run returns**, so the next poll tick re-resolves
the backend for the new state and rebuilds the full state-routing prompt. This
guarantees a backend switch never occurs inside a live session and aligns with
the pipeline's one-stage-per-tick model. (Codex sessions therefore persist only
across same-state continuations, which is already their effective behavior.)

```
WORKFLOW.md:
agent:
  backend: codex
  backend_by_state:
    implemented: claude
  blocked_state: "Blocked / Needs Attention"
```

### Component layout

```
Orchestrator dispatch
  └─ {:ok, backend} = Config.agent_backend_for_state(issue.state)   # resolved ONCE, before claim
       (on {:error, invalid} → log + don't claim; no worker)
  └─ claim + spawn worker with backend module
        AgentRunner (owns continuation loop)
          ├─ backend.start_session(workspace, opts)
          ├─ loop backend.run_turn(session, prompt, issue, opts) while state unchanged, ≤ max_turns
          │     ├─ Agent.Codex  ── existing Codex.AppServer session; emits events; returns Result
          │     └─ Agent.Claude ── one `claude -p` per turn; parses stream-json → events + Result
          │                          ├─ linear_graphql MCP: `symphony --linear-mcp --workflow <abs>` via --mcp-config
          │                          └─ approval_prompt MCP tool via --permission-prompt-tool (blocked signal)
          ├─ backend.stop_session(session)   # after-block; Claude deletes MCP temp file
          ├─ on {:ok, %Result{status: :blocked}} → AgentRunner: create_comment THEN set agent.blocked_state
          └─ on {:error, reason}                 → AgentRunner raises (existing retry/backoff applies)
```

## The Claude adapter (`Agent.Claude`)

### Launch (no shell interpolation)

Claude runs in the issue workspace. The prompt embeds untrusted Linear issue
text, so it is **never** interpolated into a shell string. Instead:

- **Local:** `Port.open({:spawn_executable, claude_bin}, [..., args: argv, cd: workspace, env: env])`,
  where `argv` is `["-p", "--output-format", "stream-json", "--verbose",
  "--mcp-config", <abs cfg path>, "--permission-prompt-tool",
  "mcp__symphony__approval_prompt", "--allowedTools", <allowed>, prompt]`. There
  is **no shell**: the prompt is a single argv element — never a `bash -lc`
  fragment. (This differs from the codex launch, which can use `bash -lc` only
  because the codex *prompt* travels over JSON-RPC, not the command line.)
- **Remote (SSH):** reuse the existing `SSH.start_port` path. Because that path
  executes a remote *shell command string*, the prompt is **not** embedded in it.
  Symphony transmits the prompt out-of-band — `ssh` reads the prompt bytes from
  Symphony's stdin and the remote `claude` consumes them via stdin (or a temp
  file written outside the project checkout on the worker). The remote command
  string contains only fixed flags and the temp-path/stdin reference, never
  prompt text. The `claude` binary on the worker is configured (see Open items #3).

**`claude.command` is an executable path, not a shell string.** Since the local
launch uses `spawn_executable` (no shell), `claude.command` resolves to a single
executable; Symphony expands `~` and `$VAR` on that path **before** `Port.open`
(it does not rely on shell expansion). Extra fixed flags go in `claude.args`
(a list), appended ahead of the Symphony-managed flags. This is intentionally
*not* the `codex.command` shell-string model, because the codex prompt never
touches a command line and the claude prompt would. The exact Claude CLI flags
are confirmed against the installed CLI during implementation (Open items #1).

### Allowed tools (security policy, enumerated)

The Claude backend's **default** allowed-tool set is explicit, not an ellipsis,
because it is a security boundary:

- `mcp__symphony__linear_graphql` — Linear reads/writes (status, comments).
- `Read`, `Grep`, `Glob` — repo inspection.
- `Bash` — required for `gh`/`git` in the `review-pr` stage.
- `Edit`, `Write` — required if a stage fixes code.
- `mcp__symphony__approval_prompt` is **not** in the allowed set — it is the
  permission-prompt tool, invoked by Claude's permission flow, and its invocation
  is the blocked signal.

The set is overridable via `claude.allowed_tools` (list). The default errs toward
the tools `review-pr` and code-fixing stages need; narrowing it is a per-workflow
choice. The exact CLI spelling of each tool name is delegated to CLI verification
(Open items #1); the *policy* above is stable.

### Stream parsing → events + `Agent.Result`

Claude emits newline-delimited JSON events. The adapter folds them, emitting a
normalized `Agent.Event` as each arrives so the dashboard updates live:

- **`system` init event** — capture `session_id`; emit `:session_started`.
- **`assistant` / `user` events** — accumulate text for `summary`; emit
  `:usage_updated` with running token totals when usage is present; detect
  `tool_use` blocks.
- **`tool_use` for `mcp__symphony__approval_prompt`** — Claude asked for a
  permission Symphony denies → set the result toward `:blocked`, record the
  requested action in `blocked_action`, emit `:blocked`.
- **final `result` event** — `usage` → `tokens`; `duration_ms` →
  `seconds_running`; map terminal status:
  - `subtype: "success"`, `is_error: false`, not already blocked → `{:ok, %Result{status: :done}}`
  - already-blocked → `{:ok, %Result{status: :blocked}}`
  - `subtype: "error_max_turns"` / `"error_during_execution"`, or `is_error: true` → `{:error, {:claude_error, subtype}}`
- **process exit / stream failure** — nonzero exit or unparseable/truncated
  stream with no `result` → `{:error, {:claude_stream, tail_of_stderr}}`.

**Blocked-wins precedence (explicit).** Once an `approval_prompt` `tool_use` has
been **fully parsed**, the turn resolves to `{:ok, %Result{status: :blocked}}`
*even if* the process subsequently exits nonzero or emits no final `result` —
a denied permission legitimately ends the run, and it must reach the Linear
blocked-write path rather than retry/backoff. The single exception: if the stream
is corrupted/truncated **before** the `approval_prompt` event is fully parsed,
that is a genuine stream failure → `{:error, {:claude_stream, …}}`. So: blocked
beats a later non-clean exit, but an incomplete blocked event does not.

`AgentRunner` translates `:usage_updated` events to the existing
`{:codex_worker_update, …}` map (see the bridge note) so Claude token totals flow
into the orchestrator's existing accumulator live (the field stays named as today
to avoid churn; it now means "agent totals").

### Timeouts

Reuse the existing codex timeout knobs (`turn_timeout_ms`, `read_timeout_ms`,
`stall_timeout_ms`) as shared agent timeouts rather than introducing parallel
claude-specific ones.

## The `linear_graphql` MCP server

A new escript mode of the `symphony` binary, `symphony --linear-mcp --workflow
<absolute WORKFLOW.md path>`, that speaks the MCP stdio protocol and exposes:

- **`linear_graphql`** — same name/description/input schema as
  `Codex.DynamicTool.tool_specs/0`; forwards `{query, variables}` to
  `Linear.Client.graphql/3`. The tool body reuses the existing
  `DynamicTool.execute/3` logic — not reimplemented.
- **`approval_prompt`** — deny-by-default. Returns a denial and is the marker
  Symphony watches for in the stream to set `:blocked`.

**Config bootstrap (critical):** `DynamicTool.execute/3` → `Linear.Client.graphql/3`
reads Symphony config via `Config.settings!()`, which needs a `WORKFLOW.md`. A
standalone escript launched from an arbitrary issue workspace has no implicit
config, so the `--workflow <absolute path>` argument is **required**: the
`--linear-mcp` mode loads that workflow to resolve the tracker/Linear settings
(including the API key, whether it comes from `LINEAR_API_KEY` or workflow front
matter). `Agent.Claude` passes the resolved absolute workflow path used by the
running orchestrator.

**Binary path resolution (critical):** `./bin/symphony` is not guaranteed to
exist in an issue workspace. `Agent.Claude` resolves an **absolute** executable
path to the Symphony escript and always appends `--linear-mcp --workflow <abs>`
itself (the config value never carries those flags — see `claude.linear_mcp_command`):

- **Local:** derive from the running escript (e.g. `:escript.script_name/0`) or
  the `claude.linear_mcp_command` override; default to that absolute path.
- **Remote (SSH):** `claude.linear_mcp_command` must give the worker-side absolute
  path to a deployed Symphony binary (the worker must have one provisioned, like
  codex auth is today).

**Secret handling (critical):** `Agent.Claude` writes the `--mcp-config` JSON to a
temp file **outside** the repo/workspace, mode `0600`, and passes `LINEAR_API_KEY`
through the spawned MCP process's **environment**, not as literal JSON in the
config. The temp file is removed in an `after` block **once the Claude process
exits** — not immediately after `Port.open` — since a spawned-but-not-yet-read
config would race on slow workers and leave `linear_graphql`/`approval_prompt`
unavailable. For SSH workers the temp file is created (and cleaned up) outside the
project checkout on the worker.

Because the tool is stateless, this standalone server is functionally identical
to what codex gets in-process. (Future convergence — pointing codex at this same
MCP server and deleting the in-process `DynamicTool` path — is out of scope here.)

## Config changes (`elixir/lib/symphony_elixir/config/schema.ex`)

Add to the `Agent` embedded schema:

- `backend` — string, default `"codex"`. Structural type only; an unknown value
  is caught at selection time by `Config.agent_backend_for_state/1` (per-issue
  skip + log), **not** rejected at parse (so reload keeps last-known-good config).
- `backend_by_state` — map, default `%{}`, key-normalized via
  `normalize_issue_state/1`; structural (string → string) validation only, for the
  same reason.
- `blocked_state` — string, default `"Blocked / Needs Attention"`; the Linear
  state `AgentRunner` sets when a run returns `:blocked`.

Add a new top-level `Claude` embedded schema (parallel to `Codex`), key `claude`:

- `claude.command` — string, default `"claude"`. A single **executable path**
  (not a shell string). Symphony expands `~`/`$VAR` on it before `Port.open`;
  there is no shell. (Contrast `codex.command`, which *is* a shell string because
  the codex prompt never reaches a command line.)
- `claude.args` — list of strings, optional; extra fixed CLI flags appended ahead
  of Symphony-managed flags. Use this instead of packing flags into `command`.
- `claude.linear_mcp_command` — string, optional; the **executable path only**
  (no flags) used to launch the MCP server. Symphony always appends
  `--linear-mcp --workflow <abs workflow path>` itself. Local default is derived
  from the running escript; required for SSH workers (absolute worker-side path).
- `claude.linear_mcp_args` — list of strings, optional; extra fixed flags inserted
  before Symphony's `--linear-mcp --workflow …` (for the rare case the launcher
  needs them). Keeps `linear_mcp_command` a bare path.
- `claude.allowed_tools` — list of strings, optional; overrides the default
  allowed-tool set documented above.

Invalid-backend handling is by selection-time skip, not parse-time rejection (see
the Backend selection section and the ADVISORY resolution below).

## Error handling, blocked semantics & tracker-write ownership

- **`:done`** → `AgentRunner`/workflow advances status as today.
- **`:blocked`** → **`AgentRunner` owns the Linear writes** (not the agent, not
  the prompt), and **comment-before-state is a strict prerequisite ordering**:
  1. `Tracker.create_comment/2` with `blocked_action` / `summary`.
     - **If the comment fails:** do **not** call `update_issue_state`. Return
       normally without raising. The issue is still in its (active) state, so the
       next poll re-encounters it and re-runs — the blocked write is retried.
  2. `Tracker.update_issue_state/2` to `agent.blocked_state` (only after the
     comment succeeded).
     - **If the state update fails:** log and return normally. The issue is still
       active, so it is retried; the retry re-posts the comment (at-least-once —
       duplicate "blocked" comments are possible and accepted as a known
       idempotency caveat). The state transition itself is idempotent.
  - This ordering is deliberate: doing the state update first could move the issue
    *out* of `active_states` (since `blocked_state` is parked, not active) before
    the audit comment lands, after which a comment failure would never be retried
    — a blocked issue parked with no explanation. Comment-first closes that gap.
    The workspace is preserved (already how neither-active-nor-terminal states
    behave).
  - **Comment body (deterministic).** The comment is built from a fixed template:
    a `**Symphony: blocked**` header, the `session_id`, and a body of
    `blocked_action || summary || "No blocked action detail was provided."`. The
    body is truncated to a bounded length (e.g. 4 000 chars, with a `… (truncated)`
    marker) so a large streamed `summary` never trips Linear comment-size limits.
    `blocked_action`/`summary` being nil is therefore never fatal — the fallback
    string is used.
- **`{:error, reason}`** → `AgentRunner` raises (as it does for codex failure
  today); the orchestrator's existing retry/backoff applies. `status: :error` is
  not a valid result — failures never travel as `{:ok, _}`.
- **Codex blocked mapping (explicit).** `Agent.Codex` does **not** emit
  `{:ok, %Result{status: :blocked}}` in this change. Its existing
  approval-required / turn-input-required / MCP-elicitation handling stays on the
  current orchestrator in-memory blocked path untouched, returning
  `:done` / `{:error, reason}` to `AgentRunner`. Only `Agent.Claude` produces
  normalized `:blocked` results that drive the `AgentRunner` Linear-write path
  above. Converging codex onto the normalized `:blocked` result (so codex
  blockers also post Linear comments + set `blocked_state`) is an explicit
  follow-up, out of scope here. This keeps the codex refactor behavior-preserving.
- **Audit trail** unchanged: `summary` becomes the Linear progress comment for
  both backends. Logging follows `elixir/docs/logging.md` — include `issue_id`,
  `issue_identifier`, and `session_id` for Claude runs (from the stream-json
  `system`/`result` event).

## Testing

- **`Agent.Claude` stream parsing** — unit tests over recorded stream-json
  fixtures (under `elixir/test/fixtures/`): success, max-turns error, mid-run
  `approval_prompt` (blocked), malformed/truncated stream, nonzero exit. Assert
  the emitted `Agent.Event` sequence and the final `{:ok, %Result{}}` /
  `{:error, _}`. No real Claude process.
- **Prompt safety (split by launch path, since the contracts differ)** — with a
  prompt containing shell metacharacters (`"; rm -rf /"`, `$(...)`, backticks,
  newlines):
  - *Local:* assert the prompt is passed as a single `Port.open` argv element and
    no `bash -lc`/shell is invoked.
  - *SSH:* assert the prompt text does **not** appear anywhere in the remote shell
    command string, and that prompt bytes are delivered only through the chosen
    channel (stdin, or a temp file outside the project checkout with mode `0600`,
    cleaned up after the turn). The two paths assert different invariants by
    design — there is no single "argv" claim for SSH.
- **Backend selection** — `Config.agent_backend_for_state/1` unit tests (default,
  per-state override, normalization, unknown-name handling) mirroring the existing
  `max_concurrent_agents_for_state` tests.
- **Blocked write ownership** — with the `memory` tracker, assert `AgentRunner`
  calls `create_comment` then `update_issue_state(blocked_state)` on `:blocked`,
  and the partial-failure path logs without raising.
- **`linear_graphql` MCP server** — reuse/extend `Codex.DynamicTool` tests against
  the shared execute logic; a `--workflow`-bootstrap test (config resolves from
  the given path); an MCP-protocol stdio framing smoke test.
- **`AgentRunner` selection + continuation** — with a stub `Agent` implementation,
  assert the backend is resolved once, that a different-active-state transition
  returns (no mid-session switch), and that `Result.status` maps to the right
  outcome.
- **Coverage** — the project enforces 100%; add new modules to tests rather than
  to `elixir/mix.exs`'s `ignore_modules`. Public `def`s in `elixir/lib/` get
  `@spec` (enforced by `mix specs.check`).
- **Live e2e (opt-in)** — extend `make e2e` with a scenario whose
  `backend_by_state` routes one state to claude, gated behind the existing
  `SYMPHONY_RUN_LIVE_E2E` flag and requiring a local `claude` CLI + auth.

## Docs & spec alignment

Per `elixir/AGENTS.md` "Docs Update Policy", in the same change:

- **Root `README.md`** — reviewed; update only if multi-agent support is surfaced
  as a user-facing *concept*. The Symphony concept/goals (orchestrate coding work
  from a tracker) are unchanged by adding a second agent backend, so a change here
  is expected to be a one-line mention at most, or none.
- **`SPEC.md`** — document the agent-backend abstraction, `agent.backend` /
  `agent.backend_by_state` / `agent.blocked_state`, and the `claude.*` config.
  The implementation must stay a non-conflicting superset of the spec.
- **`elixir/README.md`** — the new config keys; the `claude` CLI as an optional
  dependency; the `--linear-mcp --workflow` escript mode.
- **`elixir/WORKFLOW.md`** — example `backend_by_state` routing + `blocked_state`.
- **Pipeline plan** — note that this **supersedes Plan B Task 6's
  codex-shells-out-to-claude step**: `review-pr` now runs by setting
  `backend_by_state: {implemented: claude}`.

## Open items (verify during build, not design blockers)

1. **Claude CLI flags** — confirm the exact `--output-format stream-json` event
   schema, prompt delivery (argv vs stdin), `--mcp-config` shape,
   `--permission-prompt-tool` contract, and `--allowedTools` token spelling
   against the installed Claude CLI version. Highest-priority verification.
2. **Blocked fidelity** — confirm Claude reliably routes permission requests to
   the `approval_prompt` tool in `-p` mode (vs. silently proceeding or erroring).
   If not, fall back to mapping `result.subtype`/`is_error` to `:blocked` for the
   review stage and record the reduced fidelity.
3. **Remote (SSH) Claude + Symphony binary** — confirm `claude` + auth
   (`~/.claude`) and a Symphony binary (for `--linear-mcp`) are provisioned on SSH
   worker hosts, since both launch paths branch on `worker_host`.
4. **MCP server lifecycle** — confirm Claude spawns the `--mcp-config` stdio
   server itself (preferred) so Symphony need not supervise an extra process.

## ADVISORY / MINOR resolutions

- **(ADVISORY) Invalid-backend validation timing.** Current `Config.validate!` is
  invoked from the orchestrator polling path and logs+skips dispatch rather than
  halting boot; hot-reload keeps the last-known-good config. Consistent with that,
  an unknown `backend` / `backend_by_state` value is surfaced by
  `Config.agent_backend_for_state/1` as `{:error, {:invalid_agent_backend, …}}`;
  `AgentRunner` **logs a config error and skips dispatch for that issue only**
  until fixed — it does **not** halt the daemon and does **not** discard the
  loaded config. (Spec wording corrected from "fail boot".)
- **(MINOR) Callback type module name.** Use the fully-qualified
  `SymphonyElixir.Agent.Result.t()` / `SymphonyElixir.Agent.Event.t()` (not bare
  `Agent.Result.t()`, which resolves to `Elixir.Agent`).

## Decomposition

Single implementation plan, sequenced:
1. `Agent` behaviour + `Agent.Event` + `Agent.Result` + refactor `Codex.AppServer`
   behind `Agent.Codex` (no behavior change; all existing tests green).
2. Config: `agent.backend` / `backend_by_state` / `blocked_state` + `claude.*` +
   selection + validation.
3. `linear_graphql` MCP server escript mode (`--linear-mcp --workflow`), reusing
   `DynamicTool`.
4. `Agent.Claude` adapter: argv launch, stream-json parsing, event emission,
   blocked mapping, secret-safe MCP config.
5. `AgentRunner` wiring (selection-once, continuation rule, blocked-write
   ownership) + tests + docs/spec updates.
6. (Opt-in) live e2e scenario.
