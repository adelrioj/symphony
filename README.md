# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for setup and operation. One `symphony serve`
process runs many named lanes from a SQLite database, with one installation serving one client.
Each lane has its own tracker scope, workspace root, scheduler, agent settings, hooks, and prompt.
Import a `WORKFLOW.md` once, then edit the lane live in the UI or through
`PUT /api/v1/lanes/:slug`. Workflow saves create immutable versions; active attempts retain their
dispatch-time configuration. The tracker remains the scheduling source of truth, while the database
stores lane configuration and durable run history.

From `elixir/`, after installing dependencies:

```bash
export SYMPHONY_OPERATOR_TOKEN='replace-with-a-long-random-secret'
mix symphony lanes import ./WORKFLOW.md --slug main --data-root /data
mix symphony serve --data-root /data --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Use a writable persistent `/data` directory (or substitute the same directory in both commands).
New imports are disabled: sign in at <http://localhost:4000/login>, review the lane, then enable it.
Import is an offline operation, not a live file watcher; use the authenticated UI/API for live edits.
The daemon uses Mix or a Burrito release; `bin/symphony` is the escript for agent-side MCP only.
Self-hosted deployments live in their own repos, seeded from
[`deploy/client-template/`](deploy/client-template); see
[Run in Docker](elixir/README.md#run-in-docker-orbstack-compatible).
You can also ask your favorite coding agent to help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

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

See [managed operation and configuration](elixir/README.md#managed-ticket-environments) and
[SPEC Appendix B](SPEC.md#appendix-b-managed-ticket-environments-optional) before enabling it.
Neither provider has been live/production-qualified by this change. The pinned upstream Agent Sandbox
v1.0.1 baseline lacks authoritative child-create cleanup ordering acknowledgment. A candidate controller
extension and Symphony consumer implement the `symphony-create-drain-v1` journal and durable cleanup
receipts; unknown creates remain retained rather than being replayed or treated as absent.
Production Kubernetes allocation remains unconditionally blocked. This implementation does not approve
a replacement controller image/schema baseline, qualify infrastructure, or authorize deployment.
Examples reference operator-created infrastructure; the existing VM remains independent of this gate.

The test-artifact-only Kubernetes candidate runner accepts `mode: "hold"` for exactly one
non-model worker. It holds a successful managed-SSH probe until timeout, then uses normal
conservative cleanup; an operator can instead interrupt that consumer and recover with
`mode: "cleanup"` in a fresh process. Cleanup receipts include bounded scheduler-barrier observations.
The scratch LV driver under `elixir/test/support/` requires an operator-owned private identity pin,
opens only the pinned block device read-only, and releases it on timeout or SIGTERM.
It is restricted to scratch namespaces, an 8 GiB ceiling, a 1,200-second ceiling, and explicit retained-volume
exclusions. Use independent process supervision and verify physical LV absence after restoration.
These scratch checks do not qualify node-disconnection, host-loss recovery, or production allocation.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
