# Configuration system

Paged out of the root `CLAUDE.md`. Read this when touching `WORKFLOW.md` parsing,
`SymphonyElixir.Config`, `config/schema.ex`, or hot reload.

Runtime config is **not** read from env ad hoc. `WORKFLOW.md` is parsed as YAML front matter + a Markdown prompt body:

`Workflow` (loads/reloads the file) → `Config` (`config.ex`, the access layer) → `Config.Schema` (`config/schema.ex`, parse + validation + defaults).

- Always add config access through `SymphonyElixir.Config`, never ad-hoc env reads.
- Front matter sections are `tracker`, `polling`, `workspace`, `worker`, `agent`, `codex`, `claude`, `hooks`, `observability`, `server` — each an Ecto embedded schema with its own `changeset/2` in `config/schema.ex`. The Markdown body is the agent session prompt (Solid/Liquid templating, e.g. `{{ issue.identifier }}`); a default template is used if blank.
- **`codex.turn_timeout_ms` and `codex.stall_timeout_ms` govern both backends**, including `claude`. The `codex` section is not backend-scoped despite the name; only `command`/sandbox/approval fields are Codex-specific.
- Safer Codex defaults apply when policy fields are omitted (see `elixir/README.md` "Configuration"). Workflows running package managers must set `networkAccess: true` in `codex.turn_sandbox_policy`.
- On startup, invalid/missing `WORKFLOW.md` halts boot. On hot reload, a bad file is ignored and the last-known-good config is kept (the BEAM hot-reloads without stopping active agents).
