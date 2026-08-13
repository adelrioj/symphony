# Client-Owned Workflow Configuration

**Date:** 2026-08-13
**Status:** Approved design, pending implementation plan

## Problem

Symphony is deployed by multiple independent clients, each self-hosting one container per
project. Every client's workflow file — `tracker` scope, Linear state UUIDs, private repo
clone URLs, pipeline prompts — currently lives in this product repo under `workflows/`
(`wmp-shipit.md` is a real client pipeline). Clients have access to this repo, so every
client can read every other client's workflow. Deployment (`docker-compose.yml`) and CI
docs also assume workflows live in-repo, which forces new clients to clone the product
repo just to run the image.

The code itself is already decoupled: `cli.ex` accepts any workflow path,
`workflow_store.ex` hot-reloads on a 1 s content stamp with last-known-good fallback, and
`agent/claude.ex` snapshots the workflow per session. The coupling is purely a
repo-layout and distribution problem.

## Goals

- No client-specific workflow content in the product repo.
- Each client owns and edits their workflow in their own private space, with hot reload.
- Clients can run Symphony without cloning the product repo at all.

## Non-Goals

- No Elixir/runtime changes. The file-path + poll mechanism stays as is.
- No remote workflow sources (Linear documents, S3, sync sidecars). Revisit only if a
  client explicitly asks to edit their pipeline outside git; then prefer a sidecar that
  writes the mounted file, keeping Symphony file-based.
- No multi-tenant single instance. The one-container-per-project model stays.

## Design

### 1. Product repo sheds client content

- Delete `workflows/wmp-shipit.md` (real client data) and `workflows/project-b.md`.
- Rename `workflows/project-a.md` → `workflows/example.md`; it is already a sanitized
  placeholder template. It remains the only file in `workflows/` and doubles as the
  local-dev workflow for the root compose file.
- The WMP file's Linear state UUIDs and repo name remain in git history. They are opaque
  identifiers, unusable without a Linear API key or GitHub credentials, so no history
  rewrite. Decision recorded here; if that risk posture changes, `git filter-repo` is the
  tool, done by the operator outside this plan.

### 2. Published image on GHCR

New CI workflow `.github/workflows/docker-publish.yml`:

- Triggers: push to `main` and tags `v*` (same tag convention as `burrito-release.yml`),
  plus `workflow_dispatch`.
- `docker/build-push-action` with buildx, platforms `linux/amd64,linux/arm64` (clients run
  OrbStack on Apple Silicon; the compose comments already promise no platform pins).
- Pushes `ghcr.io/adelrioj/symphony` (via `ghcr.io/${{ github.repository }}` so forks
  publish under their own owner) tagged `latest` (main), `<semver>` and `<major.minor>`
  (tags), `sha-<short>` always. `permissions: packages: write`, actions pinned by SHA like
  the existing workflows.
- Reuses `docker/Dockerfile` unchanged.

This is what removes the need for clients to have product-repo access at all.

### 3. Client deployment template

New directory `deploy/client-template/` — the entire contents of a new client's private
repo, copied once per client:

```
deploy/client-template/
  README.md            # 10-line quickstart: copy, edit workflow.md, docker compose up
  docker-compose.yml   # image: ghcr.io/<owner>/symphony:<tag> — no build: block
  workflow.md          # copy of workflows/example.md
  .env.example         # LINEAR_API_KEY=
```

Template compose file, per service:

- `image: ghcr.io/<owner>/symphony:latest` (README tells clients to pin a version tag).
- Mounts the repo directory read-only: `.:/config:ro`, command
  `["/config/workflow.md", "--port", "4000", "--logs-root", "/app/elixir/log"]`.
  Directory mount, not single-file: a single-file bind mount pins the inode, so an
  editor's rename-replace on the host silently stops propagating into the container and
  hot reload dies. A directory mount tracks the path, so every save is picked up by the
  1 s poll in `workflow_store.ex`.
- Same named volumes as today (`workspaces`, `logs`) and the read-only Codex auth mount.

### 4. Root compose becomes local-dev only

`docker-compose.yml` shrinks to one `symphony-example` service building from source and
mounting `workflows/` as a directory (`./workflows:/config:ro`, command
`/config/example.md`). Its header comment changes from "copy a service block to add a
project" to "client deployments live in their own repos — see `deploy/client-template/`".

### 5. Docs

- `elixir/README.md` "Run several projects": rewrite steps to (a) local dev via root
  compose, (b) client deployment via the template repo + GHCR image. Drop the
  "copy a service block / edit `workflows/<name>.md`" instructions.
- `CLAUDE.md` line 56: update the multi-project paragraph to point at
  `deploy/client-template/` and the GHCR image.

## Data Flow (unchanged, stated for completeness)

Client edits `workflow.md` in their repo → pulls/saves on the deploy host → directory
bind mount exposes the new content → `WorkflowStore` poll detects the stamp change,
reloads, keeps last-known-good on parse errors → next agent session snapshots the new
content into its private session dir.

## Error Handling

- Bad edit by a client (invalid YAML, failed schema validation): existing
  `WorkflowStore` behavior — logs the error, keeps serving the last known good workflow.
  No new handling needed; the template README states this so clients know a broken edit
  degrades to "no change" rather than an outage.
- Image pull failures / version skew: clients pin a tag; README documents the upgrade
  step (`docker compose pull && docker compose up -d`).

## Testing / Verification

- CI: `docker-publish.yml` runs on a branch push via `workflow_dispatch`; verify the
  multi-arch manifest exists on GHCR.
- Local smoke: `docker compose up --build` at repo root starts against
  `workflows/example.md` (it will fail on the placeholder slug at the tracker step —
  container boots and logs the config error, which is the expected placeholder behavior).
- Hot reload smoke: with the example container running, edit the mounted workflow on the
  host and confirm `WorkflowStore` logs a reload within ~1 s.
- Template dry run: copy `deploy/client-template/` to a temp dir, point it at the
  published image, `docker compose config` validates; full `up` once the image exists.

## Acceptance Criteria

1. `workflows/` contains exactly one sanitized `example.md`; no client project slugs,
   state UUIDs, or private repo URLs remain in `workflows/`, `docker-compose.yml`,
   `deploy/`, or the READMEs (historical mentions in `docs/` are out of scope).
2. Pushing to `main` publishes `ghcr.io/adelrioj/symphony:latest` for amd64+arm64.
3. A new client can be onboarded by copying `deploy/client-template/` into a private
   repo, editing `workflow.md` and `.env`, and running `docker compose up -d` — without
   product-repo access.
4. Editing the mounted workflow on the host hot-reloads inside the container (directory
   mount verified, not single-file).
5. Root `docker-compose.yml` still works for local dev from source.
