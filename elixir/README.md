# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

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
adapter's tools through Symphony's standalone MCP mode.

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
mise exec -- ./bin/symphony ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## Run in Docker (OrbStack-compatible)

One Symphony instance drives one repo. Its Linear read scope is selected by
`tracker.provider.team_keys`, `tracker.provider.current_cycle`, `tracker.provider.project_slug`, or
a combination, optionally narrowed by `tracker.required_labels` / `tracker.any_labels`; at least one
of the three container selectors is required. You may still run one container per project if you
want the isolation. Everything below works as-is with [OrbStack](https://orbstack.dev/) (native
arm64, no platform pins) or Docker Desktop.

### Deploying a project

Deployments live in their own private repos, not in this one. Copy
[`deploy/client-template/`](../deploy/client-template) into a new repo and follow the README in
it: it pulls the published image `ghcr.io/adelrioj/symphony` (built and pushed by
[`.github/workflows/docker-publish.yml`](../.github/workflows/docker-publish.yml)), mounts that
repo's own `workflow.md`, and needs no clone of this repo. Prerequisites, hot reload,
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
2. **Set your Linear key** (git-ignored; `docker compose` auto-loads `.env`):
   ```bash
   cp .env.example .env      # then edit LINEAR_API_KEY
   ```
3. **Edit `workflows/example.md`** — at minimum a scope selector (`tracker.provider.project_slug`,
   `tracker.provider.team_keys`, or `tracker.provider.current_cycle` with `team_keys`) and the
   `hooks.after_create` clone URL. Keep `workspace.root: /workspaces` (it must match the volume
   mount in compose) and `server.host: 0.0.0.0` (see the port note below).
4. **Launch:**
   ```bash
   docker compose up --build          # first build compiles OTP once, then caches it
   ```
   Dashboard: <http://localhost:4000>.

The `workflows/` directory is mounted read-only at `/config` as a *directory*, never as a single
file: a single-file bind mount pins the inode, so an editor's rename-replace on the host stops
propagating and hot reload dies. Editing `workflows/example.md` on the host reloads it in the
running container within about a second.

Compose runs the daemon with the acknowledgement flag Symphony requires in order to start:

```
/config/example.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000 --logs-root /app/elixir
```

Notes:

- **Ports:** the dashboard and JSON API have no authentication, so compose publishes
  `127.0.0.1:4000:4000` — host-side loopback only. Inside the container `server.host` stays
  `0.0.0.0`, which is not a contradiction: Docker forwards the published port to the container's
  network interface, not to its loopback, so a container-side loopback bind would be
  unreachable. Do not widen the host side.
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
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Required flag:

- `--i-understand-that-this-will-be-running-without-the-usual-guardrails` — daemon mode refuses to
  start without it; it acknowledges that Codex runs with no guardrails. Not required for
  `--linear-mcp`, which serves the Linear MCP tools instead of starting the daemon.

Optional flags:

- `--logs-root` sets the directory Symphony creates `log/` under; it writes
  `<root>/log/symphony.log*` (default root: the working directory, so `./log/symphony.log`).
  Pass the parent, not the log directory itself, or the logs land one level deeper than intended
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
agent session prompt.

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
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
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

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

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

The reload identity includes provider kind, deployment ID, tracker kind, workspace root, and every provider
reference in the selected example (including auth-selection references). Workstations
project/location/cluster and Kubernetes kubeconfig/context/namespace are deployment boundaries,
not agent-controlled scheduling choices. While inventory or jobs remain, identity-changing reloads
are rejected atomically and the last good workflow remains active. Owner death does not unlock this
guard. Only authoritative empty compute-and-storage inventory with no unresolved operations permits
release, and protection is reacquired before subsequent allocation. Mutable polling, concurrency,
deadlines and retention are not identity changes; in-flight work retains its captured configuration.
Existing environments retain and validate their captured template identity rather than silently
adopting edited infrastructure.

#### Recovery, capacity, retention, and hooks

Startup performs provider preflight and complete owned-resource discovery before dispatch. Denied,
partial, malformed, or unknown inventory is not an empty deployment. Recovery reconstructs durable
identity, paths, desired state, attempts, first terminal timestamp, and pending operations; it
reconciles potentially running resources before reuse instead of trusting a lost local agent PID.
Unknown create/start outcomes block duplicate allocation.

The existing `agent.max_concurrent_agents` and per-state limits remain the execution budget.
Reservations, preparation, running, stopping, and unresolved possibly executing environments occupy
slots. Five active executions are independent of how many stopped environments are retained.
Qualified remote quiescence releases execution capacity; closing SSH, losing a local holder, killing
an agent, cancellation, or a stop request alone does not. A quiescent environment with unresolved
disk deletion can release its execution slot but still holds the identity guard and may incur charges.
Existing agent `running`, `retrying`, and `blocked` status meanings do not change.

Terminal observation is persisted once as UTC Unix milliseconds and survives restart. An expired
retention clock alone does not authorize deletion: the tracker must affirmatively still report a
terminal state. Missing issues, failed tracker reads, or nonactive nonterminal states do not authorize
destruction. A genuine reopen conditionally clears terminal/cleanup intent before restart if deletion
has not become irreversible, retaining the same workspace. A prior completed cleanup-hook marker
does not suppress a new cleanup after a genuine reopen.

`after_create` still bootstraps only a new checkout; `before_run`/`after_run` keep their existing
failure policies. All run on the selected worker through the captured execution context.
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
NetworkPolicy access, complete Sandbox/Pod/PVC/Service/Secret/PV inventory, conditional Sandbox
intent and finalizer writes, exact Pod CAS/gate/stop-fence writes, normal conditional child deletion,
owned SSH Secret lifecycle, and Pod/PV watch permissions. Keep this separate from workload RBAC.
No broad node mutation or automated node-fencing permission is part of this implementation.

Stop requires qualified kubelet termination for every regular/init/ephemeral container of every
possibly released UID, or proof a fenced unscheduled Pod was never released. A `kubelet` manager
string is not authentication: audited RBAC/admission/recovery must prevent forged status,
unverified force-deletion, out-of-service recovery, and unverified node removal/fencing. API
disappearance or generic Failed/ContainerStatusUnknown is not stop evidence.

Qualify the CSI driver's DeleteVolume and deletion-protection behavior. Bound PV identity,
claimRef/volumeHandle and `external-provisioner.volume.kubernetes.io/finalizer` must be observed
before deletion; a complete exact-UID PV deletion watch must show finalizer removal. PVC disappearance,
missing PVs, unbound claims with unknown provisioning, denied inventory, or compacted watch history
do not establish disk absence. Never strip protection finalizers to force progress.

**Final-cleanup blocker:** upstream v1.0.1 has no authoritative per-Sandbox acknowledgment ordering
all earlier child-create requests before final cleanup. Its
[deletionTimestamp branch](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.1/controllers/sandbox_controller.go#L303-L308)
only logs, clears a local deferral clock, and returns. An elapsed timeout, qualification ConfigMap,
empty child inventory, or parent 404 cannot supply the missing evidence. After reachable child/CSI
cleanup Symphony leaves the deleting parent discoverable with `symphony.dev/environment-cleanup`,
retains remaining identities, and reports `kubernetes_controller_cleanup_ordering_unproven`.
Final absence is **unknown**, the identity guard cannot release, and no full Kubernetes production
qualification is claimed. Resolving this needs authoritative upstream evidence or an approved design
change, not a workflow flag.

#### Managed observability API

Enable the existing service with `--port` or `server.port`; the dashboard layout is unchanged.
`GET /api/v1/state` adds `environments` (an array, empty with no managed entries). Each entry is an
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

`GET /api/v1/<issue_identifier>` also finds stopped retained environments with no active agent.
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
`--linear-mcp --workflow <absolute WORKFLOW.md>` flags itself. Claude permission prompts are routed
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
outcomes. These counters are in memory: a service restart clears them.

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
- Startup preflight: when `team_keys` is configured, the adapter resolves the scope against Linear
  once before the scheduling loop starts, in at most two requests regardless of how many values are
  configured — one `teams` query carrying each team's `activeCycle` and workflow states, and, only
  when a label list is non-empty, one `issueLabels` query filtered by the configured label names.
  `activeCycle` is a single object rather than a connection, so selecting it is free against
  Linear's complexity budget; only its `id` is read, purely as a presence marker.
  Every unresolved value is reported together in one `{:linear_preflight_failed, reasons}` error
  rather than one per boot. The one exception: when *no* configured team key resolves at all, the
  error lists only the team keys, because every state and label would then be reported absent too
  and would bury the single actionable reason.
  An unresolvable team key fails the boot, because that is a typo rather
  than a state. A configured state name or label absent from *all* listed teams also fails the boot,
  because it can never match; absent from only *some* listed teams is a warning naming those teams,
  because those conjuncts are ANDed with the team conjunct and the remaining teams still match. A
  `required_labels` warning says explicitly that the named teams will contribute no issues at all,
  since a required label is a mandatory conjunct; an `any_labels` warning says only that those
  teams match nothing for it. A team whose workflow-states page comes back full — the page size is
  pinned by a named module attribute, currently 50, because Linear's query complexity is
  multiplicative across nested connections — makes absence unprovable, so that warns instead of
  failing. A listed team with no active cycle warns and boots: an absent active cycle is a normal
  Linear state during sprint cooldown, and refusing to start would turn a routine condition into an
  outage. With `project_slug` as the only selector there is nothing to resolve and preflight makes
  no request — an unknown slug still fails silently, because Linear returns zero issues for it.
- No active cycle at runtime: the poll simply returns zero issues and the instance idles. No
  per-tick probe is spent and no repeated warning is emitted, because cycles legitimately end.
  Operator visibility is the boot warning plus the status board's `Scope:` line.
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

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

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
| `unrelated_resource_paths` | Nonempty list of existing, unrelated negative-control API resource paths in the selected scope. Exact immutable identities are compared after cleanup too. |
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
values** and must never be printed or copied into public evidence. Emit only
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

Every required check is individually recorded. A blocked, failed or unrun check makes
`qualified?` false, as does incomplete inventory, interruption or any remaining owned
resource. Missing service-managed disk evidence requires operator action, not a successful
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
