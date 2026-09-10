# Remote Ticket Execution Environments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run complete, isolated per-ticket Linux development environments on customer-managed Kubernetes and Google Cloud Workstations without moving repository-specific behavior into Symphony.

**Architecture:** Keep the existing orchestrator authoritative and add an execution-environment behaviour for provider lifecycle operations. Carry an immutable execution context through workspace preparation and both coding-agent backends; retain managed execution capacity until remote shutdown is proved. Provider metadata supplies restart discovery and cleanup intent without a new scheduler database.

**Tech Stack:** Elixir 1.19.x / OTP 28, Ecto changesets, existing Req/Jason, OTP Task.Supervisor and ports, SSH, Kubernetes Agent Sandbox, Google Cloud Workstations REST API and Google Cloud CLI.

**Spec:** `docs/superpowers/specs/2026-09-11-remote-ticket-environments-design.md` (approved design, including the GKE clarification in commit `486fdd5`). Read the complete specification before this plan.

## Global Constraints

- “The selected compatibility model is **a complete Linux development environment with a private Docker daemon per ticket**.”
- “Existing Docker Compose and Testcontainers workflows must work without provider-specific rewrites.”
- “Start with five concurrent ticket executions per independent Symphony deployment.” Use the existing configurable concurrency limit, not a new hard-coded limit.
- “Five active executions are independent of the number of retained, stopped environments.”
- “Cloud Workstations remains the preferred Google-managed worker provider to qualify, even if the deployment moves Symphony, application services, or review apps to GKE.”
- “Static SSH and local execution remain supported modes; they are not renamed or removed.”
- “Once managed execution is selected, a missing or invalid context is an error, never an instruction to execute locally.”
- “Closing a transport is not proof that remote execution stopped.”
- “A failed stop cannot become a successful cancellation in scheduler state.”
- “No production mutation is authorized by approval of this design document.” Live qualification needs separately authorized disposable resource scopes.
- Preserve `Agent.start_session/2`, `run_turn/4`, and `stop_session/1` semantics and backend-by-state routing. Do not call provider adapters directly from an agent backend.
- Every public `def` in `lib/` needs an adjacent `@spec`; `@impl` callbacks are exempt. Do not expand coverage exclusions.
- Preserve workspace-root/source-repo safety and hook failure policy. Include `issue_id` and `issue_identifier` in issue logs and `session_id` in agent lifecycle logs; never log credentials or connection material.
- Run `mix` commands from `elixir/` using `mise exec --`. Run the final `mise exec -- make all` quality gate after integration, not in concurrent task branches.
- No company-specific code, cross-company resource pool, new scheduler, automatic local/provider fallback, or agent-accessible cluster/cloud administration credentials.

---

## Execution boundaries and dependency order

This is one feature with a shared execution/reconciliation boundary, not two independent products. Use one plan. The Workstations and Kubernetes adapters can be implemented concurrently after their shared contracts exist; one integration owner owns `orchestrator.ex`, `WorkflowStore`, and the final configuration cutover.

Order: Tasks 1–3 establish executable, tested library/transport behavior; Tasks 4 and 5 implement the two real adapters; Tasks 6–7 wire the complete lifecycle and operator contract; Tasks 8–9 qualify and verify the complete feature. Do not enable managed dispatch between partially integrated tasks. The public `worker.environment` configuration is connected only in Task 6, after both adapters and shutdown/recovery machinery exist. No placeholder provider or production fake is registered.

Each task includes a targeted regression cycle and a commit. Concurrent adapter implementers skip validation until their work is integrated; the integration owner then runs both task-specific checks. Review each deliverable before dependent work starts. Use an isolated worktree when execution begins, following the worktree skill; this planning document does not create one.

### File ownership map

New production files:

| File | Responsibility |
| --- | --- |
| `elixir/lib/symphony_elixir/execution_environment.ex` | Behaviour, adapter resolution, stable resource key, redacted record type |
| `elixir/lib/symphony_elixir/execution_environment/config.ex` | Managed settings changeset, provider settings validation and immutable-identity fingerprint |
| `elixir/lib/symphony_elixir/execution_context.ex` | Explicit local/static-SSH/managed context and captured workspace location |
| `elixir/lib/symphony_elixir/execution_environment/lifecycle.ex` | Pure lifecycle transitions, operation-generation matching, occupied capacity, deletion eligibility |
| `elixir/lib/symphony_elixir/execution_environment/operations.ex` | Bounded asynchronous lifecycle jobs, readiness and supervised connection ownership |
| `elixir/lib/symphony_elixir/execution_environment/command.ex` | Bounded argv-only CLI execution for authentication/provider tools; timeout is an unknown result |
| `elixir/lib/symphony_elixir/execution_environment/workstations.ex` | Workstations resource/operation state, ownership metadata, persistence and connection |
| `elixir/lib/symphony_elixir/execution_environment/workstations/client.ex` | Req REST requests, authentication, pagination, etags and response classification |
| `elixir/lib/symphony_elixir/execution_environment/kubernetes.ex` | Sandbox/PVC/Pod ownership, gated start, confirmed stop and template validation |
| `elixir/lib/symphony_elixir/execution_environment/kubernetes/client.ex` | Kubernetes API operations through bounded `kubectl`, resource versions, watches and JSON |

Existing files to modify:

- `elixir/lib/symphony_elixir/config/schema.ex`: attach the managed object to `Worker` only at cutover; reject mode conflicts before nil-valued keys are discarded.
- `elixir/lib/symphony_elixir/config.ex`: local-only schema validation and access through `Config`; no network preflight during workflow publication.
- `elixir/lib/symphony_elixir/workflow_store.ex`: guard publication of identity-changing configuration without calling back into the orchestrator.
- `elixir/lib/symphony_elixir/ssh.ex`: structured connection targets and per-connection options, preserving binary/line protocol behavior.
- `elixir/lib/symphony_elixir/workspace.ex`: context-aware remote paths/hooks, canonical remote boundary check, public before-remove hook without implicit deletion.
- `elixir/lib/symphony_elixir/agent_runner.ex`: remove host re-selection once a context exists; propagate attempt identity on worker messages.
- `elixir/lib/symphony_elixir/agent/codex.ex`, `codex/app_server.ex`, `agent/claude.ex`: consume context rather than infer local execution from a nullable host.
- `elixir/lib/symphony_elixir/orchestrator.ex`: reservation, preparation, launch, shutdown, recovery, retention, capacity and snapshots.
- `elixir/lib/symphony_elixir/agent_runtime_supervisor.ex`: keep lifecycle/connection jobs under its existing `:one_for_all` ownership boundary.
- `elixir/lib/symphony_elixir_web/presenter.ex`: safe managed-resource status in existing JSON surfaces; do not expose full contexts.
- `elixir/test/support/test_support.exs`, `elixir/test/test_helper.exs`: managed configuration fixtures and explicit test-support loading.
- `SPEC.md`, `README.md`, `elixir/README.md`, `elixir/WORKFLOW.md`: actual behavior, settings, deployment prerequisites and qualification limits.

New test files are listed with their owning tasks. Existing execution tests that require migration are `agent_runner_test.exs`, `app_server_test.exs`, `workspace_and_config_test.exs`, `core_test.exs`, `extensions_test.exs`, `ssh_test.exs`, `agent/codex_test.exs`, `agent/claude_test.exs`, `agent/claude_ssh_test.exs`, `config_test.exs`, `orchestrator_test.exs`, and `orchestrator_status_test.exs`, all under `elixir/test/symphony_elixir/`.

### Grounded integration hazards

The source read for this plan has these specific hazards; re-ground line numbers before edits:

- `AgentRunner.run/3` at lines 21–35 resolves a missing host from settings, and `Agent.Codex.start_session/2` currently forwards only `:worker_host`. Neither may discard a managed context.
- `Workspace.workspace_key/1` at lines 265–278 uses the display identifier. Managed environments need their persisted opaque-issue-derived path even if that identifier changes. Preserve legacy naming for local/static SSH.
- `Workspace` remote validation at lines 465 onward is weaker than local canonicalization. Managed paths must be checked on the worker, including symlink escapes; checking the orchestrator filesystem is incorrect.
- `Orchestrator.handle_info(:DOWN, ...)` at lines 129–148 removes the running entry before retry handling. Managed completion must instead enter confirmed-shutdown reconciliation.
- `terminate_running_issue/3` at lines 685–710 removes claims immediately; `restart_stalled_issue/5`, `stop_and_block_issue/4`, missing-issue reconciliation, retry refresh and startup cleanup reach related release paths. Migrate all of them.
- `available_slots/1` at lines 1585–1590 counts only `running`. Include managed preparing/stopping/unknown capacity without double counting active managed runs.
- `workspace_head/1` assumes `worker_host == nil` means local Git is safe. Use context mode so managed runs never invoke Git on the orchestrator checkout.
- `WorkflowStore.settings/0` reloads on reads; checking immutable identity only inside the orchestrator is too late. A synchronous callback from `WorkflowStore` to the orchestrator also deadlocks when the latter is waiting for configuration.
- `AgentRuntimeSupervisor` already uses `:one_for_all`; preserve it. Killing local tasks does not establish remote quiescence.

Elixir LSP was unavailable during planning. At execution time check availability again; use LSP references before exported-symbol changes if an Elixir server is available, otherwise use scoped reference searches and migrate every caller.

## Task 1: Define managed identity, configuration and provider contracts

**Files:** Create `execution_environment.ex`, `execution_environment/config.ex`, and `execution_context.ex` at the paths above. Create `elixir/test/symphony_elixir/execution_environment_test.exs`. Do not yet attach managed settings to `Config.Schema.Worker`.

**Interfaces:** Produce the types and functions below. Later tasks must use these names and result conventions consistently. Nested types live in their owning file, not one file per trivial struct.

```elixir
# In SymphonyElixir.ExecutionEnvironment:
@type phase :: :preparing | :running | :stopping | :stopped | :deleting | :unknown
@type failure :: {:invalid, atom()} | {:denied, atom()} | {:retryable, term()} | {:unknown, term()}
@type result :: {:ok, Record.t()} | {:error, failure(), Record.t()}
@callback validate_config(map()) :: :ok | {:error, term()}
@callback preflight(map(), keyword()) :: :ok | {:error, failure()}
@callback discover(map(), keyword()) :: {:ok, [Record.t()]} | {:error, failure()}
@callback ensure(map(), Record.t(), keyword()) :: result()
@callback inspect(map(), Record.t(), keyword()) :: result()
@callback put_intent(map(), Record.t(), map(), keyword()) :: result()
@callback start(map(), Record.t(), keyword()) :: result()
@callback connect(map(), Record.t(), keyword()) :: {:ok, Connection.t()} | {:error, failure()}
@callback stop(map(), Record.t(), keyword()) :: result()
@callback destroy(map(), Record.t(), keyword()) :: result()
@spec resource_key(String.t(), String.t(), String.t()) :: String.t()
@spec adapter(String.t()) :: {:ok, module()} | {:error, term()}
```

Define `Record.t()` with required `key`, `deployment_id`, `tracker_kind`, `issue_id`,
`kind`, `scope`, `workspace_path`, and `template_identity`; optional `provider_ref`,
`version`, `attempt_id`, `issue_identifier`, `issue_state`, and `terminal_observed_at`; defaults `phase: :unknown`,
`desired: :stopped`, `pending: []`, `proof: :unknown`, `absent?: false`, and `metadata: %{}`.
`pending` holds operation kind, correlation ID when known, and an explicit unknown-outcome
marker. A successful destroy returns the record with `absent?: true` only after owned
compute and disk absence are established. A 404 alone cannot clear a pending create.
Provider adapters, not agent-writable metadata, establish `proof`.

Define `Connection.t()` with required `target` (`SSH.Target.t()` from Task 2), `owner`
(connection-holder PID), and `id` (local reference). This is runtime-only, never serialized
into provider metadata. Define `ExecutionContext.t()` with `mode` (`:local`, `:ssh`,
`:managed`), `workspace_root`, `workspace_path`, `target`, `connection` (runtime-only),
`worker_host` (safe display label), and `environment`
(`nil` or `%{config: map(), record: Record.t()}`). Implement
`ExecutionContext.local(root)`, `ssh(root, target)`, `managed(config, record, connection)`,
and `remote?/1`; managed construction requires a ready connection and a record with
matching identity. Derive redacted Inspect implementations rather than printing
credentials/config/targets in exception messages.

- [ ] **Write the failing identity and configuration regressions.** `Environment.Config.parse/1` returns `{:ok, config}` or `{:error, {:invalid_environment_config, errors}}`; it is a complete private-library parser before public configuration cutover.

```elixir
test "opaque issue keys cannot collide through separator or display-name changes" do
  alias SymphonyElixir.ExecutionEnvironment, as: Environment
  left = Environment.resource_key("deployment:a", "linear", "b")
  right = Environment.resource_key("deployment", "a:linear", "b")
  refute left == right
  assert left == Environment.resource_key("deployment:a", "linear", "b")
  assert String.match?(left, ~r/^se-[0-9a-f]{56}$/)
end

test "managed startup cannot have a zero deadline" do
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  assert {:error, {:invalid_environment_config, _}} =
           EnvironmentConfig.parse(%{
             "kind" => "google_workstations",
             "deployment_id" => "isolated-deployment",
             "provider" => %{},
             "startup_timeout_ms" => 0,
             "shutdown_timeout_ms" => 120_000
           })
end
```

- [ ] **Run the targeted test and confirm the missing contract causes failure.** From `elixir/`: `mise exec -- mix test test/symphony_elixir/execution_environment_test.exs`. Do not accept an unrelated dependency/toolchain failure as the intended red result.
- [ ] **Implement collision-safe identity and the complete configuration parser.** Use Ecto, required positive deadlines, required nonblank deployment identity, required map provider, allowed kind strings, and nonnegative retention default zero. Reject explicit null/empty managed objects at public cutover rather than allowing `drop_nil_values/1` to select local mode. Keep provider-map keys strings; never create atoms from workflow input.

```elixir
@spec resource_key(String.t(), String.t(), String.t()) :: String.t()
def resource_key(deployment_id, tracker_kind, issue_id) do
  encoded = :erlang.term_to_binary({deployment_id, tracker_kind, issue_id})
  digest = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  "se-" <> binary_part(digest, 0, 56)
end
```

The resource key fits Kubernetes DNS-label syntax and Workstations label syntax;
qualify Workstations resource-name acceptance before enabling that provider. Persist
the original identity fields too and reject an ownership mismatch even when names match.
Implement `Environment.Config.runtime(settings) :: map() | nil`: flatten the managed
settings into an atom-key map and add `workspace_root` and `tracker_kind` from the
full settings. Its `provider` remains a string-key map. All provider callbacks consume
this captured runtime map except `validate_config/1`, which validates the provider
submap only. Implement `Environment.Config.identity(settings) :: binary() | nil` from
the full settings, using kind, deployment ID, provider scope, template/configuration
reference, authentication identity reference, and workspace root. Sort map entries
recursively before hashing; exclude mutable poll/concurrency/retention settings and
secret values. Existing environments retain their persisted path/template identity.

- [ ] **Implement adapter resolution and redacted types.** The only production adapters are `Workstations` and `Kubernetes`. Resolution can name those modules before their files exist, but no configuration path may execute them until Tasks 4–6 are complete. Do not create stub adapters.
- [ ] **Run the contract tests, then commit these working library units.** Add cases for unknown kind, empty deployment ID, negative retention, and ambiguous tuple identities only where they protect distinct boundaries. Commit message: `feat: define managed execution environment contracts`.

## Task 2: Carry explicit execution contexts through SSH, workspaces and agents

**Files:** Modify `ssh.ex`, `workspace.ex`, `agent_runner.ex`, `agent/codex.ex`, `codex/app_server.ex`, `agent/claude.ex`, and their existing tests listed in the file map. Complete `execution_context.ex`.

**Interfaces:** `SSH.Target.t()` contains `executable`, argv `prefix`, per-process `env`,
and a non-secret `label`. `SSH.run/3` and `start_port/3` accept this structured target in
addition to supported static host strings. Their return and binary/line behavior do not
change. A structured target appends one `SSH.remote_shell_command(command)` argument to
its prefix; it never interpolates an executable/argv list into a local shell string.

```elixir
defmodule SymphonyElixir.SSH.Target do
  @enforce_keys [:executable, :prefix, :label]
  @derive {Inspect, only: [:label]}
  defstruct [:executable, :prefix, :label, env: []]
  @type t :: %__MODULE__{
          executable: String.t(), prefix: [String.t()],
          label: String.t(), env: [{String.t(), String.t() | nil}]
        }
end
```

`AgentRunner.run/3` and backend startup use `opts[:execution_context]`. Workspace
execution functions consume `ExecutionContext.t()` instead of a host-or-nil runtime
argument. Migrate all in-repository callers and tests; do not retain a deprecated
`:worker_host` option shim. `worker.ssh_hosts` configuration and `worker_host` diagnostic
fields remain valid static-mode concepts, not obsolete aliases.

- [ ] **Add a real process regression for structured SSH command quoting.** This invokes a local shell as the transport fixture, so it tests observable execution, not a captured argv string.

```elixir
test "structured targets preserve shell arguments without local interpolation" do
  alias SymphonyElixir.SSH
  target = %SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "fixture"}
  assert {:ok, {"literal ' quote\n", 0}} =
           SSH.run(target, "printf '%s\\n' \"literal ' quote\"")
end
```

- [ ] **Run SSH and backend tests to establish the failing new target case.** Use `mise exec -- mix test test/symphony_elixir/ssh_test.exs test/symphony_elixir/agent/codex_test.exs test/symphony_elixir/agent/claude_ssh_test.exs`.
- [ ] **Implement per-target invocation without process-global SSH mutation.** Static strings continue through the existing parser, including IPv6 and `SYMPHONY_SSH_CONFIG`. Structured targets use their own arguments/environment and must not silently inherit a global connection configuration. Preserve `:line`, binary payloads, stdin, exit status, and backend protocol parsing. Extend existing stream tests to send a real payload through a process and receive its result; remove obsolete argument-order-only assertions rather than re-pinning them.
- [ ] **Migrate context selection once at the dispatch boundary.** When managed settings exist and no managed context is supplied, return `{:error, :managed_context_required}` before workspace creation or hook execution. Local/static dispatch builds context explicitly. Ensure Codex does not discard it in `Keyword.take/2`; update both backends' remote cwd and sandbox-policy decisions to use `ExecutionContext.remote?/1`.

```elixir
# The guard belongs before any workspace or subprocess side effect.
case {Map.get(settings.worker, :environment), Keyword.get(opts, :execution_context)} do
  {%{}, %SymphonyElixir.ExecutionContext{mode: :managed} = context} -> {:ok, context}
  {%{}, _} -> {:error, :managed_context_required}
  {nil, %SymphonyElixir.ExecutionContext{} = context} -> {:ok, context}
  {nil, _} -> {:error, :execution_context_required}
end
```

This field access also works before Task 6 adds the optional schema field. The final
runner accepts one context and the dispatcher builds it for each mode. Direct test/CLI
callers must construct local/static contexts explicitly; migrate them in this task,
including the orchestrator's local/static spawning callsite, rather than breaking
legacy execution until Task 6.

- [ ] **Capture and enforce remote workspace identity.** Managed context supplies the persisted `workspace_path`, initially `Path.join(workspace_root, record.key)`. Do not recompute it from a renamed issue identifier. On the worker use `realpath -m --` for root and candidate and reject root equality, a path outside the canonical root, embedded control characters, and symlink escape before any create/delete/hook. Require GNU `realpath` in worker preflight. Keep local PathSafety behavior and static naming unchanged.

```bash
set -eu
root_real=$(realpath -m -- "$workspace_root")
workspace_real=$(realpath -m -- "$workspace")
case "$workspace_real" in
  "$root_real"/*) test "$workspace_real" != "$root_real" ;;
  *) exit 64 ;;
esac
```

Pass `workspace_root` and `workspace` using the existing shell-escaping/assignment
helpers, not raw interpolation. Preserve the existing workspace-created marker and
`after_create` semantics; a failed first checkout does not authorize deleting its
provider environment or another retained workspace.

- [ ] **Separate the before-remove hook from directory deletion.** Add `Workspace.run_before_remove_hook(workspace, issue, context) :: :ok`, retaining the documented best-effort hook-failure policy. Managed teardown invokes it before stopping/deleting compute; it must not call `Workspace.remove/2` and erase retained data prematurely. Local/static removal continues to run the hook and remove its directory.
- [ ] **Tag runner messages with the execution attempt.** Add the attempt identifier to runtime-info, turn-exhaustion and backend-update messages. Update every sender/receiver/test together; stale messages from an earlier attempt must not update a replacement's workspace, session, totals, or exhaustion state. Keep user-facing status field names unchanged.
- [ ] **Verify the migrated execution contracts.** Run the existing workspace, runner, AppServer and both backend test files. Add one retained managed-path rename regression and one managed-context-missing test with an observable local-hook sentinel that must remain absent. Commit: `refactor: pass explicit contexts through worker execution`.

## Task 3: Implement the lifecycle reducer and bounded operation ownership

**Files:** Create `execution_environment/lifecycle.ex`, `execution_environment/operations.ex`, `execution_environment/command.ex`, `elixir/test/symphony_elixir/environment_lifecycle_test.exs`, and `elixir/test/symphony_elixir/environment_operations_test.exs`. Modify `workflow_store.ex` and add `elixir/test/symphony_elixir/environment_reload_test.exs`.

**Interfaces:** `Lifecycle.Entry` has `record`, `context` (nil before connection),
`attempt_id`, `operation_id`, `purpose` (`:agent` or `:cleanup`), `phase`, `completion`,
and `operation_seq`. Implement:

```elixir
@spec new(Record.t(), String.t(), :agent | :cleanup) :: Entry.t()
@spec step(Entry.t(), term(), integer()) :: {Entry.t(), [term()]}
@spec occupied?(Entry.t()) :: boolean()
@spec deletion_due?(Record.t(), :terminal | :nonterminal | :missing | :error,
                    non_neg_integer(), integer()) :: boolean()
```

`new/3` starts at `:reserved` with sequence zero. Operation IDs are
`{attempt_id, operation_seq}`; increment the sequence for each new provider job.
Events are `:prepare`, `{:prepared, operation_id, record}`, `:launch`,
`{:agent_exited, attempt_id, completion}`, `{:cancel, completion}`,
`{:stopped, operation_id, record}`, `{:failed, operation_id, failure, record}`,
`:destroy`, and `{:destroyed, operation_id, record}`. Effects are
`{:provider, operation, operation_id}`, `{:launch_agent, attempt_id}`,
`{:release, completion}`, and `:forget`. The orchestrator interprets completion and
applies its existing retry/block policy; the reducer does not choose a retry delay.
Proof is `:unknown` or `{:quiescent, evidence_map}` generated by a qualified adapter.
Persist terminal-observation timestamps as UTC Unix milliseconds encoded in annotations;
use monotonic time only for process deadlines.

- [ ] **Write the failing shutdown-capacity regression.** Construct a complete record with the required identity fields; this example is the entire test body.

```elixir
test "agent exit cannot release capacity until remote stop is proved" do
  alias SymphonyElixir.ExecutionEnvironment.{Lifecycle, Record}
  record = %Record{
    key: "se-ticket", deployment_id: "deployment", tracker_kind: "memory",
    issue_id: "ticket", kind: "kubernetes", scope: %{},
    workspace_path: "/state/workspaces/se-ticket", template_identity: "template-v1"
  }
  entry = %{Lifecycle.new(record, "attempt-1", :agent) | phase: :running}
  {stopping, [{:provider, :stop, operation_id}]} =
    Lifecycle.step(entry, {:agent_exited, "attempt-1", :retry}, 1_000)
  assert Lifecycle.occupied?(stopping)
  unknown = %{record | phase: :unknown}
  {unresolved, effects} =
    Lifecycle.step(stopping, {:failed, operation_id, {:unknown, :timeout}, unknown}, 2_000)
  assert Lifecycle.occupied?(unresolved)
  refute Enum.any?(effects, &match?({:release, _}, &1))
  proof = %{record | phase: :stopped, pending: [], proof: {:quiescent, %{uid: "pod-1"}}}
  {stopped, [{:release, :retry}]} =
    Lifecycle.step(unresolved, {:stopped, operation_id, proof}, 3_000)
  refute Lifecycle.occupied?(stopped)
end
```

- [ ] **Run it red.** `mise exec -- mix test test/symphony_elixir/environment_lifecycle_test.exs`.
- [ ] **Implement the transition table, not an independent policy engine.**

| State/event | New state and effect |
| --- | --- |
| reserved / prepare | preparing; issue one prepare job |
| preparing / matching prepared result | preparing with updated record; wait for orchestrator eligibility revalidation |
| preparing / launch | running; launch the selected agent once |
| running / matching agent exit | stopping; preserve completion; issue stop |
| reserved/preparing/running / cancel | stopping; invalidate prior operation generation; issue stop/inspect without losing pending mutation evidence |
| stopping/unknown / matching stopped result with quiescent proof and no unresolved pending operation | stopped; release once |
| any / stale operation or attempt result | preserve current state; no launch or release |
| operation failure | preserve record and completion; unknown when side effects cannot be excluded; no release |
| stopped / destroy | deleting; issue destroy only if caller has freshly authorized terminal cleanup |
| deleting / matching destroyed record with absent true and no unresolved resources | absent represented by removal; forget |

`occupied?/1` is true for reserved/preparing/running/stopping/unknown and false for
confirmed stopped/deleting-after-quiescence. An unknown delete after a successful stop
must not be confused with unknown execution: preserve its quiescent proof and count it
as retained cleanup, not runnable capacity. Conversely, an outstanding create/start
always invalidates quiescent proof. Retention returns false for missing/error/nonterminal
tracker observations; its elapsed time is measured from the saved first terminal stamp.

- [ ] **Implement bounded provider jobs under the existing Task.Supervisor.** Produce `Operations.start(supervisor, adapter, config, entry, operation, opts) :: {:ok, Task.t()}` using `Task.Supervisor.async_nolink/2`. `Operations.run(adapter, config, entry, operation, opts)` performs one complete bounded operation and returns a tagged record/context or failure. Carry the operation ID through the result; never mutate orchestrator state from a task.

```elixir
@spec start(pid() | atom(), module(), map(), Lifecycle.Entry.t(), atom(), keyword()) ::
        {:ok, Task.t()}
def start(supervisor, adapter, config, entry, operation, opts) do
  operation_fun = Keyword.get(opts, :operation_fun, &run/5)
  task = Task.Supervisor.async_nolink(supervisor, fn ->
    {entry.operation_id, operation_fun.(adapter, config, entry, operation, opts)}
  end)
  {:ok, task}
end
```

Discovery has no ticket Entry. Add a separate wrapper
`Operations.discover(supervisor, adapter, config, opts) ::
{:ok, Task.t(), {:discovery, reference()}}`. Return the token to the caller so it can
register the `{:discovery, token}` operation ID before handling the queued result.

```elixir
@spec discover(pid() | atom(), module(), map(), keyword()) ::
        {:ok, Task.t(), {:discovery, reference()}}
def discover(supervisor, adapter, config, opts) do
  token = make_ref()
  operation_fun = Keyword.get(opts, :operation_fun, &run/5)
  task = Task.Supervisor.async_nolink(supervisor, fn ->
    {{:discovery, token}, operation_fun.(adapter, config, nil, :discover, opts)}
  end)
  {:ok, task, {:discovery, token}}
end
```

`Operations.run/5` accepts a nil Entry only for discovery; that branch performs
preflight and complete inventory. Other operations require an Entry. Pass the
orchestrator authority PID explicitly in opts before spawning jobs; `self()` inside
a short-lived prepare task is not the connection's lifetime owner.

Prepare means ensure, durable running intent, start, connect, readiness through that
authenticated connection, and capture context. Readiness checks the mounted workspace,
configured agent executable, GNU realpath, and usable private Docker within the startup
deadline. If readiness fails, retain the resource/context for stop reconciliation.
The orchestrator stores the prepared context on the matching Entry before launching
the agent; stop/cleanup jobs use `entry.context.connection` when one exists. Restart
discovery has no old connection and must not require one to stop provider compute.
Stop means persist stopped intent without clearing earlier unknown requests,
resolve/fence prior starts, stop, inspect, then close connection resources.
Every failed mutation returns its latest `Record` in the three-element error tuple.
Discovery and connection failures have no replacement record and use their declared
two-element errors. Do not wrap a timeout as an ordinary startup failure.

Poll provider operations within the task using a bounded deadline and one-second
interval; on timeout return unresolved evidence to normal orchestrator reconciliation.
Inject `request_fun`/`command_fun` and a clock only at the operation/client test boundary,
not through workflow configuration. Connection-holder processes monitor the long-lived
orchestrator authority, not the prepare task, and own their ports/private files until
explicit release or authority termination. Add `Operations.close_connection/1` with
connection-ID-checked release/acknowledgement. Preserve the holder across successful
prepare return and all continuation turns. Local connection cleanup does not guarantee
remote termination; remote executions remain discoverable until quiescence is proved.

- [ ] **Implement the argv-only command helper.** `Command.run(executable, args, opts)` returns `{:ok, %{output: binary, status: integer}}` or `{:error, {:unknown, reason}}`; require `timeout_ms`, accept per-process `env`, and return only bounded diagnostic output on failure. Use `Port.open({:spawn_executable, executable}, ...)`, not a shell command string. Treat timeout/output-limit breach as potentially side-effecting; terminate/reap the known local process and close its port, but never infer remote cancellation. Use protected temporary JSON files for kubectl request bodies and remove them after the command. Long-lived Workstations tunnels use a supervised port holder, not this bounded helper.
- [ ] **Implement configuration-publication guards without a callback deadlock.** Add `WorkflowStore.protect_environment(identity) :: {:ok, reference()} | {:error, term()}` and `release_environment(reference, :empty_inventory) :: :ok | {:error, term()}`. Keep the guard in WorkflowStore state; a replacement orchestrator can acquire the same identity but cannot clear the old guard merely because the old PID died. Initialize managed startup as guarded/undiscovered. Before publishing candidate settings compare the immutable identity with all held guards; reject an identity change and retain the old workflow/settings atomically. Release only after complete authoritative inventory and no lifecycle jobs/resources. No network calls or GenServer call back to the orchestrator occur inside WorkflowStore.

```elixir
# Place this check between loading candidate settings and publishing new_state.
case guarded_identity do
  nil -> {:ok, new_state}
  identity ->
    if SymphonyElixir.ExecutionEnvironment.Config.identity(new_state.settings) == identity,
      do: {:ok, new_state},
      else: {:error, :environment_identity_in_use, old_state}
end
```

Guard token matching prevents an old owner from releasing a newer guard. A WorkflowStore
restart recreates the guard from its loaded managed settings before orchestration can
dispatch; changing resource scope while the whole service is down remains an explicit
operator migration, not an automatically discoverable cross-account move.

- [ ] **Prove the boundary transitions and commit.** Run the lifecycle/operation/reload test files. Cover stale completion, a late start after cancel, unknown discovery, closed local port with remote activity still unknown, retained terminal timestamp, and a changed identity rejected on `settings/0` as well as `force_reload/0`. Include a process test in which a provider job blocks but an orchestrator-style owner can still answer a synchronous message. Commit: `feat: implement managed environment lifecycle safety`.

## Task 4: Implement Google Cloud Workstations lifecycle and private SSH

**Files:** Create `execution_environment/workstations.ex`, `execution_environment/workstations/client.ex`, and `elixir/test/symphony_elixir/workstations_environment_test.exs`. These files are independent of Task 5.

**Interfaces:** Implement every Environment callback. Produce
`Workstations.Client.request(config, method, path, query, body, opts)` returning
`{:ok, %{status: integer, body: term()}} | {:error, failure}`.
The injected `request_fun` takes the final Req keyword options and returns that same
response shape. Produce `Workstations.normalize(record, workstation, operations)` returning
a Record; it never clears an unrecovered unknown-request marker just because the
operation list is empty.

Required provider keys are `project`, `location`, `cluster`, `config`,
`credential_configuration`, `impersonate_service_account`, and `ssh_user`, all nonblank
strings. Use `--configuration` consistently for both token and tunnel commands; never
change the active gcloud configuration. The capture from `Environment.Config.runtime/1`
contains this map under `:provider`.

Use existing Req/Jason for lifecycle/metadata requests. Use bounded gcloud only for
authentication and a supervised gcloud process for the TCP tunnel. GA `gcloud workstations
update` does not expose the metadata/etag operations needed here; do not invent flags.

- [ ] **Add the unknown-start regression before implementing normalization.**

```elixir
test "STOPPED with no listed operations cannot erase an unknown start" do
  alias SymphonyElixir.ExecutionEnvironment.{Record, Workstations}
  record = %Record{
    key: "se-ticket", deployment_id: "deployment", tracker_kind: "memory",
    issue_id: "ticket", kind: "google_workstations", scope: %{},
    workspace_path: "/home/user/workspaces/se-ticket", template_identity: "config-uid",
    pending: [%{verb: :start, id: nil, outcome: :unknown}]
  }
  workstation = %{"uid" => "ws-uid", "etag" => "v2", "state" => "STATE_STOPPED",
                  "reconciling" => false}
  observed = Workstations.normalize(record, workstation, [])
  assert observed.phase == :unknown
  assert observed.proof == :unknown
  assert observed.pending == record.pending
end
```

- [ ] **Run the new file red, then implement the REST client and exact resource operations.** Define `region = projects/{project}/locations/{location}`, `parent = region/workstationClusters/{cluster}/workstationConfigs/{config}`, `name = parent/workstations/{record.key}`; encode identifiers and query parameters using URI/Req facilities.

| Operation | Request |
| --- | --- |
| Get config/resource | `GET /v1/{parent}` / `GET /v1/{name}` |
| Create | `POST /v1/{parent}/workstations?workstationId={key}` with initial ownership metadata |
| Write intent | `PATCH /v1/{name}?updateMask=annotations,labels` with current etag and merged metadata |
| Start / stop | `POST /v1/{name}:start` / `POST /v1/{name}:stop` with current etag |
| List owned scope | `GET /v1/{parent}/workstations?pageSize=100&pageToken={token}` |
| List operations | `GET /v1/{region}/operations?pageSize=100&pageToken={token}` |
| Inspect operation | `GET /v1/{operation.name}` |
| Delete | `DELETE /v1/{name}?etag={current_etag}` |

```elixir
Req.request(
  method: :patch,
  url: "https://workstations.googleapis.com/v1/" <> name,
  params: [updateMask: "annotations,labels"],
  headers: [{"authorization", "Bearer " <> access_token}],
  json: %{"name" => name, "etag" => etag,
          "annotations" => annotations, "labels" => labels},
  retry: false,
  receive_timeout: remaining_ms,
  connect_options: [timeout: min(remaining_ms, 30_000)]
)
```

Disable automatic HTTP mutation retries. Do not use `allowMissing`, `validateOnly`,
operation deletion, or a nonexistent requestId as lifecycle logic. Treat HTTP 401/403
as authorization failures, 409/412 as inspect-and-revalidate conflicts, and transport
timeouts as unknown. Parse LRO `done`, `error.code`, `metadata.target`, and `metadata.verb`;
HTTP 200 is not completion. Do not parse human error text as proof of absence.

- [ ] **Implement durable metadata, ensure and complete inventory.** Initial create carries labels `symphony-managed=true`, `symphony-deployment` (a short hash), and `symphony-ticket` (the resource key), plus annotations for full identity, config name/UID, captured image/config fingerprint, workspace path, desired intent, attempt, pending verb/time/operation name, and terminal-observation time. Merge operator annotations under etag; wait for each metadata LRO and read-back before relying on its durability. A deterministic-name 409 requires full ownership verification, not adoption by name.

List every page; nonempty `unreachable` or a partial/denied list blocks new dispatch.
Under the configured workstation cluster, enumerate configuration scopes needed to
discover old owned resources rather than looking only under a newly named config.
Capture config UID and a canonical digest of runtime-relevant fields; do not compare
etag alone as if it were a restorable configuration version. Reject unsafe in-place
image/storage changes for retained environments; require versioned operator configs.

- [ ] **Implement the start/stop barrier and fail-closed recovery.** Persist pending-start evidence before POST. Resolve known earlier create/start LROs to terminal success/error before issuing stop. Then POST stop with fresh etag, await its successful LRO, require the same workstation UID, `STATE_STOPPED`, `reconciling=false`, and no unresolved earlier mutation. A failed start may still need stop. Cancellation requests and tunnel closure are not proof.

If a start response was lost, search all operation pages by exact target/verb and the
serialized attempt's saved time bounds. The API has no requestId and does not document
linearizable empty-operation-list semantics: if correlation cannot be established,
retain `:unknown` and its slot. Never upgrade repeated STOPPED samples to proof.
This is an explicit operator-visible recovery limit, not a retry implementation gap.
Unexpected suspension/unknown state enums also remain unknown in this disk-only profile.

- [ ] **Implement supervised tunnel and session-scoped SSH trust.** The adapter owns this exact long-lived CLI shape, with scope/auth fields taken from validated provider settings:

```bash
gcloud workstations start-tcp-tunnel "$WORKSTATION_ID" 22 \
  --project="$PROJECT" --region="$LOCATION" --cluster="$CLUSTER" --config="$CONFIG" \
  --local-host-port=127.0.0.1:0 \
  --impersonate-service-account="$LIFECYCLE_SERVICE_ACCOUNT" --quiet
```

Never add `--start-workstation`. Wait for the assigned listening port and an actual
connection before returning `Connection`. Keep tunnel diagnostics out of agent stdout.
Use `ssh -F /dev/null -T`, `BatchMode=yes`, `ForwardAgent=no`, `IdentityAgent=none`,
loopback destination and private per-run known_hosts. Initial `accept-new` trust is
through the already authenticated IAM/TLS gateway; pin that key for this connection.
Do not apply this policy to public/static SSH. Port zero avoids a reserve-and-release
port race. Workstations' image-specific empty-password/none-auth SSH mechanism must
work non-interactively; do not add sshpass or deploy an exposed passwordless SSH server.

Obtain an OAuth bearer token with `gcloud auth print-access-token` using an explicit
deployment credential configuration/service-account impersonation. Fetch once per
bounded lifecycle job and reuse it within that job's polling/client operations; do not
spawn gcloud per HTTP poll. A definite 401 may trigger one refresh, but an ambiguous
mutation result may not be replayed. Do not assume a cached token has a fresh one-hour
lifetime. No token appears in URLs, logs, command arguments, provider annotations, or
the worker environment. A noninteractive preconfigured gcloud identity is a prerequisite.

- [ ] **Implement deletion with billable-resource evidence.** Preflight requires persistent `/home`, `gcePd.reclaimPolicy=DELETE`, `archiveTimeout=0s`, no warm pool, supported idle/running timeout settings, and TCP access to container port 22. Stop retains disk; destroy never deletes the operator's config/cluster. Persist deleting intent, await delete LRO, inspect absence and enumerate labeled Compute VM/disk resources with read-only inventory permissions. Paginate aggregated inventory and reject unreachable scopes. Retain captured disk/VM identifiers and delete-operation evidence until absence is confirmed.

Do not infer a disk's policy retroactively from a changed config. Never automatically
delete an unowned disk or bypass Workstations using broad Compute write permissions.
If Workstations leaves a backing resource after parent deletion, expose that exact
resource as unresolved cleanup for operator remediation; keep discovering it through
propagated ownership labels. Qualification must prove initial label propagation and
partial-create recovery. Unlabeled/unattributable backing resources are a provider
qualification failure, not something to adopt heuristically.
When an orphan's full issue identity is no longer recoverable from its deleted parent,
return a discovery error containing only its safe resource IDs; do not manufacture
an issue ID or silently omit it from inventory. Keep managed dispatch blocked and
surface the orphan for operator remediation. This is not an automatic orphan-deletion
permission or a successful qualification result.

- [ ] **Run the adapter regressions and commit.** Use `mise exec -- mix test test/symphony_elixir/workstations_environment_test.exs`. Add consumer-visible cases for lost create response, page-two leftovers, denied inventory, unresolved start, stop LRO error, foreign UID/ownership, nonzero retention across restart, reopen, and leftover disk after parent 404. Use scripted HTTP responses via `request_fun` to model ordering, not assertions on exact JSON formatting. Commit: `feat: implement Workstations execution environments`.

## Task 5: Implement Kubernetes Sandbox lifecycle with safe start authorization

**Files:** Create `execution_environment/kubernetes.ex`, `execution_environment/kubernetes/client.ex`, and `elixir/test/symphony_elixir/kubernetes_environment_test.exs`. These files are independent of Task 4.

**Interfaces:** Implement every Environment callback. Produce
`Kubernetes.Client.request(config, method, path, body, opts)` and
`Kubernetes.normalize(record, sandbox, pods, termination_evidence)`.
Client responses use the same status/body/failure convention as Task 4; `command_fun`
is an injected `fn executable, args, opts -> Command.run(executable, args, opts) end`.
The final adapter may not use shell stderr prose to certify NotFound or quiescence.

The baseline API is upstream Agent Sandbox **v1.0.1**, serving
`agents.x-k8s.io/v1beta1` and `extensions.agents.x-k8s.io/v1beta1`.
Preflight checks the actually installed schema/controller contract. It must reject an
incompatible release, not send old `replicas` fields or silently select another API.

Required provider keys are nonblank `kubeconfig`, `context`, `namespace`, `template`,
`ssh_user`, `ssh_auth_volume`, and integer `ssh_port` in 1..65535. Check the kubeconfig
path without printing its contents. The capture from `Environment.Config.runtime/1`
contains this string-key map under `:provider`.

- [ ] **Write the missing-termination-proof regression and run it red.**

```elixir
test "a suspended sandbox with no visible pod is not physical stop evidence" do
  alias SymphonyElixir.ExecutionEnvironment.{Kubernetes, Record}
  record = %Record{
    key: "se-ticket", deployment_id: "deployment", tracker_kind: "memory",
    issue_id: "ticket", kind: "kubernetes", scope: %{},
    workspace_path: "/state/workspaces/se-ticket", template_identity: "template-v1",
    metadata: %{"authorized_pod_uids" => ["pod-before-partition"]}
  }
  sandbox = %{
    "metadata" => %{"uid" => "sandbox-uid", "generation" => 2},
    "spec" => %{"operatingMode" => "Suspended"},
    "status" => %{"conditions" => [
      %{"type" => "Suspended", "status" => "True", "observedGeneration" => 2}
    ]}
  }
  observed = Kubernetes.normalize(record, sandbox, [], %{})
  assert observed.proof == :unknown
  refute observed.phase == :stopped
end
```

Run `mise exec -- mix test test/symphony_elixir/kubernetes_environment_test.exs`.

- [ ] **Implement bounded Kubernetes access with the installed CLI's credential support.** Every command supplies validated kubeconfig/context and a nonzero request timeout; an outer port deadline also covers a stuck credential plugin. Use JSON resource requests, UID/resourceVersion preconditions, and protected request-body files. Never use `replace --force`, force-delete, zero-grace deletion, or `resourceVersion=0` for authoritative inspection.

```bash
kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" --request-timeout=20s \
  get --raw "/apis/agents.x-k8s.io/v1beta1/namespaces/$NAMESPACE/sandboxes?limit=100"
kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" --request-timeout=20s \
  create --raw "/apis/agents.x-k8s.io/v1beta1/namespaces/$NAMESPACE/sandboxes?fieldValidation=Strict" \
  -f "$PRIVATE_SANDBOX_JSON"
```

Use a complete collection GET and exact name lookup to distinguish an absent object
from an unparseable failed single-object CLI request. For patching, use `kubectl patch
... --type=json --patch-file=... -o json`; for conditional deletion use raw
DeleteOptions with UID/resourceVersion and foreground propagation. Client list code
follows `metadata.continue` even after an empty page; token expiry restarts the entire
inventory. Incomplete inventory never becomes zero used capacity.

- [ ] **Materialize one deterministic direct Sandbox from the operator template.** Read the namespaced SandboxTemplate and copy only `podTemplate`, `volumeClaimTemplates`, and `service`. Set `operatingMode: Suspended` initially and omit `shutdownTime`. Do not set a Template ownerReference. Do not use Claims/WarmPools: this release's Claim requires `warmPoolRef`, has no suspend field, and Claim `Retain` does not retain its backing workspace.

Stamp the complete identity and a `symphony.dev/environment-cleanup` finalizer on the
initial Sandbox. Stamp ownership into the initial immutable volumeClaimTemplates and
Pod template as well; top-level labels do not automatically propagate. Preserve a
captured template UID/content digest and refuse to re-materialize retained storage
from a changed template. Direct Sandbox workloads do not automatically inherit the
Template controller's managed NetworkPolicy: require operator-owned policy selected
by an ordinary profile label and `networkPolicyManagement: Unmanaged`.

- [ ] **Implement per-Pod start authorization to fence delayed controller creates.**
Require Kubernetes >=1.30 and retain a scheduling gate permanently in the stored Pod
blueprint:

```yaml
spec:
  operatingMode: Suspended
  podTemplate:
    spec:
      schedulerName: default-scheduler
      schedulingGates:
        - name: symphony.dev/start-authorized
      automountServiceAccountToken: false
      enableServiceLinks: false
      restartPolicy: Never
```

Reject `nodeName`, incompatible schedulers, gate-stripping admission, host namespaces,
hostPath/node sockets, and an unqualified RuntimeClass. Start writes Running intent
using Sandbox UID/resourceVersion CAS, observes its owned gated Pod, persists the
authorized Pod UID before release, revalidates current intent, and CAS-removes only
Symphony's gate from that exact Pod. It never removes the gate from the Sandbox's
blueprint. A controller replacement or a late stale create therefore cannot run
without another explicit authorization. Never automatically authorize replacement
Pods while an old authorized UID has unresolved termination.

```elixir
release_patch = [
  %{"op" => "test", "path" => "/metadata/uid", "value" => pod_uid},
  %{"op" => "test", "path" => "/metadata/resourceVersion", "value" => pod_rv},
  %{"op" => "test", "path" => "/spec/schedulingGates/#{gate_index}/name",
    "value" => "symphony.dev/start-authorized"},
  %{"op" => "remove", "path" => "/spec/schedulingGates/#{gate_index}"}
]
```

Releasing an operator's additional gate is forbidden. A canceled release must not
retry against a refreshed resourceVersion. Record every possible release UID before
submission; a crash between intent and release remains reconcilable.

- [ ] **Implement stop proof, not status-only suspension.** Persist a newer stopped intent and set `operatingMode: Suspended` by CAS. Supersede any delayed ungate request by a resourceVersion-checked stop-fence update to its recorded Pod before normal deletion. Watch the exact known UID from its recorded resourceVersion and persist normal kubelet-confirmed termination evidence before forgetting it. Require current-generation Suspended status, no executable/terminating owned Pod, all authorized UIDs accounted for, and the permanent gate retained in the blueprint.

An API 404, Failed phase, node deletion, force deletion, or disconnected node cannot
prove the guest stopped. If watch history is lost/compacted before evidence is saved,
retain unknown capacity until independently verified termination/node fencing. Do not
give Symphony node-power privileges or fabricate a generic automated fencing API.
The operator qualification contract must prohibit unverified force-delete/out-of-service
recovery. Late gated Pods are non-executing and remain discoverable for cleanup.

- [ ] **Implement persistent storage and finalizer-controlled destruction.** Generated PVCs are `{claim_template_name}-{sandbox_name}` and owned by Sandbox UID, so suspension must preserve PVC UID/data. Do not wait for a WaitForFirstConsumer PVC to bind before authorizing its first Pod. Require a qualified Delete-reclaim CSI class and capture PVC UID, PV name/UID, claimRef and volumeHandle before deletion. Confirm actual backing-storage deletion through CSI/PV finalizer evidence, not merely PVC absence; require read permission for that evidence.

Keep the Sandbox cleanup finalizer until known Pods, Secrets, Services, PVCs and
recorded backing volumes are removed. A parent finalizer must not prevent explicit
child cleanup: delete children with verified ownership and let storage finalizers
complete, then remove only Symphony's finalizer. Services may need owner-UID discovery
because the controller does not copy deployment labels onto them. Scan labeled
children without a parent to recover partial creates.

Arbitrarily delayed child creates are not fenced by parent 404 alone. Qualification
must establish the controller/control-plane cleanup ordering; if it cannot, preserve
the discoverable parent/finalizer and report unresolved cleanup. Do not claim final
absence by deleting the last ownership record and hoping no child arrives afterward.

- [ ] **Implement private SSH with ticket-specific keys and pinned host identity.**
Require the orchestrator to have private reachability to the owned Pod IP/headless
Service; use no public LoadBalancer, NodePort, or implicit port-forward. Generate one
ticket-specific host key and client key through argv-only `ssh-keygen`; the client
private key stays outside the worker. Create an owned Secret containing host key and
client public authorized_keys before start, mounted only through the template's
declared `ssh-auth` volume slot. Persist the host key Secret across stop/start; rotate
client credentials while confirmed stopped and clean local material per session.

Populate private known_hosts from the public host key obtained over authenticated
Kubernetes API. Use `StrictHostKeyChecking=yes`, `HostKeyAlias` bound to environment
UID, `IdentitiesOnly=yes`, `ForwardAgent=no`, `BatchMode=yes`, and no PTY. Inspect Pod
UID/address anew after resume. A lost local client private key after orchestrator
restart is recoverable by replacing authorized_keys while the environment is stopped,
not by trusting an unknown server or weakening authentication.

- [ ] **Run adapter regressions and commit.** Cover CAS conflict/ownership replacement, lost create response, delayed ungate after stop, late gated Pod creation, missing physical termination evidence, retained PVC identity, delayed PV deletion, denied/partial inventory, and wrong host-key rejection. Validate observed behavior rather than exact YAML serialization. Commit: `feat: implement Kubernetes ticket execution environments`.

## Task 6: Wire complete managed dispatch, shutdown, recovery and retention

**Files:** Modify `orchestrator.ex`, `agent_runtime_supervisor.ex`, `config/schema.ex`,
`config.ex`, `workflow_store.ex`, `test/support/test_support.exs`, and the affected
existing tests. Create `elixir/test/symphony_elixir/managed_orchestrator_test.exs`.
Consume Tasks 1–5; one integration owner performs this task.

**Interfaces:** Add `environment_entries` (keyed by opaque issue ID),
`environment_jobs` (keyed by task monitor reference), `environment_discovery`
(`:pending`, `:ready`, or `{:error, reason}`), `environment_config`, and
`environment_guard` to Orchestrator.State. Existing running/retrying/blocked maps keep
their agent semantics. Add explicit managed-resource state rather than fabricating
running-agent entries with nonexistent PIDs/session IDs.

`Operations.run/5` returns `{:ok, ExecutionContext.t()}` for prepare,
`{:ok, Record.t()}` for stop/destroy/inspect, or `{:error, failure, Record.t()}` for a
record-scoped failure. Discovery returns `{:ok, [Record.t()]}` or `{:error, failure}`.
`environment_jobs` retains issue ID, operation ID, operation kind and task until its
matching result or DOWN is accounted for. Add test-only dependency-injection options
`environment_operation_fun` (arity five, same contract as Operations.run) and
`runner_fun` (arity three, same contract as AgentRunner.run); these are startup options,
never YAML settings. Default functions use the real implementations.
Forward `environment_operation_fun` as Operations' `:operation_fun` option and pass
the orchestrator PID as `:authority`. On discovery/stop completion, enqueue a poll
without waiting for the next full interval. Track a discovery token separately from
per-ticket operation generations. Finalize only one of result/DOWN for each task.

- [ ] **Add a controlled process regression for capacity held during shutdown.**
Use TestSupport's Memory tracker with two dispatchable issues, concurrency one, and a
valid managed config fixture. The test controls real operation/runner task completion,
not provider field forwarding. Implement the fixture configuration in
`write_workflow_file!/2` using a `worker_environment` map serialized as a nested JSON
mapping in YAML. In the new test module set up these callbacks:

```elixir
test_pid = self()
operation_fun = fn _adapter, config, entry, operation, _opts ->
  send(test_pid, {:environment_operation, operation, config, entry, self()})
  receive do
    {:complete_operation, result} -> result
  end
end
runner_fun = fn issue, _recipient, _opts ->
  send(test_pid, {:agent_started, issue.id, self()})
  receive do
    :finish_agent -> :ok
  end
end
```

Start an isolated Orchestrator with those callbacks, its own Task.Supervisor, and
Memory issues whose IDs are `first` and `second`. Complete discovery with an empty
inventory, then complete the first prepare with a context built from the received
record/config and a controlled Connection owner. Observe `{:agent_started, "first",
runner_pid}`, send `:finish_agent`, and wait for a stop operation. While that operation
is blocked, request a poll and inspect `:snapshot`: occupied managed capacity remains
one, there is no second prepare, and no second agent starts. Complete stop with the
same record carrying `phase: :stopped`, empty pending operations, and quiescent proof;
move `first` to a non-active state through Memory tracker, poll again, and require
`second` to start. Use operation notifications and synchronous snapshots as barriers,
not arbitrary sleeps. Terminate the isolated supervisor on exit so blocked fixture
tasks cannot leak into the full suite.

After the fixture workflow and two Memory issues are installed, the actual process
assertion sequence is:

```elixir
alias SymphonyElixir.{ExecutionContext, Orchestrator, SSH}
alias SymphonyElixir.ExecutionEnvironment.{Connection, Lifecycle}

{:ok, tasks} = Task.Supervisor.start_link()
{:ok, orchestrator} =
  Orchestrator.start_link(name: nil, task_supervisor: tasks,
    environment_operation_fun: operation_fun, runner_fun: runner_fun)
on_exit(fn ->
  if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
  if Process.alive?(tasks), do: Supervisor.stop(tasks)
end)
assert_receive {:environment_operation, :discover, _config, nil, discovery}, 1_000
send(discovery, {:complete_operation, {:ok, []}})
assert_receive {:environment_operation, :prepare, config, first, prepare}, 1_000
assert first.record.issue_id == "first"
target = %SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "test-worker"}
connection = %Connection{target: target, owner: self(), id: make_ref()}
ready = %{first.record | phase: :running}
context = ExecutionContext.managed(config, ready, connection)
send(prepare, {:complete_operation, {:ok, context}})
assert_receive {:agent_started, "first", runner}, 1_000
send(runner, :finish_agent)
assert_receive {:environment_operation, :stop, _config, stopping, stop}, 1_000
send(orchestrator, :run_poll_cycle)
state = :sys.get_state(orchestrator)
assert Lifecycle.occupied?(state.environment_entries["first"])
refute Map.has_key?(state.environment_entries, "second")
refute_receive {:agent_started, "second", _}, 0

:ok = SymphonyElixir.Tracker.Memory.update_issue_state("first", "In Review")
stopped = %{stopping.record | phase: :stopped, pending: [],
                            proof: {:quiescent, %{fixture: true}}}
send(stop, {:complete_operation, {:ok, stopped}})
assert_receive {:environment_operation, :prepare, next_config, second, next_prepare}, 1_000
assert second.record.issue_id == "second"
next_context = ExecutionContext.managed(
  next_config, %{second.record | phase: :running}, connection)
send(next_prepare, {:complete_operation, {:ok, next_context}})
assert_receive {:agent_started, "second", _}, 1_000
```

Use In Progress as the active fixture state and In Review as non-active; give first
priority 1 and second priority 2. Teardown must also clear the simulated inventory
and release its WorkflowStore guard with the captured token; do not restart global
services repeatedly or leave a guard poisoning the next test. A controlled Connection
in this scheduling test is not evidence that real SSH or provider readiness works.

- [ ] **Run the new process test red, then attach the public configuration surface.**
Embed the Task 1 managed config under `Config.Schema.Worker`. Reject managed mode
combined with explicitly supplied static-host or per-host-cap fields, including empty
static lists if explicitly supplied; omitted static settings may retain schema defaults.
Detect explicit null/empty managed objects before `drop_nil_values/1`. Keep all provider
preflight/network work out of Config.validate_settings/1. Adapter shape validation is
local and side-effect-free. Preserve legacy mode selection when the object is absent.

```elixir
# Validate conflicting source keys before casting/default insertion.
managed? = Map.has_key?(worker_attrs, "environment")
static? = Enum.any?(["ssh_hosts", "max_concurrent_agents_per_host"],
                    &Map.has_key?(worker_attrs, &1))
if managed? and static? do
  {:error, {:invalid_workflow_config, "managed and static worker settings conflict"}}
else
  :ok
end
```

Update the test-support writer to omit static fields when managed configuration is
requested; explicit conflict tests write both deliberately. Never repair invalid
configuration by dropping a field or interpreting managed nil as local execution.

- [ ] **Implement startup discovery before dispatch.** Protect the accepted identity in WorkflowStore, start provider preflight/discovery asynchronously, and skip new managed dispatch until complete. Reconcile all owned records, including stopped, partially created, unknown, deleting, and orphan-child inventory records, with tracker ID refreshes. Keep captured old template/path context. Stop leftover execution before redispatch; do not reattach live backend sessions or reconstruct old in-memory retry timers. Discovery failure keeps reconciliation active and capacity unavailable.
On later inventory refreshes, preserve a healthy run whose exact current attempt is
already owned by this orchestrator; do not apply startup's stop-leftovers policy to
every active run. Unknown/foreign-attempt records still enter stop reconciliation.
If an orphan cannot be mapped to an opaque issue ID, keep discovery failed with safe
resource identifiers rather than silently dropping it from the scheduler inventory.
- [ ] **Implement capacity and preparation before agent launch.** Reserve an Entry/claim before starting provider work. Count the union of unmanaged running IDs and occupied managed-entry IDs, not the sum of two overlapping maps. Apply per-state limits to managed reservations/stopping entries using their captured issue state. If startup discovery finds more than the configured limit, reconcile them without launching more.

```elixir
managed_ids =
  environment_entries
  |> Enum.filter(fn {_id, entry} -> Lifecycle.occupied?(entry) end)
  |> Enum.map(&elem(&1, 0))
used_ids = MapSet.union(MapSet.new(Map.keys(running)), MapSet.new(managed_ids))
available = max(max_concurrent_agents - MapSet.size(used_ids), 0)
```

After prepare succeeds, re-fetch the issue and validate eligibility, routing, backend,
and active state before launch. If state/backend selection changed during preparation,
stop and reschedule under the new state rather than launching the stale backend.
Claim-time state moves still happen according to existing config and should not be
interpreted as an unexpected external state transition. Record the state resulting
from Symphony's own successful claim-time transition as the revalidation baseline.

- [ ] **Make every managed completion/cancellation path go through stop confirmation.**
Intercept managed worker DOWN before `pop_running_entry/2` releases capacity. Finalize
session totals once, preserve completion disposition, then issue stop. Route normal
completion, exception, startup timeout, input-required blocking, turn-exhaustion
parking, stall recovery, terminal/non-active state, missing issue and retry refresh
through the same managed lifecycle helper. Do not run workspace deletion on these
paths. For local/static modes keep existing behavior.

When a lifecycle task returns `{ref, result}`, demonitor with `[:flush]` and match the
recorded operation ID before applying it. A DOWN without a result is unresolved
operation failure, not proof no work occurred. Ignore stale worker-update generations.
Only the matching stopped proof removes execution capacity and executes the saved
retry/block/release disposition. A retry timer firing while stop is unresolved cannot
launch a second execution. This applies even if the agent's local task no longer exists.

- [ ] **Implement terminal retention and hook-aware cleanup.** Persist the first affirmative terminal observation once. Before expiry, retain stopped storage. On expiry, refresh tracker state; missing/error/nonterminal does not authorize destruction. If reopened before destruction starts, clear the terminal stamp/deletion intent by a conditional metadata write. If already irreversibly deleting, finish deletion and create a fresh environment only afterward.

Run a configured before-remove hook in the original remote workspace before provider
destruction. If the environment is stopped, reserve an execution slot for
`purpose: :cleanup`, start it without launching an agent or running before-run hooks,
invoke the best-effort before-remove hook, then confirm stop and destroy. Retention
expiry alone must not erase files before that hook. Record completed cleanup-hook
intent so restart does not deliberately replay it; a crash during the hook can still
repeat side effects, consistent with the absence of exactly-once external effects.
If the worker cannot be started, retain/report cleanup rather than silently skipping
the hook. A missing workspace follows the existing skip-hook behavior.

- [ ] **Verify restart, reload, shutdown and all entry paths.** Run the new managed process test plus `orchestrator_test.exs`, `orchestrator_status_test.exs`, `core_test.exs`, `extensions_test.exs`, `agent_runner_test.exs`, `config_test.exs`, and `workspace_and_config_test.exs`. Add controlled cases for restart with unknown capacity, stop failure, lifecycle DOWN before result, stale result after cancellation, active-state change during prepare, terminal cleanup of a stopped environment, and identity-changing reload while retained storage exists. Commit: `feat: integrate managed workers with scheduler reconciliation`.

## Task 7: Expose the operator contract and document both deployment profiles

**Files:** Modify `orchestrator.ex`, `elixir/lib/symphony_elixir_web/presenter.ex`,
`orchestrator_status_test.exs`, `SPEC.md`, `README.md`, `elixir/README.md`, and
`elixir/WORKFLOW.md`. Keep existing status UI layout; this is not a new dashboard.

**Interfaces:** Add a safe `environments` collection to the existing snapshot/API
payload. Each entry exposes only environment key/provider, issue ID/identifier, phase,
desired state, whether execution capacity is occupied, workspace path, safe provider
resource ID, first terminal observation, and a structured redacted unresolved error.
Existing agent-running/retrying/blocked payloads preserve their meanings.

- [ ] **Add a snapshot redaction regression, then run it red.** Seed a managed Entry with a connection target containing a sentinel private key path/token in its private fields. Through the existing snapshot/Presenter path, assert the public environment entry reports the unresolved stop and occupied capacity while the serialized payload contains neither sentinel. Do not merely test `Inspect` output or copy a private map into the presenter.
For the redaction assertion, seed a complete Record/Entry in an isolated orchestrator
whose Memory tracker is empty, with `record.metadata` containing
`%{"test_secret" => "never-expose-this"}` and phase unknown. Then exercise the real
Presenter API rather than a private formatting helper:

```elixir
payload = SymphonyElixirWeb.Presenter.state_payload(orchestrator, 1_000)
encoded = Jason.encode!(payload)
assert Enum.any?(payload.environments, fn environment ->
  environment.environment_id == record.key and environment.occupies_slot
end)
refute encoded =~ "never-expose-this"
```
- [ ] **Implement safe status projection from explicit fields.**

```elixir
%{
  environment_id: record.key,
  provider: record.kind,
  issue_id: record.issue_id,
  phase: entry.phase,
  desired: record.desired,
  occupies_slot: Lifecycle.occupied?(entry),
  workspace_path: record.workspace_path
}
```

Add resource ID/terminal stamp/error only through explicit safe projections. Do not
serialize Record.metadata wholesale, access tokens, SSH args, full provider config,
authentication references, or raw CLI output. Logs distinguish invalid config,
provider denial, pending/unknown operations, and incomplete deletion.
Extend `Presenter.issue_payload/3` to find a retained environment even when no
running/retrying/blocked agent entry exists. Use its persisted workspace path and safe
provider label; do not fall back to computing a local path from the display identifier.
Add an assertion that a stopped retained ticket remains inspectable through that API
and reports no active agent session.

- [ ] **Document the real public settings with usable examples.** These samples contain no credentials. Resource references are operator-created example names, not resources created by Symphony. Providers validate the following exact string-key maps:

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

`credential_configuration` names a preconfigured gcloud configuration selected with
`--configuration`; it must work without interactive login and must not mutate the
user's active configuration. `impersonate_service_account` is required in this baseline
so token and tunnel identity are explicit and consistent. IAM must also permit the
read-only Compute inventory needed by destroy verification.

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

The Kubernetes namespace/context and Workstations cluster scope are stable deployment
boundaries, not agent-controlled scheduling choices. Provider subprocesses receive
explicit paths/auth selection. Changes to these references are identity changes and
must pass the publication guard. New settings must be documented with their actual
validation rules and default zero retention; no implicit fallback configuration.

- [ ] **Document runtime/image/security prerequisites rather than provision infrastructure.**
Kubernetes's reference profile is a qualified Kata VM boundary with
`privileged_without_host_devices=true`; guest-contained DinD privilege is not an
unrestricted privileged runc Pod. Runtime/admission must fail closed if Kata is absent.
Document CSI/PV evidence permissions, scheduling gates, read-only template access,
Pod CAS/gate permissions, owned Secret lifecycle, enforcing NetworkPolicy, and private
SSH reachability. Explicitly document the Kata virtiofs/overlayfs incompatibility:
persistent Docker storage needs a qualified guest filesystem/storage driver; an
ephemeral memory directory is not a solution.

For Workstations, document separate lifecycle and worker VM identities, API/operation
permissions, noninteractive CLI setup, persistent `/home`, Docker data, DELETE reclaim,
disabled archival/warm pool, loopback tunnel, quotas and charges. Do not claim that
an in-worker firewall controlled by root prevents privileged code from obtaining
metadata credentials. Qualification must establish provider-enforced isolation or
report that profile unavailable. Never place the lifecycle identity on the worker VM.

Each repository supplies its Linux development image and unchanged setup/test commands.
Both agent executables, Bash/GNU realpath/Git, Compose, browser dependencies and
appropriate Docker storage are prerequisites checked in readiness/qualification.
GKE hosting Symphony/review apps does not change the preferred Google worker choice.
GKE Standard/Kata prerequisites are distinct from managed gVisor and from Autopilot;
do not conflate their support contracts.

- [ ] **Update the source-of-truth specification and verify the actual status surface.**
Add the managed extension to SPEC.md with explicit configuration, restart inventory,
capacity, retention and cleanup semantics; preserve Appendix A. Update root concept
docs and Elixir run/workflow instructions in the same feature change. Exercise the
existing JSON API with a disposable Memory-tracker setup and controlled environment
operations, inspect its actual response, and confirm credentials are absent. Run the
status tests, then commit: `docs: document managed worker operation and recovery`.

## Task 8: Qualify both providers on authorized disposable infrastructure

**Files:** Create `elixir/test/symphony_elixir/managed_environment_live_e2e_test.exs`
for the genuinely uncertain lifecycle/isolation contracts. Use the existing
`:live_e2e` tag and per-module opt-in skip convention; do not include it in ordinary
unauthenticated test runs. Create
`elixir/test/support/managed_environment_fixture/compose.yaml`,
`testcontainers_probe.py`, and `browser_probe.mjs` as small real workloads. Modify
`elixir/README.md` with the exact opt-in invocation and required operator inputs.

**Interfaces:** The live harness reads an explicitly selected workflow path and provider
through test configuration, uses the real Environment adapters and Orchestrator, and
creates an isolated `deployment_id` for its disposable resources. No production issue
tracker mutation is needed: use Memory tracker for scheduler transitions and real
Claude/Codex processes for backend qualification. It writes a machine-readable evidence
file only to an operator-selected temporary output path, not a repository fixture
pretending to be a successful live result.

Use these exact opt-in test variables: `SYMPHONY_RUN_MANAGED_E2E=1`,
`SYMPHONY_MANAGED_E2E_WORKFLOW` (absolute path to the authorized disposable workflow),
and `SYMPHONY_MANAGED_E2E_OUTPUT` (absolute temporary evidence JSON path). The provider
kind comes from that workflow through Config, not a second provider override.
Read required paths inside enabled test setup, so ordinary skipped test loading
does not fail for missing live credentials or files.

```elixir
@moduletag :live_e2e
@moduletag timeout: 1_800_000
@moduletag skip: System.get_env("SYMPHONY_RUN_MANAGED_E2E") != "1"
```

After authorization, execute once per provider with its independently scoped workflow:

```bash
env SYMPHONY_RUN_MANAGED_E2E=1 \
  SYMPHONY_MANAGED_E2E_WORKFLOW="$AUTHORIZED_WORKFLOW" \
  SYMPHONY_MANAGED_E2E_OUTPUT="$EVIDENCE_JSON" \
  mise exec -- mix test test/symphony_elixir/managed_environment_live_e2e_test.exs \
  --include live_e2e --timeout 1800000
```

- [ ] **Obtain explicit authorization and establish prerequisite evidence before creating resources.**
Record the cloud project/region or Kubernetes context/namespace, installed controller
and runtime versions, quotas, image digest, permitted resource budget, cleanup scope,
and credentials sufficient for lifecycle plus deletion evidence. Authorization must
cover five concurrent workers and paid model calls. An existing credential file alone
is not authorization. If either target lacks prerequisites, implement/run reachable
local tests but report that provider's qualification blocked; do not reduce the
feature to the other provider or label it production-ready.
- [ ] **Implement deterministic workload fixtures that check real data and protocols.**

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: isolated-test-only
    volumes:
      - database:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 2s
      timeout: 2s
      retries: 30
volumes:
  database:
```

```python
from testcontainers.core.container import DockerContainer

with DockerContainer("alpine:3.20").with_command("sleep 60") as container:
    code, output = container.exec(["sh", "-c", "printf testcontainers-ok"])
    assert code == 0
    assert output.decode() == "testcontainers-ok"
```

```javascript
import { chromium } from "playwright";
const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  await page.setContent('<button id="check">run</button><output id="result"></output>');
  await page.evaluate(() => {
    document.querySelector("#check").onclick = () => {
      document.querySelector("#result").textContent = "browser-ok";
    };
  });
  await page.click("#check");
  const value = await page.locator("#result").textContent();
  if (value !== "browser-ok") throw new Error(`Unexpected browser result: ${value}`);
} finally {
  await browser.close();
}
```

The operator-qualified image supplies pinned compatible Testcontainers/Playwright
dependencies and browsers. Resolve/pin fixture image digests for reproducible live
qualification before execution, and record them; the tags above identify the intended
images, not a license to silently change images between comparisons.

- [ ] **Run the complete worker path on each provider.** Create the environment through the actual API, establish SSH, clone a disposable repository, and run both backends separately. Have each agent perform a verifiable file change and invoke the Compose, Testcontainers and browser probes under its configured permissions; verify the resulting data/output independently over SSH. A direct SSH test alone does not prove the agent can use Docker through its own sandbox/approval policy. Do not silently weaken either the backend policy or the outer isolation to obtain a passing run.
- [ ] **Exercise five active tickets and a queued sixth.** Keep five backend runs active with controlled work. Observe provider resource identities, occupied slots, and absence of a sixth running environment. Write distinct sentinel files and PostgreSQL rows per ticket; prove those values remain independent. Test denial of unauthorized access to another ticket, node runtime sockets, and usable administration/metadata credentials using narrowly scoped non-destructive probes.
- [ ] **Exercise review and persistent resume.** Modify an uncommitted checkout file and insert a unique database row in the Compose named volume. Transition to a configured non-active review state; confirm actual compute shutdown and slot reuse. Reactivate, restart Compose, then read the same file/row. A separately deployed review app must not be tied to the worker's loopback tunnel or compute lifetime.
- [ ] **Inject the specified lifecycle failures.** Lose create/start responses after acceptance, kill the local SSH/tunnel, restart Symphony, deny a stop request, and delay storage deletion in disposable infrastructure. Verify no duplicate runnable worker, unknown capacity retained, correct attempt matching, no local fallback and eventual recovery when the uncertainty can actually be resolved. On Kubernetes, include delayed gate release and a node-disconnection scenario only with explicit permission; never force-delete an unverified live node as a test shortcut.
- [ ] **Exercise terminal deletion, retention and reopening.** Verify zero retention, nonzero retention surviving restart, a reopen before deletion, and restart after deletion begins. Confirm all owned compute/disk resources are absent at the end and that unrelated resources remain intact. Record unresolved service-managed disks or missing physical-stop evidence as failures requiring operator action; do not hide them in a successful test summary.
- [ ] **Record the actual evidence and clean up disposable resources.**

```elixir
%{
  provider: provider_kind,
  deployment_id: deployment_id,
  image_digest: image_digest,
  runtime_version: runtime_version,
  checks: check_results,
  remaining_owned_resources: remaining_owned_resources,
  qualified?: Enum.all?(check_results, &(&1.status == :passed)) and
                remaining_owned_resources == []
}
```

`check_results` contains individually named outcomes and observable identifiers, not
credential-bearing request dumps. A skipped required check makes qualification false.
The live test fails if any owned billable resource remains; it prints only safe IDs
needed for authorized remediation. Remove throwaway scripts/data after observing
cleanup. Keep only regression fixtures that defend the specified uncertain contracts.
Commit the harness/docs, not credentials or fabricated evidence:
`test: qualify managed worker lifecycle and workload isolation`.

## Task 9: Run integration gates and hand off the complete implementation

**Files:** Only files changed by Tasks 1–8 and any narrowly required corrections.
Do not pre-emptively alter unrelated code, coverage exclusions or snapshot wording.

**Interfaces:** This task produces the release-readiness evidence: both provider
qualification outcomes, passing applicable local gates, and an explicit list of
unresolved infrastructure prerequisites if any remain. A plan or adapter compile is
not feature completion.

- [ ] **Run all targeted lifecycle/backend tests together after both adapter branches merge.**

```bash
mise exec -- mix test \
  test/symphony_elixir/execution_environment_test.exs \
  test/symphony_elixir/environment_lifecycle_test.exs \
  test/symphony_elixir/environment_operations_test.exs \
  test/symphony_elixir/environment_reload_test.exs \
  test/symphony_elixir/workstations_environment_test.exs \
  test/symphony_elixir/kubernetes_environment_test.exs \
  test/symphony_elixir/managed_orchestrator_test.exs \
  test/symphony_elixir/agent_runner_test.exs \
  test/symphony_elixir/app_server_test.exs \
  test/symphony_elixir/agent/claude_ssh_test.exs
```

- [ ] **Run the full repository gate once the working tree is integrated.** From `elixir/`, run `mise exec -- make all`; investigate actual failures without suppressing symptoms or broadening ignored coverage. Execute the live harness separately in each authorized provider scope; skipped live tests in the ordinary suite are not provider qualification.
- [ ] **Perform an end-to-end callsite review.** Confirm no runtime path still interprets a missing managed context as local, no stale worker message bypasses attempt checks, no cancellation path skips the remote stop barrier, and no startup/retry/terminal cleanup path loses captured ownership. Check normal startup, reload, orchestrator/WorkflowStore restart, identity migration refusal, failed creation, and partial deletion.
- [ ] **Check source-of-truth/docs/config parity and remove only throwaway artifacts.**
Ensure SPEC.md and the operator examples describe the code actually shipped, both
provider profiles remain covered, and qualification limitations are stated honestly.
Do not commit credentials, generated cloud identifiers, temporary known_hosts/client
keys, or local qualification output. Preserve actual evidence in the authorized
artifact location. Request the repository's normal code review before merging.
- [ ] **Deliver verification without overstating support.** State exact commands and real scenarios exercised, provider/runtime/image versions, cleanup evidence and remaining blockers. If an authorized provider could not pass qualification, say so explicitly; do not label the whole feature done or substitute a different runtime. Commit any final scoped fixes with their own rationale; do not push/merge unless requested.

## Provider evidence and qualification limits

The implementation choices above are grounded in public documentation/source, not
live-provider experiments. Preserve these boundaries while executing:

- [Agent Sandbox v1.0.1 Sandbox CRD](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.1/k8s/crds/agents.x-k8s.io_sandboxes.yaml): `operatingMode`, immutable volume templates and scheduling-gate-compatible PodSpec.
- [Sandbox controller](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.1/controllers/sandbox_controller.go): Pod/PVC ownership, suspension, service metadata and observed generation.
- [Template CRD](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.1/k8s/crds/extensions.agents.x-k8s.io_sandboxtemplates.yaml) and [Claim CRD](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.1/k8s/crds/extensions.agents.x-k8s.io_sandboxclaims.yaml): direct materialization versus warm-pool claim lifecycle.
- [Scheduling gates](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-scheduling-readiness/), [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/), and [PV deletion](https://kubernetes.io/docs/concepts/storage/persistent-volumes/): gated starts, physical termination limits and backing-storage proof.
- [Kata Docker-in-Docker](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-run-docker-with-kata.md): guest Docker and filesystem constraints. Pin the installed runtime/image in live evidence rather than assuming a moving documentation example is a supported customer configuration.
- [GKE Agent Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/machine-learning/agent-sandbox) and [nested virtualization](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nested-virtualization): managed-controller versus self-operated Kata support boundaries.
- [Workstations REST discovery](https://workstations.googleapis.com/$discovery/rest?version=v1): actual methods, etags, annotations, state and LRO fields. There is no lifecycle requestId.
- [Workstations architecture](https://cloud.google.com/workstations/docs/architecture), [resource deletion](https://cloud.google.com/workstations/docs/delete-resources), and [labels](https://cloud.google.com/workstations/docs/label-resources): persistent disk lifecycle and inventory correlation.
- [Workstations SSH support](https://cloud.google.com/workstations/docs/ssh-support) and [TCP tunnel command](https://cloud.google.com/sdk/gcloud/reference/workstations/start-tcp-tunnel): IAM/TLS gateway, container SSH and supervised loopback route.
- [Workstations IAM](https://cloud.google.com/workstations/docs/access-control), [custom images](https://cloud.google.com/workstations/docs/customize-container-images), and [security practices](https://cloud.google.com/workstations/docs/set-up-security-best-practices): authentication, private Docker and credential-boundary qualification.

Three provider facts cannot be promoted into guarantees by this plan: Workstations
does not document a linearizable unknown-start recovery barrier; Kubernetes object
absence does not prove a partitioned guest stopped; neither parent-resource 404 alone
proves every backing-storage side effect disappeared. The implementation must retain
unknown execution/deletion evidence, expose operator intervention, and fail the
corresponding qualification check rather than inventing proof.

## Spec coverage and review checklist

| Approved requirement | Implementing tasks |
| --- | --- |
| Independent deployments, opaque ticket identity, no company coupling | 1, 4, 5, 7 |
| Full Linux/private Docker, unchanged Compose/Testcontainers/browser workflows | 2, 4, 5, 7, 8 |
| Provider-neutral orchestration and unchanged Claude/Codex protocols | 1, 2, 3, 6 |
| Kubernetes and Google Workstations; GKE does not change default choice | 4, 5, 7, 8 |
| Five configurable execution slots including preparing/stopping/unknown | 3, 6, 8 |
| Persisted checkout/data, review stop/resume, review-app independence | 2, 4, 5, 6, 7, 8 |
| Idempotent provisioning, no duplicate run, no local fallback | 1, 2, 3, 4, 5, 6, 8 |
| Restart inventory and cleanup without scheduler DB | 3, 4, 5, 6, 8 |
| Terminal retention, reopen/deletion races and before-remove hook | 2, 3, 4, 5, 6, 8 |
| Configuration publication, immutable identity and captured context | 1, 2, 3, 6, 7 |
| Isolation, scoped credentials, correct remote paths | 2, 4, 5, 7, 8 |
| Visible unresolved resources and safe status/logging | 4, 5, 6, 7 |
| Legacy local/static SSH behavior and all affected callsites | 2, 6, 9 |
| Real-provider acceptance, deterministic regressions and quality gate | 1–9 |
| SPEC/README/workflow parity and honest support claims | 7, 8, 9 |

Before execution, re-read the approved spec and this contract map. During review,
reject renamed/incompatible interfaces between tasks, unexplained changes to the
isolation model, missing lifecycle entry paths, or a claimed live pass backed only by
mock responses. No implementation or infrastructure qualification was performed while
writing this plan.
