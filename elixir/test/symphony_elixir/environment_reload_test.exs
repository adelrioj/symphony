defmodule SymphonyElixir.EnvironmentReloadTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.WorkflowStore

  setup do
    original = :sys.get_state(WorkflowStore)
    on_exit(fn -> :sys.replace_state(WorkflowStore, fn _ -> original end) end)
    :ok
  end

  test "guard survives acquiring owner death and only newest token releases it" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, token} = WorkflowStore.protect_environment(nil)
        send(parent, {:guard, token})
      end)

    monitor = Process.monitor(owner)
    assert_receive {:guard, old}
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    assert {:error, :environment_identity_in_use} = WorkflowStore.protect_environment("different")
    assert {:ok, current} = WorkflowStore.protect_environment(nil)
    assert {:error, :invalid_environment_guard} = WorkflowStore.release_environment(old, :empty_inventory)
    assert :ok = WorkflowStore.release_environment(current, :empty_inventory)
  end

  test "settings and force reload atomically retain publication behind a held identity" do
    {:ok, original} = WorkflowStore.settings()
    {:ok, token} = WorkflowStore.protect_environment(EnvironmentConfig.identity(original))
    # Task6 has not attached the public managed schema. Inject the guarded identity
    # to exercise publication rejection, without claiming managed YAML integration.
    :sys.replace_state(WorkflowStore, fn state -> %{state | environment_guard: %{identity: "managed-scope", token: token}} end)
    path = Workflow.workflow_file_path()
    File.write!(path, File.read!(path) <> "\nCandidate prompt\n")
    assert {:ok, ^original} = WorkflowStore.settings()
    assert {:error, :environment_identity_in_use} = WorkflowStore.force_reload()
    assert :ok = WorkflowStore.release_environment(token, :empty_inventory)
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt =~ "Candidate prompt"
  end

  test "workflow reads and reload checks survive the store dying with requests already queued" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Restart-safe prompt", max_concurrent_agents: 7)
    store = Process.whereis(WorkflowStore)
    parent = self()
    :ok = :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      if is_nil(Process.whereis(WorkflowStore)), do: Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    end)

    {reader, read_monitor} = spawn_monitor(fn -> send(parent, {:workflow_read, WorkflowStore.current()}) end)
    {reloader, reload_monitor} = spawn_monitor(fn -> send(parent, {:reload_check, WorkflowStore.force_reload()}) end)

    {settings_reader, settings_monitor} =
      spawn_monitor(fn -> send(parent, {:settings_read, WorkflowStore.settings()}) end)

    requests = [{reader, :current}, {reloader, :force_reload}, {settings_reader, :settings}]
    wait_for_store_requests(store, requests, System.monotonic_time(:millisecond) + 1_000)
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert_receive {:workflow_read, {:ok, %{prompt: "Restart-safe prompt"}}}, 1_000
    assert_receive {:reload_check, :ok}, 1_000
    assert_receive {:settings_read, {:ok, %{agent: %{max_concurrent_agents: 7}}}}, 1_000
    assert_receive {:DOWN, ^read_monitor, :process, ^reader, :normal}, 1_000
    assert_receive {:DOWN, ^reload_monitor, :process, ^reloader, :normal}, 1_000
    assert_receive {:DOWN, ^settings_monitor, :process, ^settings_reader, :normal}, 1_000
    assert {:ok, _replacement} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Restart-safe prompt"}} = WorkflowStore.current()
  end

  defp wait_for_store_requests(store, requests, deadline) do
    {:messages, messages} = Process.info(store, :messages)
    queued = for {:"$gen_call", {caller, _}, operation} <- messages, do: {caller, operation}

    if Enum.all?(requests, &(&1 in queued)) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "workflow requests did not reach the suspended store"
      Process.sleep(1)
      wait_for_store_requests(store, requests, deadline)
    end
  end
end
