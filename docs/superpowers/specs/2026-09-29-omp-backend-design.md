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
| `thinking` | unset | `--thinking` level |
| `args` | `[]` | Passthrough argv, placed before Symphony's flags |
| `allowed_tools` | read, grep, find, edit, write, bash | `--tools` allowlist of built-in tools only; omp rejects `mcp__symphony__*` here and mounts the tracker MCP tools itself (as `mcp__symphony_*`), so they are always available |
| `linear_mcp_command` / `linear_mcp_args` | as Claude | Tracker MCP server launch |
| `extra_mcp_servers` | `{}` | Merged left; `symphony` wins collisions |

## Turn flow

Per turn, a fresh process: `omp -p --mode json --session-dir <private>/sessions --approval-mode yolo --tools <allowlist> --no-extensions --no-skills --no-rules --no-title --config <private>/overlay.yml [--continue] [--model --thinking]`, cwd = workspace, env `PI_CODING_AGENT_DIR=<private>/agent`, prompt on stdin from a private file.

- Turn 1 sends the full prompt. Turns 2..N pass `--continue` with the short continuation prompt.
- `Omp.Stream` folds events: `session`, `agent_start`, `turn_start`, `message_update`, `turn_end`, `agent_end`. Tokens are summed from assistant `usage`.
- Error: `stopReason` other than `stop`, non-zero exit, or no `agent_end` gives `{:error, {:omp_*, reason}}`.
- Result is never `:blocked` from approvals. Blocked comes from the agent's tracker tool or comment, as with Codex.
- Workspace confinement remains Symphony's job (cwd and `path_safety.ex`), since omp runs in `yolo`.

## Tool delivery and isolation

The tracker MCP server reaches omp through `<private>/agent/mcp.json`, and `PI_CODING_AGENT_DIR` points omp at that private agent dir.

Verified by probe (omp 18.4.3): omp has no `--strict-mcp-config` and auto-discovers MCP servers from `~/.omp/agent/mcp.json`, `~/.claude.json`, plugins, Cursor, project `.mcp.json`, and more. A `--config` overlay with `disabledProviders` alone did not remove user-level native servers (the agent still called `mcp__chrome_devtools_*`). What did give a hermetic tool list:

- private `PI_CODING_AGENT_DIR` holding only Symphony's `mcp.json`;
- overlay `mcp.enableProjectConfig: false`;
- overlay `disabledProviders` listing every discovery provider except `native`: `omp-plugins, claude, agent-plugins, codex, agents, claude-plugins, gemini, opencode, cursor, windsurf, cline, github, vscode, agents-md, mcp-json, ssh-json`;
- `--no-extensions --no-skills --no-rules`.

With this, only the `symphony` server was attempted and the model reported no `mcp__` tools otherwise.

## Credentials

A private agent dir has no `agent.db`, so omp's stored logins are not visible. Symlinking `agent.db` is unsafe: SQLite would create a separate `-wal` in the private dir beside the shared database file. So credentials come from the process environment, which the Port and SSH login shell already inherit:

- provider API keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, ...);
- subscription/OAuth logins through omp's auth broker (`omp auth-broker serve`) with `OMP_AUTH_BROKER_URL` and `OMP_AUTH_BROKER_TOKEN`.

Limitation, documented: OAuth logins that exist only in a local `agent.db` are unavailable to Symphony lanes until moved to a broker.

## Execution contexts

- Local: Port, cwd = workspace.
- SSH and managed: the remote command creates a persistent remote session dir (`/tmp/symphony-omp-<token>`, mode 0700, holding `sessions/`), rewrites `agent/mcp.json`, `overlay.yml`, and the workflow snapshot each turn from length-prefixed stdin, unsets tracker secrets after use, chooses `--continue` when `sessions/` is non-empty, then runs `omp`. `stop_session` removes the remote dir best-effort. omp must be installed on each remote host or guest, with credentials in that environment. Managed requires a `:managed` `ExecutionContext`.

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
