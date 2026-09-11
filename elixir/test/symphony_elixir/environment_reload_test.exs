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
    owner = spawn(fn ->
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
end
