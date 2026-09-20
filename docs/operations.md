# Operation and lane/profile lifecycle

Check out [elixir/README.md](../elixir/README.md) for setup and operation. One `symphony serve`
process runs many named lanes from a SQLite database, with one installation serving one client.
Each lane owns tracker scope, prompt, hooks, backend and limits. An execution profile owns worker
configuration, credential references and a workspace base; multiple lanes may link to one profile.
Import a `WORKFLOW.md` once, then edit structured lane/profile state in the UI or authenticated API.
Workflow saves create immutable lane versions; active attempts retain their dispatch-time profile and
lane snapshot. The tracker remains the scheduling source of truth, while the database stores profile,
lane configuration and durable run history.

From `elixir/`, after installing dependencies:

```bash
export SYMPHONY_OPERATOR_TOKEN='replace-with-a-long-random-secret'
mix symphony lanes import ./WORKFLOW.md --slug main --data-root /data
mix symphony serve --data-root /data --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Use a writable persistent `/data` directory (or substitute the same directory in both commands).
New imports are disabled: sign in at <http://localhost:4000/login>, review the lane, then enable it.
Import creates a dedicated profile and reports its generated name. It is an offline operation, not a
live file watcher; use the authenticated UI/API for live edits. Profile changes automatically reach
future runs on every linked lane, but do not stop active attempts or rewrite their cleanup snapshot.

Use `/execution-profiles` to create and edit shared worker/workspace settings. A profile edit validates
all linked lanes, including disabled lanes, and publishes them atomically. Per-lane concurrency and
per-host limits remain independent; the profile view can show the aggregate linked-lane/shared-host
impact, but sharing a profile does not create a global scheduling pool.
Changing workspace or target identity is rejected while a reservation, active attempt, retained
workspace/resource, or unverifiable remote inventory still owns the old identity. Clear ownership
through supported disable/cleanup operations before retrying. Profile deletion is rejected while any
lane reference remains, including soft-deleted history. Saves never provision infrastructure.

Rollback activates a historical lane version against the currently selected profile. It does not
restore historical worker infrastructure, profile revisions, or a previous workspace identity.
Exports and API/UI projections preserve only secret references such as `$LINEAR_API_KEY`; resolved
credentials are never persisted or returned.
The daemon uses Mix or a Burrito release; `bin/symphony` is the escript for agent-side MCP only.
Self-hosted deployments live in their own repos, seeded from
[`deploy/client-template/`](../deploy/client-template); see
[Run in Docker](../elixir/README.md#run-in-docker-orbstack-compatible).
