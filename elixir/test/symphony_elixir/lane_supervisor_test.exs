defmodule SymphonyElixir.LaneSupervisorTest do
  use ExUnit.Case
  alias SymphonyElixir.{LaneRegistry, Lanes, LaneStore, LaneSupervisor, Orchestrator, Runs, TestSupport}
  alias SymphonyElixir.Tracker.Issue

  @linear """
  tracker:
    kind: linear
    api_key: test-key
    active_states: [Todo]
    terminal_states: [Done]
    provider:
      team_keys: [TEAM]
  polling:
    interval_ms: 60000
  """
  @memory "tracker:\n  kind: memory\npolling:\n  interval_ms: 60000"

  setup do
    TestSupport.reset_lanes!()
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_owner = Application.get_env(:symphony_elixir, :lane_preflight_test_owner)
    Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.BlockingClient)
    Application.put_env(:symphony_elixir, :lane_preflight_test_owner, self())

    on_exit(fn ->
      TestSupport.reset_lanes!()
      restore(:linear_client_module, previous_client)
      restore(:lane_preflight_test_owner, previous_owner)
    end)

    :ok
  end

  test "unknown runtime operations are safe" do
    refute LaneSupervisor.running?(123)
    assert :ok = LaneSupervisor.stop_lane(123)
  end

  test "enabling starts a real lane runtime only after actual tracker preflight succeeds" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "passing", front_matter: @linear})
    assert {:ok, %{enabled: true}} = Lanes.set_enabled(lane, true)
    assert_receive {:preflight, worker}, 1000
    refute LaneSupervisor.running?(lane.id)
    finish_preflight(worker, success())
    eventually(fn -> LaneSupervisor.running?(lane.id) end)
    orchestrator = LaneRegistry.whereis(lane.id, :orchestrator)
    assert %{} = Orchestrator.snapshot(orchestrator, 1000)
    eventually(fn -> match?({:ok, %{runtime: %{started_at: %DateTime{}}}}, LaneStore.lookup(lane.id)) end)
    attempt_id = "disable-#{System.unique_integer([:positive])}"
    Runs.started(%{lane_id: lane.id, issue: %Issue{id: "issue-disable", identifier: "TEAM-1", state: "Todo"}, attempt_id: attempt_id, owner_pid: orchestrator})
    assert %{status: "running"} = Runs.get_by_attempt(attempt_id)
    assert :ok = Lanes.disable(lane.id, "explicit stop")
    refute LaneSupervisor.running?(lane.id)
    assert {:ok, %{enabled: false, runtime: %{started_at: nil}}} = LaneStore.lookup(lane.id)
    assert %{status: "stopped"} = Runs.get_by_attempt(attempt_id)
  end

  test "actual preflight transport failure disables persisted lane and exposes the reason" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "failing", front_matter: @linear, enabled: true})
    assert_receive {:preflight, worker}, 1000
    finish_preflight(worker, {:error, :transport_down})
    refute Lanes.get!(lane.id).enabled
    assert {:ok, %{enabled: false, error: message}} = LaneStore.lookup(lane.id)
    assert message =~ "Tracker preflight failed"
    assert message =~ "transport_down"
    refute LaneSupervisor.running?(lane.id)
  end

  test "invalid tracker scope disables the lane with actionable provider reasons" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "invalid-scope", front_matter: @linear, enabled: true})
    assert_receive {:preflight, worker}, 1000
    finish_preflight(worker, {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}})
    refute Lanes.get!(lane.id).enabled
    assert {:ok, %{enabled: false, error: message}} = LaneStore.lookup(lane.id)
    assert message =~ "TEAM"
    refute LaneSupervisor.running?(lane.id)
  end

  test "raised and thrown preflight failures fail closed without poisoning later enable attempts" do
    owner = Process.whereis(LaneStore)
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "preflight-exceptions", front_matter: @linear, enabled: true})
    assert_receive {:preflight, raising_worker}, 1000
    finish_preflight(raising_worker, {:raise, "credential refresh failed"})
    refute Lanes.get!(lane.id).enabled
    assert {:ok, %{error: message}} = LaneStore.lookup(lane.id)
    assert message =~ "credential refresh failed"
    refute LaneSupervisor.running?(lane.id)

    assert {:ok, _} = Lanes.set_enabled(lane, true)
    assert_receive {:preflight, throwing_worker}, 1000
    finish_preflight(throwing_worker, {:throw, :credential_expired})
    refute Lanes.get!(lane.id).enabled
    assert {:ok, %{error: message}} = LaneStore.lookup(lane.id)
    assert message =~ "credential_expired"
    refute LaneSupervisor.running?(lane.id)
    assert Process.whereis(LaneStore) == owner

    assert {:ok, _} = Lanes.set_enabled(lane, true)
    assert_receive {:preflight, repaired_worker}, 1000
    finish_preflight(repaired_worker, success())
    assert %{} = Orchestrator.snapshot(LaneRegistry.whereis(lane.id, :orchestrator), 1000)
    assert {:ok, %{enabled: true, error: nil}} = LaneStore.lookup(lane.id)
  end

  test "registry outage fails runtime startup closed and registration recovers on explicit reenable" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "registry-recovery", front_matter: @memory})
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, LaneRegistry)

    try do
      assert {:ok, _} = Lanes.set_enabled(lane, true)
      eventually(fn -> match?({:ok, %{enabled: false, error: error}} when is_binary(error), LaneStore.lookup(lane.id)) end)
      refute Lanes.get!(lane.id).enabled
      assert {:ok, %{error: message}} = LaneStore.lookup(lane.id)
      assert message =~ "runtime failed to start"
      refute LaneSupervisor.running?(lane.id)
      assert is_nil(LaneRegistry.whereis(lane.id, :orchestrator))

      assert {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, LaneRegistry)
      assert {:ok, _} = Lanes.set_enabled(lane, true)
      eventually(fn -> match?({:ok, %{runtime: %{started_at: %DateTime{}}}}, LaneStore.lookup(lane.id)) end)
      assert %{} = Orchestrator.snapshot(LaneRegistry.whereis(lane.id, :orchestrator), 1000)
      assert {:ok, %{enabled: true, error: nil}} = LaneStore.lookup(lane.id)
    after
      Supervisor.restart_child(SymphonyElixir.Supervisor, LaneRegistry)
    end
  end

  test "a stale failing preflight cannot disable a newer valid version" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "stale-failure", front_matter: @linear, enabled: true})
    assert_receive {:preflight, old_worker}, 1000
    {:ok, current} = TestSupport.update_lane_from_front_matter(lane, %{front_matter: @memory, prompt: "new version"})
    eventually(fn -> LaneSupervisor.running?(lane.id) end)
    finish_preflight(old_worker, {:error, :old_scope_failed})
    assert Lanes.get!(lane.id).enabled
    assert {:ok, %{version_id: version_id, error: nil}} = LaneStore.lookup(lane.id)
    assert version_id == current.current_version_id
    assert LaneSupervisor.running?(lane.id)
  end

  test "pending tracker failure survives metadata and prompt saves on an already running lane" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "pending-save", front_matter: @memory, enabled: true})
    eventually(fn -> LaneSupervisor.running?(lane.id) end)
    original_runtime = LaneRegistry.whereis(lane.id, :runtime)
    {:ok, _} = TestSupport.update_lane_from_front_matter(lane, %{front_matter: @linear})
    assert_receive {:preflight, tracker_worker}, 1000
    {:ok, _} = Lanes.update(lane, %{name: "Renamed while checking"})
    assert_receive {:preflight, metadata_worker}, 1000
    {:ok, current} = Lanes.update(lane, %{prompt: "Saved while checking"})
    assert_receive {:preflight, prompt_worker}, 1000
    finish_preflight(tracker_worker, success())
    finish_preflight(metadata_worker, success())
    assert Lanes.get!(lane.id).enabled
    assert LaneRegistry.whereis(lane.id, :runtime) == original_runtime
    finish_preflight(prompt_worker, {:error, :replacement_tracker_unavailable})
    refute Lanes.get!(lane.id).enabled
    refute LaneSupervisor.running?(lane.id)

    assert {:ok,
            %{
              version_id: version_id,
              name: "Renamed while checking",
              workflow: %{prompt: "Saved while checking"},
              error: error
            }} = LaneStore.lookup(lane.id)

    assert version_id == current.current_version_id
    assert error =~ "replacement_tracker_unavailable"
  end

  test "queued explicit stop during runtime startup does not consume crash allowance after reenable" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "queued-stop", front_matter: @linear, enabled: true})
    assert_receive {:preflight, worker}, 1000
    :ok = :sys.suspend(LaneSupervisor)

    try do
      monitor = Process.monitor(worker)
      send(worker, {:preflight_reply, success()})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1000
      eventually(fn -> queued_call?(LaneSupervisor, fn request -> match?({:start_child, _}, request) end) end)
      stopper = Task.async(fn -> LaneSupervisor.stop_lane(lane.id) end)
      eventually(fn -> queued_call?(LaneStore, &(&1 == {:stop_runtime, lane.id})) end)
      :ok = :sys.resume(LaneSupervisor)
      assert :ok = Task.await(stopper)
    after
      :sys.resume(LaneSupervisor)
    end

    :sys.get_state(LaneStore)

    eventually(fn ->
      {:ok, entry} = LaneStore.lookup(lane.id)
      is_nil(entry.runtime.started_at) or entry.runtime.restarts > 0
    end)

    refute LaneSupervisor.running?(lane.id)
    assert {:ok, %{enabled: false, runtime: %{started_at: nil, restarts: 0, last_crash: nil}}} = LaneStore.lookup(lane.id)

    {:ok, _} = Lanes.set_enabled(lane, true)
    assert_receive {:preflight, replacement_worker}, 1000
    finish_preflight(replacement_worker, success())
    assert %{} = Orchestrator.snapshot(LaneRegistry.whereis(lane.id, :orchestrator), 1000)
    Process.exit(LaneRegistry.whereis(lane.id, :runtime), :kill)
    eventually(fn -> match?({:ok, %{runtime: %{restarts: 1}}}, LaneStore.lookup(lane.id)) end)
    assert Lanes.get!(lane.id).enabled
    assert :ok = Lanes.disable(lane.id, "test complete")
  end

  test "normal runtime shutdown clears health without counting a crash" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "normal-stop", front_matter: @memory, enabled: true})
    eventually(fn -> match?({:ok, %{runtime: %{started_at: %DateTime{}}}}, LaneStore.lookup(lane.id)) end)
    runtime = LaneRegistry.whereis(lane.id, :runtime)
    assert :ok = Supervisor.stop(runtime, :normal)
    eventually(fn -> match?({:ok, %{runtime: %{started_at: nil}}}, LaneStore.lookup(lane.id)) end)
    assert {:ok, %{runtime: %{restarts: 0, last_crash: nil}}} = LaneStore.lookup(lane.id)
    refute LaneSupervisor.running?(lane.id)
  end

  test "a stale successful preflight cannot start a newer generation still awaiting preflight" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "stale-success", front_matter: @linear, enabled: true})
    assert_receive {:preflight, old_worker}, 1000
    {:ok, _} = Lanes.update(lane, %{prompt: "second"})
    assert_receive {:preflight, new_worker}, 1000
    finish_preflight(old_worker, success())
    refute LaneSupervisor.running?(lane.id)
    finish_preflight(new_worker, {:error, :new_scope_failed})
    refute Lanes.get!(lane.id).enabled
    refute LaneSupervisor.running?(lane.id)
  end

  test "disable then reenable fences the prior generation even with the same version ID" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "toggle", front_matter: @linear, enabled: true})
    assert_receive {:preflight, old_worker}, 1000
    assert {:ok, _} = Lanes.set_enabled(lane, false)
    assert {:ok, _} = Lanes.set_enabled(lane, true)
    assert_receive {:preflight, new_worker}, 1000
    finish_preflight(old_worker, success())
    refute LaneSupervisor.running?(lane.id)
    finish_preflight(new_worker, success())
    eventually(fn -> LaneSupervisor.running?(lane.id) end)
    assert Lanes.get!(lane.id).enabled
  end

  test "disabled and deleted lanes cannot be resurrected by pending enable success" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "deleted", front_matter: @linear, enabled: true})
    assert_receive {:preflight, worker}, 1000
    assert {:ok, _} = Lanes.set_enabled(lane, false)
    assert :ok = Lanes.delete(lane)
    finish_preflight(worker, success())
    assert :error = LaneStore.lookup(lane.id)
    refute LaneSupervisor.running?(lane.id)
    assert is_nil(Lanes.get(lane.id))
  end

  test "five real runtime deaths stop only the failing lane and persist the disabled state" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "crash-loop", front_matter: @memory, enabled: true})
    {:ok, healthy} = TestSupport.create_lane_from_front_matter(%{slug: "healthy", front_matter: @memory, enabled: true})
    eventually(fn -> LaneSupervisor.running?(healthy.id) end)
    healthy_pid = LaneRegistry.whereis(healthy.id, :runtime)

    for n <- 1..5 do
      eventually(fn -> LaneSupervisor.running?(lane.id) end, 250)
      eventually(fn -> match?({:ok, %{runtime: %{started_at: %DateTime{}}}}, LaneStore.lookup(lane.id)) end)
      Process.exit(LaneRegistry.whereis(lane.id, :runtime), :kill)
      eventually(fn -> match?({:ok, %{runtime: %{restarts: ^n}}}, LaneStore.lookup(lane.id)) end)
    end

    refute Lanes.get!(lane.id).enabled
    assert {:ok, %{enabled: false, error: message}} = LaneStore.lookup(lane.id)
    assert message =~ "crashed repeatedly"
    refute LaneSupervisor.running?(lane.id)
    assert LaneRegistry.whereis(healthy.id, :runtime) == healthy_pid
    assert %{} = Orchestrator.snapshot(LaneRegistry.whereis(healthy.id, :orchestrator), 1000)
  end

  test "authority recovery replaces stale runtime ownership and completes orphaned runs" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "recovery", front_matter: @memory, enabled: true})
    eventually(fn -> LaneSupervisor.running?(lane.id) end)
    old_runtime = LaneRegistry.whereis(lane.id, :runtime)
    attempt_id = "orphan-#{System.unique_integer([:positive])}"
    Runs.started(%{lane_id: lane.id, issue: %Issue{id: "issue-orphan", identifier: "TEAM-2", state: "Todo"}, attempt_id: attempt_id})
    assert %{status: "running"} = Runs.get_by_attempt(attempt_id)
    assert {:ok, _} = TestSupport.update_lane_from_front_matter(lane, %{front_matter: @linear})
    assert_receive {:preflight, old_worker}, 1000
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, LaneStore)
    assert {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, LaneStore)
    assert_receive {:preflight, replacement_worker}, 1000
    finish_preflight(old_worker, {:error, :old_authority_failure})
    assert Lanes.get!(lane.id).enabled
    refute LaneSupervisor.running?(lane.id)
    finish_preflight(replacement_worker, success())

    eventually(fn ->
      pid = LaneRegistry.whereis(lane.id, :runtime)
      is_pid(pid) and pid != old_runtime
    end)

    refute Process.alive?(old_runtime)
    Runs.flush()
    assert %{status: "failed"} = Runs.get_by_attempt(attempt_id)
    assert %{} = Orchestrator.snapshot(LaneRegistry.whereis(lane.id, :orchestrator), 1000)
    eventually(fn -> match?({:ok, %{runtime: %{started_at: %DateTime{}}}}, LaneStore.lookup(lane.id)) end)
  end

  test "disabling a crashed lane fences its queued restart" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "cancel-restart", front_matter: @memory, enabled: true})
    eventually(fn -> LaneSupervisor.running?(lane.id) end)
    runtime = LaneRegistry.whereis(lane.id, :runtime)
    monitor = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :killed}, 1_000

    eventually(fn ->
      {:ok, entry} = LaneStore.lookup(lane.id)
      entry.runtime.crashes != []
    end)

    assert {:ok, %{enabled: false}} = Lanes.set_enabled(Lanes.get!(lane.id), false)
    Process.sleep(1_100)
    :sys.get_state(LaneStore)
    refute LaneSupervisor.running?(lane.id)
    refute Lanes.get!(lane.id).enabled
  end

  test "authority recovery monitors a runtime created by the old authority's queued start" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "late-start-recovery", front_matter: @memory})
    supervisor = Process.whereis(LaneSupervisor)
    old_store = Process.whereis(LaneStore)
    :ok = :sys.suspend(supervisor)

    try do
      assert {:ok, %{enabled: true}} = Lanes.set_enabled(lane, true)
      eventually(fn -> queued_start?(supervisor, old_store) end)
      refute LaneSupervisor.running?(lane.id)
      {:ok, old_entry} = LaneStore.lookup(lane.id)
      monitor = Process.monitor(old_store)
      Process.exit(old_store, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^old_store, :killed}, 1000

      eventually(fn ->
        replacement_store = Process.whereis(LaneStore)
        is_pid(replacement_store) and replacement_store != old_store and queued_start?(supervisor, replacement_store)
      end)

      {:ok, recovered_entry} = LaneStore.lookup(lane.id)
      refute recovered_entry.generation == old_entry.generation
      refute LaneSupervisor.running?(lane.id)
      # Both real start_child calls are queued: the dead caller's request wins,
      # and the current authority must adopt its already-started runtime.
      :ok = :sys.resume(supervisor)
      :sys.get_state(LaneStore)
      runtime = LaneRegistry.whereis(lane.id, :runtime)
      assert is_pid(runtime)
      runtime_monitor = Process.monitor(runtime)

      # One scheduler crash is handled locally. Exhaust that supervisor's real
      # restart allowance so recovery must come from the replacement LaneStore.
      Enum.reduce(1..4, nil, fn _, previous_scheduler ->
        eventually(fn ->
          scheduler = LaneRegistry.whereis(lane.id, :orchestrator)
          is_pid(scheduler) and scheduler != previous_scheduler
        end)

        scheduler = LaneRegistry.whereis(lane.id, :orchestrator)
        assert %{} = Orchestrator.snapshot(scheduler, 1000)
        scheduler_monitor = Process.monitor(scheduler)
        Process.exit(scheduler, :kill)
        assert_receive {:DOWN, ^scheduler_monitor, :process, ^scheduler, :killed}, 1000
        scheduler
      end)

      assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, 1000

      eventually(
        fn ->
          replacement_runtime = LaneRegistry.whereis(lane.id, :runtime)
          scheduler = LaneRegistry.whereis(lane.id, :orchestrator)
          is_pid(replacement_runtime) and replacement_runtime != runtime and is_pid(scheduler)
        end,
        250
      )

      assert %{} = Orchestrator.snapshot(LaneRegistry.whereis(lane.id, :orchestrator), 1000)
      assert {:ok, %{enabled: true, error: nil}} = LaneStore.lookup(lane.id)
      assert Lanes.get!(lane.id).enabled
    after
      :sys.resume(supervisor)
      TestSupport.ensure_lane_store_started!()
    end
  end

  test "metadata and prompt saves during restoration preserve the recovered runtime" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "visible-late-start", front_matter: @linear})
    {:ok, barrier_lane} = TestSupport.create_lane_from_front_matter(%{slug: "restore-barrier", front_matter: @memory})
    supervisor = Process.whereis(LaneSupervisor)
    old_store = Process.whereis(LaneStore)
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:symphony_elixir, :repo, :query],
        fn _, _, metadata, _ ->
          if self() != old_store and self() == Process.whereis(LaneStore) and metadata.params == [barrier_lane.current_version_id, barrier_lane.id] do
            send(parent, {:restoring_remaining_lane, self()})

            receive do
              :finish_recovery -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        nil
      )

    :ok = :sys.suspend(supervisor)

    try do
      assert {:ok, %{enabled: true}} = Lanes.set_enabled(lane, true)
      assert_receive {:preflight, initial_worker}, 1_000
      send(initial_worker, {:preflight_reply, success()})
      eventually(fn -> queued_start?(supervisor, old_store) end)
      old_monitor = Process.monitor(old_store)
      Process.exit(old_store, :kill)
      assert_receive {:DOWN, ^old_monitor, :process, ^old_store, :killed}, 1_000
      assert_receive {:restoring_remaining_lane, replacement_store}, 1_000
      assert :error = LaneStore.lookup(lane.id)
      refute LaneSupervisor.running?(lane.id)

      :ok = :sys.resume(supervisor)
      :sys.get_state(supervisor)
      send(replacement_store, :finish_recovery)
      :sys.get_state(replacement_store)
      assert Process.whereis(LaneStore) == replacement_store
      assert {:ok, %{enabled: true}} = LaneStore.lookup(lane.id)

      assert_receive {:preflight, recovery_worker}, 1_000
      assert {:ok, _} = Lanes.update(lane, %{name: "Renamed during adoption", prompt: "Saved during adoption"})
      assert_receive {:preflight, replacement_worker}, 1_000
      finish_preflight(recovery_worker, success())
      finish_preflight(replacement_worker, success())
      eventually(fn -> is_pid(LaneRegistry.whereis(lane.id, :runtime)) end)
      runtime = LaneRegistry.whereis(lane.id, :runtime)
      assert %{} = Orchestrator.snapshot(LaneRegistry.whereis(lane.id, :orchestrator), 1_000)

      monitor = Process.monitor(runtime)
      Process.exit(runtime, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^runtime, :killed}, 1_000
      assert_receive {:preflight, restart_worker}, 2_000
      finish_preflight(restart_worker, success())

      eventually(fn ->
        current = LaneRegistry.whereis(lane.id, :runtime)
        scheduler = LaneRegistry.whereis(lane.id, :orchestrator)
        is_pid(current) and current != runtime and is_pid(scheduler)
      end)

      assert %{} = Orchestrator.snapshot(LaneRegistry.whereis(lane.id, :orchestrator), 1_000)
      assert Lanes.get!(lane.id).enabled
    after
      :telemetry.detach(handler)
      :sys.resume(supervisor)
      TestSupport.ensure_lane_store_started!()
    end
  end

  test "failed recovery preflight drains old authority starts before leaving the lane disabled" do
    {:ok, lane} = TestSupport.create_lane_from_front_matter(%{slug: "failed-late-start", front_matter: @linear})
    supervisor = Process.whereis(LaneSupervisor)
    old_store = Process.whereis(LaneStore)
    :ok = :sys.suspend(supervisor)

    try do
      assert {:ok, %{enabled: true}} = Lanes.set_enabled(lane, true)
      assert_receive {:preflight, initial_worker}, 1_000
      send(initial_worker, {:preflight_reply, success()})
      eventually(fn -> queued_start?(supervisor, old_store) end)
      monitor = Process.monitor(old_store)
      Process.exit(old_store, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^old_store, :killed}, 1_000

      assert_receive {:preflight, recovery_worker}, 1_000
      send(recovery_worker, {:preflight_reply, {:error, :transport_down}})
      eventually(fn -> not Lanes.get!(lane.id).enabled end)
      assert {:ok, %{enabled: false}} = LaneStore.lookup(lane.id)

      :ok = :sys.resume(supervisor)
      :sys.get_state(supervisor)
      :sys.get_state(LaneStore)
      refute LaneSupervisor.running?(lane.id)
      assert LaneRegistry.whereis(lane.id, :orchestrator) == nil
      refute Lanes.get!(lane.id).enabled
    after
      :sys.resume(supervisor)
      TestSupport.ensure_lane_store_started!()
    end
  end

  defmodule BlockingClient do
    def graphql(_query, _variables) do
      owner = Application.fetch_env!(:symphony_elixir, :lane_preflight_test_owner)
      send(owner, {:preflight, self()})
      monitor = Process.monitor(owner)

      receive do
        {:preflight_reply, result} ->
          Process.demonitor(monitor, [:flush])

          case result do
            {:raise, message} -> raise message
            {:throw, reason} -> throw(reason)
            reply -> reply
          end

        {:DOWN, ^monitor, :process, ^owner, _} ->
          {:error, :test_owner_gone}
      end
    end

    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issues_by_ids(_ids), do: {:ok, []}
  end

  defp success do
    {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"key" => "TEAM", "states" => %{"nodes" => [%{"name" => "Todo"}, %{"name" => "Done"}]}}]}}}}
  end

  defp finish_preflight(worker, result) do
    monitor = Process.monitor(worker)
    send(worker, {:preflight_reply, result})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1000
    :sys.get_state(LaneStore)
  end

  defp queued_call?(server, matches?) do
    {:messages, messages} = Process.info(Process.whereis(server), :messages)

    Enum.any?(messages, fn
      {:"$gen_call", _from, request} -> matches?.(request)
      _ -> false
    end)
  end

  defp queued_start?(supervisor, caller) do
    {:messages, messages} = Process.info(supervisor, :messages)

    Enum.any?(messages, fn
      {:"$gen_call", {^caller, _tag}, {:start_child, _spec}} -> true
      _ -> false
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never met")

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
