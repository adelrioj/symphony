# Configuration system

Paged out of root `CLAUDE.md`. Read this when touching lane versions, workflow import/export,
`SymphonyElixir.Config`, `config/schema.ex`, or live configuration publication.

`WORKFLOW.md` is the import/export format, not the daemon's live configuration source:

`Lanes` (database + immutable versions) → `LaneStore` (validated ETS entries) →
`Config` (access through `LaneContext`) → `Config.Schema` (typed schema/defaults/validation).
Writes parse through `Workflow.parse_parts/2` and `Config.Schema` before commit; reads use the
already validated entry, rather than reparsing a file.

- Always add config access through `SymphonyElixir.Config`, never ad-hoc env reads.
- Front matter sections are `tracker`, `polling`, `workspace`, `worker`, `agent`, `codex`, `claude`, `hooks`, `observability`, `server` — each an Ecto embedded schema with its own `changeset/2` in `config/schema.ex`. The Markdown body is the agent session prompt (Solid/Liquid templating, e.g. `{{ issue.identifier }}`); a default template is used if blank.
- **`codex.turn_timeout_ms` and `codex.stall_timeout_ms` govern both backends**, including `claude`. The `codex` section is not backend-scoped despite the name; only `command`/sandbox/approval fields are Codex-specific.
- Safer Codex defaults apply when policy fields are omitted (see `elixir/README.md` "Configuration"). Workflows running package managers must set `networkAccess: true` in `codex.turn_sandbox_policy`.
- A submitted `front_matter` or `prompt` creates an immutable version and advances the lane pointer; metadata-only saves do not. Version activation validates and moves the pointer to an existing version of that same lane.
- Live apply is a serialized save/commit → refresh/publication → ETS swap → `{:lane_updated, lane_id}` to the orchestrator. PubSub uses `{:lane_updated, slug}` and global update notifications. Invalid saves return field-path errors at the form/API and do not insert a version. Invalid persisted boot versions disable only their lane; a failed refresh can retain a previous usable entry with a visible error.
- `LaneStore` serializes writes and managed-environment guard acquisition. Guarded identity includes provider kind, deployment ID, tracker kind, workspace root, and provider references (including auth selection). Save/activation cannot change it while resources or unresolved operations remain. Runtime owner death does not release the guard; authoritative empty compute-and-storage inventory with no unresolved work is required before release.
- Before start and after tracker changes, preflight is asynchronous and bound to a publication generation. Newer saves replace pending checks even if the newer edit only changes metadata or prompt, preserving any pending start/adoption intent so the accepted runtime remains monitored. Checks for an already monitored runtime remain refresh-only. Stale successes/failures are ignored; only the current enabled generation may start or disable a runtime.
- Long-lived lane processes call `LaneContext.put/1`. The scheduler sees current configuration. Each active attempt captures a full immutable entry before task creation (including retries), then keeps its settings, workflow, version, executor, hooks, tool adapter and completion policy through helpers and deferred managed completion. Future attempts use the new version; an edit is not an implicit stop/restart.
- Installation settings come through `Config`: `--data-root` (default cwd), `--host` (default `127.0.0.1`), `--port` (default `4000`), `--events-retention-days` (default `30`), and `SYMPHONY_OPERATOR_TOKEN`. Relative local workspace roots resolve against the data root, not the imported file's directory.
- `server` front matter is retained for export but ignored with a warning; only installation flags control the listener. The single terminal dashboard uses `observability` from the lowest-id lane with valid settings, or schema defaults when none exists.
- `mix symphony lanes import`/`export` are offline database commands. Import creates a disabled lane or a new version for an existing slug; a separate running daemon does not pick that import up until restart. Use UI/API writes for live changes. The standalone MCP escript uses a private file-backed `LaneStore` without Repo or schedulers, not a second daemon mode.
- Raw YAML and prompt are ordinary editable strings. Export is exact for canonical nonempty LF-delimited front matter with a newline after the closing delimiter (and prompt-only split/render); arbitrary CRLF/empty/EOF envelopes normalize. Runtime prompt parsing separately normalizes line breaks and trims the rendered template.
- Tests share an in-memory SQLite database and run serially; `TestSupport.write_workflow_file!/2` publishes into the test lane instead of relying on filesystem reload.
