# Deployment, credentials, and release builds

Paged out of the root `CLAUDE.md`. Read this when touching Docker, the client
template, tracker credentials, the MCP mode, or release packaging.

## Tracker credentials

Each tracker adapter declares its own credential env vars via the `secret_environment_names/1` callback — `LINEAR_API_KEY` (linear), `JIRA_EMAIL` + `JIRA_API_TOKEN` (jira), `ASANA_PAT` (asana), `GITHUB_TOKEN`/`GH_TOKEN` (github), `GITLAB_TOKEN`/`GITLAB_PAT` (gitlab).

## The MCP mode

The built escript `./bin/symphony --linear-mcp --workflow <path>` serves the MCP stdio server in
`mcp/linear_server.ex` without opening the installation database. The `claude` backend spawns it
to give Claude Code tracker access (`claude.linear_mcp_command`) using the attempt's private
workflow snapshot. Keep the escript for MCP; run the database-backed daemon through `mix symphony`
or a Burrito release, not an escript, because SQLite's NIF needs an on-disk application layout.

## Docker and client deployments

One installation serves one client and runs multiple lanes in one `mix symphony serve` process.
Each lane has its own tracker scope, hooks, agent settings, prompt, limits and scheduler; selected
execution profiles share worker settings, credential references and workspace bases.
For Linear, each lane needs at least one of `tracker.provider.team_keys`,
`tracker.provider.current_cycle`, or `tracker.provider.project_slug`; see the adapter profile in
`elixir/README.md`. Lanes share one SQLite database and installation credentials, not tenant isolation.

Clients self-host from private repos seeded by `deploy/client-template/`, pulling the published
`ghcr.io/adelrioj/symphony` image (built by `.github/workflows/docker-publish.yml`). This repo's root
Compose file is only a source-built development installation: its service is `symphony-example`;
the client template's service is `symphony`.

The image pins Erlang/Elixir from `elixir/mise.toml` and starts with `ENTRYPOINT ["mix", "symphony"]`.
`mix escript.build` already compiles the application and dependencies on disk; the image retains
that build tree for the SQLite NIF, so a redundant `mix compile` adds no packaging effect.
`/app/elixir/bin` is on `PATH` so the default `symphony` MCP command resolves to the built escript.

Both Compose services run:

```bash
mix symphony serve --host 0.0.0.0 --port 4000 --data-root /data \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

They require `SYMPHONY_OPERATOR_TOKEN` and `LINEAR_API_KEY` in the environment (the client template
also loads `.env` for clone and other deployment credentials). The operator token is a separate,
high-entropy installation credential; generate one with `openssl rand -hex 32`. `serve` refuses
to start without it. Tracker and agent credentials are still required for the corresponding lanes.

The `/data` named volume holds `symphony.sqlite3` and `log/`; it replaces the old log-only mount
and `--logs-root` flag. `/workspaces` remains a separate persistent volume. Preserve both during
upgrades: `docker compose down -v` deletes them. Relative profile workspace bases resolve against
`--data-root`; use distinct bases or lane subdirectories under `/workspaces` for container lanes.

Both Compose files mount the import directory read-only at `/config`, not a single file, so
explicit imports see files replaced by host editors. Mounted files are never watched. YAML
`server:` values are accepted but ignored with a warning; the listener is installation-level.
The container binds `0.0.0.0` via `serve --host`, while the host publishes only `127.0.0.1:4000`.
The UI/API are authenticated, but remote use still needs a TLS reverse proxy or SSH tunnel:
do not expose bearer credentials over public HTTP.

For a new root development installation, export both required credentials and build provenance from a clean checkout, then:

```bash
export SOURCE_REVISION="$(git rev-parse HEAD)"
export SOURCE_ARCHIVE_SHA256="$(git archive --format=tar "$SOURCE_REVISION" elixir | sha256sum | cut -d' ' -f1)"
docker compose build
docker compose run --rm symphony-example lanes import /config/example.md --slug example --data-root /data
docker compose up -d
```

Log in at <http://localhost:4000> with the operator token and enable `example`. A newly imported
lane is disabled. The client template's equivalent imports `/config/workflow.md` as `main` with
the service name `symphony`; its README has the full setup and API enable command.

## Client migration

Replace separate `features`, `bugs`, and `qa` daemons for the **same client** with three lanes in
one installation. Do not combine separate clients: use distinct services, databases/volumes,
operator tokens, tracker/clone secrets, and agent credentials for each trust boundary. The template
shares the host `~/.codex` directory; use separate credential directories when isolating clients.
Agents can read the installation environment and mounted `.env`; do not put unrelated secrets there.

1. Render the client's existing workflows into `features.md`, `bugs.md`, and `qa.md` in its import
   directory. Preserve the intended scopes/prompts and assign safe profile bases/subdirectories under
   `/workspaces`. Remove `server:` settings; host/port are now service flags.
2. Drain active work before stopping the old daemons so the new installation will not dispatch
   the same issues concurrently. With the new service stopped, import all three into its database:

   ```bash
   docker compose run --rm symphony lanes import /config/features.md --slug features --data-root /data
   docker compose run --rm symphony lanes import /config/bugs.md --slug bugs --data-root /data
   docker compose run --rm symphony lanes import /config/qa.md --slug qa --data-root /data
   docker compose up -d
   ```

   All imports and `serve` must use the same `--data-root /data`. Native deployments use
   `mix symphony lanes import <file> --slug <slug> --data-root <dir>` and the same directory for
   `mix symphony serve`. Keep one service unit, with `SYMPHONY_OPERATOR_TOKEN` and tracker/clone
   secrets in its protected `EnvironmentFile`, an Elixir working directory, a provisioned Mix/OTP
   toolchain, and the acknowledgement flag on `ExecStart`. Do not retain one unit per lane.
3. Log in and enable the three lanes individually, checking each lane's tracker preflight status.
   A preflight error disables that lane, not the installation. The same enable action is
   `PUT /api/v1/lanes/:slug` with `{"enabled":true}` and bearer authentication.
4. Converge subsequent configuration through the authenticated API, not file replacement or
   service restart. With `TOKEN` set to the installation operator token:

   ```bash
   curl --fail-with-body -X PUT http://localhost:4000/api/v1/lanes/features \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     --data @payload.json
   ```

   `payload.json` is a JSON object using lane-owned attributes: `execution_profile_id`,
   `workspace_subdir`, `config`, `prompt`, optional `name`, `enabled`, and `note`. `config` must
   not contain `worker`, `workspace`, or `workspace_base`; those belong to the selected profile.
   Supplying config or prompt creates an immutable lane version; metadata-only updates do not.
   Invalid saves return HTTP 422 with field-path errors and leave configuration unchanged. Valid
   saves do not restart active attempts, which retain dispatch-time snapshots.

   Manage shared infrastructure separately:

   ```bash
   curl --fail-with-body -X PUT http://localhost:4000/api/v1/execution-profiles/1 \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     --data '{"description":"Shared workers","worker":{"ssh_hosts":["worker-1"]}}'
   ```

   Profile updates validate and publish every linked lane atomically. They apply to future runs and
   leave active attempts/cleanup on their captured snapshot. Guarded workspace/target identity
   changes are rejected while the lane/profile owns reservations, runs, retained resources, or an
   unverifiable remote inventory; explicitly disable and complete supported cleanup before retrying.

`lanes import` is an offline operation. It creates a disabled lane and a generated dedicated
execution profile, and reports that profile name. Imports made while `serve` runs are not picked up
by that process until restart; use the structured UI/API for live changes. Changes to installation
flags or environment credentials still require a planned service restart. Back up the database and
workspaces before deployment migrations; old log-only volumes are not lane databases and are not
migrated automatically. Migration keeps invalid/overlapping legacy lanes disabled and visible for
repair; do not delete their history or bypass the identity guard.

## Release builds

Tagged pushes build Burrito binaries (`burrito-release.yml`, `releases` in `mix.exs`) for macOS/Linux on arm64 + x86_64.
