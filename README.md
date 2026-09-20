# Symphony

[![Status: engineering preview](https://img.shields.io/badge/status-engineering_preview-orange)](#status)
[![CI](https://github.com/adelrioj/symphony/actions/workflows/make-all.yml/badge.svg?branch=main)](https://github.com/adelrioj/symphony/actions/workflows/make-all.yml)
[![Container build](https://github.com/adelrioj/symphony/actions/workflows/docker-publish.yml/badge.svg?branch=main)](https://github.com/adelrioj/symphony/actions/workflows/docker-publish.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Symphony picks up issues from your tracker and runs coding agents in isolated workspaces.
One self-hosted Elixir/OTP service manages independently configured **lanes**, each with
its own tracker scope, workflow and limits. Reusable execution profiles own worker settings,
credential references and workspace bases, so one profile can serve several lanes.

**Trackers:** Linear, GitHub Issues, GitLab, Jira Cloud, Asana. **Agents:** Codex, Claude Code.

## Status

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

Local workspaces and static SSH workers are supported. Managed cloud environments are
not production-qualified; production Kubernetes allocation is blocked.
See [managed environments and limitations](docs/managed-environments.md).

## Install

**Docker is the primary deployment path.** The supplied image uses Codex; the template uses Linear.
Requires Docker Compose **2.24+**, a logged-in [Codex CLI](https://github.com/openai/codex),
and a Linear API key. Agents run unattended: use a trusted environment and scoped credentials.

1. Copy [`deploy/client-template/`](deploy/client-template/) into your own private deployment repo.
2. From that repo, run `cp .env.example .env`. Set `LINEAR_API_KEY` and a strong
   `SYMPHONY_OPERATOR_TOKEN` (generate one with `openssl rand -hex 32`).
3. Edit `workflow.md`: set your Linear scope, matching issue states, and repository clone URL.
4. Import the lane and start the service:

   ```bash
   docker compose pull
   docker compose run --rm symphony lanes import /config/workflow.md \
     --slug main --data-root /data
   docker compose up -d
   ```

Open <http://localhost:4000>, sign in with the operator token, and enable `main`.
New lanes start disabled. Use the structured lane editor and `/execution-profiles` for live
changes; the imported file is flattened interchange only, not a watched runtime configuration.
Profile edits apply to future runs on every linked lane. Active attempts retain their dispatch
snapshot, and workspace/target identity changes are rejected while retained work is still owned.

[Full deployment guide](deploy/client-template/README.md) ·
[Run from source](elixir/README.md#run) ·
[Native release builds](elixir/README.md#burrito-releases) (no published releases yet)

## Documentation

- [Operation and lane lifecycle](docs/operations.md)
- [Configuration and agent backends](elixir/README.md#configuration)
- [Dashboard and API](elixir/README.md#web-dashboard)
- [Language-agnostic specification](SPEC.md)

## Origin and license

Forked from [OpenAI Symphony](https://github.com/openai/symphony).
[Upstream background and demo](docs/upstream-background.md).
This project is licensed under the [Apache License 2.0](LICENSE).
