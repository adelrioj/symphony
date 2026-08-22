# Deployment, credentials, and release builds

Paged out of the root `CLAUDE.md`. Read this when touching Docker, the client
template, tracker credentials, the MCP mode, or release packaging.

## Tracker credentials

Each tracker adapter declares its own credential env vars via the `secret_environment_names/1` callback — `LINEAR_API_KEY` (linear), `JIRA_EMAIL` + `JIRA_API_TOKEN` (jira), `ASANA_PAT` (asana), `GITHUB_TOKEN`/`GH_TOKEN` (github), `GITLAB_TOKEN`/`GITLAB_PAT` (gitlab).

## The MCP mode

The escript has a second mode: `./bin/symphony --linear-mcp --workflow <path>` serves the MCP stdio server in `mcp/linear_server.ex` instead of starting the daemon. The `claude` agent backend spawns this on itself to give Claude Code tracker access (`claude.linear_mcp_command`) — don't repurpose it as a general entrypoint.

## Docker and client deployments

One instance drives one repo, scoped either by `tracker.provider.project_slug` or by `tracker.provider.team_keys` plus optional `tracker.any_labels`; team scoping lets tickets from any project qualify, so adding a project needs no config change. At least one of the two scope selectors is required, and with `team_keys` set the adapter resolves team keys, labels and state names against Linear at startup and refuses to boot naming anything that does not resolve. Client deployments are self-hosted from their own private repos, seeded by copying `deploy/client-template/`, which pulls the published image `ghcr.io/adelrioj/symphony` (built and pushed by `.github/workflows/docker-publish.yml`). This repo keeps only local dev: `docker/Dockerfile`, `docker-compose.yml` (one `symphony-example` service), `.env.example`, and the single sanitized `workflows/example.md`. Both compose files mount the workflow file's directory read-only at `/config` — never the single file, or an editor's rename-replace on the host kills hot reload — pass `--i-understand-that-this-will-be-running-without-the-usual-guardrails` (the CLI refuses to start without it), and publish on `127.0.0.1:4000` only, since the dashboard and JSON API have no authentication; the workflow files set `server.host: 0.0.0.0` so the container binds the interface Docker forwards to. Steps are in `elixir/README.md` ("Run in Docker") and `deploy/client-template/README.md`. The image pins its toolchain from `elixir/mise.toml`; keep those two in sync.

## Release builds

Tagged pushes build Burrito binaries (`burrito-release.yml`, `releases` in `mix.exs`) for macOS/Linux on arm64 + x86_64.
