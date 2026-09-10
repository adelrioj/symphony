# Remote ticket execution environments

Date: 2026-09-11
Status: design sections approved; written specification awaiting user review

## Problem and decision

Symphony currently supports local execution and execution on configured SSH hosts.
Running several coding agents, builds, browsers, and application dependencies on the
orchestrator machine couples orchestration capacity to development workload capacity.
Static SSH hosts move that work elsewhere but do not provide a managed per-ticket
provisioning, suspension, discovery, and deletion lifecycle.

Add an optional managed execution-environment boundary. Symphony remains the scheduler
and runs its existing Claude/Codex backends inside remote, isolated ticket environments.
The environment provider manages infrastructure, not the coding-agent loop.

The selected compatibility model is **a complete Linux development environment with a
private Docker daemon per ticket**. Existing Docker Compose and Testcontainers workflows
must work without provider-specific rewrites. Changing execution provider may require
infrastructure configuration and a suitable development image, but must not require
translating application dependencies into provider-specific resources inside Symphony.

Two deployment profiles are design targets:

1. Customer-managed Kubernetes, using a runtime capable of safely hosting this workload.
2. Google-managed development environments, with Cloud Workstations the selected
   candidate to validate.

Neither profile is claimed operationally supported by this document. Section
“Provider qualification” defines the real-infrastructure gates for both. Failure of a
gate does not authorize reduced isolation, local fallback, or a different compatibility
model; it requires a documented prerequisite or an explicit design revision.

## Goals and deployment boundary

- Start with five concurrent ticket executions per independent Symphony deployment.
  Use the existing configurable concurrency limit rather than hard-coding five.
- Keep each deployment's scheduler, provider resources, credentials, storage, network
  policy, and budgets independent. There is no cross-company scheduling or shared state.
- Keep the agent, repository checkout, hooks, builds, browsers, tests, and development
  services off the orchestrator machine.
- Preserve a ticket's workspace across continuation runs, retries, and human review.
- Release development compute while a ticket waits for review, without deleting its
  workspace or requiring its separately deployed review app to stop.
- Prevent duplicate execution and untracked resources after ambiguous API failures,
  transport loss, configuration reloads, and orchestrator restarts.
- Keep provider and application details out of scheduler and agent-backend policy.

The motivating repositories are examples only. No company names, application stacks,
tracker identifiers, or existing review-app conventions become Symphony concepts.
Five active executions are independent of the number of retained, stopped environments.
Per-environment CPU, memory, and disk sizing must come from the repository's measured
workload. Moving execution does not eliminate its aggregate resource requirements.

## Non-goals

- A multi-tenant control plane, shared company resource pool, or distributed scheduler.
- Replacing Claude/Codex protocols with a cloud vendor's agent framework.
- A platform that interprets Compose files and translates them to Kubernetes manifests.
- Provisioning customers' Kubernetes clusters, installing privileged cluster runtimes,
  or creating their foundational cloud networks from the agent or ticket workflow.
- General review-app hosting, routing, deployment, or teardown inside Symphony core.
- Transparent migration of a running agent, process memory preservation, automatic
  cross-provider failover, or exactly-once execution of external agent side effects.
- Warm pools, predictive autoscaling, new dashboards, or a durable scheduler database
  solely for this feature.
- Implementing every commercial sandbox provider evaluated during research.

## Existing contracts and specification relationship

`SPEC.md` remains the source of truth for implemented behavior. This document describes
an extension to implement, not a claim that managed environments already exist.

Relevant existing contracts:

- Sections 2 and 7 keep one authoritative orchestrator, bounded concurrency, deterministic
  workspaces, and tracker/filesystem-driven restart recovery.
- Section 14.3 does not promise recovery of live sessions or in-memory retry timers.
- Appendix A runs the selected backend over SSH stdio, interprets `workspace.root`
  remotely, preserves host affinity, and rejects accidental local fallback.
- `SymphonyElixir.Agent` owns `start_session`, `run_turn`, and `stop_session`.
  `AgentRunner` owns the continuation loop.
- `Workspace` owns workspace preparation, hooks, and path safety. `SSH` provides the
  existing remote shell and process transport.
- Configuration comes through `Workflow` and `Config`, not ad-hoc environment reads.

Managed execution extends these contracts with provider-owned environment identity and
reconciliation. Static SSH and local execution remain supported modes; they are not
renamed or removed. New managed behavior is opt-in and must not change their defaults.
Implementation must update `SPEC.md` alongside meaningful behavioral changes, including
managed-resource recovery, capacity accounting, and terminal retention. In particular,
nonzero retention is an explicit extension to immediate terminal workspace cleanup, not
a silent reinterpretation of the current specification.

## Architecture and ownership

| Component | Responsibility | Must not own |
| --- | --- | --- |
| Orchestrator | Eligibility, claims, concurrency, retries, tracker reconciliation, lifecycle decisions | Cloud or Kubernetes API details |
| Execution-environment behaviour and adapters | Ensure, inspect, start, connect, stop, discover, and destroy owned environments | Ticket priority, agent turns, application deployment policy |
| AgentRunner and Agent backends | Existing coding-agent session and continuation semantics | Choosing or provisioning an infrastructure provider |
| Workspace | Remote directory preparation, repository hooks, workspace-boundary enforcement | Cloud resource ownership |
| Repository workflow and environment definition | Development toolchain, application services, tests, review-app commands | Symphony provisioning credentials |
| Deployment operator | Provider templates, runtime, networks, IAM/RBAC, quotas, images, storage policy | Per-ticket scheduling |

Introduce one execution-environment behaviour, following the repository's existing
adapter pattern. Do not add a separate scheduler or duplicate the retry policy in each
adapter. Lifecycle work must not block the orchestrator's ability to poll and reconcile.

The provider returns an execution context that identifies the environment and its
connection route. Thread that context through workspace and backend startup; do not
store a mutable global “current worker.” Once managed execution is selected, a missing
or invalid context is an error, never an instruction to execute locally.

### Provider contract

These operations describe semantic responsibilities; implementation planning determines
Elixir argument shapes and module decomposition without changing the contract.

| Operation | Required semantics |
| --- | --- |
| Ensure | Find or create the environment for a stable ticket key; repeated calls return the same owned resource |
| Inspect | Return authoritative lifecycle state, resource identity, and outstanding provider operation status |
| Start | Make an existing environment runnable, preserving its persistent workspace |
| Connect | Return an authenticated, non-interactive execution route with bidirectional stdin/stdout, error reporting, and session-scoped cleanup |
| Stop | Stop all ticket execution compute, including Docker workloads; preserve persistent storage; distinguish requested from confirmed stop |
| Discover | Enumerate resources owned by this deployment after restart, including partially provisioned and deletion-pending resources |
| Destroy | Idempotently remove ticket compute, storage, and connection resources; report incomplete deletion |

Use SSH as the initial process transport, reusing Appendix A and existing backend
protocols. Kubernetes and Workstations adapters establish their authenticated private
route or tunnel to the environment's SSH service. Public SSH exposure and a shared
mutable SSH configuration are not requirements. Credentials and connection processes
are scoped to the environment/run and cleaned up when no longer needed. Closing a
transport is not proof that remote execution stopped.

Provider calls distinguish pending operations, retryable errors, invalid configuration,
authorization failures, absent resources, and unknown outcomes. A timeout after a create
or start request must be resolved by inspection, not assumed to mean nothing happened.

### Identity and recovery metadata

Use a stable key derived from deployment identity, tracker kind, and opaque issue ID.
Do not key resources solely by a mutable issue identifier or a sanitized display name.
Provider-safe names must preserve collision resistance.

Provider-side ownership metadata must be discoverable without local scheduler memory:

- Stable deployment identity and ticket key.
- Provider resource identity and the template/configuration identity used to create it.
- Current execution-attempt identity when an attempt exists.
- Lifecycle intent needed to recover incomplete stop or deletion operations.
- Terminal-observation time when delayed cleanup applies.

Ownership metadata belongs to provider control-plane resources, not solely to files the
coding agent can modify. Labels/metadata are identifiers, not a replacement for IAM or
RBAC authorization. A single orchestrator remains authoritative for each deployment;
active-active operation is not introduced.

## Configuration and repository contract

Add an optional `worker.environment` configuration object through `Config`:

| Field | Contract |
| --- | --- |
| `kind` | `kubernetes` or `google_workstations`; unknown values fail validation |
| `deployment_id` | Required stable, non-secret identity used to discover and authorize ownership checks |
| `provider` | Adapter-validated mapping of resource scope, template references, and authentication configuration |
| `startup_timeout_ms` | Required positive deadline covering provisioning/start/readiness for an attempt |
| `shutdown_timeout_ms` | Required positive deadline before unconfirmed shutdown is surfaced as unresolved |
| `terminal_retention_ms` | Nonnegative duration, default zero; measured from a persisted terminal observation |

Managed mode is selected only when this object is present. Combining it with
`worker.ssh_hosts` or `worker.max_concurrent_agents_per_host` is invalid rather than
silently choosing precedence. Without it, current local/static-SSH selection remains
unchanged. The existing agent concurrency limit controls execution slots.

Provider settings are deliberately adapter-specific:

- Kubernetes requires a cluster authentication/context reference, resource scope, and
  an operator-provisioned sandbox template reference. That template specifies the
  compatible runtime, image, resources, per-ticket storage, and security/network policy.
- Workstations requires project, location, workstation-cluster, and workstation-config
  references. The configuration specifies image, machine resources, persistent storage,
  networking, and execution-compatible timeout settings.

Credentials use existing deployment authentication facilities and references; do not put
raw provider credentials in committed workflow YAML. Each adapter validates its own
settings and required permissions, and reports actionable errors through existing logs.

Repository-owned images/configuration provide Linux, the configured coding-agent
executables, SSH support, Git, required build/browser tools, and private Docker. Existing
repository hooks prepare the checkout and start application dependencies. Providers may
need different image packaging, but the application/test commands remain the same.
Remote paths continue to obey the configured workspace root and source-repo exclusion.

Continuation and retry reuse must not depend on process memory. The persistent mount
must contain the checkout and explicitly retained development data, including Docker
data where needed. Named volumes intended to survive compute stops must reside on that
persistent storage; ephemeral containers and process state are recreated by repository
commands. Stopping is not a backup strategy or a guarantee against disk corruption.

Configuration reload applies future settings without reassigning an existing environment
to a different provider, deployment identity, resource scope, or template. Existing runs
and cleanup retain their captured environment context. Reject identity-changing reloads
while owned resources remain; an intentional migration requires draining and explicitly
handling retained resources first. Changing templates is not permission to recreate a
workspace or detach its storage silently.

## Lifecycle and capacity

The normal lifecycle is:

`absent -> preparing -> running -> stopping -> stopped -> preparing`

Terminal cleanup adds:

`stopped -> deletion pending -> absent`

A failed/unknown operation is an observed condition requiring reconciliation, not proof
of transition to `stopped` or `absent`.

### Dispatch and execution

1. Reconcile tracker and provider state before dispatch.
2. Apply existing eligibility, claim, and concurrency rules; reserve an execution slot
   before provisioning or starting compute.
3. Ensure the stable environment exists, then start it and wait for readiness.
4. Revalidate eligibility before launching the agent, because provisioning may take time.
5. Establish the connection, prepare the remote workspace through existing hooks, and
   start the configured backend. Infrastructure administration credentials stay outside
   the worker. Backend-required credentials retain their existing security contract.
6. Keep the same environment throughout continuation turns. Record enough context for
   cancellation and later reconciliation even if agent startup fails.

Readiness means more than a provider resource existing: the authenticated execution
route works, the persistent workspace is mounted and writable, the configured agent
executable is available, and the private Docker daemon is usable. Infrastructure
preflight does not replace repository setup hooks.

Preparing, running, stopping, and possibly-running unknown environments consume slots.
A sixth ticket waits when five slots are occupied. Confirmed stopped environments do
not consume execution slots, although their storage still incurs cost. Provisioning
failures release a slot only after inspection establishes no execution compute remains.
This deliberately favors safety over throughput during provider outages.

### Retry, review, and terminal state

- Continuations within an active run do not stop compute between turns.
- At the end of a worker run, stop execution compute before releasing its slot. A later
  eligible retry starts the same environment and uses existing retry/backoff policy.
- A configured non-active/nonterminal state, including human review, stops execution
  without deleting the workspace. No universal tracker state name is introduced.
- A terminal state stops execution and schedules deletion. Zero retention preserves
  immediate cleanup intent; positive retention keeps stopped storage until expiry.
- Before delayed deletion, re-fetch the issue and ensure it remains terminal. Reopening
  cancels pending retention-based deletion if destruction has not started. Once storage
  destruction has begun, a reopened ticket must wait for completion and obtain a fresh
  environment; the old workspace cannot be promised recoverable.
- Tracker failures or missing issue data are not affirmative terminal-state evidence.
  Do not delete retained storage merely because an issue was absent from a candidate
  list or temporarily unreadable. Surface unresolved resources for operator action.

### Review applications

Review-app deployment and teardown remain repository workflow responsibilities. They
may use infrastructure separate from the coding environment and remain available while
that environment is stopped. Symphony does not infer review-app lifecycle from worker
lifecycle. Services running only inside the worker, including forwarded development
ports, stop with it; they are not durable review-app hosting.

## Failure handling and recovery

### Lost connection or ambiguous provider result

Never assume SSH disconnect, tunnel exit, or API timeout killed the remote process.
Inspect the known resource and reconcile outstanding operations. Stop its execution
compute and establish that any earlier create/start operation can no longer make it
runnable before permitting another attempt. If termination cannot be established, keep
the ticket and its possible execution capacity reserved and report the unresolved state.

Cancellation must terminate the backend and its child workloads, not merely the local
transport. Confirmed environment stop is the provider-independent hard boundary for
quiescence. A failed stop cannot become a successful cancellation in scheduler state.

A retry may repeat external side effects from an earlier attempt; this design prevents
concurrent duplicate execution but does not provide transactionality for pushes, ticket
writes, or application changes performed by the agent.

### Orchestrator restart

Discover all deployment-owned environments and reconcile them with tracker state before
new dispatch. Do not assume live backend sessions can be reattached. Establish that
leftover execution has stopped, account for unknown resources, then redispatch eligible
tickets using preserved workspaces. Reconstruct pending deletion from provider metadata;
in-memory retry timers and exact session state are not restored.

If ownership discovery or authoritative state inspection is unavailable, skip new
managed dispatch rather than assuming capacity is empty. Keep reconciliation and
operator-visible errors active. No additional scheduler database is required: durable
resource identity and cleanup intent live with the provider, and eligibility remains
tracker-driven.

### Deletion and partial creation

Destroy must tolerate already-absent components and incomplete previous attempts.
Failed deletion remains discoverable until all owned compute and persistent storage
are confirmed removed. Partial creates must carry ownership from their first durable
resource, including standalone volumes, so restart discovery can recover them.

Only resources positively owned by the configured deployment and ticket may be mutated
or deleted. Unmatched or conflicting ownership is an error requiring operator action,
not a reason to adopt or remove the resource. Provider resources that remain billable
must remain visible even if their ticket is no longer dispatchable.

## Isolation and credentials

- Each ticket has its own Docker daemon, workspace, and persistent application data.
- Never mount the Kubernetes node's container-runtime socket into the environment.
- Ordinary namespaces alone are not sufficient isolation for this workload. Do not
  silently enable an unrestricted privileged pod to make nested Docker work.
- Kubernetes runtime security must contain the private daemon within the ticket's
  sandbox boundary and prevent access to node resources or other ticket environments.
- Workers cannot access provider administration credentials, broad cluster service
  account tokens, cloud metadata credentials, or neighboring ticket networks by default.
  Configure network policy and metadata access controls for the actual platform.
- Repository and model credentials are scoped to required work. This is not a guarantee
  that an autonomous agent cannot read credentials intentionally supplied to it.
- Preserve the existing backend-specific tracker-tool credential contract. Appendix A
  documents that Claude's private MCP config can contain tracker credentials; do not
  claim all tracker secrets remain physically on the orchestrator.
- Provider templates constrain resources and allowed images. Agent-controlled workflow
  content cannot grant the agent new provider permissions or override isolation policy.

## Provider profiles and qualification

### Customer-managed Kubernetes

Use a per-ticket sandbox workload and persistent storage. Upstream Kubernetes SIGs
Agent Sandbox is the preferred lifecycle-controller candidate, not a requirement for a
Google-managed Kubernetes service. Its lifecycle API does not establish isolation or
nested-Docker compatibility by itself.

The deployment must provide a supported runtime that safely hosts the complete Linux
and private-Docker contract. Kata or another VM-backed runtime is a candidate; this
document does not claim the customer's existing cluster supports it. Dedicated sandbox
nodes may be required. Installing runtime classes, controllers, storage classes, and
cluster-wide policy is an operator prerequisite, not an agent task.

Qualification must establish runtime availability on the actual managed cluster,
Compose/Testcontainers/browser compatibility, persistent-volume behavior, stop semantics,
private SSH connectivity, quotas, and isolation. Controller “pause” or replica changes
must not be treated as stopped compute until their actual semantics are verified.
A runtime that only accepts OCI images but cannot safely run the private daemon fails
qualification. If no suitable runtime is available, the Kubernetes profile is blocked
by infrastructure capability; it does not fall back to ordinary privileged pods.

### Google-managed environments

Validate Cloud Workstations using a workstation per ticket, an operator-managed
configuration, and persistent development storage. A workstation cluster is a Cloud
Workstations resource, not a requirement to operate a GKE cluster.

Use service-account IAM for lifecycle and connection operations with the minimum
required permissions. Keep that identity separate from credentials available inside
the workstation. Use its supported authenticated connection/tunnel mechanism for SSH.

Qualification must establish unattended provisioning and connection, non-interactive
backend protocol fidelity, private Docker workloads, browser execution, disk persistence,
confirmed compute stop, and full deletion. Set idle and running timeouts to accommodate
Symphony-controlled execution; product defaults must not silently terminate valid runs.
The baseline relies on persistent disk across stop/start, not preview memory suspension.

Account for per-deployment workstation control-plane charges, running compute/management
charges, retained disk cost, and quotas. Do not assume costs or capacity are shared
between independent deployments. If Cloud Workstations fails qualification, changing to
another Google-hosted product requires review; a local or self-managed VM fallback is
not silently substituted for the approved managed profile.

### Other approaches considered

- Commercial sandboxes such as Daytona and E2B remain alternatives, not additional
  implementations in this scope. Their runtime, persistence, session limits, and
  isolation class would need the same qualification.
- Coder with per-ticket VMs can supply compatible workspaces but adds an operated
  control plane; plain VMs also remain a legitimate architectural alternative.
- GitHub Actions is CI execution, not the retained interactive worker lifecycle selected
  here. Codespaces was considered but is not the chosen Google-managed profile.
- Separate Kubernetes dependency pods were rejected as the default compatibility model
  because they require additional repository-specific provisioning and potentially test
  changes. Repositories may use external services by choice, not provider coercion.

## Acceptance and verification

Provider support requires the following real-infrastructure scenarios on each profile.
Documentation research and mocked API tests are not substitutes.

1. **Complete execution:** provision an environment, connect without a terminal, run the
   existing Claude and Codex backend protocols, execute a Compose workload, a test that
   creates dependencies through Testcontainers, and a browser smoke check. Observe
   remote execution, usable agent events/output, exit status, and cancellation.
2. **Capacity and separation:** run five independent tickets while a sixth remains
   queued. Verify independent workspaces, Docker daemons, and database data; attempted
   access to another ticket's protected resources must be denied.
3. **Review and resume:** change a ticket to a configured review state, confirm compute
   stops and its slot is reusable, then reactivate it. Verify saved checkout changes
   and designated Docker volume data survive and services restart successfully. A
   separately deployed review app remains independent of the stop operation.
4. **Ambiguous creation and start:** interrupt requests after provider acceptance; retries
   and restart discovery must resolve to one environment and one active execution.
5. **Connection loss and restart:** break transport and restart Symphony while remote
   work exists. Verify old execution is quiescent before replacement, unknown capacity
   is not reused, and the saved workspace is retained.
6. **Terminal cleanup:** exercise zero and positive retention, reopening before expiry,
   failed deletion, partial resource creation, and orchestrator restart during cleanup.
   Confirm eventual removal of all owned compute/storage once operations succeed, with
   no deletion of unrelated resources or storage on inconclusive tracker responses.
7. **Cancellation and isolation:** verify backend descendants and Docker workloads stop;
   verify worker inability to reach provider administration credentials or node sockets.
8. **Configuration lifecycle:** reject conflicting modes and unsafe identity changes;
   retain the correct environment context through reload, retries, and cleanup. Verify
   that existing local and static-SSH behavior remains unchanged.

Keep deterministic regression tests for plausible concurrency and lifecycle failures:
ambiguous outcomes, incomplete shutdown, unknown capacity, ownership mismatches,
reopening/deletion races, and restart discovery. Test observable scheduler and provider
contracts rather than field forwarding or exact log wording. Run existing contract tests
broken by the new boundary; run the repository quality gate for implementation changes.
Real-provider qualification uses disposable, explicitly authorized infrastructure and
records resource scope, configuration, observed outcomes, and cleanup evidence without
secrets. No production mutation is authorized by approval of this design document.

## Implementation scope and documentation

The implementation plan must cover the shared execution boundary and both provider
profiles, including their qualification prerequisites. It may sequence the work but may
not call a scaffold or a single-provider subset the completed feature.

Primary integration surfaces are `Config`/its schema, the orchestrator's dispatch and
reconciliation paths, `AgentRunner`, `Workspace`, `SSH`, and backend session startup.
Trace and migrate all affected execution-context callsites. Provider-specific branching
belongs in adapters, not in the orchestrator or coding-agent continuation loop. Preserve
existing backend selection, path safety, retry policy, and logging conventions.

Extend existing operator-visible logs/status with environment identity, provider state,
and unresolved stop/deletion errors where needed to explain actual lifecycle outcomes.
Issue events retain `issue_id` and `issue_identifier`; session events retain `session_id`.
Do not add credentials or sensitive connection material to status output.

Update `SPEC.md`, root `README.md`, `elixir/README.md`, and `elixir/WORKFLOW.md` with the
implemented behavior/configuration and deployment prerequisites in the implementation
change. This design-only commit does not alter those current operational contracts.
Before implementation planning, the user reviews this written specification. Live
provider qualification additionally requires authorized Kubernetes/cloud access and
permission to create disposable billable resources; those are not implied by design
approval or by the existence of credentials on a machine.

## Primary references

Repository evidence:

- [Service specification](../../../SPEC.md), especially Sections 2, 7, 14 and Appendix A.
- [Agent behaviour](../../../elixir/lib/symphony_elixir/agent.ex).
- [Agent runner](../../../elixir/lib/symphony_elixir/agent_runner.ex).
- [Workspace manager](../../../elixir/lib/symphony_elixir/workspace.ex).
- [SSH transport](../../../elixir/lib/symphony_elixir/ssh.ex).
- [Configuration schema](../../../elixir/lib/symphony_elixir/config/schema.ex).

Provider documentation consulted during design; these are capability references, not
results of exercising either provider:

- [Upstream Kubernetes Agent Sandbox](https://github.com/kubernetes-sigs/agent-sandbox).
- [GKE Agent Sandbox overview](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/machine-learning/agent-sandbox).
- [GKE Sandbox restrictions](https://cloud.google.com/kubernetes-engine/docs/concepts/sandbox-pods).
- [Cloud Workstations overview](https://cloud.google.com/workstations/docs/overview).
- [Cloud Workstations custom images and Docker](https://cloud.google.com/workstations/docs/customize-container-images).
- [Cloud Workstations agent-optimized development](https://cloud.google.com/workstations/docs/agent-optimized-development).
- [Cloud Workstations IAM](https://cloud.google.com/workstations/docs/access-control).
- [Cloud Workstations SSH](https://cloud.google.com/sdk/gcloud/reference/workstations/ssh).
- [Cloud Workstations configuration API](https://cloud.google.com/workstations/docs/reference/rest/v1/projects.locations.workstationClusters.workstationConfigs).
- [Cloud Workstations pricing](https://cloud.google.com/workstations/pricing).
