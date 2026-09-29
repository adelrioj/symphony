# omp agent backend and shared CLI harness

Status: draft for review. Scope: `omp` only. `pi` is a separate follow-up spec.

## Goal

Add `omp` (oh-my-pi) as a third `Agent` backend beside `codex` and `claude`, so lanes can use any model or subscription omp supports, including OpenRouter. Symphony never stores provider keys; auth stays owned by omp.

## Non-goals

- `pi` support (pi has no native MCP; it needs its own tool-bridge design).
- Approval bridging. omp has no `-p` approval hook.
- Per-state model overrides. `agent.backend_by_state` already selects a backend per state.
- A long-lived `--mode rpc` process.

## Architecture

```
Agent.CliHarness   new, extracted from Agent.Claude
  private 0700 session dir + owner-DOWN cleanup monitor
  executable resolution, Port driver, SSH command wrapper
  tracker secret env capture, managed/remote context validation
Agent.Claude       refactored onto CliHarness; behavior unchanged
Agent.Omp          argv, session config files, result mapping
Agent.Omp.Stream   pure folder for omp JSON events (mirrors Claude.Stream)
```

Touchpoints:

- `Agent.module_for("omp")`.
- `Config.Schema`: new `omp` embed. `Config` validation: selected `omp` backend requires non-blank `omp.command`.
- `orchestrator.ex` (~L2207): replace the `if backend == Agent.Claude` command lookup with a per-backend lookup.
- `AgentRunner.build_turn_prompt/5`: omp gets the continuation prompt on turns 2..N.
- Lane editor (`lane_editor_live.ex`): backend option and an omp settings section.
- Docs in the same change: `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, `.claude/docs/architecture.md`.

## Configuration (`omp.*`)

| Key | Default | Meaning |
|---|---|---|
| `command` | `omp` | Executable |
| `model` | unset | omp `provider/id`, e.g. `openrouter/...` |
| `profile` | unset | Pre-authorized omp profile supplying credentials |
| `thinking` | unset | `--thinking` level |
| `args` | `[]` | Passthrough argv |
| `allowed_tools` | read, grep, find, edit, write, bash | `--tools` allowlist; tracker MCP tools always added |
| `linear_mcp_command` / `linear_mcp_args` | as Claude | Tracker MCP server launch |
| `extra_mcp_servers` | `{}` | Merged left; `symphony` wins collisions |

## Turn flow

Per turn, a fresh process: `omp -p --mode json --session-dir <private> --approval-mode yolo --tools <allowlist> [--continue] [--model --profile --thinking]`, cwd = workspace, prompt from a private file.

- Turn 1 sends the full prompt. Turns 2..N pass `--continue` with the short continuation prompt.
- `Omp.Stream` folds events: `session`, `agent_start`, `turn_start`, `message_update`, `turn_end`, `agent_end`. Tokens are summed from assistant `usage`.
- Error: `stopReason` other than `stop`, non-zero exit, or no `agent_end` gives `{:error, {:omp_*, reason}}`.
- Result is never `:blocked` from approvals. Blocked comes from the agent's tracker tool or comment, as with Codex.
- Workspace confinement remains Symphony's job (cwd and `path_safety.ex`), since omp runs in `yolo`.

## Tool delivery and isolation

The tracker MCP server reaches omp through a config written to the private session dir.

Problem: omp has no `--strict-mcp-config`. It auto-discovers MCP servers from `~/.omp`, `~/.claude`, `~/.codex`, Cursor, project `.mcp.json`, and more. A probe attempted to connect an ambient Notion server. Workspace `.mcp.json` could also inject servers.

Plan, per session: an omp config overlay (`--config`) setting `mcp.enableProjectConfig: false` and `disabledProviders` for foreign-tool discovery, plus `--no-extensions --no-skills --no-rules`. `omp.profile` names the pre-authorized profile that supplies credentials.

**Open verification (blocks implementation of this section):** confirm that `disabledProviders` and the overlay actually suppress MCP discovery from foreign tools and root `.mcp.json`. If not, fall back to an isolated profile with credentials copied in, or fail the lane preflight. The spec must not ship with ambient MCP leakage.

## Execution contexts

- Local: Port, cwd = workspace.
- SSH and managed: harness builds the remote command as Claude does, uploads the config and workflow snapshot to a remote temp path, unsets tracker secrets after use, then runs `omp`. omp must be installed and authenticated on each remote host or guest. Managed requires a `:managed` `ExecutionContext`.

## Testing

- Existing Claude tests are the regression net for the harness extraction; the extraction lands first, alone.
- `Omp.Stream`: fixture tests from recorded real event streams (success, tool calls, error stopReason, truncated stream).
- `Omp`: argv and config-file tests; a fake `omp` script exercising the Port path; remote-command builder; config validation.
- Smoke: one real `omp` run on a memory-tracker issue with a cheap model.
- `make all` must pass (80% coverage, specs, credo, dialyzer).

## Order of work

1. Extract `CliHarness`; Claude tests green, no behavior change.
2. `Omp.Stream` and schema/config.
3. `Agent.Omp` local path, then SSH/managed.
4. Isolation verification, lane editor, docs and `SPEC.md`.
