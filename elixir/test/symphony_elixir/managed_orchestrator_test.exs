defmodule SymphonyElixir.ManagedOrchestratorTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ExecutionContext, ExecutionEnvironment, SSH}
  alias SymphonyElixir.ExecutionEnvironment.{Lifecycle, Operations, Record}

  defmodule MemoryInventory do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    @impl true
    def init(parent) do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      {:ok, %{parent: parent, issues: []}}
    end

    @impl true
    def handle_call({:replace, issues}, _from, state) do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
      {:reply, :ok, %{state | issues: issues}}
    end

    @impl true
    def handle_info({:memory_tracker_state_update, id, state_name}, state) do
      issues = Enum.map(state.issues, fn issue -> if issue.id == id, do: %{issue | state: state_name}, else: issue end)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
      send(state.parent, {:inventory_state_applied, id, state_name})
      {:noreply, %{state | issues: issues}}
    end

    def handle_info({:memory_tracker_comment, _id, _body}, state), do: {:noreply, state}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      workspace_root: "/home/user/workspaces",
      worker_environment: environment(),
      max_concurrent_agents: 1,
      poll_interval_ms: 60_000
    )

    release_guard_on_exit(:sys.get_state(WorkflowStore).environment_guard.token)
    inventory = start_supervised!({MemoryInventory, self()})
    Process.put({__MODULE__, :inventory}, inventory)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, inventory)
    :ok
  end

  test "capacity stays occupied until actual controlled stop completes" do
    issues([issue("first", 1), issue("second", 2)])
    {owner, tasks} = scheduler()
    discover([])
    {config, first, prepare} = operation(:prepare)
    assert first.record.issue_id == "first"
    ready(config, first, prepare, owner, tasks)
    assert_receive {:agent_started, "first", runner, _}, 1_000
    send(runner, :finish_agent)
    {_config, stopping, stop} = operation(:stop)
    poll(owner)
    assert Lifecycle.occupied?(:sys.get_state(owner).environment_entries["first"])
    refute Map.has_key?(:sys.get_state(owner).environment_entries, "second")
    refute_receive {:agent_started, "second", _, _}, 0
    :ok = set_issue_state("first", "In Review")
    stopped(stop, stopping)
    {config, second, prepare} = operation(:prepare)
    assert second.record.issue_id == "second"
    ready(config, second, prepare, owner, tasks)
    assert_receive {:agent_started, "second", _, _}, 1_000
  end

  test "failed stop and lifecycle task DOWN never free capacity" do
    issues([issue("first", 1), issue("second", 2)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", runner, _}, 1_000
    send(runner, :finish_agent)
    {_, stopping, stop} = operation(:stop)
    send(stop, {:complete_operation, {:error, {:unknown, :lost_stop}, stopping.record}})
    wait_state(owner, &(&1.environment_entries["first"].phase == :unknown))
    poll(owner)
    assert Lifecycle.occupied?(:sys.get_state(owner).environment_entries["first"])
    {_, inspection, inspect_task} = operation(:inspect)
    send(inspect_task, {:complete_operation, {:ok, %{inspection.record | version: "refreshed-version"}}})
    {_, _, retry_stop} = operation(:stop)
    Process.exit(retry_stop, :kill)
    wait_state(owner, &(&1.environment_entries["first"].phase == :unknown))
    poll(owner)
    assert Lifecycle.occupied?(:sys.get_state(owner).environment_entries["first"])
    refute_receive {:agent_started, "second", _, _}, 0
  end

  test "restart unknown inventory is stopped before any new prepare" do
    issues([issue("first", 1)])
    {owner, _tasks} = scheduler()
    discover([record("orphan")])
    {_, entry, stop} = operation(:stop)
    assert entry.record.issue_id == "orphan"
    poll(owner)
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    stopped(stop, entry)
    {_, next, _} = operation(:prepare)
    assert next.record.issue_id == "first"
  end

  test "state change during prepare closes the lease and stops without launching stale backend" do
    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    :ok = set_issue_state("first", "In Review")
    ready(config, entry, prepare, owner, tasks)
    {_, stopping, stop} = operation(:stop)
    refute_receive {:agent_started, _, _, _}, 0
    stopped(stop, stopping)
    wait_state(owner, &(&1.environment_entries["first"].phase == :stopped))
    poll(owner)
    refute Lifecycle.occupied?(:sys.get_state(owner).environment_entries["first"])
  end

  test "identity reload is rejected while retained storage exists" do
    issues([])
    {owner, _tasks} = scheduler()
    retained = %{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}}
    discover([retained])
    poll(owner)
    original = Config.settings!().worker.environment.deployment_id
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: "/home/user/workspaces", worker_environment: Map.put(environment(), "deployment_id", "other"))
    assert {:error, :environment_identity_in_use} = WorkflowStore.force_reload()
    assert Config.settings!().worker.environment.deployment_id == original
  end

  test "explicit null empty and static managed conflicts never select local execution" do
    for invalid <- [nil, %{}] do
      assert {:error, {:invalid_workflow_config, _}} = SymphonyElixir.Config.Schema.parse(%{"worker" => %{"environment" => invalid}})
    end

    for {key, value} <- [{"ssh_hosts", []}, {"max_concurrent_agents_per_host", nil}] do
      assert {:error, {:invalid_workflow_config, _}} = SymphonyElixir.Config.Schema.parse(%{"worker" => %{"environment" => environment(), key => value}})
    end
  end

  test "stopped terminal cleanup runs hook then durable marker then stop before destruction" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      workspace_root: "/home/user/workspaces",
      worker_environment: environment(),
      max_concurrent_agents: 1,
      hook_before_remove: "echo cleanup"
    )

    issues([%{issue("first", 1) | state: "Done"}])
    {owner, tasks} = scheduler()
    retained = %{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}, terminal_observed_at: 1}
    discover([retained])
    {config, cleanup, prepare} = operation(:prepare)
    assert cleanup.purpose == :cleanup
    ready(config, cleanup, prepare, owner, tasks)
    {_, hook, task} = operation(:cleanup_hook)
    refute_receive {:agent_started, _, _, _}, 0
    send(task, {:complete_operation, {:ok, hook.record}})
    {_, marker, task} = operation(:metadata)
    send(task, {:complete_operation, {:ok, marker.record}})
    {_, stopping, task} = operation(:stop)
    poll(owner)
    refute_receive {:environment_operation, :destroy, _, _, _, _}, 0
    stopped(task, stopping)
    {_, destroying, task} = operation(:destroy)
    assert destroying.record.metadata["symphony_cleanup_hook_completed"]
    send(task, {:complete_operation, {:ok, %{destroying.record | absent?: true, pending: []}}})
    discover([])
  end

  test "reopened retained environment clears marker durably before preparing again" do
    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    retained = %{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}, terminal_observed_at: 1, metadata: %{"symphony_cleanup_hook_completed" => true}}
    discover([retained])
    {_, reopening, task} = operation(:metadata)
    poll(owner)
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    reopened = struct!(reopening.record, reopening.metadata_intent)
    send(task, {:complete_operation, {:ok, reopened}})
    {config, entry, prepare} = operation(:prepare)
    refute entry.record.metadata["symphony_cleanup_hook_completed"]
    ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", _, _}, 1_000
  end

  test "stale prepared result releases its real lease but cannot launch" do
    issues([])
    {owner, tasks} = scheduler()
    discover([])
    config = SymphonyElixir.ExecutionEnvironment.Config.runtime(Config.settings!())
    entry = Lifecycle.new(record("stale"), "stale-attempt", :agent)
    target = %SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "stale"}
    {:ok, connection} = Operations.open_connection(tasks, owner, target, [])
    context = ExecutionContext.managed(config, %{entry.record | phase: :running}, connection)
    ref = Process.monitor(connection.owner)
    send(owner, {make_ref(), {{"stale-attempt", 9}, {:ok, context}}})
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    assert Orchestrator.snapshot(owner, 1_000).running == []
  end

  for disposition <- [:exception, :input_required, :turn_exhausted, :missing, :nonactive, :terminal, :stall] do
    test "#{disposition} retains managed capacity until stop confirmation" do
      issues([issue("first", 1), issue("second", 2)])
      {owner, tasks} = scheduler()
      discover([])
      {config, entry, prepare} = operation(:prepare)
      ready(config, entry, prepare, owner, tasks)
      assert_receive {:agent_started, "first", runner, opts}, 1_000

      case unquote(disposition) do
        :exception ->
          send(runner, {:fail_agent, :fixture_failure})

        :input_required ->
          send(owner, {:codex_worker_update, "first", opts[:attempt_id], %{event: :turn_input_required, timestamp: DateTime.utc_now()}})
          Orchestrator.snapshot(owner, 1_000)
          send(runner, :finish_agent)

        :turn_exhausted ->
          :sys.replace_state(owner, fn state -> %{state | turn_exhaustions: %{"first" => %{state: "in progress", count: 2, head: nil}}} end)
          send(owner, {:agent_turns_exhausted, "first", opts[:attempt_id], "In Progress"})
          Orchestrator.snapshot(owner, 1_000)
          send(runner, :finish_agent)

        :missing ->
          issues([issue("second", 2)])
          poll(owner)

        :nonactive ->
          set_issue_state("first", "In Review")
          poll(owner)

        :terminal ->
          set_issue_state("first", "Done")
          poll(owner)

        :stall ->
          :sys.replace_state(owner, fn state -> put_in(state.running["first"].started_at, DateTime.add(DateTime.utc_now(), -600, :second)) end)
          poll(owner)
      end

      {_, stopping, stop} = operation(:stop)
      assert Lifecycle.occupied?(:sys.get_state(owner).environment_entries["first"])
      refute_receive {:agent_started, "second", _, _}, 0
      refute Map.has_key?(:sys.get_state(owner).blocked, "first")
      refute Map.has_key?(:sys.get_state(owner).retry_attempts, "first")
      stopped(stop, stopping)
      {_, next, _} = operation(:prepare)
      assert next.record.issue_id == "second"

      case unquote(disposition) do
        :input_required ->
          assert Map.has_key?(:sys.get_state(owner).blocked, "first")

        :turn_exhausted ->
          expected = Config.settings!().agent.blocked_state
          assert_receive {:inventory_state_applied, "first", ^expected}, 1_000
          assert {:ok, [parked]} = Tracker.fetch_issues_by_ids(["first"])
          assert parked.state == Config.settings!().agent.blocked_state

        kind when kind in [:exception, :stall] ->
          assert Map.has_key?(:sys.get_state(owner).retry_attempts, "first")

        _ ->
          refute MapSet.member?(:sys.get_state(owner).claimed, "first")
      end
    end
  end

  test "backend reload during prepare stops instead of launching the old backend" do
    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      workspace_root: "/home/user/workspaces",
      worker_environment: environment(),
      max_concurrent_agents: 1,
      agent_backend: "claude"
    )

    ready(config, entry, prepare, owner, tasks)
    {_, stopping, stop} = operation(:stop)
    refute_receive {:agent_started, _, _, _}, 0
    stopped(stop, stopping)
    {_, next, _} = operation(:prepare)
    assert next.backend_module == SymphonyElixir.Agent.Claude
  end

  test "routine inventory preserves an exact healthy current attempt" do
    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", runner, _}, 1_000
    current = :sys.get_state(owner).environment_entries["first"].record
    assert %{queued: true} = Orchestrator.request_refresh(owner)
    discover([current])
    wait_state(owner, &(&1.environment_discovery == :ready))
    assert Process.alive?(runner)
    assert :sys.get_state(owner).running["first"].pid == runner
    refute_receive {:environment_operation, :stop, _, _, _, _}, 0
  end

  test "active state transition during prepare is revalidated before a new attempt" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress", "Review"],
      workspace_root: "/home/user/workspaces",
      worker_environment: environment(),
      max_concurrent_agents: 1
    )

    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    :ok = set_issue_state("first", "Review")
    ready(config, entry, prepare, owner, tasks)
    {_, stopping, stop} = operation(:stop)
    refute_receive {:agent_started, _, _, _}, 0
    stopped(stop, stopping)
    {_, next, _} = operation(:prepare)
    assert next.attempt_id != entry.attempt_id
  end

  test "route loss during prepare cannot launch and retry timers cannot bypass unresolved stop" do
    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    issues([%{issue("first", 1) | dispatchable: false}])
    poll(owner)
    ready(config, entry, prepare, owner, tasks)
    {_, stopping, stop} = operation(:stop)
    token = make_ref()
    :sys.replace_state(owner, fn state -> %{state | retry_attempts: %{"first" => %{attempt: 1, retry_token: token, due_at_ms: 0, identifier: "TEST-first"}}} end)
    send(owner, {:retry_issue, "first", token})
    poll(owner)
    assert Lifecycle.occupied?(:sys.get_state(owner).environment_entries["first"])
    refute_receive {:agent_started, _, _, _}, 0
    stopped(stop, stopping)
  end

  test "first terminal observation survives stop and restart without extending retention" do
    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", _, _}, 1_000
    :ok = set_issue_state("first", "Done")
    poll(owner)
    {_, stopping, stop} = operation(:stop)
    assert is_integer(stopping.record.terminal_observed_at)
    first = stopping.record.terminal_observed_at
    stopped(stop, stopping)
    state = wait_state(owner, &(&1.environment_entries["first"].phase == :stopped))
    retained = state.environment_entries["first"].record
    assert retained.terminal_observed_at == first
    GenServer.stop(owner)
    {replacement, _} = scheduler()
    discover([retained])
    wait_state(replacement, &Map.has_key?(&1.environment_entries, "first"))
    assert :sys.get_state(replacement).environment_entries["first"].record.terminal_observed_at == first
    refute_receive {:environment_operation, :metadata, _, _, _, _}, 0
    refute_receive {:environment_operation, :destroy, _, _, _, _}, 0
  end

  test "expired retained storage is not destroyed when tracker visibility is missing" do
    issues([])
    {owner, _} = scheduler()
    retained = %{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}, terminal_observed_at: 1}
    discover([retained])
    wait_state(owner, &Map.has_key?(&1.environment_entries, "first"))
    poll(owner)
    refute_receive {:environment_operation, :destroy, _, _, _, _}, 0
    assert Orchestrator.snapshot(owner, 1_000).environments != []
  end

  test "completed cleanup marker recovered after restart does not deliberately replay the hook" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: "/home/user/workspaces", worker_environment: environment(), hook_before_remove: "echo cleanup")
    issues([%{issue("first", 1) | state: "Done"}])
    {_owner, _tasks} = scheduler()
    retained = %{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}, terminal_observed_at: 1, metadata: %{"symphony_cleanup_hook_completed" => true}}
    discover([retained])
    {_, destroying, _} = operation(:destroy)
    assert destroying.record.workspace_path == retained.workspace_path
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    refute_receive {:environment_operation, :cleanup_hook, _, _, _, _}, 0
  end

  test "cleanup prepare failure retains storage and reports failure instead of skipping the hook" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: "/home/user/workspaces", worker_environment: environment(), hook_before_remove: "echo cleanup")
    issues([%{issue("first", 1) | state: "Done"}])
    {owner, _} = scheduler()
    retained = %{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}, terminal_observed_at: 1}
    discover([retained])
    {_, entry, prepare} = operation(:prepare)
    send(prepare, {:complete_operation, {:error, {:unknown, :startup_timeout}, entry.record}})
    {_, stopping, stop} = operation(:stop)
    stopped(stop, stopping)
    wait_state(owner, &(&1.environment_entries["first"].phase == :stopped))
    poll(owner)
    refute_receive {:environment_operation, :destroy, _, _, _, _}, 0
    refute_receive {:environment_operation, :cleanup_hook, _, _, _, _}, 0
    assert [%{unresolved: %{category: :unknown}}] = Orchestrator.snapshot(owner, 1_000).environments
  end

  test "tracker kind reload cannot reinterpret retained opaque issue identities" do
    issues([])
    {owner, _} = scheduler()
    discover([%{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}}])
    wait_state(owner, &Map.has_key?(&1.environment_entries, "first"))
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", workspace_root: "/home/user/workspaces", worker_environment: environment())
    assert {:error, :environment_identity_in_use} = WorkflowStore.force_reload()
    assert Config.settings!().tracker.kind == "memory"
  end

  test "empty inventory releases identity and the next allocation reacquires current protection" do
    issues([])
    {owner, tasks} = scheduler()
    discover([])
    wait_state(owner, &(&1.environment_discovery == :ready and is_nil(&1.environment_guard)))
    new_environment = Map.put(environment(), "deployment_id", "next-deployment")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      workspace_root: "/home/user/workspaces",
      worker_environment: new_environment,
      max_concurrent_agents: 1
    )

    issues([issue("first", 1)])
    poll(owner)
    discover([])
    {config, entry, prepare} = operation(:prepare)
    assert entry.record.deployment_id == "next-deployment"
    assert is_reference(:sys.get_state(owner).environment_guard)
    ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", _, _}, 1_000
  end

  test "a replaced same-identity authority cannot allocate with its stale token" do
    issues([])
    {owner, _} = scheduler()
    discover([%{record("retained") | phase: :stopped, proof: {:quiescent, %{fixture: true}}}])
    wait_state(owner, &Map.has_key?(&1.environment_entries, "retained"))
    {:ok, replacement} = WorkflowStore.protect_environment(SymphonyElixir.ExecutionEnvironment.Config.identity(Config.settings!()))
    release_guard_on_exit(replacement)
    issues([issue("first", 1)])
    poll(owner)
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    assert {:error, :authority_replaced} = :sys.get_state(owner).environment_discovery
    assert :sys.get_state(WorkflowStore).environment_guard.token == replacement
  end

  test "running and reserved entries count as a union rather than double charging a managed agent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      workspace_root: "/home/user/workspaces",
      worker_environment: environment(),
      max_concurrent_agents: 2
    )

    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", _, _}, 1_000
    issues([issue("first", 1), issue("second", 2)])
    poll(owner)
    {_, next, _} = operation(:prepare)
    assert next.record.issue_id == "second"
  end

  test "per-state capacity includes preparation and stopping reservations" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      workspace_root: "/home/user/workspaces",
      worker_environment: environment(),
      max_concurrent_agents: 2,
      max_concurrent_agents_by_state: %{"In Progress" => 1}
    )

    issues([issue("first", 1), issue("second", 2)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    poll(owner)
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", runner, _}, 1_000
    send(runner, :finish_agent)
    {_, stopping, stop} = operation(:stop)
    poll(owner)
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    :ok = set_issue_state("first", "In Review")
    stopped(stop, stopping)
    {_, second, _} = operation(:prepare)
    assert second.record.issue_id == "second"
  end

  test "prepare task DOWN is uncertainty and requires a stop before retry" do
    issues([issue("first", 1), issue("second", 2)])
    {owner, _tasks} = scheduler()
    discover([])
    {_, _entry, prepare} = operation(:prepare)
    Process.exit(prepare, :kill)
    {_, stopping, stop} = operation(:stop)
    poll(owner)
    assert Lifecycle.occupied?(:sys.get_state(owner).environment_entries["first"])
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    stopped(stop, stopping)
    {_, second, _} = operation(:prepare)
    assert second.record.issue_id == "second"
    assert Map.has_key?(:sys.get_state(owner).retry_attempts, "first")
  end

  test "duplicate lifecycle result and DOWN cannot account twice or close the active lease" do
    issues([issue("first", 1)])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    {ref, job} = Enum.find(:sys.get_state(owner).environment_jobs, fn {_, job} -> job.task.pid == prepare end)
    connection = ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", runner, _}, 1_000
    context = :sys.get_state(owner).environment_entries["first"].context
    send(owner, {ref, {job.operation_id, {:ok, context}}})
    send(owner, {:DOWN, ref, :process, prepare, :fixture_duplicate})
    Orchestrator.snapshot(owner, 1_000)
    assert Process.alive?(runner)
    assert :ok = GenServer.call(connection.owner, {:validate_connection, connection.id, connection.target})
    refute_receive {:environment_operation, :stop, _, _, _, _}, 0
  end

  test "unmapped owned inventory fails discovery and never allocates" do
    issues([issue("first", 1)])
    {owner, _} = scheduler()
    discover([%{record("orphan") | issue_id: nil, provider_ref: %{name: "safe-owned-resource"}}])
    wait_state(owner, &match?({:error, _}, &1.environment_discovery))
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    assert {:error, {:unmapped_owned_resource, ["safe-owned-resource"]}} = :sys.get_state(owner).environment_discovery
  end

  test "unknown cleanup hook outcome is stopped without a completed marker or destruction" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: "/home/user/workspaces", worker_environment: environment(), hook_before_remove: "echo cleanup")
    issues([%{issue("first", 1) | state: "Done"}])
    {owner, tasks} = scheduler()
    discover([%{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}, terminal_observed_at: 1}])
    {config, cleanup, prepare} = operation(:prepare)
    ready(config, cleanup, prepare, owner, tasks)
    {_, hook, task} = operation(:cleanup_hook)
    send(task, {:complete_operation, {:error, {:managed_execution_unknown, {:remote_command_timeout, "before_remove", 10}}, hook.record}})
    {_, stopping, stop} = operation(:stop)
    refute stopping.record.metadata["symphony_cleanup_hook_completed"]
    refute_receive {:environment_operation, :metadata, _, _, _, _}, 0
    stopped(stop, stopping)
    wait_state(owner, &(&1.environment_entries["first"].phase == :stopped))
    poll(owner)
    refute_receive {:environment_operation, :destroy, _, _, _, _}, 0
  end

  test "reopen during unknown deletion waits for full absence before a fresh environment" do
    issues([%{issue("first", 1) | state: "Done"}])
    {owner, _tasks} = scheduler()
    discover([%{record("first") | phase: :stopped, proof: {:quiescent, %{fixture: true}}, terminal_observed_at: 1}])
    {_, deleting, task} = operation(:destroy)
    :ok = set_issue_state("first", "In Progress")
    send(task, {:complete_operation, {:error, {:unknown, :delete_response_lost}, deleting.record}})
    wait_state(owner, &(&1.environment_entries["first"].phase == :unknown))
    poll(owner)
    {_, inspection, inspect_task} = operation(:inspect)
    send(inspect_task, {:complete_operation, {:ok, inspection.record}})
    {_, deleting, task} = operation(:destroy)
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    send(task, {:complete_operation, {:ok, %{deleting.record | absent?: true, pending: []}}})
    discover([])
    {_, fresh, _} = operation(:prepare)
    assert fresh.record.terminal_observed_at == nil
    assert fresh.record.template_identity == nil
    assert fresh.attempt_id != deleting.attempt_id
  end

  test "unknown startup inventory blocks allocation and retains its publication guard" do
    issues([issue("first", 1)])
    {owner, _tasks} = scheduler()
    assert_receive {:environment_operation, :discover, _, nil, task, _}, 1_000
    send(task, {:complete_operation, {:error, {:unknown, :inventory_unreachable}}})
    wait_state(owner, &match?({:error, _}, &1.environment_discovery))
    assert is_reference(:sys.get_state(owner).environment_guard)
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
  end

  test "a successful claim-time transition is the prepare revalidation baseline" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      workspace_root: "/home/user/workspaces",
      worker_environment: environment(),
      max_concurrent_agents: 1
    )

    issues([%{issue("first", 1) | state: "Todo"}])
    {owner, tasks} = scheduler()
    discover([])
    {config, entry, prepare} = operation(:prepare)
    assert_receive {:inventory_state_applied, "first", "In Progress"}, 1_000
    ready(config, entry, prepare, owner, tasks)
    assert_receive {:agent_started, "first", _, _}, 1_000
    refute_receive {:environment_operation, :stop, _, _, _, _}, 0
  end

  test "startup reservations without durable state metadata still respect per-state capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      workspace_root: "/home/user/workspaces",
      worker_environment: environment(),
      max_concurrent_agents: 2,
      max_concurrent_agents_by_state: %{"In Progress" => 1}
    )

    issues([issue("first", 1), issue("second", 2)])
    {owner, _tasks} = scheduler()
    discover([%{record("first") | issue_state: nil}])
    {_, stopping, stop} = operation(:stop)
    poll(owner)
    refute_receive {:environment_operation, :prepare, _, _, _, _}, 0
    :ok = set_issue_state("first", "In Review")
    stopped(stop, stopping)
    {_, next, _} = operation(:prepare)
    assert next.record.issue_id == "second"
  end

  test "OTP state diagnostics cannot inspect captured provider config or raw failure terms" do
    sentinel = "PRIVATE-CONNECTION-MATERIAL"
    entry = %{Lifecycle.new(record("first"), "attempt", :agent) | last_error: {:stop, {:unknown, %{authorization: sentinel}}}}
    state = %Orchestrator.State{environment_config: %{provider: %{"token" => sentinel}}, environment_entries: %{"first" => entry}}
    refute inspect(state) =~ sentinel
    refute inspect(entry) =~ sentinel
  end

  test "inventory refresh recovers provider identity lost with a preparing task" do
    issues([issue("first", 1)])
    {owner, _tasks} = scheduler()
    discover([])
    {_, entry, prepare} = operation(:prepare)
    Process.exit(prepare, :kill)
    {_, stopping, stop} = operation(:stop)
    send(stop, {:complete_operation, {:error, {:invalid, :missing_captured_identity}, stopping.record}})
    wait_state(owner, &(&1.environment_entries["first"].phase == :unknown))
    Orchestrator.request_refresh(owner)
    recovered = %{entry.record | template_identity: "created-template", provider_ref: %{name: "safe-created-resource", uid: "created-uid"}, version: "recovered-version", phase: :running}
    discover([recovered])
    {_, inspection, inspect_task} = operation(:inspect)
    send(inspect_task, {:complete_operation, {:ok, inspection.record}})
    {_, stopping, stop} = operation(:stop)
    # The provider only accepts the recovered ownership and version preconditions.
    refute_receive {:agent_started, _, _, _}, 0

    if stopping.record.provider_ref == recovered.provider_ref and stopping.record.version == recovered.version and stopping.record.template_identity == recovered.template_identity do
      stopped(stop, stopping)
    else
      send(stop, {:complete_operation, {:error, {:invalid, :ownership_unproven}, stopping.record}})
    end

    wait_state(owner, &Map.has_key?(&1.retry_attempts, "first"))
    refute Lifecycle.occupied?(:sys.get_state(owner).environment_entries["first"])
  end

  defp wait_state(owner, predicate), do: wait_state(owner, predicate, System.monotonic_time(:millisecond) + 1_000)

  defp wait_state(owner, predicate, deadline) do
    state = :sys.get_state(owner)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "controlled scheduler transition did not complete"
      wait_state(owner, predicate, deadline)
    end
  end

  defp scheduler do
    parent = self()
    tasks = start_supervised!({Task.Supervisor, []}, id: make_ref())

    operation_fun = fn _adapter, config, entry, operation, opts ->
      send(parent, {:environment_operation, operation, config, entry, self(), opts})

      receive do
        {:complete_operation, result} -> result
      end
    end

    runner_fun = fn issue, _recipient, opts ->
      send(parent, {:agent_started, issue.id, self(), opts})

      receive do
        :finish_agent -> :ok
        {:fail_agent, reason} -> exit(reason)
      end
    end

    owner =
      start_supervised!(Supervisor.child_spec({Orchestrator, name: nil, task_supervisor: tasks, environment_operation_fun: operation_fun, runner_fun: runner_fun}, restart: :temporary), id: make_ref())

    state = wait_state(owner, fn state -> state.poll_check_in_progress == false and state.next_poll_due_at_ms > System.monotonic_time(:millisecond) end)
    release_guard_on_exit(state.environment_guard)
    {owner, tasks}
  end

  defp discover(records) do
    assert_receive {:environment_operation, :discover, _, nil, task, _}, 1_000
    send(task, {:complete_operation, {:ok, records}})
  end

  defp operation(kind) do
    assert_receive {:environment_operation, ^kind, config, entry, task, opts}, 1_000
    release_guard_on_exit(:sys.get_state(opts[:authority]).environment_guard)
    {config, entry, task}
  end

  defp release_guard_on_exit(token) when is_reference(token) do
    on_exit({:environment_guard, token}, fn ->
      # The simulated inventory lives only in these private tasks/messages. ExUnit
      # has stopped their supervisors before this callback releases its exact token.
      WorkflowStore.release_environment(token, :empty_inventory)
    end)
  end

  defp release_guard_on_exit(_token), do: :ok

  defp ready(config, entry, task, authority, tasks) do
    target = %SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "controlled-worker"}
    {:ok, connection} = Operations.open_connection(tasks, authority, target, [])
    record = %{entry.record | phase: :running, template_identity: "fixture-template", attempt_id: entry.attempt_id}
    context = ExecutionContext.managed(config, record, connection)
    send(task, {:complete_operation, {:ok, context}})
    connection
  end

  defp stopped(task, entry) do
    send(task, {:complete_operation, {:ok, %{entry.record | phase: :stopped, desired: :stopped, pending: [], proof: {:quiescent, %{fixture: true}}}}})
  end

  defp poll(owner) do
    send(owner, :run_poll_cycle)
    Orchestrator.snapshot(owner, 1_000)
  end

  defp issues(issues), do: GenServer.call(Process.get({__MODULE__, :inventory}), {:replace, issues})

  defp set_issue_state(id, state_name) do
    :ok = Tracker.Memory.update_issue_state(id, state_name)
    assert_receive {:inventory_state_applied, ^id, ^state_name}, 1_000
    :ok
  end

  defp issue(id, priority), do: %Issue{id: id, identifier: "TEST-#{id}", title: id, state: "In Progress", priority: priority, dispatchable: true}

  defp record(id) do
    %Record{
      key: ExecutionEnvironment.resource_key("deployment", "memory", id),
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: id,
      issue_identifier: "TEST-#{id}",
      issue_state: "In Progress",
      kind: "google_workstations",
      scope: %{"project" => "p", "location" => "l", "cluster" => "c"},
      workspace_path: "/home/user/workspaces/#{id}",
      template_identity: "fixture-template",
      attempt_id: "previous-attempt"
    }
  end

  defp environment do
    %{
      "kind" => "google_workstations",
      "deployment_id" => "deployment",
      "startup_timeout_ms" => 10_000,
      "shutdown_timeout_ms" => 10_000,
      "terminal_retention_ms" => 60_000,
      "provider" => %{
        "project" => "p",
        "location" => "l",
        "cluster" => "c",
        "config" => "cfg",
        "credential_configuration" => "deploy",
        "impersonate_service_account" => "sa@example.com",
        "ssh_user" => "user"
      }
    }
  end
end
