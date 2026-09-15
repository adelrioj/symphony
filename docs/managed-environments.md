# Managed environments and limitations

## Managed ticket environments

Local workspaces and static SSH workers remain supported. The optional managed mode gives each
ticket a complete Linux development environment with a private Docker daemon, keeping existing
Docker Compose and Testcontainers setup/test commands unchanged. Environments belong to one stable,
independent deployment and opaque tracker issue ID, not a display identifier or a shared company pool.
Use the existing `agent.max_concurrent_agents: 5` for five simultaneous executions; retained stopped
environments do not consume those execution slots, but their storage can still incur charges.

Cloud Workstations is the preferred Google-managed worker profile to qualify, even when Symphony
or review apps run on GKE. The alternative Kubernetes Agent Sandbox profile requires qualified Kata
VM isolation, persistent guest-compatible Docker storage, admission, networking, and CSI evidence;
managed gVisor and GKE Autopilot are not interchangeable with this profile.

Claude's guest-side MCP snapshot carries the pinned tracker configuration, not controller-only
provider files. Guests do not need the controller's kubeconfig; non-interactive approval remains
deny-only, including for the memory tracker.

Managed selection never falls back to local execution or another provider. Startup inventories owned
resources before dispatch, and unresolved remote stop or deletion remains visible rather than being
treated as successful cleanup. Terminal retention defaults to zero, but deletion still requires a
fresh terminal observation, qualified stop, cleanup hooks, and compute-plus-storage absence proof.
Identity-changing lane saves and version activations are rejected while resources or unresolved operations remain.

The dashboard, terminal status, and `/api/v1/state` expose pending or blocked managed discovery even
before an environment record exists. Its redacted `environment_discovery` status distinguishes a
frozen dispatch queue from an idle deployment without exposing provider credentials or raw errors.

See [managed operation and configuration](../elixir/README.md#managed-ticket-environments) and
[SPEC Appendix B](../SPEC.md#appendix-b-managed-ticket-environments-optional) before enabling it.
Neither provider has been live/production-qualified by this change. The pinned upstream Agent Sandbox
v1.0.1 baseline lacks authoritative child-create cleanup ordering acknowledgment. A candidate controller
extension and Symphony consumer implement the `symphony-create-drain-v1` journal and durable cleanup
receipts; unknown creates remain retained rather than being replayed or treated as absent.
Production Kubernetes allocation remains unconditionally blocked. This implementation does not approve
a replacement controller image/schema baseline, qualify infrastructure, or authorize deployment.
Examples reference operator-created infrastructure; the existing VM remains independent of this gate.
