# Operation and lane lifecycle

Check out [elixir/README.md](../elixir/README.md) for setup and operation. One `symphony serve`
process runs many named lanes from a SQLite database, with one installation serving one client.
Each lane has its own tracker scope, workspace root, scheduler, agent settings, hooks, and prompt.
Import a `WORKFLOW.md` once, then edit the lane live in the UI or through
`PUT /api/v1/lanes/:slug`. Workflow saves create immutable versions; active attempts retain their
dispatch-time configuration. The tracker remains the scheduling source of truth, while the database
stores lane configuration and durable run history.

From `elixir/`, after installing dependencies:

```bash
export SYMPHONY_OPERATOR_TOKEN='replace-with-a-long-random-secret'
mix symphony lanes import ./WORKFLOW.md --slug main --data-root /data
mix symphony serve --data-root /data --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Use a writable persistent `/data` directory (or substitute the same directory in both commands).
New imports are disabled: sign in at <http://localhost:4000/login>, review the lane, then enable it.
Import is an offline operation, not a live file watcher; use the authenticated UI/API for live edits.
The daemon uses Mix or a Burrito release; `bin/symphony` is the escript for agent-side MCP only.
Self-hosted deployments live in their own repos, seeded from
[`deploy/client-template/`](../deploy/client-template); see
[Run in Docker](../elixir/README.md#run-in-docker-orbstack-compatible).
