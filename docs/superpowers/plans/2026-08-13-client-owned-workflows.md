# Client-Owned Workflow Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every client-specific Symphony workflow out of this product repo, publish the runtime image to GHCR, and ship a copy-once deployment template so each self-hosting client owns and edits their own workflow without product-repo access.

**Architecture:** No Elixir changes. `cli.ex` already accepts any workflow path and `WorkflowStore` already hot-reloads on a 1 s content stamp with last-known-good fallback, so the whole change is repo layout, CI, and Docker wiring: strip `workflows/` down to one sanitized example, add a multi-arch GHCR publish workflow built on native runners, add `deploy/client-template/` as the seed of a client's private repo, and repoint the root compose file at local dev only.

**Tech Stack:** Docker Compose, GitHub Actions (`docker/*` actions, GHCR), Elixir/OTP image built by `docker/Dockerfile`, Markdown docs.

## Global Constraints

- No changes to any file under `elixir/lib/` or `elixir/test/`. This plan touches zero Elixir source; if a task seems to require one, stop and escalate.
- GHCR image name is `ghcr.io/${{ github.repository }}` (resolves to `ghcr.io/adelrioj/symphony`); never hardcode the owner in workflow YAML.
- Every GitHub Action MUST be pinned by full commit SHA with a trailing `# vN` comment, matching `.github/workflows/burrito-release.yml`.
- Workflow files are mounted into containers as a **directory** (`:/config:ro`), never as a single file. A single-file bind mount pins the inode, so an editor's rename-replace on the host silently stops propagating and hot reload dies.
- `workspace.root: /workspaces` in any workflow file MUST match the container volume mount.
- Commit after each task with a conventional-commit subject, no AI attribution footers, no co-author trailers.
- The repo is a fork of `openai/symphony` (`upstream`); keep changes additive to shared files where possible so upstream merges stay clean.

---

### Task 1: Strip client workflows and repoint the root compose file at local dev

Removes the actual leak (`workflows/wmp-shipit.md`) and collapses the two-project compose demo into a single local-dev service using a directory mount.

**Files:**
- Delete: `workflows/wmp-shipit.md`
- Delete: `workflows/project-b.md`
- Rename: `workflows/project-a.md` → `workflows/example.md`
- Modify: `docker-compose.yml` (full rewrite, currently 46 lines)
- Verify: no test files reference these paths (`grep` step below proves it)

**Interfaces:**
- Consumes: nothing.
- Produces: `workflows/example.md` — the single sanitized workflow, also copied verbatim into `deploy/client-template/workflow.md` in Task 3. Compose service name `symphony-example`, container config mount point `/config`, workflow path inside the container `/config/example.md`.

- [ ] **Step 1: Prove nothing in code or tests depends on the files being removed**

Run:
```bash
grep -rn "wmp-shipit\|project-a\|project-b\|workflows/" elixir/ docker/ .github/ --include="*.ex" --include="*.exs" --include="*.yml" --include="*.yaml" --include="Dockerfile"
```
Expected: matches only in `.github/workflows/*.yml` referring to GitHub's own `.github/workflows` directory, and `elixir/test/symphony_elixir/live_e2e_test.exs` referring to its own private `test/support/live_e2e_docker/docker-compose.yml`. **No match may point at the repo-root `workflows/` directory.** If one does, stop — the plan's "no Elixir changes" constraint is wrong and needs escalation.

- [ ] **Step 2: Remove the client workflow and the duplicate placeholder**

```bash
git rm workflows/wmp-shipit.md workflows/project-b.md
git mv workflows/project-a.md workflows/example.md
```

- [ ] **Step 3: Retitle the example workflow's header comment**

In `workflows/example.md`, replace the first two comment lines (currently lines 2-3, beginning `# Per-project config for one Symphony container.`) with:

```yaml
# Sanitized example workflow — the only workflow kept in the product repo.
# Real client deployments live in their own private repos: copy deploy/client-template/.
# Blank body below => Symphony's default Codex prompt template.
```

Leave every other line unchanged, including `project_slug: "REPLACE-with-linear-project-slug-a"` and `workspace.root: /workspaces`.

- [ ] **Step 4: Rewrite `docker-compose.yml` as a single local-dev service**

Replace the entire file with:

```yaml
# Local development only: one Symphony container built from source, running the sanitized
# example workflow. Client deployments do NOT belong here — each client owns a private repo
# seeded from deploy/client-template/, which pulls the published GHCR image.
#
#   export LINEAR_API_KEY=...
#   docker compose up --build          # or: orb start, then the same command
#
# The workflow is mounted as a directory, not a single file: a single-file bind mount pins
# the inode, so an editor's rename-replace on the host stops propagating and hot reload dies.

services:
  symphony-example:
    build:
      context: .
      dockerfile: docker/Dockerfile
    image: symphony:latest
    environment:
      LINEAR_API_KEY: ${LINEAR_API_KEY:?set LINEAR_API_KEY in your shell}
    restart: unless-stopped
    volumes:
      - ${HOME}/.codex/auth.json:/root/.codex/auth.json:ro   # Codex login from the host
      - ./workflows:/config:ro
      - example-workspaces:/workspaces
      - example-logs:/app/elixir/log
    command: ["/config/example.md", "--port", "4000", "--logs-root", "/app/elixir/log"]
    ports:
      - "4000:4000"   # dashboard + JSON API -> http://localhost:4000

volumes:
  example-workspaces:
  example-logs:
```

- [ ] **Step 5: Validate the compose file parses and resolves**

Run:
```bash
LINEAR_API_KEY=dummy docker compose config >/dev/null && echo COMPOSE_OK
```
Expected: `COMPOSE_OK`. A YAML or interpolation error prints a `services.symphony-example...` diagnostic instead — fix it before committing.

- [ ] **Step 6: Confirm no client data remains in the working tree**

Run:
```bash
grep -rn "wmp-shipit\|watsonandmonday\|symphony-workflow-2f7600b452dc" . --exclude-dir=.git --exclude-dir=docs
```
Expected: no output. (`docs/` is excluded on purpose: the design spec and this plan discuss the removal by name, and historical plan docs are out of scope per the spec's acceptance criteria.)

- [ ] **Step 7: Commit**

```bash
git add -A workflows docker-compose.yml
git commit -m "refactor: keep only a sanitized example workflow in the product repo"
```

---

### Task 2: Publish the runtime image to GHCR (multi-arch, native runners)

Without a published image, clients still need to clone this repo to build — which is the access path the whole change is removing.

**Files:**
- Create: `.github/workflows/docker-publish.yml`
- Reference (unchanged): `docker/Dockerfile`, `.github/workflows/burrito-release.yml` (SHA-pinning and runner conventions)

**Interfaces:**
- Consumes: `workflows/example.md` is irrelevant to the build; the image only needs `docker/Dockerfile` and `elixir/`.
- Produces: image `ghcr.io/adelrioj/symphony` with tags `latest` (default branch), `<major.minor.patch>` and `<major.minor>` (on `v*` tags), and `sha-<short>` (always). Task 3's template compose file pulls `ghcr.io/adelrioj/symphony:latest`.

**Why two native runner jobs instead of one QEMU job:** `docker/Dockerfile` installs Erlang/OTP through mise/kerl, which **compiles OTP from source** (see its `KERL_CONFIGURE_OPTIONS`). Under QEMU emulation that compile routinely runs for hours and can exceed the job limit. `burrito-release.yml` already proves native `ubuntu-24.04-arm` runners are available to this repo, so each architecture builds natively and a final job stitches the two digests into one manifest list.

- [ ] **Step 1: Create the publish workflow**

Create `.github/workflows/docker-publish.yml`:

```yaml
name: docker-publish

on:
  workflow_dispatch:
  push:
    branches:
      - main
    tags:
      - "v*"

env:
  IMAGE: ghcr.io/${{ github.repository }}

jobs:
  build:
    name: build-${{ matrix.platform }}
    runs-on: ${{ matrix.runner }}
    permissions:
      contents: read
      packages: write
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: linux/amd64
            runner: ubuntu-24.04
            slug: amd64
          - platform: linux/arm64
            runner: ubuntu-24.04-arm
            slug: arm64

    steps:
      - name: Checkout
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4

      - name: Set up Buildx
        uses: docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f # v3

      - name: Log in to GHCR
        uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9 # v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push by digest
        id: build
        uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8 # v6
        with:
          context: .
          file: docker/Dockerfile
          platforms: ${{ matrix.platform }}
          cache-from: type=gha,scope=${{ matrix.slug }}
          cache-to: type=gha,mode=max,scope=${{ matrix.slug }}
          outputs: type=image,name=${{ env.IMAGE }},push-by-digest=true,name-canonical=true,push=true

      - name: Export digest
        env:
          DIGEST: ${{ steps.build.outputs.digest }}
        run: |
          mkdir -p /tmp/digests
          touch "/tmp/digests/${DIGEST#sha256:}"

      - name: Upload digest
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        with:
          name: digest-${{ matrix.slug }}
          path: /tmp/digests/*
          if-no-files-found: error
          retention-days: 1

  merge:
    name: merge-manifest
    needs: build
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write

    steps:
      - name: Download digests
        uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4
        with:
          pattern: digest-*
          merge-multiple: true
          path: /tmp/digests

      - name: Set up Buildx
        uses: docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f # v3

      - name: Log in to GHCR
        uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9 # v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Docker metadata
        id: meta
        uses: docker/metadata-action@c299e40c65443455700f0fdfc63efafe5b349051 # v5
        with:
          images: ${{ env.IMAGE }}
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,format=short

      - name: Create manifest list and push
        working-directory: /tmp/digests
        run: |
          docker buildx imagetools create \
            $(jq -cr '.tags | map("-t " + .) | join(" ")' <<<"$DOCKER_METADATA_OUTPUT_JSON") \
            $(printf "${IMAGE}@sha256:%s " *)

      - name: Inspect published image
        run: docker buildx imagetools inspect "${IMAGE}:${{ steps.meta.outputs.version }}"
```

- [ ] **Step 2: Validate the workflow YAML parses**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/docker-publish.yml')); print('YAML_OK')"
```
Expected: `YAML_OK`.

- [ ] **Step 3: Verify every action is SHA-pinned**

Run:
```bash
grep -n "uses:" .github/workflows/docker-publish.yml | grep -v "@[0-9a-f]\{40\} #"
```
Expected: no output. Any line printed is an unpinned action — pin it.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/docker-publish.yml
git commit -m "ci: publish multi-arch symphony image to ghcr"
```

- [ ] **Step 5: Run it once and verify the manifest (requires push access; do after merge to main)**

Run:
```bash
gh workflow run docker-publish.yml
gh run watch
docker buildx imagetools inspect ghcr.io/adelrioj/symphony:latest
```
Expected: the inspect output lists two manifests, `linux/amd64` and `linux/arm64`. If the package is private, make it public (or document a PAT pull) before handing the template to clients — record which you chose in `deploy/client-template/README.md` during Task 3.

---

### Task 3: Add the client deployment template

The artifact a client copies once into their own private repo. Self-contained: no product-repo file is referenced by relative path.

**Files:**
- Create: `deploy/client-template/docker-compose.yml`
- Create: `deploy/client-template/workflow.md`
- Create: `deploy/client-template/.env.example`
- Create: `deploy/client-template/README.md`
- Create: `deploy/client-template/.gitignore`

**Interfaces:**
- Consumes: image `ghcr.io/adelrioj/symphony:latest` from Task 2; `workflows/example.md` from Task 1 as the seed content for `workflow.md`.
- Produces: the onboarding artifact referenced by the docs in Task 4 (`deploy/client-template/`).

- [ ] **Step 1: Seed the template workflow from the sanitized example**

```bash
mkdir -p deploy/client-template
cp workflows/example.md deploy/client-template/workflow.md
```

Then replace the leading comment lines of `deploy/client-template/workflow.md` (the three `#` lines added in Task 1, before `tracker:`) with:

```yaml
# Your Symphony pipeline. Edit the marked lines; everything else is a working default.
# Symphony re-reads this file about once a second — saving it applies the change live.
# A broken edit is logged and ignored; the last valid version keeps running.
# Blank body below => Symphony's default Codex prompt template. Write a prompt body here
# to drive a custom pipeline.
```

- [ ] **Step 2: Write the template compose file**

Create `deploy/client-template/docker-compose.yml`:

```yaml
# One Symphony container for one project (one Linear project + one repo).
#
#   cp .env.example .env     # then edit LINEAR_API_KEY
#   docker compose up -d
#
# Upgrade:  docker compose pull && docker compose up -d
#
# This directory is mounted read-only at /config as a *directory*, not a single file:
# a single-file bind mount pins the inode, so an editor's rename-replace on the host stops
# propagating into the container and live reload of workflow.md dies.
# Note: .env is therefore visible inside the container at /config/.env — no new exposure,
# the same key is already passed in as an environment variable.

services:
  symphony:
    image: ghcr.io/adelrioj/symphony:latest   # pin a version tag (e.g. :0.0.2) for production
    environment:
      LINEAR_API_KEY: ${LINEAR_API_KEY:?set LINEAR_API_KEY in .env}
    restart: unless-stopped
    volumes:
      - ${HOME}/.codex/auth.json:/root/.codex/auth.json:ro   # host Codex login
      - .:/config:ro
      - workspaces:/workspaces
      - logs:/app/elixir/log
    command: ["/config/workflow.md", "--port", "4000", "--logs-root", "/app/elixir/log"]
    ports:
      - "4000:4000"   # dashboard + JSON API -> http://localhost:4000

volumes:
  workspaces:
  logs:
```

- [ ] **Step 3: Write the template env example and gitignore**

Create `deploy/client-template/.env.example`:

```bash
# Copy to .env (git-ignored). docker compose auto-loads it for ${VAR} interpolation.
LINEAR_API_KEY=your-linear-api-key
```

Create `deploy/client-template/.gitignore`:

```gitignore
.env
```

- [ ] **Step 4: Write the template README**

Create `deploy/client-template/README.md`:

```markdown
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
```

If Task 2 Step 5 left the GHCR package private, add a short "Authenticating to GHCR" section here with the `docker login ghcr.io` + PAT instructions; if it is public, say nothing.

- [ ] **Step 5: Validate the template compose file standalone**

Run:
```bash
cd deploy/client-template && LINEAR_API_KEY=dummy docker compose config >/dev/null && echo TEMPLATE_OK; cd -
```
Expected: `TEMPLATE_OK`.

- [ ] **Step 6: Prove the template is self-contained**

Run:
```bash
grep -rn "\.\./\|workflows/\|docker/Dockerfile" deploy/client-template/
```
Expected: no output. Any hit means the template reaches back into the product repo and would break once copied out.

- [ ] **Step 7: Commit**

```bash
git add deploy/client-template
git commit -m "feat: add client deployment template for self-hosted symphony"
```

---

### Task 4: Repoint the docs at the new model

`elixir/README.md` and `CLAUDE.md` still tell people to add a service block per project inside this repo, which is exactly the behavior being removed.

**Files:**
- Modify: `elixir/README.md:83-119` (the "Run several projects (Docker / OrbStack)" section)
- Modify: `CLAUDE.md:56` (the one-instance-per-project paragraph)

**Interfaces:**
- Consumes: `deploy/client-template/` (Task 3), `workflows/example.md` and the `symphony-example` service (Task 1), the GHCR image name (Task 2).
- Produces: nothing downstream.

- [ ] **Step 1: Rewrite the README section**

In `elixir/README.md`, replace everything from the heading `## Run several projects (Docker / OrbStack)` through the line ending `...if you route states to it via` + `` `agent.backend_by_state`. `` (currently lines 83-119, i.e. up to but not including `## Burrito releases`) with:

```markdown
## Run in Docker (OrbStack-compatible)

One Symphony instance is scoped to a **single** project: one `tracker.provider.project_slug`
and one repo. To orchestrate several projects, run one container per project. Everything below
works as-is with [OrbStack](https://orbstack.dev/) (native arm64, no platform pins) or Docker
Desktop.

### Deploying a project

Deployments live in their own private repos, not in this one. Copy
[`deploy/client-template/`](../deploy/client-template) into a new repo and follow its README:
it pulls the published image `ghcr.io/adelrioj/symphony`, mounts your `workflow.md`, and needs
no clone of this repo.

### Local development

The repo-root `docker-compose.yml` builds the image from source and runs the sanitized
`workflows/example.md`:

1. **Log in to Codex once** on the host — the container mounts `~/.codex/auth.json` read-only:
   ```bash
   codex login
   ```
2. **Set your Linear key** (git-ignored; `docker compose` auto-loads `.env`):
   ```bash
   cp .env.example .env      # then edit LINEAR_API_KEY
   ```
3. **Edit `workflows/example.md`** — at minimum `tracker.provider.project_slug` and the
   `hooks.after_create` clone URL. Keep `workspace.root: /workspaces` (it must match the volume
   mount in compose).
4. **Launch:**
   ```bash
   docker compose up --build          # first build compiles OTP once, then caches it
   ```
   Dashboard: <http://localhost:4000>.

The workflow directory is mounted read-only at `/config`; editing the file on the host reloads
it in the running container within about a second.

Notes:

- **Private repos:** `after_create` clones over HTTPS. For a private repo, forward a token into
  the container (add `env_file: .env` to the service so Codex inherits it via
  `shell_environment_policy.inherit=all`) and use it in the clone URL.
- **The `claude` backend** is not installed in the image; it ships the Codex CLI only. Add the
  `claude` CLI and its auth if you route states to it via `agent.backend_by_state`.
```

- [ ] **Step 2: Rewrite the CLAUDE.md paragraph**

In `CLAUDE.md`, replace line 56 in full with:

```markdown
One instance drives one project (a single `tracker.project_slug` + one repo). Client deployments are self-hosted from their own private repos, seeded by copying `deploy/client-template/`, which pulls the published image `ghcr.io/adelrioj/symphony` (built and pushed by `.github/workflows/docker-publish.yml`). This repo keeps only local dev: `docker/Dockerfile`, `docker-compose.yml` (one `symphony-example` service), and the single sanitized `workflows/example.md`. Workflow files are mounted as a directory at `/config`, never as a single file, so host edits keep hot-reloading. Steps are in `elixir/README.md` ("Run in Docker"). The image pins its toolchain from `elixir/mise.toml`; keep those two in sync.
```

- [ ] **Step 3: Check for stale references**

Run:
```bash
grep -rn "project-a\|project-b\|Run several projects\|copying a service block\|copy a service block" README.md CLAUDE.md elixir/README.md docker-compose.yml deploy/
```
Expected: no output.

- [ ] **Step 4: Verify every path the docs now promise actually exists**

Run:
```bash
for p in deploy/client-template/README.md deploy/client-template/docker-compose.yml deploy/client-template/workflow.md deploy/client-template/.env.example workflows/example.md .github/workflows/docker-publish.yml; do test -e "$p" || echo "MISSING $p"; done; echo CHECKED
```
Expected: `CHECKED` with no `MISSING` lines.

- [ ] **Step 5: Commit**

```bash
git add elixir/README.md CLAUDE.md
git commit -m "docs: document client-owned deployments and local-dev compose"
```

---

### Task 5: End-to-end verification

Proves the two claims the spec makes that static checks cannot: the local-dev container boots on the example workflow, and a host edit hot-reloads through the directory mount.

**Files:**
- Modify: none (verification only; `workflows/example.md` is edited and reverted in place)

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing.

- [ ] **Step 1: Build and start the local-dev container**

Run:
```bash
LINEAR_API_KEY=dummy docker compose up --build -d
```
Expected: the build succeeds (first run compiles OTP and takes a long time; subsequent runs hit the layer cache) and `symphony-example` reaches `running`.

- [ ] **Step 2: Confirm it loaded the mounted workflow**

Run:
```bash
docker compose logs symphony-example | tail -40
```
Expected: startup logs referencing `/config/example.md`. A tracker error about the placeholder slug (`REPLACE-with-linear-project-slug-a`) or the dummy API key is **expected and correct** — it proves the file was read and parsed. A `Missing WORKFLOW.md at /config/example.md` line is a failure: the mount or the `command:` path is wrong.

- [ ] **Step 3: Edit the workflow on the host and watch it reload**

Run:
```bash
sed -i.bak 's/interval_ms: 5000/interval_ms: 7000/' workflows/example.md
sleep 3
docker compose logs --since 30s symphony-example | tail -20
```
Expected: the container reacts within a couple of seconds — a reload or a fresh config/validation line, not silence. Silence means the mount is not propagating; re-check that compose mounts `./workflows` (a directory) and not `./workflows/example.md`.

- [ ] **Step 4: Revert the probe edit**

Run:
```bash
mv workflows/example.md.bak workflows/example.md
git diff --exit-code workflows/example.md && echo REVERTED
```
Expected: `REVERTED`.

- [ ] **Step 5: Tear down**

Run:
```bash
docker compose down -v
```

- [ ] **Step 6: Run the repo's own gate**

Run:
```bash
cd elixir && make all; cd -
```
Expected: pass. Nothing in this plan touches Elixir, so a failure here is pre-existing — confirm by stashing the branch's changes and re-running before investigating.

- [ ] **Step 7: Final acceptance sweep against the spec**

Run:
```bash
ls workflows/
grep -rn "ghcr.io" .github/workflows/docker-publish.yml deploy/client-template/docker-compose.yml
grep -c "build:" deploy/client-template/docker-compose.yml
```
Expected: `workflows/` contains only `example.md`; both files reference the GHCR image; the template contains **zero** `build:` keys (it must pull, never build).

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| 1. Product repo sheds client content | Task 1, Steps 2-3, 6 |
| 1. No history rewrite (decision only) | No task — recorded decision, operator action if reversed |
| 2. Published image on GHCR | Task 2 |
| 3. Client deployment template | Task 3 |
| 4. Root compose becomes local-dev only | Task 1, Step 4 |
| 5. Docs | Task 4 |
| Error handling (broken edit degrades) | Task 3, Step 4 (documented in template README) |
| Verification: multi-arch manifest | Task 2, Step 5 |
| Verification: local smoke | Task 5, Steps 1-2 |
| Verification: hot reload smoke | Task 5, Steps 3-4 |
| Verification: template dry run | Task 3, Step 5 |
| Acceptance criteria 1-5 | Task 1 Step 6, Task 2 Step 5, Task 3 Steps 5-6, Task 5 Steps 3, 7 |

**Placeholder scan:** No TBD/TODO items; every step carries the literal file content or the exact command plus its expected output.

**Type consistency:** Mount point `/config` is identical in the root compose, the template compose, and both READMEs. Workflow paths are `/config/example.md` (local dev) and `/config/workflow.md` (client), consistently paired with their own compose file. Image name is `ghcr.io/${{ github.repository }}` in CI and the literal `ghcr.io/adelrioj/symphony` in the template and docs — matching by construction for this repo. Service names `symphony-example` (root) and `symphony` (template) are used consistently in every command that references them.

**Known deviation from the skill's TDD default:** this change contains no application code, so there is no failing-test-first cycle. Each task instead ends with an executable check (`docker compose config`, YAML parse, `grep` invariant, container smoke) whose expected output is stated, and Task 5 gates on the real runtime behavior.
