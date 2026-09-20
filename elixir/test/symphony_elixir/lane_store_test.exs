defmodule SymphonyElixir.LaneStoreTest do
  use ExUnit.Case
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{ExecutionProfiles, LaneRegistry, Lanes, LaneStore, Repo, TestSupport, Workflow}
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.Lanes.Lane
  alias SymphonyElixir.LaneStore.Entry
  alias SymphonyElixirWeb.ObservabilityPubSub

  @workflow "---\ntracker:\n  kind: memory\ncodex:\n  command: codex app-server\n---\n\nTest prompt.\n"

  setup do
    TestSupport.reset_lanes!()
    on_exit(fn -> TestSupport.reset_lanes!() end)
    :ok
  end

  test "registry isolates roles and lanes" do
    assert {:via, Registry, {LaneRegistry, {3, :orchestrator}}} = LaneRegistry.via(3, :orchestrator)
    assert is_nil(LaneRegistry.whereis(3, :orchestrator))
    registered = start_supervised!(%{id: :registry_agent, start: {Agent, :start_link, [fn -> :healthy end, [name: LaneRegistry.via(3, :orchestrator)]]}})
    assert LaneRegistry.whereis(3, :orchestrator) == registered
    assert Agent.get(registered, & &1) == :healthy
    assert is_nil(LaneRegistry.whereis(3, :runtime))
    assert is_nil(LaneRegistry.whereis(4, :orchestrator))
  end

  test "file mode serves raw content and parsed settings without reading the database" do
    path = Path.join(System.tmp_dir!(), "lane-store-#{System.unique_integer([:positive])}.md")
    File.write!(path, @workflow)
    replace_store(file: path)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, %Entry{slug: "workflow", settings: %Schema{}} = entry} = LaneStore.lookup(0)
    assert {:ok, %Schema{tracker: %{kind: "memory"}}} = LaneStore.settings(0)
    assert %Schema{} = LaneStore.settings!(0)
    assert {:ok, %{prompt: "Test prompt."}} = LaneStore.workflow(0)
    assert :ok = LaneStore.validate(0)
    assert [^entry] = LaneStore.list()
    assert {:ok, ^entry} = LaneStore.by_slug("workflow")
    assert :error = LaneStore.by_slug("missing")
    assert Workflow.render(entry.front_matter, entry.prompt) == @workflow
    {:ok, token} = LaneStore.protect_environment(0, nil)
    assert :ok = LaneStore.release_environment(0, token, :empty_inventory)
  end

  test "invalid file startup refuses the configuration and missing stores are safe to read" do
    path = Path.join(System.tmp_dir!(), "lane-store-invalid-#{System.unique_integer([:positive])}.md")
    File.write!(path, "---\ntracker: [\n---\n")
    Supervisor.terminate_child(SymphonyElixir.Supervisor, LaneStore)

    on_exit(fn ->
      File.rm(path)
      Supervisor.restart_child(SymphonyElixir.Supervisor, LaneStore)
    end)

    assert :error = LaneStore.lookup(1)
    assert [] = LaneStore.list()
    assert :ok = LaneStore.check_identity(1, %Schema{})
    Process.flag(:trap_exit, true)
    assert {:error, {:workflow_parse_error, _}} = LaneStore.start_link(file: path)

    assert {:ok, lane} = create_lane(%{slug: "offline", front_matter: "tracker:\n  kind: memory", prompt: "imported offline"})
    assert {:ok, updated} = Lanes.update(lane, %{prompt: "\nsaved offline\n"})
    assert {:error, [%{path: "front_matter", message: _}]} = Lanes.update(updated, %{name: "must roll back", front_matter: "tracker: ["})
    assert Lanes.get!(lane.id).name == "offline"
    assert {:ok, exported} = Lanes.export(Lanes.get!(lane.id))
    assert {:ok, parsed} = Workflow.parse(exported)
    assert parsed.config["tracker"] == %{"kind" => "memory"}
    assert :error = LaneStore.lookup(lane.id)
    assert {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, LaneStore)
    assert {:ok, %{prompt: "saved offline"}} = LaneStore.workflow(lane.id)
  end

  test "unknown lanes and invalid entries return explicit errors" do
    assert :error = LaneStore.lookup(42)
    assert {:error, {:lane_unavailable, 42}} = LaneStore.settings(42)
    assert {:error, {:lane_unavailable, 42}} = LaneStore.workflow(42)
    assert {:error, {:lane_unavailable, 42}} = LaneStore.validate(42)
    assert {:error, :environment_identity_in_use} = LaneStore.protect_environment(42, nil)
    assert_raise ArgumentError, ~r/lane 42/, fn -> LaneStore.settings!(42) end
    :ok = LaneStore.put_entry(%Entry{lane_id: 5, slug: "broken", error: "invalid config"})
    assert {:error, {:lane_invalid, "invalid config"}} = LaneStore.settings(5)
    assert {:error, {:lane_invalid, "invalid config"}} = LaneStore.workflow(5)
    assert {:error, :environment_identity_in_use} = LaneStore.protect_environment(5, nil)
    assert_raise ArgumentError, ~r/invalid config/, fn -> LaneStore.settings!(5) end
    assert :ok = LaneStore.mark_error(5, "preflight failed")
    assert {:ok, %{error: "preflight failed"}} = LaneStore.lookup(5)
    assert :ok = LaneStore.mark_error(404, "ignored")
  end

  test "a persisted lane without a version is disabled until a valid version repairs it" do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Missing version #{System.unique_integer([:positive])}", workspace_base: Path.join(System.tmp_dir!(), "symphony_workspaces"), worker: %{}})

    lane =
      %Lane{}
      |> Lane.changeset(%{slug: "missing-version", name: "Missing version", enabled: true, execution_profile_id: profile.id, workspace_subdir: "missing-version"})
      |> Repo.insert!()

    assert :ok = LaneStore.refresh(lane.id)
    assert {:ok, %Entry{settings: nil, enabled: false, version_id: nil, error: error}} = LaneStore.lookup(lane.id)
    assert error =~ "no version"
    refute Lanes.get!(lane.id).enabled
    assert {:error, [%{path: "version"}]} = Lanes.set_enabled(lane, true)
    assert {:error, :no_version} = Lanes.export(Lanes.get!(lane.id))
    assert Lanes.versions(lane) == []
    assert {:ok, repaired} = Lanes.update(lane, %{config: %{"tracker" => %{"kind" => "memory"}}, prompt: "repaired"})
    assert repaired.current_version_id
    assert {:ok, %{prompt: "repaired"}} = LaneStore.workflow(lane.id)
    assert {:ok, %Entry{enabled: false, error: nil}} = LaneStore.lookup(lane.id)
  end

  test "guard survives acquiring process death and only the newest authority can release it" do
    {:ok, lane} = create_lane(%{slug: "guarded", front_matter: "tracker:\n  kind: memory"})
    {:ok, other} = create_lane(%{slug: "other", front_matter: "tracker:\n  kind: memory"})
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, token} = LaneStore.protect_environment(lane.id, nil)
        send(parent, {:guard, token})
      end)

    assert_receive {:guard, old}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert {:error, :environment_identity_in_use} = LaneStore.protect_environment(lane.id, "different")
    assert {:ok, current} = LaneStore.protect_environment(lane.id, nil)
    assert {:ok, ^current} = LaneStore.protect_environment(lane.id, nil, current)
    assert {:error, :invalid_environment_guard} = LaneStore.protect_environment(lane.id, nil, old)
    assert {:error, :invalid_environment_guard} = LaneStore.release_environment(lane.id, old, :empty_inventory)
    assert {:ok, other_token} = LaneStore.protect_environment(other.id, nil)
    assert :ok = LaneStore.release_environment(other.id, other_token, :empty_inventory)
    assert :ok = LaneStore.release_environment(lane.id, current, :empty_inventory)
  end

  test "refresh keeps the effective last good version, and startup disables invalid DB lanes visibly" do
    {:ok, lane} = create_lane(%{slug: "reload", enabled: true, front_matter: "tracker:\n  kind: memory\npolling:\n  interval_ms: 2000", prompt: "one"})
    version = Lanes.current_version(lane)
    Repo.update!(Ecto.Changeset.change(version, front_matter: "polling:\n  interval_ms: nope"))
    assert :ok = LaneStore.refresh(lane.id)
    assert {:ok, %Entry{settings: %Schema{polling: %{interval_ms: 2000}}, workflow: %{prompt: "one"}, error: error}} = LaneStore.lookup(lane.id)
    assert error =~ "polling.interval_ms"
    replace_store([])
    assert {:ok, %Entry{settings: nil, enabled: false, error: error}} = LaneStore.lookup(lane.id)
    assert error =~ "polling.interval_ms"
    refute Lanes.get!(lane.id).enabled
    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
    assert :ok = Lanes.delete(lane)
    assert :error = LaneStore.lookup(lane.id)
  end

  test "scheduler reads stay available while a DB write is blocked" do
    {:ok, lane} = create_lane(%{slug: "readers", front_matter: "tracker:\n  kind: memory", prompt: "before"})
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          send(parent, :db_held)
          receive do: (:release_db -> :ok)
        end)
      end)

    assert_receive :db_held
    writer = Task.async(fn -> Lanes.update(lane, %{prompt: "after"}) end)
    assert {:ok, %{prompt: "before"}} = LaneStore.workflow(lane.id)
    assert {:ok, %Schema{}} = LaneStore.settings(lane.id)
    send(holder.pid, :release_db)
    assert {:ok, :ok} = Task.await(holder)
    assert {:ok, _} = Task.await(writer)
    assert {:ok, %{prompt: "after"}} = LaneStore.workflow(lane.id)
  end

  test "publication and errors broadcast both global and lane subscriptions without orchestrator polling" do
    :ok = ObservabilityPubSub.subscribe()
    :ok = ObservabilityPubSub.subscribe_lane("visible")
    {:ok, lane} = create_lane(%{slug: "visible", front_matter: "tracker:\n  kind: memory"})
    assert_receive :observability_updated
    assert_receive {:lane_updated, "visible"}
    :ok = LaneStore.mark_error(lane.id, "needs attention")
    assert_receive :observability_updated
    assert_receive {:lane_updated, "visible"}
    assert :ok = Lanes.delete(lane)
    assert_receive {:lane_updated, "visible"}
  end

  defp replace_store(opts) do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, LaneStore)
    start_supervised!({LaneStore, opts})

    on_exit(fn ->
      if pid = Process.whereis(LaneStore), do: GenServer.stop(pid)
      Supervisor.restart_child(SymphonyElixir.Supervisor, LaneStore)
    end)
  end

  defp create_lane(attrs) do
    front_matter = Map.fetch!(attrs, :front_matter)
    prompt = Map.get(attrs, :prompt, "")
    {:ok, workflow} = Workflow.parse_parts(front_matter, prompt)
    {profile_attrs, config} = Configuration.split(workflow.config)

    {:ok, profile} =
      ExecutionProfiles.create(%{
        name: "Test #{Map.fetch!(attrs, :slug)} #{System.unique_integer([:positive])}",
        workspace_base: profile_attrs["workspace_base"] || Path.join(System.tmp_dir!(), "symphony_workspaces"),
        worker: profile_attrs["worker"] || %{}
      })

    lane_attrs =
      attrs
      |> Map.drop([:front_matter, :enabled])
      |> Map.put(:execution_profile_id, profile.id)
      |> Map.put(:config, config)
      |> Map.put(:prompt, prompt)

    with {:ok, lane} <- Lanes.create(lane_attrs) do
      if Map.get(attrs, :enabled, false), do: Lanes.set_enabled(lane, true), else: {:ok, lane}
    end
  end
end
