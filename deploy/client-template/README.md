# Symphony deployment

One container, one project: a single Linear project plus a single repo. Everything here is
yours — this directory is meant to be copied into your own private repo.

## Prerequisites

- **Docker Engine with Docker Compose v2.24 or newer** — Docker Desktop or
  [OrbStack](https://orbstack.dev/) both ship it. Check with `docker compose version`; older
  Compose releases reject the `env_file` mapping in `docker-compose.yml` with a parse error.
- **The Codex CLI**, installed on the host and logged in. Symphony's agents run Codex inside the
  container, but the container has no browser, so it reuses the login file that the CLI writes on
  the host. Get it from <https://github.com/openai/codex>.
- **A Linear API key** with access to the project you want automated.

## Setup

1. Log in to Codex once on the host (the container mounts the `~/.codex` directory):
   ```bash
   codex login
   ls -ld ~/.codex        # a directory containing auth.json
   ```
   The container shares this one login and can refresh the token itself, so a long-running
   deployment keeps working without you logging in again. If you run several projects on one
   host, they all share this directory and therefore the same Codex account.
2. Set your Linear key:
   ```bash
   cp .env.example .env      # then edit LINEAR_API_KEY
   ```
3. Edit `workflow.md`:
   - `tracker.provider.project_slug` — the slug from your Linear project's URL, **not** the
     project's display name. Open the project in Linear and copy the `<project-name>-<id>`
     segment of `https://linear.app/<workspace>/project/<project-name>-<id>/overview`
     (the URL may end in `/overview` or `/issues` — do not copy that part); it looks like
     `my-project-4c1a9f3b7e02`. This is the one value whose failure is silent: for an unknown
     slug Linear simply returns zero issues, Symphony logs nothing, and the container sits idle
     forever with clean logs and a working dashboard. If no issue is ever picked up, suspect
     this line first.
   - `hooks.after_create` — the clone command for your repo
   - `tracker.active_states` / `terminal_states` — must match the workflow state names in *your*
     Linear workspace exactly. `Merging` and `Rework` do not exist in a default workspace; a
     state name that does not exist there is silently never matched, with the same idle-container
     symptom as a wrong slug.
   - Keep `workspace.root: /workspaces` (it must match the volume mount in compose)
4. Start it:
   ```bash
   docker compose up -d
   ```
   Dashboard: <http://localhost:4000>

## Pulling the image

The image lives in GitHub Container Registry at `ghcr.io/adelrioj/symphony`. The package is
public, so `docker compose pull` and `docker compose up -d` work with no login and no token.

If a pull ever fails with an authentication error or `denied`, the package's visibility has
changed. A token alone cannot fix that: ask the operator to make the package public again or
grant your GitHub account read access, then log in once with a personal access token carrying
the `read:packages` scope:

```bash
echo "$GITHUB_PAT" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

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

`hooks.after_create` runs inside the container, so the clone needs credentials that exist there.
The supported path is HTTPS with a token: compose loads this directory's `.env` into the
container environment (`env_file`), and Symphony runs the hook through the container's own shell
(`sh -lc`), which inherits that environment — so a token you put in `.env` is expanded in the
clone URL.

1. Create a GitHub personal access token with read access to the repo (a fine-grained token with
   *Contents: Read* is enough) and add it to `.env` — never to `workflow.md`, which is committed:

   ```bash
   # .env
   LINEAR_API_KEY=lin_api_...
   GIT_TOKEN=github_pat_...
   ```

2. Use it in the clone URL in `workflow.md`:

   ```yaml
   hooks:
     after_create: |
       git clone --depth 1 https://x-access-token:${GIT_TOKEN}@github.com/your-org/your-repo .
   ```

3. `docker compose up -d` again — `.env` changes are read at container start, not hot-reloaded.

SSH cloning also works in principle, but this template does not set it up: it additionally
requires mounting a private key into the container and seeding `known_hosts`, or host-key
verification fails.

## Security notes

- The dashboard and JSON API have **no authentication**. Exposure is controlled on the host side:
  the `ports:` entry in `docker-compose.yml` publishes on `127.0.0.1:4000` only — do not widen it
  to `0.0.0.0`. For remote access, front it with an authenticated reverse proxy or use an SSH
  tunnel.
- Inside the container, `server.host` in `workflow.md` must stay `0.0.0.0`, and that is not a
  contradiction: Docker forwards the published port to the container's own network interface, not
  to its loopback, so a container-side `127.0.0.1` bind makes the dashboard unreachable while the
  container still looks healthy. Container binds all interfaces; host publishes loopback only.
- Everything in `.env` is passed into the container and readable by the agents Symphony runs
  (they run with `approval_policy: never`). Keep `.env` to the keys this deployment needs.
- `.gitignore` here excludes `.env` and common private-key filenames. Keep it that way: a private
  repo is not a secret store — a committed key stays in history and is visible to collaborators.
