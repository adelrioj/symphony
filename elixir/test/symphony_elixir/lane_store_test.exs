defmodule SymphonyElixir.LaneStoreTest do
  use ExUnit.Case
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.{ExecutionProfiles, LaneRegistry, Lanes, LaneStore, LaneSupervisor, Repo, TestSupport, Workflow}
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
    assert entry.workflow.config["tracker"]["kind"] == "memory"
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
    assert {:error, {:lane_unavailable, 42}} = LaneStore.reserve_dispatch(42)
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
    assert {:error, {:lane_invalid, ^error}} = LaneStore.reserve_dispatch(lane.id)
    assert error =~ "no version"
    refute Lanes.get!(lane.id).enabled
    assert {:error, [%{path: "version"}]} = Lanes.set_enabled(lane, true)
    assert {:error, :no_version} = Lanes.export(Lanes.get!(lane.id))
    assert Lanes.versions(lane) == []
    assert {:ok, _other} = create_lane(%{slug: "healthy-neighbor", front_matter: "tracker:\n  kind: memory"})
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

  @tag :remediation
  @tag :tmp_dir
  test "remediation: missing tracker credentials after restart cannot abandon retained ownership during repair", %{tmp_dir: root} do
    previous_key = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "original-token")
    on_exit(fn -> TestSupport.restore_env("LINEAR_API_KEY", previous_key) end)

    {:ok, original_profile} = ExecutionProfiles.create(%{name: "Original location", workspace_base: Path.join(root, "original"), worker: %{}})
    {:ok, next_profile} = ExecutionProfiles.create(%{name: "Next location", workspace_base: Path.join(root, "next"), worker: %{}})
    config = %{"tracker" => %{"kind" => "linear", "api_key" => "$LINEAR_API_KEY", "project_slug" => "test-project"}}

    {:ok, lane} = Lanes.create(%{slug: "credential-repair", execution_profile_id: original_profile.id, config: config})
    {:ok, settings} = LaneStore.settings(lane.id)
    retained = Path.join(settings.workspace.root, "retained-checkout")
    File.mkdir_p!(retained)
    File.write!(Path.join(retained, "work"), "keep")
    original_version = lane.current_version_id
    System.delete_env("LINEAR_API_KEY")

    replace_store([])

    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
    refute Lanes.get!(lane.id).enabled
    repaired_config = put_in(config, ["tracker", "api_key"], "replacement-token")
    attrs = %{config: repaired_config, execution_profile_id: next_profile.id}

    assert {:error, errors} = Lanes.update(lane, attrs)
    assert Enum.any?(errors, &(&1.path == "worker.environment"))
    assert Lanes.get!(lane.id).execution_profile_id == original_profile.id
    assert Lanes.get!(lane.id).current_version_id == original_version
    assert File.read!(Path.join(retained, "work")) == "keep"
    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)

    File.rm_rf!(retained)

    assert {:ok, moved} = Lanes.update(Lanes.get!(lane.id), attrs)
    assert moved.execution_profile_id == next_profile.id
    assert moved.current_version_id != original_version
    assert {:ok, repaired_settings} = LaneStore.settings(lane.id)
    assert repaired_settings.tracker.api_key == "replacement-token"
    assert repaired_settings.workspace.root != settings.workspace.root
    refute moved.enabled
  end

  for {field, invalid_config} <- [
        {"Codex command", %{"tracker" => %{"kind" => "memory"}, "codex" => %{"command" => ""}}},
        {"tracker kind", %{"tracker" => %{"kind" => "unsupported"}}}
      ] do
    @tag :remediation
    @tag :tmp_dir
    test "remediation: a migration-marked #{field} repair preserves known local ownership after restart", %{tmp_dir: root} do
      {:ok, profile} = ExecutionProfiles.create(%{name: "Migrated local owner", workspace_base: root, worker: %{}})
      config = %{"tracker" => %{"kind" => "memory"}, "codex" => %{"command" => "codex app-server"}}
      {:ok, lane} = Lanes.create(%{slug: "migrated-repair", execution_profile_id: profile.id, config: config})
      {:ok, original_settings} = LaneStore.settings(lane.id)
      retained = Path.join(original_settings.workspace.root, "retained")
      File.mkdir_p!(retained)
      File.write!(Path.join(retained, "work"), "keep")
      Repo.update!(Ecto.Changeset.change(Lanes.current_version(lane), front_matter: Workflow.encode_config(unquote(Macro.escape(invalid_config)))))
      Repo.update!(Ecto.Changeset.change(profile, repair_error: "legacy configuration requires repair"))

      replace_store([])

      assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
      assert {:error, {:lane_invalid, _}} = LaneStore.reserve_dispatch(lane.id)
      assert {:ok, repaired} = Lanes.update(lane, %{config: config})
      refute repaired.enabled
      assert repaired.execution_profile_id == profile.id
      assert is_nil(ExecutionProfiles.get(profile.id).repair_error)
      assert {:ok, %Entry{enabled: false, error: nil, settings: settings}} = LaneStore.lookup(lane.id)
      assert settings.workspace.root == original_settings.workspace.root
      assert settings.codex.command == "codex app-server"
      assert File.read!(Path.join(retained, "work")) == "keep"
      refute LaneSupervisor.running?(lane.id)
    end
  end

  @tag :remediation
  test "remediation: managed credential repair after restart retains the original non-memory tracker identity" do
    key = "LINEAR_API_KEY"
    previous = System.get_env(key)
    System.put_env(key, "original-token")
    on_exit(fn -> TestSupport.restore_env(key, previous) end)
    {:ok, profile} = ExecutionProfiles.create(%{name: "Managed credential owner", workspace_base: "/managed/credential-repair", worker: managed_worker()})
    config = %{"tracker" => %{"kind" => "linear", "api_key" => "$" <> key, "project_slug" => "test-project"}}
    {:ok, lane} = Lanes.create(%{slug: "managed-credential-repair", execution_profile_id: profile.id, config: config})
    {:ok, original_settings} = LaneStore.settings(lane.id)
    original_identity = EnvironmentConfig.identity(original_settings)
    assert is_binary(original_identity)
    System.delete_env(key)

    replace_store([])

    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
    repaired_config = put_in(config, ["tracker", "api_key"], "replacement-token")
    assert {:ok, repaired} = Lanes.update(lane, %{config: repaired_config})
    refute repaired.enabled
    assert {:ok, settings} = LaneStore.settings(lane.id)
    assert settings.tracker.kind == "linear"
    assert settings.tracker.api_key == "replacement-token"
    assert EnvironmentConfig.identity(settings) == original_identity
    assert {:error, errors} = Lanes.update(repaired, %{config: %{"tracker" => %{"kind" => "memory"}}})
    assert Enum.any?(errors, &(&1.path == "worker.environment"))
    assert {:ok, ^settings} = LaneStore.settings(lane.id)
    refute LaneSupervisor.running?(lane.id)
  end

  for mutation <- [:create, :relink, :profile] do
    @tag :remediation
    @tag :tmp_dir
    test "remediation: #{mutation} cannot claim a credential-invalid startup lane's retained workspace", %{tmp_dir: root} do
      key = "LINEAR_API_KEY"
      previous = System.get_env(key)
      System.put_env(key, "original-token")
      on_exit(fn -> TestSupport.restore_env(key, previous) end)
      {:ok, profile} = ExecutionProfiles.create(%{name: "Retained owner", workspace_base: Path.join(root, "owned"), worker: %{}})
      {:ok, other_profile} = ExecutionProfiles.create(%{name: "Healthy neighbor", workspace_base: Path.join(root, "other"), worker: %{}})
      config = %{"tracker" => %{"kind" => "linear", "api_key" => "$" <> key, "project_slug" => "test-project"}}
      {:ok, owner} = Lanes.create(%{slug: "retained-owner", execution_profile_id: profile.id, workspace_subdir: ".", config: config})
      {:ok, neighbor} = Lanes.create(%{slug: "healthy-neighbor", execution_profile_id: other_profile.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})
      {:ok, owner_settings} = LaneStore.settings(owner.id)
      retained = Path.join(owner_settings.workspace.root, "retained/work")
      File.mkdir_p!(Path.dirname(retained))
      File.write!(retained, "keep")
      System.delete_env(key)

      replace_store([])

      assert {:error, {:lane_invalid, _}} = LaneStore.settings(owner.id)
      {:ok, neighbor_entry} = LaneStore.lookup(neighbor.id)

      result =
        case unquote(mutation) do
          :create -> Lanes.create(%{slug: "intruder", execution_profile_id: profile.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})
          :relink -> Lanes.update(neighbor, %{execution_profile_id: profile.id})
          :profile -> ExecutionProfiles.update(other_profile, %{workspace_base: profile.workspace_base})
        end

      assert {:error, errors} = result
      assert Enum.any?(errors, &String.contains?(&1.message, "conflicts"))
      assert is_nil(Lanes.get_by_slug("intruder"))
      assert Lanes.get!(neighbor.id).execution_profile_id == other_profile.id
      assert ExecutionProfiles.get(other_profile.id).workspace_base == other_profile.workspace_base
      assert {:ok, ^neighbor_entry} = LaneStore.lookup(neighbor.id)
      assert File.read!(retained) == "keep"
      assert {:error, {:lane_invalid, _}} = LaneStore.settings(owner.id)
    end
  end

  for invalid_first? <- [true, false] do
    @tag :remediation
    @tag :tmp_dir
    test "remediation: startup protects invalid retained ownership when invalid lane sorts first=#{invalid_first?}", %{tmp_dir: root} do
      key = "LINEAR_API_KEY"
      previous = System.get_env(key)
      System.put_env(key, "original-token")
      on_exit(fn -> TestSupport.restore_env(key, previous) end)
      {:ok, profile} = ExecutionProfiles.create(%{name: "Startup owners", workspace_base: root, worker: %{}})
      invalid = %{slug: "invalid-owner", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "linear", "api_key" => "$" <> key, "project_slug" => "test-project"}}}
      valid = %{slug: "valid-neighbor", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}}
      ordered = if unquote(invalid_first?), do: [invalid, valid], else: [valid, invalid]

      lanes =
        Enum.map(ordered, fn attrs ->
          {:ok, lane} = Lanes.create(attrs)
          lane
        end)

      owner = Enum.find(lanes, &(&1.slug == "invalid-owner"))
      neighbor = Enum.find(lanes, &(&1.slug == "valid-neighbor"))
      {:ok, settings} = LaneStore.settings(owner.id)
      retained = Path.join(settings.workspace.root, "retained/work")
      File.mkdir_p!(Path.dirname(retained))
      File.write!(retained, "keep")
      Repo.update!(Ecto.Changeset.change(neighbor, workspace_subdir: owner.workspace_subdir, enabled: true))
      System.delete_env(key)

      replace_store([])

      assert {:error, {:lane_invalid, _}} = LaneStore.settings(owner.id)

      assert {:ok, %Entry{enabled: false, error: error}} = LaneStore.lookup(neighbor.id)
      assert is_binary(error)
      refute Lanes.get!(neighbor.id).enabled
      refute Lanes.get!(owner.id).enabled
      refute LaneSupervisor.running?(neighbor.id)
      refute LaneSupervisor.running?(owner.id)
      assert {:error, _} = LaneStore.reserve_dispatch(neighbor.id)
      assert File.read!(retained) == "keep"
    end
  end

  @tag :remediation
  test "remediation: missing managed tracker identity cannot be reconstructed as the memory tracker" do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Unknown managed tracker", workspace_base: "/managed/unknown-tracker", worker: managed_worker()})
    config = %{"tracker" => %{"kind" => "linear", "api_key" => "token", "project_slug" => "test-project"}}
    {:ok, lane} = Lanes.create(%{slug: "unknown-managed-tracker", execution_profile_id: profile.id, config: config})
    Repo.update!(Ecto.Changeset.change(Lanes.current_version(lane), front_matter: "tracker: {}"))

    replace_store([])

    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
    assert {:error, errors} = Lanes.update(lane, %{config: %{"tracker" => %{"kind" => "memory"}}})
    assert Enum.any?(errors, &(&1.path == "worker.environment"))
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
  end

  @tag :remediation
  @tag :tmp_dir
  test "remediation: a sanitized legacy worker cannot be mistaken for known local ownership", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Sanitized legacy worker", workspace_base: root, worker: %{}})
    config = %{"tracker" => %{"kind" => "memory"}}
    {:ok, lane} = Lanes.create(%{slug: "sanitized-worker", execution_profile_id: profile.id, config: config})
    legacy_config = Map.merge(config, %{"worker" => "broken", "workspace" => %{"root" => root}})
    Repo.update!(Ecto.Changeset.change(Lanes.current_version(lane), front_matter: Workflow.encode_config(legacy_config)))
    Repo.update!(Ecto.Changeset.change(profile, repair_error: "legacy configuration requires repair"))

    replace_store([])

    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
    assert {:error, errors} = Lanes.update(lane, %{config: config})
    assert Enum.any?(errors, &(&1.path == "worker.environment"))
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    assert ExecutionProfiles.get(profile.id).repair_error
    assert {:error, [%{path: "lane"}]} = Lanes.delete(lane)
  end

  @tag :remediation
  @tag :tmp_dir
  test "remediation: unknown startup worker ownership does not authorize a second lane at its root", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Unknown owner", workspace_base: root, worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "unknown-owner", execution_profile_id: profile.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})
    retained = Path.join(root, "retained")
    File.mkdir_p!(root)
    File.write!(retained, "keep")
    Repo.update!(Ecto.Changeset.change(profile, worker: %{"ssh_hosts" => %{"unknown" => "target"}}))

    replace_store([])

    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
    {:ok, replacement} = ExecutionProfiles.create(%{name: "Apparent local replacement", workspace_base: root, worker: %{}})
    assert {:error, [_ | _]} = Lanes.create(%{slug: "unknown-intruder", execution_profile_id: replacement.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})
    assert is_nil(Lanes.get_by_slug("unknown-intruder"))
    assert File.read!(retained) == "keep"
  end

  @tag :remediation
  @tag :tmp_dir
  test "remediation: malformed startup location identity fails closed instead of permitting a profile switch", %{tmp_dir: root} do
    {:ok, original_profile} = ExecutionProfiles.create(%{name: "Malformed owner", workspace_base: Path.join(root, "original"), worker: %{}})
    {:ok, next_profile} = ExecutionProfiles.create(%{name: "Valid replacement", workspace_base: Path.join(root, "next"), worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "malformed-owner", execution_profile_id: original_profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, settings} = LaneStore.settings(lane.id)
    File.mkdir_p!(settings.workspace.root)
    retained = Path.join(settings.workspace.root, "retained")
    File.write!(retained, "keep")

    Repo.update!(Ecto.Changeset.change(original_profile, worker: %{"ssh_hosts" => %{"unknown" => "target"}}))
    replace_store([])

    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
    assert {:error, errors} = Lanes.update(lane, %{execution_profile_id: next_profile.id})
    assert Enum.any?(errors, &(&1.path == "worker.environment"))
    assert Lanes.get!(lane.id).execution_profile_id == original_profile.id
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    assert {:error, [%{path: "lane"}]} = Lanes.delete(lane)
    assert is_nil(Lanes.get!(lane.id).deleted_at)
    assert File.read!(retained) == "keep"
  end

  test "startup disables persisted overlapping lanes before starting runtimes" do
    {:ok, first} = create_lane(%{slug: "startup-first", enabled: true, front_matter: "tracker:\n  kind: memory"})
    {:ok, second} = create_lane(%{slug: "startup-second", enabled: true, front_matter: "tracker:\n  kind: memory"})
    first_profile = ExecutionProfiles.get(first.execution_profile_id)
    second_profile = ExecutionProfiles.get(second.execution_profile_id)
    Repo.update!(Ecto.Changeset.change(second_profile, workspace_base: first_profile.workspace_base))
    Repo.update!(Ecto.Changeset.change(second, workspace_subdir: first.workspace_subdir))

    replace_store([])

    assert {:ok, %Entry{enabled: false, error: first_error}} = LaneStore.lookup(first.id)
    assert {:ok, %Entry{enabled: false, error: second_error}} = LaneStore.lookup(second.id)
    assert first_error =~ "conflicts"
    assert second_error =~ "conflicts"
    refute Lanes.get!(first.id).enabled
    refute Lanes.get!(second.id).enabled
    refute LaneSupervisor.running?(first.id)
    refute LaneSupervisor.running?(second.id)
  end

  @tag :remediation
  @tag :tmp_dir
  test "remediation: dedicated profiles repair independent legacy overlap groups sequentially", %{tmp_dir: root} do
    [first, second, third, fourth] = overlapping_legacy_lanes(root)
    {:ok, first_entry} = LaneStore.lookup(first.id)
    {:ok, third_entry} = LaneStore.lookup(third.id)
    {:ok, fourth_entry} = LaneStore.lookup(fourth.id)
    second_profile = ExecutionProfiles.get(second.execution_profile_id)
    fourth_profile = ExecutionProfiles.get(fourth.execution_profile_id)

    assert {:error, errors} = ExecutionProfiles.update(second_profile, %{workspace_base: fourth_profile.workspace_base})
    assert Enum.any?(errors, &String.contains?(&1.message, "conflicts"))
    assert ExecutionProfiles.get(second_profile.id).workspace_base == second_profile.workspace_base

    second_root = Path.join(root, "repaired-second")
    assert {:ok, _} = ExecutionProfiles.update(second_profile, %{workspace_base: second_root})
    assert {:ok, %Entry{enabled: false, error: nil, settings: second_settings}} = LaneStore.lookup(second.id)
    assert second_settings.workspace.root == second_root
    assert {:ok, ^first_entry} = LaneStore.lookup(first.id)
    assert {:ok, ^third_entry} = LaneStore.lookup(third.id)
    assert {:ok, ^fourth_entry} = LaneStore.lookup(fourth.id)
    assert {:error, {:lane_invalid, _}} = LaneStore.reserve_dispatch(third.id)
    assert {:error, {:lane_invalid, _}} = LaneStore.reserve_dispatch(fourth.id)

    assert {:error, errors} = ExecutionProfiles.update(fourth_profile, %{workspace_base: first_entry.settings.workspace.root})
    assert Enum.any?(errors, &String.contains?(&1.message, "conflicts"))
    assert ExecutionProfiles.get(fourth_profile.id).workspace_base == fourth_profile.workspace_base

    fourth_root = Path.join(root, "repaired-fourth")
    assert {:ok, _} = ExecutionProfiles.update(fourth_profile, %{workspace_base: fourth_root})
    assert {:ok, %Entry{enabled: false, error: nil, settings: fourth_settings}} = LaneStore.lookup(fourth.id)
    assert fourth_settings.workspace.root == fourth_root
    assert {:ok, ^first_entry} = LaneStore.lookup(first.id)
    assert {:ok, ^third_entry} = LaneStore.lookup(third.id)

    for lane <- [first, second, third, fourth] do
      refute Lanes.get!(lane.id).enabled
      assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
      refute LaneSupervisor.running?(lane.id)
    end
  end

  @tag :remediation
  @tag :tmp_dir
  test "remediation: an unlinked profile claims no workspace amid independent legacy overlaps", %{tmp_dir: root} do
    [first | _] = overlapping_legacy_lanes(root)
    entries = LaneStore.list()
    occupied_root = ExecutionProfiles.get(first.execution_profile_id).workspace_base

    assert {:ok, profile} = ExecutionProfiles.create(%{name: "Unlinked repair option", workspace_base: occupied_root, worker: %{}})
    assert ExecutionProfiles.get(profile.id)
    assert LaneStore.list() == entries
    refute Enum.any?(Lanes.list(), &(&1.execution_profile_id == profile.id))
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

  test "refresh removes a row deleted outside the authority and rejects later dispatch" do
    {:ok, lane} = create_lane(%{slug: "externally-removed", front_matter: "tracker:\n  kind: memory"})
    Repo.update!(Ecto.Changeset.change(lane, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)))

    assert :ok = LaneStore.refresh(lane.id)
    assert :error = LaneStore.lookup(lane.id)
    assert :error = LaneStore.by_slug(lane.slug)
    assert {:error, {:lane_unavailable, id}} = LaneStore.reserve_dispatch(lane.id)
    assert id == lane.id
    assert :ok = Lanes.disable(9_223_372_036_854_775_807, "already absent")
    assert :error = LaneStore.lookup(9_223_372_036_854_775_807)
  end

  @tag :tmp_dir
  test "cyclic profile locations remain visible for repair without authorizing deletion", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Broken location", workspace_base: Path.join(root, "original"), worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "cyclic-location", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    loop = Path.join(root, "loop")
    :ok = File.ln_s("loop", loop)
    Repo.update!(Ecto.Changeset.change(profile, workspace_base: loop))

    replace_store([])

    assert {:ok, %Entry{settings: nil, enabled: false, profile_name: "Broken location", workspace_base: ^loop}} = LaneStore.lookup(lane.id)
    assert {:error, {:lane_invalid, _}} = LaneStore.settings(lane.id)
    assert {:error, [%{path: "lane"}]} = Lanes.delete(lane)
    assert is_nil(Lanes.get!(lane.id).deleted_at)
    assert {:error, :no_version} = Lanes.export(lane)
  end

  test "a repair-marked profile with unknown legacy infrastructure stays visible but cannot be dispatched or discarded" do
    {:ok, lane} = create_lane(%{slug: "profile-repair", front_matter: "tracker:\n  kind: memory"})
    profile = ExecutionProfiles.get(lane.execution_profile_id)
    Repo.update!(Ecto.Changeset.change(Lanes.current_version(lane), front_matter: "tracker:\n  kind: memory\nworker: [unknown-target]"))
    Repo.update!(Ecto.Changeset.change(profile, repair_error: "legacy infrastructure could not be recovered"))
    replace_store([])

    assert {:ok, %Entry{settings: nil, enabled: false, profile_name: name, error: error}} = LaneStore.lookup(lane.id)
    assert name == profile.name
    assert {:error, [%{path: "profile"}]} = Lanes.resolve_lane(Lanes.get!(lane.id))
    assert {:error, {:lane_invalid, ^error}} = LaneStore.reserve_dispatch(lane.id)
    assert {:error, [%{path: "lane"}]} = Lanes.delete(lane)
    assert Lanes.get!(lane.id).execution_profile_id == profile.id
  end

  defp managed_worker do
    %{
      "environment" => %{
        "kind" => "google_workstations",
        "deployment_id" => "credential-repair",
        "startup_timeout_ms" => 1_000,
        "shutdown_timeout_ms" => 1_000,
        "terminal_retention_ms" => 0,
        "provider" => %{
          "project" => "project",
          "location" => "location",
          "cluster" => "cluster",
          "config" => "config",
          "credential_configuration" => "credentials",
          "impersonate_service_account" => "worker@example.com",
          "ssh_user" => "worker",
          "ssh_port" => 22
        }
      }
    }
  end

  defp overlapping_legacy_lanes(root) do
    lanes =
      Enum.map(["first", "second", "third", "fourth"], fn slug ->
        workspace_root = Path.join(root, slug)
        front_matter = Workflow.encode_config(%{"tracker" => %{"kind" => "memory"}, "workspace" => %{"root" => workspace_root}})
        {:ok, lane} = create_lane(%{slug: slug, workspace_subdir: ".", front_matter: front_matter})
        lane
      end)

    [first, second, third, fourth] = lanes

    for {owner, duplicate} <- [{first, second}, {third, fourth}] do
      owner_profile = ExecutionProfiles.get(owner.execution_profile_id)
      duplicate_profile = ExecutionProfiles.get(duplicate.execution_profile_id)
      File.mkdir_p!(owner_profile.workspace_base)
      Repo.update!(Ecto.Changeset.change(duplicate_profile, workspace_base: owner_profile.workspace_base))
    end

    for lane <- lanes, do: Repo.update!(Ecto.Changeset.change(lane, enabled: true))
    replace_store([])

    for lane <- lanes do
      assert {:ok, %Entry{enabled: false, error: error}} = LaneStore.lookup(lane.id)
      assert error =~ "conflicts"
      refute Lanes.get!(lane.id).enabled
      refute LaneSupervisor.running?(lane.id)
    end

    lanes
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
        workspace_base: profile_attrs["workspace_base"] || Path.join(System.tmp_dir!(), "symphony-workspaces-#{System.unique_integer([:positive])}"),
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
