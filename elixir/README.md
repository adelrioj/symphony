# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

One installation serves one client with multiple DB-backed lanes. Each enabled lane independently:

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches the configured agent backend inside the workspace
4. Sends a workflow prompt to the agent
5. Keeps the agent working on the issue until the work is done

The default backend is Codex in
[App Server mode](https://developers.openai.com/codex/app-server/). Symphony also has an optional
Claude backend that runs `claude -p --output-format stream-json`.

During Codex app-server sessions, the selected tracker adapter may advertise provider-native tools.
Linear serves `linear_graphql` and `linear_fetch_attachment`, GitHub Issues serves `github_api`, Jira Cloud serves `jira_rest`,
Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those tools with
configured host-side auth and removes declared tracker-token environment variables from the Codex
child, so the agent does not need a second tracker login. The Claude backend exposes the selected
adapter's tools through Symphony's standalone MCP mode. Its private workflow snapshot contains
the pinned tracker configuration and prompt, not controller-only worker/provider settings.
The memory tracker advertises no tracker tools, but MCP still provides the deny-only
`approval_prompt`; removing MCP is not a supported permission workaround.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If the active backend reports a normalized blocked result, Symphony asks the selected tracker
adapter to post a deterministic comment and move the issue to `agent.blocked_state`; the included
Linear and memory adapters support these writes. Codex app-server approval, input, and MCP
elicitation events instead keep the issue claimed and expose it as blocked in runtime state, the
JSON API, and the dashboard. Those runtime blocked entries are in memory only; restarting the
orchestrator clears them.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` tool for raw Linear GraphQL operations
     such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
export SYMPHONY_OPERATOR_TOKEN='replace-with-a-long-random-secret'
mise exec -- mix symphony lanes import ./WORKFLOW.md --slug main --data-root /data
mise exec -- mix symphony serve --data-root /data --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Create a writable persistent `/data` directory, or replace it consistently in all commands.
Sign in at <http://localhost:4000/login> with the operator token, review the imported lane, then
enable it. New lanes are disabled by default. Repeat import with a different slug for each lane.
The daemon runs through Mix or a Burrito release because the SQLite NIF cannot load from an
escript; `mix build` builds `bin/symphony` for agent-side `--linear-mcp` use only.

## Run in Docker (OrbStack-compatible)

One container runs one installation with multiple independently scheduled lanes. Each lane selects
its own tracker scope and workspace root; use distinct workspace roots and managed deployment
identities where lanes must not share resources. For Linear, at least one of
`tracker.provider.team_keys`, `current_cycle`, or `project_slug` is required; label policies can
narrow that scope further. This works with [OrbStack](https://orbstack.dev/) or Docker Desktop.

### Deploying a project

Deployments live in their own private repos, not in this one. Copy
[`deploy/client-template/`](../deploy/client-template) into a new repo and follow the README in
it: it pulls the published image `ghcr.io/adelrioj/symphony` (built and pushed by
[`.github/workflows/docker-publish.yml`](../.github/workflows/docker-publish.yml)), mounts that
repo's workflow import files, and needs no clone of this repo. Prerequisites, live UI/API edits,
private-repo cloning, GHCR authentication and the security model are documented there; this
section does not repeat them.

### Local development

The repo-root `docker-compose.yml` is local dev only: it builds the image from source and runs
the sanitized `workflows/example.md` in a single `symphony-example` service.

All commands below run **from the repo root** — `cd ..` if you followed the `## Run` section
above, which leaves you in `symphony/elixir`.

1. **Log in to Codex once** on the host — the container mounts the `~/.codex` directory
   read-write, so it shares this login and can refresh the token itself:
   ```bash
   codex login
   ```
2. **Set tracker and operator credentials** (git-ignored; compose auto-loads `.env`):
   ```bash
   cp .env.example .env      # edit LINEAR_API_KEY and SYMPHONY_OPERATOR_TOKEN
   ```
3. **Edit `workflows/example.md`** before import: set the tracker scope and `hooks.after_create`
   clone URL. Keep `workspace.root: /workspaces` to match the volume. Any `server` section is ignored.
4. **Import offline, then launch:**
   ```bash
   docker compose build
   docker compose run --rm symphony-example lanes import /config/example.md --slug example --data-root /data
   docker compose up -d
   ```
   Sign in at <http://localhost:4000/login>, review the lane, then enable it.

The `/config` mount supplies import files; it is not watched. SQLite and logs persist in the
`/data` volume. Use the UI or authenticated API for live edits; offline imports made while
`serve` is running are not published to its lane store until restart.

Compose runs:

```text
serve --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000 --host 0.0.0.0 --data-root /data
```

Notes:

- **Ports:** all lane UI/API routes require the operator credential. Compose still publishes
  `127.0.0.1:4000:4000` (host loopback only); the daemon binds `--host 0.0.0.0` inside the container
  so Docker can forward traffic. Use TLS and a deliberate network policy for remote access.
- **Private repos:** `after_create` clones over HTTPS. For a private repo, forward a token into
  the container (add `env_file: .env` to the service) and use it in the clone URL. Symphony runs
  the hook itself through the container's own shell (`sh -lc`), which inherits the container
  environment, so a token in `.env` is expanded in the clone URL. Codex is not involved in the
  clone.
- **The `claude` backend** is not installed in the image; it ships the Codex CLI only. Add the
  `claude` CLI and its auth if you route states to it via `agent.backend_by_state`.

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
export SYMPHONY_OPERATOR_TOKEN='replace-with-a-long-random-secret'
./symphony-v0.0.1-macos_arm64 lanes import ./WORKFLOW.md --slug main --data-root /data
./symphony-v0.0.1-macos_arm64 serve --data-root /data --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## Configuration

The daemon reads lane configuration from `<data-root>/symphony.sqlite3`, not a positional workflow
file. Lane workflow saves insert immutable versions; metadata-only edits do not. Activate an older
version to roll back the pointer without rewriting history. Active attempts keep a dispatch-time
snapshot of settings, prompt, hooks, backend/tools, version and completion policy, including retries'
new dispatches and deferred completion helpers. Later attempts use the saved version.

Required for `serve`:

- `--i-understand-that-this-will-be-running-without-the-usual-guardrails`: acknowledges unattended
  execution. Offline import/export and MCP do not require it.
- `SYMPHONY_OPERATOR_TOKEN`: a nonblank installation-wide secret; serve refuses to start without it.

Installation flags:

| Flag | Meaning/default |
| --- | --- |
| `--data-root <dir>` | Persistent database and `log/symphony.log*`; default current directory |
| `--port <port>` | HTTP listener; default `4000`, `0` requests an ephemeral port, valid range `0..65535` |
| `--host <ip>` | Literal bind IP; default `127.0.0.1` |
| `--events-retention-days <n>` | Positive event-retention days; default `30` |

Use the same data root for every command targeting an installation:

```bash
mix symphony lanes import /path/to/WORKFLOW.md --slug main --name "Main lane" --note "initial import" --data-root /data
mix symphony lanes export main --data-root /data
```

Import creates a disabled lane, or appends a version to an existing slug while preserving enabled
state. These commands open only the database, not schedulers. They are offline tools: importing in
another process while serve runs is not applied live until restart; use the UI/API instead.
For import, UI creation, and API create/update, lane slugs must match `^[a-z][a-z0-9-]{1,40}$`.
The exact slug `new` is reserved for the creation page at `/lanes/new`; use an ordinary slug such as
`main` or `new-work`. A rejected slug produces a field error without saving a lane or version.
Export writes the current workflow to stdout. Canonical nonempty LF-delimited front matter with a
newline after its closing delimiter round-trips exactly; arbitrary delimiter/newline envelopes
normalize. Raw YAML and prompt text, including leading blank lines, remain editable content.

`WORKFLOW.md` uses YAML front matter plus a Markdown prompt. `server.port` and `server.host`
are retained but ignored with a warning on import/save; listener settings belong to `serve`.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_turn_exhaustions: 3
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility. `team_keys` and
  `current_cycle` have no flat aliases and are read only from `tracker.provider`.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running.
- `tracker.any_labels` is optional. When set, an issue must have at least one
  configured label to dispatch or continue running. It combines with
  `required_labels` as a conjunction: an issue must satisfy both.
- Both label lists are trimmed, lowercased, and deduplicated when the workflow is loaded, and
  matching ignores case and surrounding whitespace. A blank configured label matches no issue, and
  an empty list imposes no constraint.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"granular":{"sandbox_approval":false,"rules":false,"skill_approval":false,"request_permissions":false,"mcp_elicitations":false}}`, rejecting approval prompts rather than auto-approving them.
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. Codex 0.153.4 supports `untrusted`, `on-request`, `never`, and object-form `granular`. Older workflows using `reject` must migrate to `granular` and invert each rejection flag into an allowance flag.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back agent turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.max_turn_exhaustions` caps how many agent invocations in a row may end at `agent.max_turns`
  while the issue stays in the same active state. When the cap is hit, Symphony posts a comment and
  moves the issue to `agent.blocked_state` instead of restarting the agent again. This is what stops
  an issue that is too large for its turn budget from looping forever. Default: `3`.
  Set `0` to disable this automatic parking limit for a lane, such as QA, whose
  normal work includes waiting for external CI and reviews. This does not disable
  explicit blocked results, human-stop rules, turn limits or timeouts. Keep a
  positive limit for development lanes so work that makes no progress stops.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- Invalid imports/saves return field-path errors without inserting a version. An invalid stored lane
  at boot is disabled with an operator-visible error rather than preventing other lanes from running.
- Tracker preflight runs before runtime start and after tracker edits. Pending checks are tied to the
  current publication generation; newer edits replace pending checks and stale results cannot start
  or disable the lane. A current failure disables only that lane.
- Local relative `workspace.root` values resolve against `--data-root`, not the import directory.

### Managed ticket environments

Managed mode is optional; omitting `worker.environment` preserves local/static SSH selection.
Once selected, an invalid configuration, unavailable provider, missing execution context, or failed
readiness check is an error, never a request to execute locally or on another provider. These are
complete Linux environments with one private Docker daemon per ticket; repository Compose and
Testcontainers workflows retain their existing commands. Infrastructure and images are supplied by
the operator, not provisioned by these examples. Neither provider has live/production qualification
from this change; authorization of a design is not authorization to create billable resources.

#### Workflow settings

Merge **one** of these fragments into a workflow with its existing tracker, agent backend, hooks,
and prompt. All resource names below are illustrative references to operator-created resources.
The Kubernetes example also requires the existing kubeconfig and qualification profile described
below; it cannot bootstrap an empty cluster.

```yaml
agent:
  max_concurrent_agents: 5
workspace:
  root: /home/user/workspaces
worker:
  environment:
    kind: google_workstations
    deployment_id: isolated-development
    startup_timeout_ms: 600000
    shutdown_timeout_ms: 120000
    terminal_retention_ms: 0
    provider:
      project: development-project
      location: europe-west1
      cluster: coding-workers
      config: linux-docker-v1
      credential_configuration: symphony-workers
      impersonate_service_account: symphony-workers@development-project.iam.gserviceaccount.com
      ssh_user: user
```

```yaml
agent:
  max_concurrent_agents: 5
workspace:
  root: /state/workspaces
worker:
  environment:
    kind: kubernetes
    deployment_id: isolated-development
    startup_timeout_ms: 600000
    shutdown_timeout_ms: 120000
    terminal_retention_ms: 0
    provider:
      kubeconfig: /etc/symphony/kubeconfig
      context: development-cluster
      namespace: symphony-workers
      template: linux-kata-v1
      ssh_user: developer
      ssh_port: 2222
      ssh_auth_volume: ssh-auth
```

- `kind` is exactly `google_workstations` or `kubernetes`; `deployment_id` is a required nonblank
  string, stable across restarts and unique to this independent deployment.
- `startup_timeout_ms` and `shutdown_timeout_ms` are required positive integer durations in
  milliseconds. Provider jobs use one bounded monotonic deadline, not a fresh timeout for every
  request. Expiry is not proof that a remote operation was canceled.
- `terminal_retention_ms` is a nonnegative integer duration in milliseconds, default **0**. Zero
  means eligible for cleanup on a fresh terminal observation, not synchronous or guaranteed deletion.
- Explicit `worker.environment: null`, an empty/non-map environment, null required values, and
  missing provider settings are invalid. Omit the environment key to choose unmanaged execution.
  Do not combine managed mode with explicit `worker.ssh_hosts` or
  `worker.max_concurrent_agents_per_host`, even empty/null static values; omission is intentional.
- `provider` uses string keys. Workstations requires all seven nonblank strings shown above.
  Kubernetes requires the six nonblank strings shown plus integer `ssh_port` in `1..65535`;
  `kubeconfig` must name an existing regular local file and `ssh_user` must match
  `^[a-z_][a-z0-9_-]*[$]?$`. No implicit current kube context, active gcloud configuration,
  credential discovery, or provider fallback replaces these references.
- `workspace.root` is an absolute worker-side root after normal configuration resolution. Persisted
  ticket paths must stay strictly beneath it, never equal it, traverse a symlink outside it, or use
  the source checkout. Display-identifier changes never rename a retained managed checkout.

The guarded identity includes provider kind, deployment ID, tracker kind, workspace root, and every provider
reference in the selected example (including auth-selection references). Workstations
project/location/cluster and Kubernetes kubeconfig/context/namespace are deployment boundaries,
not agent-controlled scheduling choices. While inventory or jobs remain, identity-changing lane saves
and version activations are rejected atomically and the last good workflow remains active. Owner death does not unlock this
guard. Only authoritative empty compute-and-storage inventory with no unresolved operations permits
release, and protection is reacquired before subsequent allocation. Mutable polling, concurrency,
deadlines and retention are not identity changes; in-flight work retains its captured configuration.
Existing environments retain and validate their captured template identity rather than silently
adopting edited infrastructure.
A LaneStore replacement stops surviving lane runtimes, releases stale guard owners, and
rebuilds accepted identities from SQLite before restarting enabled lanes. A competing owner
remains fenced; rejected identity edits never reach the database and cannot become accepted
merely because the store restarted.

#### Recovery, capacity, retention, and hooks

Startup performs provider preflight and complete owned-resource discovery before dispatch. Denied,
partial, malformed, or unknown inventory is not an empty deployment. Recovery reconstructs durable
identity, paths, desired state, attempts, first terminal timestamp, and pending operations; it
reconciles potentially running resources before reuse instead of trusting a lost local agent PID.
Unknown create/start outcomes block duplicate allocation.
Workstations metadata-only updates can be confirmed by their owned annotation payload without
depending indefinitely on retained completed-operation history. This does not clear uncertain
compute mutations. A definitively denied initial create can retry through ordinary stop/intent
handling only after complete parent and backing/child absence evidence, with no earlier ambiguity;
denial alone never releases a slot.

The existing `agent.max_concurrent_agents` and per-state limits remain the execution budget.
Reservations, preparation, running, stopping, and unresolved possibly executing environments occupy
slots. Five active executions are independent of how many stopped environments are retained.
Qualified remote quiescence releases execution capacity; closing SSH, losing a local holder, killing
an agent, cancellation, or a stop request alone does not. A quiescent environment with unresolved
disk deletion can release its execution slot but still holds the identity guard and may incur charges.
Newly observed possible execution invalidates an older stop proof and occupies capacity again;
cleanup-only storage uncertainty does not invalidate qualified compute quiescence.
Existing agent `running`, `retrying`, and `blocked` status meanings do not change.

Terminal observation is persisted once as UTC Unix milliseconds and survives restart. An expired
retention clock alone does not authorize deletion: the tracker must affirmatively still report a
terminal state. Missing issues, failed tracker reads, or nonactive nonterminal states do not authorize
destruction. A genuine reopen conditionally clears terminal/cleanup intent before restart if deletion
has not become irreversible, retaining the same workspace. A prior completed cleanup-hook marker
does not suppress a new cleanup after a genuine reopen.

`after_create` still bootstraps only a new checkout; `before_run`/`after_run` keep their existing
failure policies. All run on the selected worker through the captured execution context.
Ordinary backend exceptions/exits still attempt best-effort `after_run` before propagating the
original failure. Explicit managed-execution uncertainty skips follow-on remote hooks.
Cleanup needing `before_remove` prepares the retained environment under the same capacity budget,
without launching an agent or `before_run`, runs that hook best-effort, persists a confirmed completion
marker, stops remotely, then attempts destruction. A managed hook timeout is unknown execution:
do not run follow-on hooks, retry in-place, or delete until qualified stop. Failure/timeout to stop
remains unresolved; it cannot be reported as successful cancellation or free execution capacity.

#### Linux image and operator tooling

Each repository supplies its development image, Bash, Git, **GNU** `realpath`, `findmnt`, both agent
executables if routing to both backends, Docker/Compose, Testcontainers prerequisites, and browser
dependencies. Remote Claude also needs its configured Symphony MCP executable. Preserve the repo's
unchanged setup/test commands. Readiness checks the selected backend, authenticated SSH, a mounted
writable workspace, actual GNU `realpath -m --` behavior (including nonexistent path components),
and a usable local Unix Docker endpoint with writable Docker data. Cleanup preparation does not
require an agent executable. These probes are not independent proof of persistence or daemon
isolation: qualify those properties in the infrastructure/image.

Local macOS development tests that exercise managed path safety also need GNU coreutils `realpath`
on `PATH` (for example, the coreutils `gnubin` directory ahead of the system tools). A BSD utility or
a wrapper printing GNU version text is insufficient; the real `-m --` semantics must work. This is
a local test prerequisite, not a relaxation of the Linux worker requirement.

#### Cloud Workstations profile

Workstations remains the preferred Google-managed worker to qualify even if Symphony and review
apps run on GKE. Install noninteractive gcloud and SSH on the orchestrator. The required
`credential_configuration` names an already configured gcloud profile selected by `--configuration`;
the adapter never changes the user's active configuration or performs interactive login.
Required `impersonate_service_account` selects the same explicit lifecycle identity for token
acquisition and the tunnel. Supply Workstations API/resource/operation read and lifecycle permissions,
impersonation permission, and read-only project-wide Compute instance/disk inventory permissions.
Do not grant worker code those lifecycle or inventory credentials.

Use distinct lifecycle and worker VM identities. Never attach the lifecycle service account to a
worker VM or put its credentials in the image. Qualification must demonstrate **provider-enforced**
isolation from usable cloud metadata credentials for privileged ticket code, or report the profile
unavailable. An in-worker firewall controlled by root is not such an isolation boundary.

The qualified config must persist `/home`, with the checkout and private Docker data on persistent
storage, `gcePd.reclaimPolicy: DELETE`, `archiveTimeout: 0s`, no normal or boost warm pool, no suspension
policy, and disabled idle/running timeouts for this serialized execution profile. Plain TCP must not
be disabled and container port 22 must be allowed. The image's SSH user must support the documented
gateway/none-auth flow; the adapter uses an authenticated gcloud tunnel on loopback, noninteractive
SSH, no forwarding, and per-connection host trust pinned after the gateway handshake. Private tunnels
and trust files are owned by supervised holders, not by the short-lived preparation job.

Qualification must also establish backing VM/disk ownership-label propagation. Recovery inventories
all configs in the cluster, regional operations, and all pages of project-wide Compute instances and
disks. Deletion needs qualified stop, completed provider deletion, parent absence, and complete absence
of owned/captured backing resources; a missing workstation is not proof of deleted disks. Captured
IDs continue to count even after labels disappear. The adapter does not delete clusters/configs or
issue Compute writes. Plan quotas and charges for startup, active VMs, retained disks, and partial
create/deletion leftovers; five execution slots is not a storage or billing cap. Archival/warm-pool
retention is not a substitute for the supported disk-only policy.

#### Kubernetes Agent Sandbox qualification contract

The baseline is Kubernetes >=1.30 with Agent Sandbox **v1.0.1**, source commit
`3e77ccbac4db8a12b0157eafcad0d1ad5872f32a`, using direct `agents.x-k8s.io/v1beta1` Sandboxes and
read-only `extensions.agents.x-k8s.io/v1beta1` SandboxTemplates. Both CRDs must serve/store only that
pinned version. Symphony does not use Claims or WarmPools. Installed schema canonical SHA-256
prefixes must be Sandbox `37f0b89594ba20ca4d37b93714c362bcd694369f` and Template
`6c5c594b1a0cddda9b330bb094272e1c465d11c2`. Canonicalization recursively turns maps into sorted
`[key, value]` pair arrays, preserves array order, compact-JSON encodes, hashes, and takes the first
40 lowercase hexadecimal characters; the same procedure binds the template spec digest.

The operator-owned Template annotation `symphony.dev/qualification` names an **immutable ConfigMap**
in the configured namespace. Its `data["contract.json"]` must contain the following JSON fields;
these describe actual audited resources, not values to invent to bypass preflight:

| Field | Required value or binding |
| --- | --- |
| `release` | Exactly `v1.0.1` |
| `template_uid` | Actual SandboxTemplate UID |
| `template_digest` | Canonical digest of actual Template spec |
| `qualification_report` | Nonblank reference to audited operator qualification evidence |
| `termination_contract` | Exactly `qualified-kubelet-all-containers-v1` |
| `controller_namespace` | Namespace of actual controller Deployment |
| `controller_name` | Actual controller Deployment name |
| `controller_uid` | Actual controller Deployment UID |
| `controller_source_commit` | Exactly `3e77ccbac4db8a12b0157eafcad0d1ad5872f32a` |
| `controller_image` | Audited digest-pinned `registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:...`, matching actual containers |
| `runtime_class_uid` | Actual Template-selected RuntimeClass UID |
| `runtime_handler` | Actual qualified RuntimeClass handler |
| `storage_class_uids` | Array of actual qualified claim-template StorageClass UIDs |
| `csi_driver` | Exact qualified CSI driver/provisioner; StorageClasses use Delete reclaim |
| `network_policy_uid` | Actual operator-owned NetworkPolicy UID |
| `network_profile_label` | Ordinary profile label on Template Pods and policy selector, not a controller label |

Symphony reads but never writes this ConfigMap. It is evidence of prerequisites, **not** a remote
operation fence or per-Pod/per-volume proof. Preflight reads the actual available controller, version,
schemas, runtime, storage classes and policy, rejecting mismatches instead of trusting arbitrary
operator booleans. Keep qualification data, lifecycle annotations, finalizers, authorization and
status evidence inaccessible to workers.

Qualify a Kata VM boundary with `privileged_without_host_devices=true`. Guest-contained privileged
DinD must never become unrestricted privileged runc access to the node. Runtime/admission must fail
closed if Kata is missing. GKE Standard with a qualified Kata setup is distinct from managed gVisor
or Autopilot; hosting Symphony on GKE proves none of these worker prerequisites. Kata virtiofs and
overlayfs are incompatible for this purpose: persistent Docker data needs a qualified guest
filesystem/storage driver. An ephemeral memory directory is not a persistent-storage solution.

Provide enforcing NetworkPolicy, a trusted admission/scheduling path, privately reachable Pod SSH
(no public LoadBalancer/NodePort or implicit port-forward), and the declared read-only `ssh_auth_volume`
for the owned SSH Secret. Do not mount Kubernetes lifecycle credentials or service-account tokens in
the guest. Admission must preserve `symphony.dev/start-authorized`, never directly set `nodeName`,
inject host namespaces/hostPath/node sockets/host ports, or project service-account credentials.
The permanent blueprint gate remains in the Template-derived Sandbox; only a revalidated exact Pod
UID/resourceVersion may have Symphony's gate removed after durable release authorization.

The orchestrator needs read-only Template/qualification/CRD/controller/RuntimeClass/StorageClass/
NetworkPolicy access, complete Sandbox/Pod/PVC/Service/Secret/PV and guard ConfigMap inventory,
conditional Sandbox intent and finalizer writes, exact Pod CAS/gate/stop-fence writes, normal
conditional child deletion, owned SSH Secret lifecycle, and Pod/PV watch permissions. It also owns
CAS updates to its retained create guards, but never deletes them. Keep this separate from workload RBAC.
No broad node mutation or automated node-fencing permission is part of this implementation.

Stop requires qualified kubelet termination for every regular/init/ephemeral container of every
possibly released UID, or proof a fenced unscheduled Pod was never released. A `kubelet` manager
string is not authentication: audited RBAC/admission/recovery must prevent forged status,
unverified force-deletion, out-of-service recovery, and unverified node removal/fencing. API
disappearance or generic Failed/ContainerStatusUnknown is not stop evidence.

Qualify the CSI driver's DeleteVolume and deletion-protection behavior. Bound PV identity,
claimRef/volumeHandle and `external-provisioner.volume.kubernetes.io/finalizer` must be observed
before deletion; a complete exact-UID PV `DELETED` watch event must match that bound identity.
Kubernetes can delete atomically when an update removes the last finalizer, so the watch event
may still contain the prior object's finalizer list
([upstream implementation](https://github.com/kubernetes/kubernetes/blob/v1.33.0/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go#L565-L614)).
PVC disappearance,
missing PVs, unbound claims with unknown provisioning, denied inventory, or compacted watch history
do not establish disk absence. Never strip protection finalizers to force progress.

**Pinned baseline and production stop:** upstream v1.0.1 has no authoritative per-Sandbox acknowledgment
ordering all earlier child-create requests before final cleanup. Its
[deletionTimestamp branch](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.1/controllers/sandbox_controller.go#L303-L308)
does not supply that witness. Timeout, qualification ConfigMaps, empty inventory and parent 404 are
not substitutes. The candidate controller extension and consumer described below do not change the
approved source/image/schema pins above or qualify a replacement baseline.

Production `Kubernetes.preflight/2` returns
`{:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}}` even when every
read-only profile and inventory check succeeds. The normal discovery path remains blocked and
the scheduler admits no Kubernetes tickets; this is not merely a qualification-harness restriction.
The full distributed qualification harness preserves the same blocker. No workflow field or operator ConfigMap can override it.
Local/static SSH operation and the existing VM deployment do not depend on this managed-provider gate.

##### Candidate create-drain protocol

The controller extension opts in through `spec.creationControl.protocol: symphony-create-drain-v1`
at Sandbox creation, with `symphony.dev/environment-cleanup` already present. Its UID-bound
`status.creationJournal` serializes child issuance and irreversible closure with resourceVersion CAS.
Only a positively acknowledged issuance permits one POST; a recovered `Issued` entry is never replayed.
Timeouts, API rejections and missing objects leave it unresolved until exact attributed commitment is
positively observed. History is retained, bounded to 128 operations and 128 KiB with completion space
reserved. Exhaustion blocks further issuance rather than pruning evidence.

Symphony creates a deterministic `symphony-guard-<identity digest>` ConfigMap before any parent POST,
then journals its Sandbox and Secret attempts in `data["guard.json"]`. The guard, not the parent
annotation, owns durable lifecycle state. Guards progress through `Open`, `Closing`, `ReadyToFinalize`
and `Complete`; they have no garbage-collection owner and are never deleted or reopened. Completed
receipts do not count as active inventory, but still reject reuse of that environment identity.

Cleanup closes provider issuance and validates the controller's complete `Drained` acknowledgement:
exact parent UID, close-request ID, revision, operation count and immutable committed membership.
It retains storage before that acknowledgement. Every committed Pod needs durable physical safety
classification, including Pods never authorized to start; missing/unclassified Pods remain unknown.
Every committed PVC retains its qualified backing-storage obligation. Newly discovered physical
uncertainty invalidates any older compute-stop proof. Closure cleanup uses these proofs rather than
waiting for a new `Suspended` condition from a controller that has already drained.

The full `ReadyToFinalize` receipt must be CAS-persisted and exactly read back before finalizer
removal. Exact parent, child and backing absence precedes the durable `Complete` readback. Recovery
can resume finalization through the normal operation path even if the parent disappeared; bare parent
absence never proves cleanup. Genuinely unknown issuance can retain the guard indefinitely.

The candidate controller checkout supplies `k8s/symphony-create-drain-policy.yaml`, installed separately
only after approval. It selects the namespace label `symphony.dev/create-drain=symphony-create-drain-v1`.
Namespace **annotations** `symphony.dev/creation-controller` and `symphony.dev/creation-provider` hold
distinct exact `system:serviceaccount:<namespace>:<name>` identities. They are not label values.
Protect namespace configuration, original attribution, journals and guards from workers; admission
authenticates writers and attribution but is not a commit-time create fence.

The Symphony runtime needs both `kubectl` and `symphony-kubernetes-create` on `PATH`. Build the helper
from the same reviewed controller source with `make build-symphony-kubernetes-create`; the output is
`bin/symphony-kubernetes-create`. The generic Symphony Dockerfile does not bundle these tools.
All POSTs use that helper; there is no `kubectl create` fallback. GET/watch/CAS/delete retain kubectl.
The helper requires the configured explicit kubeconfig/context and private JSON request file. It uses
verified HTTPS over one fresh HTTP/1.1 connection, with no redirect, proxy, authentication-refresh or
client-go retry path. Static bearer/token-file snapshots, basic auth and client certificates are
supported; exec/auth-provider plugins, impersonation, custom transports and insecure TLS are rejected.
Controller token files are snapshotted at client construction, not refreshed after rejection.
The helper accepts a bare API path; the shared transport always adds `fieldValidation=Strict`.

##### Test-only candidate runner

`Kubernetes.candidate_preflight/3` and its candidate validator exist only in
`MIX_ENV=test` artifacts. Ordinary `Kubernetes.preflight/2` rejects candidate options
and retains its unconditional allocation stop. This is not a workflow switch or a
production baseline replacement.

The opt-in runner uses the real lifecycle operations, single-attempt helper, Memory
tracker, and managed SSH transport. It clears workflow hooks, permits one to four
workers, and starts a fresh runtime for terminal cleanup. With `backend: null`, it
replaces the agent callback with a nonce write/read/remove probe and invokes no model.
With explicit model authorization and `backend: "claude"` or `"codex"`, it invokes
AgentRunner with a nonce task rendered from the issue description. Provision the
selected backend's authentication in the guest; the runner does not provision credentials
or bypass the backend's approval policy.

Evidence always says `candidate-unqualified` and `qualified: false`.
`workers` records a sticky outcome for each expected issue. Cleanup starts only after
all requested workers succeed in distinct environments, or after failure/timeout;
duplicate success cannot satisfy another worker and later success cannot erase failure.
`dispatches`, keyed by attempt ID, records issue/environment identity, backend,
dispatch start/end, probe completion, and observed backend lifecycle events.
`model_probes_completed` counts model wrappers that reach artifact readback;
`model_sessions_started` and `model_sessions_completed` count distinct attempt/session
identities observed in backend lifecycle messages, including interrupted attempts.
These counters are zero for non-model and cleanup runs. Model acceptance requires
one successful probe per requested worker, `dispatch: "ok"`, and `artifact_matched: true`
after reading the nonce file over managed SSH. A transcript claiming success is insufficient.
Model dispatch waits, within the existing run timeout, for every expected managed
worker to register in a distinct live environment. This readiness barrier does not
itself prove model overlap; multi-worker model acceptance additionally requires
overlapping observed session-start/completion intervals for the same session identities.

Dispatch and lifecycle observations include controller UTC and monotonic millisecond
timestamps. A dispatch remains occupied after its probe finishes, until cleanup releases
it: overlapping dispatch intervals do **not** prove overlapping model calls. Inspect
observed session-start/completion intervals separately; missing terminal events are
incomplete evidence, not a model completion or proof of overlap. Timing is observed at
the controller, not provider-side inference timing. No raw model payloads or credentials
are retained in these lifecycle records.

Run from an operator-reviewed source checkout with accessible Git metadata, not a
production release artifact. PR21 moved runtime configuration into SQLite lanes:
the runner imports its sanitized workflow as a **disabled** lane and passes its ID
to the existing custom managed runtime. It does not enable `LaneSupervisor`, and
`executor: local` describes the Symphony scheduler, not the managed worker.
The database lane/version IDs are included in evidence.

Use a fresh private database for **each invocation**, including cleanup mode.
The runner rejects a nonempty LaneStore because Memory tracker state is global.
Configure Repo **before application startup**. `MIX_ENV=test` normally uses a fresh
in-memory SQLite database; the explicit file-backed setup below retains lane/version
evidence after exit without touching an existing installation. The disabled candidate
lane remains for inspection, including after failed cleanup.
`SYMPHONY_CANDIDATE_DB` below is a launcher input, not a built-in application setting.
Its parent must already be a private directory.

```bash
MIX_ENV=test \
SYMPHONY_RUN_KUBERNETES_CANDIDATE=1 \
SYMPHONY_KUBERNETES_CANDIDATE_INPUT=/absolute/private/candidate-input.json \
SYMPHONY_CANDIDATE_DB=/absolute/private/fresh-symphony.sqlite3 \
mise exec -- mix run --no-start -e '
  database = System.fetch_env!("SYMPHONY_CANDIDATE_DB")
  false = File.exists?(database)
  Application.put_env(:symphony_elixir, :data_root, Path.dirname(database))
  Application.put_env(:symphony_elixir, SymphonyElixir.Repo, database: database)
  {:ok, _} = Application.ensure_all_started(:symphony_elixir)
  Mix.Task.run("test", ["--no-start", "test/symphony_elixir/kubernetes_candidate_live_test.exs"])
'
```

The input JSON requires exactly:

| Field | Meaning |
| --- | --- |
| `authorization` | `disposable-namespace-non-model` or `disposable-namespace-model`; explicit operator authorization, not permission to provision infrastructure |
| `mode` | `run` for a fresh deployment identity; `cleanup` for recovery of that same identity |
| `backend` | `null` for non-model; `"claude"` or `"codex"` requires model authorization |
| `worker_count` | Integer from 1 to 4 |
| `workflow_path` | Absolute path to the existing Kubernetes workflow |
| `output_path` | New evidence file in an existing caller-owned `0700` directory |
| `pins` | Exact candidate baseline described below |
| `timeout_ms`, `cleanup_timeout_ms` | Each between 1,000 and 900,000 milliseconds |
| `runner_sha256` | SHA-256 of `test/support/kubernetes_candidate_runner.exs` |
| `negative_control_paths` | Nonempty list of independent existing resource API paths, compared before and after |

`pins` contains `namespace`, `namespace_uid`, `deployment_id`,
`consumer_source_commit`, `consumer_artifact_sha256`, `helper_sha256`, `contract`,
`schema_digests`, `controller_spec_digest`, `controller_authorization`,
`runtime_class_spec_digest`, `storage_class_digests`, and
`network_policy_spec_digest`. Missing or extra keys fail closed. Artifact identity
comes from `Kubernetes.Candidate.artifact_identity/0`: actual application BEAM hashes
and their aggregate, not a source-version label. The helper pin hashes the executable
actually found on `PATH`. Source commits remain provenance attestations; checking
Git HEAD does not prove a clean checkout or a source-to-binary build.

The immutable qualification ConfigMap's `contract.json` must equal `pins.contract`.
It uses the existing contract fields above, but supplies the reviewed candidate
release/source/image, plus `stage: "candidate-unqualified"`, `qualified: false`,
`termination_contract: "candidate-unqualified-kubelet-all-containers-v1"`, and
`worker_image`. Controller and worker images must use immutable SHA-256 references;
every template container and init container must match the worker image.

Use `Kubernetes.Candidate.digest/1` for object pins: canonical JSON SHA-256 truncated
to 40 hexadecimal characters, not SHA-1. Schema pins map the two CRD names to their
served/storage `v1beta1` `openAPIV3Schema` digests. Controller, Template and
NetworkPolicy pins hash `spec`; RuntimeClass hashes `handler`, `overhead` and
`scheduling`; StorageClass pins map UID to the object without metadata/apiVersion/kind.
Authorization requires exactly `service_account`, `workload_role`, `workload_binding`,
`management_role`, and `management_binding`, each with `name`, `namespace`, `uid`,
and a digest of the object without metadata/apiVersion/kind.

The controller must use its pinned entrypoint, one canonical namespace flag, and
explicit management-namespace leader election, with extensions disabled. Candidate
preflight additionally needs management-namespace ServiceAccount listing and
cluster-wide read-only listing of Roles, RoleBindings, ClusterRoles and
ClusterRoleBindings. It verifies workload and Lease grants and rejects extra
controller-principal grants, except non-resource discovery reads and self-reviews.
This inspection authority does not give the controller those inspection permissions.

No resources or admission prerequisites are installed by the runner. Protected
namespace identities, the enforcing create-drain policy, runtime isolation and
network/storage prerequisites above still require operator preparation and
qualification. Candidate preflight is not proof of admission enforcement or physical
fault behavior. Full model-session and fault qualification remains a separate gated suite.
Completed guard receipts remain after billable resources disappear; never reuse their
deployment/ticket identities. After interruption, use `mode: "cleanup"` with the same
pins and a fresh output path; unknown obligations are not absence proof.

#### Managed observability API

Use the authenticated HTTP service started by `serve` (`--port`, default 4000).

Each lane entry in `GET /api/v1/state` exposes `environment_discovery`: null for local/static execution, otherwise:

```json
{"provider_kind":"google_workstations","status":"blocked","error_code":"denied"}
```

`status` is `pending`, `ready`, or `blocked`. Pending/ready have a null error; blocked uses only
`denied`, `invalid`, `retryable`, `unknown`, `authority_replaced`, or `unresolved`. The Phoenix
dashboard and terminal status show this global discovery condition even with zero environment
entries, so paused admission is distinguishable from an idle deployment. Agent counts are unchanged.

Each lane entry in `GET /api/v1/state` adds `environments` (an array, empty with no managed entries). Each entry is an
explicit safe projection, never a serialized provider Record, config, SSH target, or CLI response:

| Field | Meaning |
| --- | --- |
| `environment_id` | Stable deterministic environment key, independent of display identifier |
| `provider` | `google_workstations` or `kubernetes` |
| `issue_id` | Opaque tracker issue ID |
| `issue_identifier` | Display identifier, nullable |
| `phase` | `reserved`, `preparing`, `running`, `stopping`, `stopped`, `deleting`, or `unknown` |
| `desired` | Durable desired state: `running`, `stopped`, or `absent` |
| `occupies_slot` | Boolean: possibly executing/reserved capacity, not a storage/billing count |
| `workspace_path` | Persisted worker-side path, never derived from the current display identifier |
| `provider_resource_id` | Safe Workstations resource name or Kubernetes UID, nullable |
| `terminal_observed_at` | First terminal observation, **UTC Unix milliseconds**, nullable |
| `unresolved` | Null, or fixed safe `category`, `code`, `operation` fields; no raw error text |

`unresolved` distinguishes invalid configuration, provider denial, retryable failure, and unknown
operation/cleanup state. Unknown phase without a captured failure still reports a safe unknown
state. Fixed redacted codes are diagnostic classifications, not cloud error payloads. A reported
failure is not a successful cancellation, and deletion uncertainty is not proof of running compute.
No access token, private key path, SSH argv/environment, authentication reference, private metadata,
or provider diagnostic body is exposed.

`GET /api/v1/lanes/:slug/:issue_identifier` also finds stopped retained environments with no active agent.
It adds `environment` (the same projection, null for unmanaged issues); managed `workspace.path`
comes from persisted environment state and `workspace.host` is the safe provider label. When no
running/retrying/blocked agent entry exists, `status` is the environment phase string and those
three agent fields are null, with no active session or invented event. Otherwise their existing
precedence and meanings remain unchanged. The existing state counts still count agents, not
environments. All other API timestamp formats remain unchanged; only `terminal_observed_at` is
introduced as UTC Unix milliseconds. Unknown issue identifiers still return not-found.

### Agent backends

`agent.backend` selects the default backend. Supported values are `codex` and `claude`; the default
is `codex`. `agent.backend_by_state` overrides the backend for a tracker state after trimming and
lowercasing the state key. `agent.blocked_state` is where Symphony parks a blocked backend result
after posting the blocked comment when the selected adapter supports tracker writes.
`agent.in_progress_state` is the state the orchestrator moves a claimed issue to right
after a successful spawn (default `In Progress`). Set it to `""` for an instance that
dispatches from a review state and must leave the issue where it found it.

```yaml
agent:
  backend: codex
  backend_by_state:
    implemented: claude
  blocked_state: "Blocked / Needs Attention"
  in_progress_state: "In Progress"
```

The Claude backend is optional. Install and authenticate the `claude` CLI on the orchestrator host
and on any SSH worker that may run Claude-routed issues. Tracker credentials are required only on
the orchestrator host. Claude-specific settings live under the top-level `claude:` block:

```yaml
claude:
  command: claude
  args: []
  linear_mcp_command: /absolute/path/to/symphony
  linear_mcp_args: []
  allowed_tools:
    - mcp__symphony__linear_graphql
    - Read
    - Grep
    - Glob
    - Bash
    - Edit
    - Write
  extra_mcp_servers: {}
```

`extra_mcp_servers` merges additional MCP servers into the generated config, keyed by server name
and holding Claude's own server object (`command`, `args`, `env`). Symphony passes
`--strict-mcp-config`, so this block is the only way to reach a second server and `~/.claude.json`
is ignored. The `symphony` key wins a name collision, so this block cannot displace the tracker
server. Tools from an added server must also be listed in `allowed_tools`, because that list is
passed as `--allowedTools`. `WORKFLOW.md` is the prompt itself, so pass a credential to an added
server through a wrapper script rather than writing it here.

`linear_mcp_command` is an executable path only. Symphony appends the required
`--linear-mcp --workflow <private-workflow-snapshot>` flags itself. Claude permission prompts are routed
through `--permission-prompt-tool mcp__symphony__approval_prompt`, not through the normal
`allowed_tools` list.

Claude currently uses the shared `codex.turn_timeout_ms` and `codex.stall_timeout_ms` settings for
turn and stall timeouts.

Claude telemetry uses the existing dashboard and JSON token fields (including the legacy
`codex_totals` name). Input totals include uncached, cache-write, and cache-read tokens; they
measure usage, not billing cost. Message IDs prevent repeated content blocks from counting
twice, and the final invocation total reconciles live estimates. Each fresh Claude turn starts
its usage baseline at zero while the worker and process totals continue accumulating.
Activity shows bounded assistant text, tool names without arguments, and completion/failure
outcomes. Live counters reset on runtime restart; durable attempt totals remain in run history.

For SSH workers, each worker must be able to resolve `claude.command` and either
`claude.linear_mcp_command` or `symphony` on `PATH`; worker-side tracker environment variables are
not required. At session start the orchestrator captures adapter-declared tracker secret values and
writes them only into the MCP server `env` inside a private mode-0600 config. The Claude process
inherits those secret names unset and receives no credential in argv, but a compromised Claude
process can read its `--mcp-config` file for the session lifetime. For a remote turn, Symphony sends
the workflow snapshot, MCP config, and prompt as length-prefixed SSH stdin. The remote shell writes
the workflow and config to mode-0600 temporary files, unsets the adapter-declared secret names
before launching Claude, and trap-removes both files on exit. `claude.linear_mcp_args` is inserted
before Symphony's required `--linear-mcp --workflow <worker-temp-WORKFLOW.md>` flags.

The helper mode can also be run directly when debugging MCP wiring:

```bash
./bin/symphony --linear-mcp --workflow /absolute/path/to/WORKFLOW.md
```

This escript starts a file-backed lane context only, without SQLite or a scheduler. During normal
execution the daemon writes a private snapshot of the attempt's workflow for MCP; changing the
current lane version cannot switch the adapter or prompt under that running attempt.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), and optional `assignee` (a Linear user ID or `me`, defaulting to `LINEAR_ASSIGNEE`).
  The read scope comes from `tracker.provider.team_keys` (list of Linear team keys),
  `tracker.provider.current_cycle` (boolean; requires `team_keys`), and
  `tracker.provider.project_slug` (string), plus the core `tracker.required_labels` /
  `tracker.any_labels` lists. At least one of those three container selectors is required —
  labels narrow a container, they do not define one. `team_keys` must be a list of non-empty
  strings and `current_cycle` must be a boolean; `current_cycle: true` without `team_keys` is
  rejected, because an unqualified active-cycle filter would match the active cycle of every team
  the token can see.
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported; `team_keys` and `current_cycle` have none. `required_labels`, `any_labels`,
  `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured scope and the requested state names,
  following Linear pages of 50 (nested relation pages of 50, attachment pages of 25). ID refreshes
  apply no scope at all — they filter on the requested IDs only — and batch up to 50 IDs per
  request. Empty state/ID lists return `{:ok, []}` without a Linear request. Team keys, label
  names, and state names are matched case-insensitively (`eqIgnoreCase`), several team keys are an
  `or` list, `any_labels` is one `or` list, and each `required_labels` entry is its own mandatory
  conjunct. `project_slug` is trimmed before it is queried and before it is displayed, so a
  configured slug with stray whitespace resolves to the trimmed value instead of silently matching
  nothing.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, the label policy, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. The configured scope governs scheduler reads, not raw tool calls; the tool can
  access whatever the configured Linear token can access.
- Attachments: the poll query also fetches issue `attachments` (title + url) onto the normalized
  `Issue`, and the default prompt lists them. The adapter advertises `linear_fetch_attachment`,
  which downloads an `https://uploads.linear.app/...` attachment with the configured token and
  returns its UTF-8 contents to the agent. It rejects non-Linear hosts, caps downloads at 1 MiB,
  and rejects non-text payloads (`{:error, :missing_url}`, `{:error, :invalid_attachment_url}`,
  `{:error, :attachment_too_large}`, `{:error, :attachment_not_text}`, plus the shared
  `{:error, :missing_linear_api_token}` / `{:error, {:linear_api_status, status}}` /
  `{:error, {:linear_api_request, reason}}`).
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_scope}`,
  `{:error, :missing_linear_team_keys}`, `{:error, :invalid_linear_team_keys}`,
  `{:error, :invalid_linear_current_cycle}`, `{:error, {:linear_preflight_failed, reasons}}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, scope, team keys, current cycle, endpoint,
  assignee, or viewer errors to `tracker_config` or `tracker_auth` — `:missing_linear_scope`,
  `:missing_linear_team_keys`, `:invalid_linear_team_keys`, `:invalid_linear_current_cycle`, and
  `{:linear_preflight_failed, reasons}` are all `tracker_config` — request failures to
  `tracker_transport`, non-200 responses to `tracker_response` (`429` is `tracker_rate_limited`),
  GraphQL/unknown payload failures to `tracker_payload`, and missing cursors to
  `tracker_pagination`; logs and tool responses carry the human-readable provider detail.
- Lane preflight: when `team_keys` is configured, the adapter resolves the scope against Linear
  before the lane starts and after tracker edits, in at most two requests per check regardless of
  how many values are configured — one `teams` query carrying active cycles and workflow states, and, only
  when a label list is non-empty, one `issueLabels` query filtered by the configured label names.
  `activeCycle` is a single object rather than a connection, so selecting it is free against
  Linear's complexity budget; only its `id` is read, purely as a presence marker.
  Every unresolved value is reported together in one `{:linear_preflight_failed, reasons}` error
  rather than one per edit/start. The one exception: when *no* configured team key resolves at all, the
  error lists only the team keys, because every state and label would then be reported absent too
  and would bury the single actionable reason.
  An unresolvable team key disables the lane, because that is a typo rather
  than a state. A configured state name or label absent from *all* listed teams also disables the lane,
  because it can never match; absent from only *some* listed teams is a warning naming those teams,
  because those conjuncts are ANDed with the team conjunct and the remaining teams still match. A
  `required_labels` warning says explicitly that the named teams will contribute no issues at all,
  since a required label is a mandatory conjunct; an `any_labels` warning says only that those
  teams match nothing for it. A team whose workflow-states page comes back full — the page size is
  pinned by a named module attribute, currently 50, because Linear's query complexity is
  multiplicative across nested connections — makes absence unprovable, so that warns instead of
  failing. A listed team with no active cycle warns and permits lane startup: an absent active cycle is a normal
  Linear state during sprint cooldown, and refusing to start would turn a routine condition into an
  outage. With `project_slug` as the only selector there is nothing to resolve and preflight makes
  no request — an unknown slug still fails silently, because Linear returns zero issues for it.
- No active cycle at runtime: the poll simply returns zero issues and that lane idles. No
  per-tick probe is spent and no repeated warning is emitted, because cycles legitimately end.
  Operator visibility is the preflight warning plus the status board's `Scope:` line.
- Scope on the status board: the adapter implements the optional `Tracker.scope_summary/1`
  callback, so the board renders an unconditional `Scope:` line — for example
  `teams ENG, OPS · current cycle · required labels agent`. Label names render lowercase because
  both label lists are normalized when the workflow is loaded. A tracker that reports no scope
  renders the sentinel `n/a`. There is no project link: a real Linear project URL is
  workspace-prefixed and no workspace slug exists anywhere in the config, so the old
  `https://linear.app/project/<slug>/issues` line was always broken and has been removed.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- **Known deviation from `SPEC.md` §11.1, fix pending.** §11.1 requires that an ID refresh apply no
  configured scope selection as a filter, and exempts only an adapter that cannot produce a complete
  normalized snapshot outside its container. This adapter fits neither: the bulk-fetch request is
  already unscoped and its `issue.id` is Jira's global immutable ID, yet the response is then
  filtered by project key. Consequence: an issue moved out of the configured project while an agent
  is running on it is reported as missing rather than as still-live, so the orchestrator releases
  the claim and stops the run. Candidate-read scoping is correct and unaffected. The fix is a code
  change outside the scope of the change that amended §11.1, so it is recorded here per §11.2 rather
  than left as an undocumented conflict.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes. That omission is `SPEC.md` §11.1's
  container-bound case rather than a deviation: a task's normalized `state` is the name of its
  section *within the configured project*, so outside that project there is no state to report and
  no complete snapshot to return.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

Phoenix LiveView and Bandit provide the installation's authenticated control and observability UI.
Tracker links use only tracker-provided `http`/`https` URLs.

| Route | Surface |
| --- | --- |
| `/login` | Operator-token login |
| `/` | Lane list, health, enable/disable controls |
| `/lanes/new` | Create a disabled lane |
| `/lanes/:slug` | Lane runtime, issue activity and durable run history |
| `/lanes/:slug/edit` | Metadata, raw YAML and prompt editor with field-path errors |
| `/lanes/:slug/versions` | Immutable version history and activation |
| `/runs/:attempt_id` | Durable attempt details, token totals and event timeline |

Browser requests without authentication redirect to `/login`; API requests return `401`.
Login establishes an HTTP-only signed session; bearer authentication can also seed a browser session.
Login and cookie-authenticated mutations require CSRF protection. Explicit bearer-authenticated API
requests do not require a CSRF token. Rotating the operator token invalidates existing sessions.
Only login and static assets are public. The token permits configuration writes, so treat it as an
administrative credential; keep loopback binding or deploy appropriate TLS/network restrictions.

```bash
curl -H "Authorization: Bearer $SYMPHONY_OPERATOR_TOKEN" http://localhost:4000/api/v1/lanes
curl -X PUT -H "Authorization: Bearer $SYMPHONY_OPERATOR_TOKEN" \
  -H 'Content-Type: application/json' -d '{"enabled":true}' \
  http://localhost:4000/api/v1/lanes/main
```

All API routes below require authentication:

| Method | Route | Result |
| --- | --- | --- |
| GET | `/api/v1/lanes` | `{"lanes":[...]}` metadata/runtime health list |
| POST | `/api/v1/lanes` | Create lane, `201` with lane object |
| PUT | `/api/v1/lanes/:slug` | Partial metadata/workflow update, `200` with lane object |
| POST | `/api/v1/lanes/:slug/versions/:id/activate` | Activate a version of that lane, `200` |
| GET | `/api/v1/lanes/:slug/export` | Current workflow as `text/markdown` |
| DELETE | `/api/v1/lanes/:slug` | Soft delete, `204`; enabled/running lane returns `409` |
| GET | `/api/v1/state` | `{"generated_at":"...","lanes":[...]}` with per-lane runtime payloads |
| GET | `/api/v1/lanes/:slug/:issue_identifier` | Lane-scoped issue details including `"lane"` |
| GET | `/api/v1/:issue_identifier` | First matching lane's issue details; prefer the scoped route |
| POST | `/api/v1/refresh` | Best-effort refresh of available lanes, `202` with `{"lanes":[...]}`; `503` if none available |

Create/update accepts `slug`, `name`, `enabled`, `executor`, `front_matter`, `prompt`, and `note`.
`front_matter` is a YAML string without delimiters, `prompt` a string, `enabled` a boolean, and
`note` a string or null. Slugs match `^[a-z][a-z0-9-]{1,40}$`; only executor `"local"` is currently
accepted (SSH/managed worker selection still belongs inside the workflow). New lanes default disabled.
Supplying either workflow string creates a version, even when unchanged; omitted strings retain
their current values. Metadata-only updates create no version. Invalid input returns
`422 {"errors":[{"path":"polling.interval_ms","message":"..."}]}`. Missing lanes return `404`.
Soft deletion retains history and reserves the slug; disable and wait for runtime shutdown first.

### Durable history and retention

SQLite stores lanes, immutable lane versions, run attempts, and run events. Attempt records retain
the dispatch-time lane version/executor, status, timing, turn count, and token totals including cached
usage. The ordered history writer is asynchronous: scheduling never waits for database writes.
Database errors are logged, not retried; uncommitted queued events may be lost on process failure.
History is observability data, never the source for claims, retries, or restart scheduling.

Disabling a lane stops its runtime/agents and finishes active attempts as stopped; abnormal runtime
death finishes them as failed. Runtime crashes are isolated by lane; five abnormal deaths within
60 seconds disable the lane with a visible error. Event retention starts one minute after boot and
runs daily, deleting events older than `--events-retention-days` while preserving run summaries and
workflow versions. Live views subscribe to lane/run updates.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: example import/export contract for one lane
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

The suite uses a shared in-memory SQLite database and runs serially. The test harness resets lane
state between tests; `TestSupport.write_workflow_file!/2` updates the current test lane immediately,
not a file watcher. Do not point tests at an installation's persistent data root.

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

### Opt-in managed-worker provider qualification

`managed_environment_live_e2e_test.exs` is a **real, billable qualification harness**, not
a simulated provider test. Ordinary test loading skips it and does not read its live
workflow, credentials, or evidence path. It uses a Memory tracker (no production issue
mutations), the real Orchestrator and provider adapters, and separate real Codex and
Claude runs under the workflow's existing approval/sandbox policies. Do not weaken those
policies to obtain a pass.

Neither provider has a live qualification result from this change. **Kubernetes Agent
Sandbox v1.0.1 remains blocked before allocation by unproven controller cleanup
ordering.** No `qualification` flag bypasses that production preflight blocker. The
gate-hold and dedicated-node fault protocols are implemented for qualification, not
permission to exercise a currently unqualified cluster. Workstations also remains
blocked until an operator supplies and authorizes every prerequisite below.

Obtain explicit authorization for the selected disposable project/region/cluster or
Kubernetes context/namespace, five concurrent workers, at least six retained
environments, paid model sessions, deletion, and the specified physical fault scope.
Possession of credentials is not authorization. Use a separately scoped workflow and
fresh output directory for each provider/run. The selected provider comes exclusively
from `worker.environment.kind`, through Config; there is no provider override variable.

From `elixir/`, invoke with these **exact three opt-in variables**:

```bash
# AUTHORIZED_WORKFLOW must name the reviewed absolute workflow path.
# Resolve symlinks in the output parent (including macOS /var and /tmp aliases).
umask 077
EVIDENCE_DIR="$(mktemp -d)"
EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd -P)"
EVIDENCE_JSON="$EVIDENCE_DIR/evidence.json"
env SYMPHONY_RUN_MANAGED_E2E=1 \
  SYMPHONY_MANAGED_E2E_WORKFLOW="$AUTHORIZED_WORKFLOW" \
  SYMPHONY_MANAGED_E2E_OUTPUT="$EVIDENCE_JSON" \
  mise exec -- mix test test/symphony_elixir/managed_environment_live_e2e_test.exs \
  --include live_e2e --timeout 1800000
```

The output must be a **new absolute file in an empty, private temporary directory**,
not a repository path, symlink, or an existing evidence file. The harness rejects
symlink ancestors and group/world-accessible output directories. Evidence and its
staged recovery workflow are written privately and atomically. Allocation intent is
persisted before publishing Memory issues; interruption recovery gets a separate
bounded cleanup deadline. Keep the private directory if cleanup is unresolved and
use its deployment/resource IDs for authorized remediation. Successful cleanup removes
the staged workflow; never commit evidence, credentials, or generated infrastructure IDs.

The private evidence keeps `captured_resources` separately from
`remaining_owned_resources`. Captured environment, Workstations VM/disk, Kubernetes
PVC/PV/CSI volume-handle and cleanup-child identifiers survive later inventory
failure and interrupted recovery. They are historical remediation clues, **not**
proof those resources remain present. Successful current inventory labels current
resources `observed_present`; unresolved inventory labels retained clues `captured`
and includes `inventory_unresolved`. Never treat a generic inventory error or missing
parent as proof of absence. Only bounded, allowlisted non-secret identifiers are
retained; provider/request bodies and credential material are not evidence.

Supply the following **test-only** map at
`worker.environment.provider.qualification` in the selected workflow. This is not a new
production provider mode or an authorization bypass:

| Field | Required operator input |
| --- | --- |
| `paid_model_calls_authorized` | Literal `true`, covering real Codex and Claude calls. |
| `max_concurrent_workers` | Exactly `5`; the harness also queues a sixth ticket. |
| `max_retained_environments` | Integer at least `6`. |
| `max_backend_sessions` | Integer at least `20`; an enforced ceiling including recovery/restarts. |
| `qualification_report` | Non-secret reference to the operator's authorization, runtime/controller evidence, quota assessment and cleanup plan. |
| `quota_evidence` | Numeric `concurrent_workers >= 5`, `retained_environments >= 6`, and optional nonnegative `persistent_disk_gib`. Only these fields enter evidence. |
| `runtime_version` | Operator-qualified worker/runtime version; recorded as operator-reported, separately from versions actually observed over SSH. |
| `worker_image` | Exact digest-pinned image matching the actual provider template/config, including `@sha256:` and 64 lowercase hex digits. |
| `node_modules_path` | Absolute **remote** directory containing the pinned compatible Playwright installation. No dependency-path fallback is supplied. |
| `review_app_url` | Independently deployed deterministic HTTPS health endpoint, with no URL credentials, query or fragment; redirects are not followed. Its response must remain available and identical while **all** disposable workers are physically stopped. |
| `unrelated_resource_paths` | Nonempty list of existing, unrelated negative-control API resource paths in the selected scope. Immutable identities and stable configuration/ownership/lifecycle fingerprints must remain unchanged after cleanup. |
| `fault_driver` | Absolute local path to the operator's audited, self-contained physical-fault executable. |
| `fault_driver_sha256` | SHA-256 of that executable's bytes. The helper executes a private snapshot of precisely those bytes; do not depend on sibling files beside the executable. |
| `storage_fault_authorized` | Literal `true`, authorizing scoped physical storage-deletion delay and restoration. |
| `node_fault_authorized` | Kubernetes only: literal `true` for the dedicated-node disconnection scenario. |
| `authorized_node_uids` | Kubernetes only: explicit nonempty allowlist of dedicated node UIDs; unrelated workload sharing is rejected. |
| `denied_identity` | Kubernetes only: deliberately denied, non-`system:` Kubernetes username that the authorized caller can impersonate for the real stop-rejection probe, without impersonated groups. |

The rest of the workflow must satisfy the normal provider configuration and credential
requirements documented above. Its `hooks.after_create` must clone an authorized
disposable Git repository into the managed checkout. Supply functional real backend
installations/authentication on the worker without mounting cloud/cluster administrative
credentials into it. Pin compatible Python Testcontainers, Node Playwright and Chromium
dependencies in the qualified worker image; install Docker Engine, Compose, Python 3,
Node, Git, SSH and the fixture-required command-line tools. The three workload fixtures
already bind PostgreSQL 16, Alpine 3.20 and Ryuk 0.8.1 to exact image digests. Review those
digests and architecture availability before authorizing the run; do not silently
substitute tags, disable Ryuk, or download changing dependencies between comparisons.
Evidence records fixture hashes/images and actual worker tool versions. A local fixture
smoke run is not evidence that either real backend can invoke Docker under its policy.

Isolation checks use bounded concurrent probes to the other owned workers' private
Docker/SSH endpoints and to narrowly scoped credential endpoints: GCP metadata DNS and
link-local IP, AWS IMDSv2/instance-role credentials, and Azure managed-identity tokens.
Returned tokens are never printed. A denied connection/authorization is distinct from
an unexpected usable credential response; ambiguous successful responses fail the check.
Workstations prerequisite reads also require Compute regional quota visibility and an
installed `gcloud` CLI whose JSON version output can be observed.

The physical-fault helper protocol is `fault_driver --request <private-json-file>`.
Its JSON contains `scenario` (`storage_deletion`, `node_disconnection`, or `all`),
`phase` (`apply` or `restore`), the generated `deployment_id`, selected `scope`,
`resource` (safe backing-storage/volume/node identities, or `null` for `all/restore`),
and `credential_references`. References select the operator's existing credential
configuration/impersonation identity or kubeconfig/context; they are **not credential
values**. Never print or copy credential-reference maps into public evidence. The selected
Kubernetes context name is recorded separately with its namespace as required target audit
identity; credential file paths, configurations and impersonation selectors stay private. Emit only
`{"applied":true}` on stdout after successful application/restoration. This acknowledgment
and the executable hash are **not physical-effect proof**. `all/restore` must be
idempotent, confined to this deployment/scope, and work even after the original provider
record is lost.

The harness observes accepted deletion followed by a real failed/uncertain deletion
operation with the captured physical storage still present, restarts the runtime, then
requires eventual provider-certified absence after restoration. Merely withholding a
client DELETE or observing ordinary asynchronous deletion latency does not qualify.
Node `NotReady`, a closed SSH connection, CLI success prose and absent parent objects
are never substitutes for physical-stop/deletion proof. Never force-delete an unverified
node or invent broad IAM changes to make the test proceed.

Every runner invocation, including response-loss recovery and cleanup/restart paths,
is checked before the real `AgentRunner` is called. The context must be a valid live
managed lease for the selected deployment/scope and issue, with the matching attempt.
Missing, local, static SSH, forged or stale contexts are rejected without starting
that backend. Evidence records only safe mode/outcome enums and opaque issue/attempt
IDs; targets, options and credentials are never serialized. `runner_rejected` latches
permanently: later valid runs, successful checks or complete cleanup cannot erase it.
Both this latch and invocation count are persisted for interruption recovery.

Unrelated-resource baselines retain `{path, uid, fingerprint}`. The SHA-256 fingerprint
covers stable non-secret configuration, ownership and meaningful lifecycle fields,
not volatile versions, timestamps or heartbeats. In-place changes therefore fail even
when the UID is unchanged. Recovery restores the fingerprint; legacy UID-only or
invalid baselines fail closed rather than silently weakening the comparison.

Every required check is individually recorded. A blocked, failed or unrun check makes
`qualified?` false, as does incomplete inventory, interruption, any rejected runner
invocation or any remaining owned resource. Missing service-managed disk evidence
requires operator action, not a successful
summary. Unavailable authorization, audited fault helper, scoped infrastructure,
quota/image/dependency evidence, real backend access, physical deletion evidence, or
the Kubernetes cleanup-ordering guarantee remain explicit qualification blockers.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
