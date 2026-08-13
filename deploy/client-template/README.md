# Symphony deployment

One container, one project: a single Linear project plus a single repo. Everything here is
yours — this directory is meant to be copied into your own private repo.

## Setup

1. Log in to Codex once on the host (the container mounts `~/.codex/auth.json` read-only):
   ```bash
   codex login
   ```
2. Set your Linear key:
   ```bash
   cp .env.example .env      # then edit LINEAR_API_KEY
   ```
3. Edit `workflow.md`:
   - `tracker.provider.project_slug` — your Linear project
   - `hooks.after_create` — the clone command for your repo
   - `tracker.active_states` / `terminal_states` — must match your Linear workflow states
   - Keep `workspace.root: /workspaces` (it must match the volume mount in compose)
4. Start it:
   ```bash
   docker compose up -d
   ```
   Dashboard: <http://localhost:4000>

## Authenticating to GHCR

The image lives in GitHub Container Registry. If `docker compose pull` (or the first
`docker compose up -d`) fails with an authentication error or `denied`, the package is
private and you need to log in once:

```bash
echo "$GITHUB_PAT" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

`GITHUB_PAT` is a GitHub personal access token with the `read:packages` scope. If the pull
succeeds without logging in, the package is public and you can skip this section entirely —
the operator can make the package public once instead of issuing a token per client.

## Editing the pipeline

Save `workflow.md` and the running container picks it up within about a second — no restart.
If an edit is invalid, Symphony logs the error and keeps running the last valid version, so a
typo degrades to "no change" rather than an outage. Check with:

```bash
docker compose logs -f
```

## Upgrading

```bash
docker compose pull && docker compose up -d
```

Pin a version tag in `docker-compose.yml` (e.g. `:0.0.2`) instead of `:latest` if you want
upgrades to be an explicit edit.

## Private repos

`hooks.after_create` runs inside the container. For a private repo, either clone over SSH with
a key mounted into the container, or put a token in `.env` and use it in an HTTPS clone URL —
the agent backend inherits the container environment.
