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

1. On load, spawn the tracker MCP server command given in env `SYMPHONY_MCP_COMMAND` / `SYMPHONY_MCP_ARGS_JSON` / `SYMPHONY_MCP_ENV_JSON` (same server Claude and omp use: `symphony --linear-mcp --workflow <path>`), with `cwd` = workspace.
2. Speak minimal MCP over stdio itself (newline-delimited JSON-RPC 2.0): `initialize`, `notifications/initialized`, `tools/list`, `tools/call`. No npm dependencies.
3. Register every listed tool with `pi.registerTool()`, name prefixed `symphony_` (e.g. `symphony_linear_graphql`), forwarding the input schema and mapping the MCP result content to the pi tool result; MCP `isError` becomes a tool error.
4. Kill the child on `session_shutdown` and on process exit; a child that dies mid-session makes subsequent tool calls return an error, not hang (per-call timeout from `codex.turn_timeout_ms`).

Tracker secrets: the bridge receives them via the MCP server's env only (`SYMPHONY_MCP_ENV_JSON`, delivered through the private 0600 config, never argv); pi's own process env has them scrubbed like the other backends.

The extension is materialized by `Agent.Pi` into the private session dir at `start_session` (locally) or streamed in the SSH payload (remotely), so hosts need no Symphony checkout and the version always matches the running daemon.

### Isolation

Private agent dir `<private>/agent` via `PI_CODING_AGENT_DIR`. Flags: `--no-extensions` (auto-discovery off; explicit `-e` still works), `--no-skills`, `--no-prompt-templates`, `--no-themes`, `--no-context-files`, `--no-approve` (ignore project-local trust-gated files and workspace `.pi/`), `--offline`, `--no-session` is NOT used. Global settings: a `<private>/agent/settings.json` written by Symphony with `defaultProjectTrust: "never"` and no packages. Verification required before implementation (same discipline as omp): a probe shows a workspace `.pi/extensions`, `.pi/settings.json`, `AGENTS.md`/`CLAUDE.md`, and the user's `~/.pi/agent/extensions` all contribute nothing.

### Tools

`--tools read,bash,edit,write,grep,find,ls,symphony_*` allowlist semantics apply to built-in, extension and custom tools alike (`--tools` help text). Default built-ins: `read, bash, edit, write, grep, find, ls`; the bridge's registered names are appended (they are known only after the bridge lists them, so `Agent.Pi` passes `--exclude-tools` for nothing and relies on the extension loading only Symphony's server; open verification: whether `--tools` accepts a glob for extension tools, else the allowlist omits bridge tools and `--no-builtin-tools` semantics are used with `--exclude-tools` for the built-ins to drop).

### Config (`pi.*`)

| Key | Default | Meaning |
|---|---|---|
| `command` | `pi` | Executable |
| `model` | unset | pi `--model` pattern, e.g. `openrouter/anthropic/claude-sonnet-4` |
| `thinking` | unset | `off, minimal, low, medium, high, xhigh` (pi has no `max`/`auto`) |
| `args` | `[]` | Passthrough argv |
| `allowed_tools` | built-ins above | Built-in tool allowlist |
| `linear_mcp_command` / `linear_mcp_args` | as omp | Tracker MCP server launch |
| `extra_mcp_servers` | not supported | pi bridge serves the tracker server only; omitted from the schema, not silently ignored |

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

1. Probe isolation and `--tools` extension-glob behavior (resolves both open verifications); record results in this spec.
2. Rename shared stream folder; extract shared harness pieces (omp tests are the net).
3. Bridge extension and its tests.
4. `pi.*` config, registry, `Agent.Pi` local, then SSH/managed.
5. Lane editor, docs, `SPEC.md`, gate.

## Open verifications (block implementation of the affected section)

1. Isolation recipe: confirm the flags and private `settings.json` fully suppress project `.pi/`, context files, and user extensions.
2. `--tools` behavior for extension-registered tools (glob or explicit names); fallback recorded above.
3. `pi -e <ts file>` loads TypeScript without a build step in the installed pi version, and works with `--no-extensions`.
