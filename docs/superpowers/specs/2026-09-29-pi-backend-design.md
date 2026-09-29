# pi agent backend

Status: draft for review. Builds on `2026-09-29-omp-backend-design.md` (merged in PR #53). Read that spec first: this one records only what differs.

## Goal

Add `pi` (earendil-works pi-coding-agent, v0.79.1 probed) as a fourth `Agent` backend (`agent.backend: pi`), so lanes can use pi with any model or subscription it supports, including OpenRouter.

## Non-goals

- Approval bridging. pi has no permission popups; it runs with the daemon user's privileges (`security.md`: "not a sandbox").
- Installing or updating pi, or any pi package, on hosts.
- Per-state model overrides (`agent.backend_by_state` already selects a backend per state).
- A long-lived `--mode rpc` process.

## What is the same as omp

Per-turn process, `--session-dir` plus `--continue` for turns 2..N, prompt on stdin from a private 0600 file, private per-session dir with 0700 layout, `PI_CODING_AGENT_DIR` pointing at a private agent dir, credentials from the process environment (no `auth.json` copying), tracker secret scrub/unset, local + SSH + managed contexts, the SSH remote script with a persistent remote `sessions/` and an EXIT trap removing secret-bearing files.

The JSON stream is the same family as omp's (`session` header v3, `agent_start`, `turn_*`, `message_*`, `tool_execution_*`, `agent_end`; `stopReason` in `stop | length | toolUse | error | aborted`; assistant `usage`). `Agent.Omp.Stream` is renamed to a shared `Agent.PiFamily.Stream` and used by both; behavior unchanged, omp fixtures stay. Error tuples keep the `:omp_*` tags for omp and use `:pi_*` for pi via a `label` field on the folder struct.

## What differs

### Tracker tools: no MCP

pi has no MCP support (`usage.md`); tools come only from extensions via `pi.registerTool()`. Decision: ship one small TypeScript extension with Symphony, `priv/pi/symphony-mcp-bridge.ts`, loaded with `-e <path>`.

Bridge behavior:

1. On load, read `SYMPHONY_BRIDGE_CONFIG` (path to a 0600 JSON file `{command,args,env,timeoutMs}`) and spawn the tracker MCP server command it describes (same server Claude and omp use: `symphony --linear-mcp --workflow <path>`), with `cwd` = workspace.
2. Speak minimal MCP over stdio itself (newline-delimited JSON-RPC 2.0): `initialize`, `notifications/initialized`, `tools/list`, `tools/call`. No npm dependencies.
3. Register every listed tool with `pi.registerTool()`, name prefixed `symphony_` (e.g. `symphony_linear_graphql`), forwarding the input schema and mapping the MCP result content to the pi tool result; MCP `isError` becomes a tool error.
4. Kill the child on `session_shutdown` and on process exit; a child that dies mid-session makes subsequent tool calls return an error, not hang (per-call timeout from `codex.turn_timeout_ms`).

Tracker secrets: they live only in the `SYMPHONY_BRIDGE_CONFIG` JSON file (0600, never argv) and reach the MCP server through its `env`; never in pi's own environment, which is scrubbed like the other backends.

The extension is materialized by `Agent.Pi` into the private session dir at `start_session` (locally) or streamed in the SSH payload (remotely), so hosts need no Symphony checkout and the version always matches the running daemon.

### Isolation

Private agent dir `<private>/agent` via `PI_CODING_AGENT_DIR`. Flags: `--no-extensions` (auto-discovery off; explicit `-e` still works), `--no-skills`, `--no-prompt-templates`, `--no-themes`, `--no-context-files`, `--no-approve`, `--offline`; `--no-session` is NOT used. Symphony writes `<private>/agent/settings.json` with `defaultProjectTrust: "never"` and no packages. Verified, see Verification results.

### Tools

The allowlist is `--tools <built-ins>,<bridge names>`, explicit names only (globs are not supported, verified). Built-ins default to `read, bash, edit, write, grep, find, ls`, overridable by `pi.allowed_tools`. Bridge names are `symphony_<tool name>` for each spec from `Tracker.bind_agent_tools().tool_specs`, computed by Symphony before launch, exactly as Claude's allowlist is. A tool the tracker lists at runtime but not in the specs is not callable.

### Config (`pi.*`)

| Key | Default | Meaning |
|---|---|---|
| `command` | `pi` | Executable |
| `model` | unset | pi `--model` pattern, e.g. `openrouter/anthropic/claude-sonnet-4` |
| `thinking` | unset | `off, minimal, low, medium, high, xhigh` (pi has no `max`/`auto`) |
| `args` | `[]` | Passthrough argv |
| `allowed_tools` | built-ins above | Built-in tool allowlist |
| `linear_mcp_command` / `linear_mcp_args` | as omp | Tracker MCP server launch |
| `extra_mcp_servers` | not supported; if set it is ignored | pi bridge serves the tracker server only; no validation is added |

### Credentials

pi reads provider keys from the environment (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, ...). pi stores logins in `auth.json` (plain JSON, no SQLite WAL), but copying it would fork refresh-token state across concurrent lanes, so the omp rule holds: environment only. Documented limitation: logins stored only in `~/.pi/agent/auth.json` are not visible to lanes.

## Touchpoints

`Agent.module_for("pi")`; `Config.Schema.Pi` embed and `Config` blank-command validation and `backend_command/2`; `Agent.Pi`; shared `Agent.PiFamily.Stream` (rename of `Agent.Omp.Stream`, tests and fixtures moved, error tags parametrized); `priv/pi/symphony-mcp-bridge.ts` plus its tests; lane editor pi section; `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, `.claude/docs/*`, `CLAUDE.md` backend list.

Shared code: `Agent.Omp` and `Agent.Pi` overlap heavily (session layout, remote script, stop_session). Extract only what both use identically into `Agent.CliHarness` (session layout creation, bounded remote cleanup, payload encoding); keep argv builders and config writers per backend. No third abstraction layer.

## Testing

- Shared stream folder: existing omp tests moved unchanged, plus a pi fixture recorded from a real run.
- Bridge: a fake MCP server script (Node) and a harness that loads the bridge through a stub of the pi extension API; tests cover tools/list to registerTool mapping, tools/call success and isError, child death, timeout, secret env not in argv. Runs under `node --test` gated behind availability of `node`; skipped with an explicit message otherwise.
- `Agent.Pi`: argv, private settings.json, fake `pi` script end to end (turn 1 vs `--continue`, env, stdin, secret scrub, error stream), SSH fake-ssh tests incl. trap cleanup and bounded stop.
- Smoke: real `pi` isolation probe (workspace `.pi`/AGENTS.md/user extensions contribute nothing) and, with a real provider key, one tracker tool round trip through the bridge against a memory tracker.
- `make all` must pass.

## Order of work

1. (Done) Probes for isolation, `--tools` and `-e` TypeScript loading; results recorded above.
2. Rename shared stream folder; extract shared harness pieces (omp tests are the net).
3. Bridge extension and its tests.
4. `pi.*` config, registry, `Agent.Pi` local, then SSH/managed.
5. Lane editor, docs, `SPEC.md`, gate.

## Verification results (pi 0.79.1, probed against a fake OpenAI-compatible server)

1. Isolation: with a private `PI_CODING_AGENT_DIR`, `settings.json` `{"defaultProjectTrust":"never","packages":[]}` and flags `--no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve --offline`, the request carried only built-in tools and none of the planted workspace `.pi/extensions/leak.ts`, `.pi/settings.json`, `AGENTS.md` or `CLAUDE.md`. Controls: without `--no-extensions`/`--no-approve` the project tool loaded; without `--no-context-files` the planted context markers reached the model.
2. `--tools` takes explicit names only: `read,bash,symphony_probe` worked, the glob `read,symphony_*` dropped everything but `read`. Pi's default tools are `read, bash, edit, write` (no `grep/find/ls`).
3. `pi -e file.ts` loads TypeScript with no build step and works together with `--no-extensions`.
