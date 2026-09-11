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
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Restart-safe prompt")
    store = Process.whereis(WorkflowStore)
    parent = self()
    :ok = :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      if is_nil(Process.whereis(WorkflowStore)), do: Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    end)

    {reader, read_monitor} = spawn_monitor(fn -> send(parent, {:workflow_read, WorkflowStore.current()}) end)
    {reloader, reload_monitor} = spawn_monitor(fn -> send(parent, {:reload_check, WorkflowStore.force_reload()}) end)
    wait_for_store_requests(store, System.monotonic_time(:millisecond) + 1_000)
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert_receive {:workflow_read, {:ok, %{prompt: "Restart-safe prompt"}}}, 1_000
    assert_receive {:reload_check, :ok}, 1_000
    assert_receive {:DOWN, ^read_monitor, :process, ^reader, :normal}, 1_000
    assert_receive {:DOWN, ^reload_monitor, :process, ^reloader, :normal}, 1_000
    assert {:ok, _replacement} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Restart-safe prompt"}} = WorkflowStore.current()
  end

  defp wait_for_store_requests(store, deadline) do
    {:messages, messages} = Process.info(store, :messages)
    queued = Enum.count(messages, &workflow_request?/1)

    if queued == 2 do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "workflow requests did not reach the suspended store"
      Process.sleep(1)
      wait_for_store_requests(store, deadline)
    end
  end

  defp workflow_request?({:"$gen_call", _, operation}) when operation in [:current, :force_reload], do: true
  defp workflow_request?(_message), do: false
end
