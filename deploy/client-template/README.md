# Symphony deployment

One container, one client installation, many lanes. Each lane has its own tracker scope,
workspace root, agent settings, hooks, prompt, and scheduler; all lanes share the installation's
SQLite database and operator credential. Everything here is yours — copy this directory into
your own private repo. Lanes are not security boundaries between clients.

## Prerequisites

- **Docker Engine with Docker Compose v2.24 or newer** — Docker Desktop or
  [OrbStack](https://orbstack.dev/) both ship it. Check with `docker compose version`; older
  Compose releases reject the `env_file` mapping in `docker-compose.yml` with a parse error.
- **The Codex CLI**, installed on the host and logged in. Symphony's agents run Codex inside the
  container, but the container has no browser, so it reuses the login file that the CLI writes on
  the host. Get it from <https://github.com/openai/codex>.
- **A Linear API key** with access to the work you want automated.
- **An operator token** for this installation. Use a high-entropy value, not a tracker API key.

## Setup

1. Log in to Codex once on the host (the container mounts the `~/.codex` directory):
   ```bash
   codex login
   ls -ld ~/.codex        # a directory containing auth.json
   ```
   The container shares this one login and can refresh the token itself, so a long-running
   deployment keeps working without you logging in again. If you run several projects on one
   host, they all share this directory and therefore the same Codex account.
2. Set your Linear key and operator token:
   ```bash
   cp .env.example .env      # then set LINEAR_API_KEY and SYMPHONY_OPERATOR_TOKEN
   openssl rand -hex 32      # use this output as the operator token in .env
   ```
   Both values are required by Compose. For the host-side API commands below, also export the
   same `SYMPHONY_OPERATOR_TOKEN` value in your shell; Compose does not export `.env` to it.
3. Prepare and import `workflow.md` once:
   - The read scope — at least one of `tracker.provider.team_keys`,
     `tracker.provider.current_cycle` (requires `team_keys`), or `tracker.provider.project_slug`.
     A lane needs a valid scope before it can run. `tracker.required_labels` and
     `tracker.any_labels` narrow whichever scope you pick; they cannot stand in for it.
     - `project_slug` is the slug from your Linear project's URL, **not** the project's display
       name. Open the project in Linear and copy the `<project-name>-<id>` segment of
       `https://linear.app/<workspace>/project/<project-name>-<id>/overview` (the URL may end in
       `/overview` or `/issues` — do not copy that part); it looks like
       `my-project-4c1a9f3b7e02`. **This is the one value whose failure is still silent:** for an
       unknown slug Linear simply returns zero issues, Symphony logs nothing, and the container
       sits idle forever with clean logs and a working dashboard. Startup preflight does not
       resolve project slugs. If no issue is ever picked up with a project-only scope, suspect
       this line first.
     - `team_keys` is checked. When a lane starts, Symphony resolves every configured team key
       against Linear. A missing team fails that lane's preflight and disables it with a named
       error; other lanes and the installation remain available.
   - `hooks.after_create` — the clone command for your repo
   - `tracker.active_states` / `terminal_states` — must match the workflow state names in *your*
     Linear workspace exactly. `Merging` and `Rework` do not exist in a default workspace, and
     `Cancelled` / `Canceled` are two spellings of one state, so prune the shipped lists before you
     enable `team_keys`. With `team_keys` configured, startup checks these too: a state name that
     exists in none of the listed teams fails the lane's preflight with a named error, and one
     missing from only some teams logs a warning naming those teams — unless a listed team has
     50 or more workflow states, in which case absence cannot be proven and Symphony warns instead.
     With a project-only scope there is nothing to check them against, and an unknown state name is
     silently never matched, with the same idle-container symptom as a wrong slug. Configured
     `required_labels` / `any_labels` are checked by exactly the same rule, and likewise only when
     `team_keys` is set.
   - Keep the first lane's `workspace.root` under `/workspaces` (the persistent volume). For
     multiple lanes use separate roots, such as `/workspaces/features` and `/workspaces/bugs`,
     to avoid sharing per-issue clones.
   - `server:` in imported YAML is ignored with a warning. Compose supplies installation-level
     `serve --host 0.0.0.0 --port 4000`; no workflow file controls the HTTP listener.

   With the service stopped, import into the same data root used by `serve`:
   ```bash
   docker compose run --rm symphony lanes import /config/workflow.md --slug main --data-root /data
   ```
   A new lane is created disabled. `/config` is an import directory, not a live configuration
   source. Never omit `--data-root /data`: the command must use the service's database volume.
4. Start the installation:
   ```bash
   docker compose up -d
   ```
   Open <http://localhost:4000>, log in with the operator token, and enable `main`. Alternatively:
   ```bash
   curl --fail-with-body -X PUT http://localhost:4000/api/v1/lanes/main \
     -H "Authorization: Bearer $SYMPHONY_OPERATOR_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"enabled":true}'
   ```
   Enabling runs tracker preflight before the lane starts. Inspect its status in the UI if it
   remains stopped. Add further lanes in the UI, or import them while the service is stopped.

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

The running configuration lives in the database. Edit a lane at `/lanes/main/edit`, or save
through the authenticated API — editing the mounted `workflow.md` does nothing automatically.
`lanes import` is an offline command: if used while `serve` runs, its writes are not observed by
that process until restart. Use the UI/API for live changes instead.

For automation, put the desired fields in `payload.json` and submit:

```bash
curl --fail-with-body -X PUT http://localhost:4000/api/v1/lanes/main \
  -H "Authorization: Bearer $SYMPHONY_OPERATOR_TOKEN" \
  -H "Content-Type: application/json" \
  --data @payload.json
```

`front_matter` is a raw YAML string without the `---` delimiters; `prompt` is the Markdown body
string. A save containing either creates an immutable workflow version; omitted fields retain
their current values. For example, `{"prompt":"Work on the assigned issue.","note":"Revise prompt"}`
changes only the prompt. Metadata-only saves, including `{"enabled":true}`, do not create a version.
Invalid saves return HTTP 422 with field-path errors and are not stored; the form shows those
errors inline. Version history and rollback are available at `/lanes/main/versions`.

Valid prompt/configuration saves apply without restarting active attempts: those attempts retain
their dispatch-time configuration, while future dispatches use the saved version. Changes to
guarded tracker/workspace identity are rejected while the lane owns work rather than interrupting
it. Explicitly disabling a lane stops its runtime and active work; that is not a configuration-save
workaround. Do not restart the container just to deploy a prompt change.

The `data` volume holds `/data/symphony.sqlite3` and `/data/log/`; preserve it across upgrades.
Do not use `docker compose down -v` unless intentionally deleting database/history and workspaces.
Runtime logs are rotating files, not `docker compose logs` (stdout belongs to the status board):

```bash
docker compose exec symphony sh -lc 'cat /data/log/symphony.log.[0-9]*' | tail -n 20
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

2. Use it in the clone URL in the lane's YAML (or in `workflow.md` before the first import):

   ```yaml
   hooks:
     after_create: |
       git clone --depth 1 https://x-access-token:${GIT_TOKEN}@github.com/your-org/your-repo .
   ```

3. Save the lane configuration through the UI/API. Environment changes still require
   `docker compose up -d` to recreate the container: `.env` is read at container start, not live.
   Plan that restart for a maintenance window because it interrupts active work.

SSH cloning also works in principle, but this template does not set it up: it additionally
requires mounting a private key into the container and seeding `known_hosts`, or host-key
verification fails.

## Security notes

- The dashboard and JSON API require the installation's `SYMPHONY_OPERATOR_TOKEN`. The browser
  login creates an authenticated session; scripts send `Authorization: Bearer <token>`.
  Cookie-authenticated writes also require CSRF protection; bearer API automation does not.
- Keep `ports:` publishing on `127.0.0.1:4000`. For remote use, put a TLS reverse proxy in front
  of it or use an SSH tunnel; an operator token is not encryption and must not cross public HTTP.
- Inside the container, `serve --host 0.0.0.0` binds the interface Docker forwards to. A
  container-side `127.0.0.1` bind makes the dashboard unreachable from the published port.
  Container binds all interfaces; host publishes loopback only. Workflow `server:` is ignored.
- Treat each installation as one trust boundary: all its lanes share credentials, database,
  filesystem access, and operator authority. Separate clients need separate installations,
  tokens, volumes, tracker/clone secrets, and agent credentials; lanes are not tenant isolation.
- Everything in `.env` is passed into the container and readable by the agents Symphony runs
  (they run with `approval_policy: never`). Keep `.env` to the keys this deployment needs.
- `.gitignore` here excludes `.env` and common private-key filenames. Keep it that way: a private
  repo is not a secret store — a committed key stays in history and is visible to collaborators.
