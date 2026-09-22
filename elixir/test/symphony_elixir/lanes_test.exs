defmodule SymphonyElixir.LanesTest do
  use ExUnit.Case
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.{ExecutionProfiles, LaneContext, Lanes, LaneStore, Repo, TestSupport, Workflow}
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.Lanes.{Lane, LaneVersion}

  @front_matter "tracker:\n  kind: memory\ncodex:\n  command: codex app-server"
  @fixtures Path.expand("../fixtures/lanes", __DIR__)

  setup do
    TestSupport.reset_lanes!()
    previous_key = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "test-linear-api-key")

    on_exit(fn ->
      TestSupport.reset_lanes!()
      TestSupport.restore_env("LINEAR_API_KEY", previous_key)
    end)

    :ok
  end

  test "creation stores one raw version and exposes a disabled local lane" do
    assert {:ok, %Lane{slug: "features", enabled: false, executor: "local"} = lane} =
             create_lane(%{slug: "features", front_matter: @front_matter, prompt: "Do work", note: "first"})

    assert lane.name == "features"
    assert [%LaneVersion{id: id, note: "first", prompt: "Do work", front_matter: front_matter}] = Lanes.versions(lane)
    assert {:ok, parsed} = Workflow.parse_parts(front_matter, "Do work")
    assert parsed.config["tracker"] == %{"kind" => "memory"}
    assert lane.current_version_id == id
    assert Lanes.get_by_slug("features").id == lane.id
    assert Lanes.get!(lane.id).id == lane.id
    assert [^lane] = Lanes.list()
    assert {:ok, %{version_id: ^id}} = LaneStore.lookup(lane.id)
  end

  @tag :tmp_dir
  test "export and current content use the effective raw configuration", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Raw export", workspace_base: root, worker: %{"api_key" => "literal-worker-secret"}})

    {:ok, lane} =
      Lanes.create(%{
        slug: "raw-export",
        execution_profile_id: profile.id,
        workspace_subdir: ".",
        config: %{
          "tracker" => %{"kind" => "memory", "api_key" => "literal-tracker-secret"},
          "references" => %{"token" => "$LINEAR_API_KEY"},
          "extension" => %{"nested" => [1, true]}
        },
        prompt: "Do work"
      })

    assert {:ok, exported} = Lanes.export(lane)
    assert {:ok, parsed} = Workflow.parse(exported)
    assert parsed.config["workspace"]["root"] == root
    assert parsed.config["tracker"]["api_key"] == "$REDACTED"
    assert parsed.config["worker"]["api_key"] == "$REDACTED"
    assert parsed.config["references"]["token"] == "$LINEAR_API_KEY"
    refute exported =~ "literal-tracker-secret"
    refute exported =~ "literal-worker-secret"
    refute exported =~ System.fetch_env!("LINEAR_API_KEY")

    LaneContext.put(lane.id)
    assert {:ok, content} = Workflow.current_content()
    assert {:ok, current} = Workflow.parse(content)
    assert current.config["extension"] == %{"nested" => [1, true]}
    assert current.config["tracker"]["api_key"] == "$REDACTED"
    assert current.config["worker"]["api_key"] == "$REDACTED"
  end

  test "invalid config and invalid metadata never write a lane or a version" do
    assert {:error, errors} = Lanes.create(%{slug: "bugs", execution_profile_id: profile_id(), config: %{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => "nope"}}, prompt: ""})
    assert Enum.any?(errors, &(&1.path == "polling.interval_ms"))
    assert {:error, [%{path: "config", message: _}]} = Lanes.create(%{slug: "sequence", execution_profile_id: profile_id(), config: []})
    assert {:error, [%{path: "tracker.kind"}]} = Lanes.create(%{slug: "unsupported", execution_profile_id: profile_id(), config: %{"tracker" => %{"kind" => "unsupported"}}})
    assert {:error, [%{path: "slug"}]} = Lanes.create(%{slug: "Bad Slug", execution_profile_id: profile_id(), config: %{"tracker" => %{"kind" => "memory"}}})
    assert {:error, [%{path: "slug"}]} = Lanes.create(%{slug: "x", execution_profile_id: profile_id(), config: %{"tracker" => %{"kind" => "memory"}}})
    assert {:error, [%{path: "executor", message: _}]} = Lanes.create(%{slug: "okay", executor: "kubernetes", execution_profile_id: profile_id(), config: %{"tracker" => %{"kind" => "memory"}}})
    assert Lanes.list() == []
    assert Repo.aggregate(LaneVersion, :count) == 0
  end

  test "the reserved creation slug cannot be imported or assigned by an update" do
    assert {:error, [%{path: "slug"}]} = Lanes.import_file(Path.join(@fixtures, "example.md"), slug: "new")
    assert Lanes.list() == []
    assert Repo.aggregate(LaneVersion, :count) == 0

    {:ok, lane} = create_lane(%{slug: "new-work", front_matter: @front_matter, prompt: "original"})
    assert {:error, [%{path: "slug"}]} = Lanes.update(lane, %{slug: "new", prompt: "must not be saved"})
    assert is_nil(Lanes.get_by_slug("new"))
    assert Lanes.get_by_slug("new-work").id == lane.id
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    assert [%LaneVersion{prompt: "original"}] = Lanes.versions(lane)
  end

  test "wrong JSON types return field errors and cannot overwrite a current version" do
    {:ok, lane} = create_lane(%{slug: "typed", front_matter: @front_matter, prompt: "original"})

    for {field, value} <- [{"slug", nil}, {"name", []}, {"enabled", "false"}, {"enabled", nil}, {"executor", %{}}, {"front_matter", nil}, {"prompt", []}, {"note", false}] do
      assert {:error, errors} = Lanes.update(lane, %{field => value})
      assert Enum.any?(errors, &(&1.path == field))
    end

    assert {:error, [%{path: "lane"}]} = Lanes.create([])
    assert {:error, [%{path: "lane"}]} = Lanes.update(lane, nil)
    assert {:error, [%{path: "lane"}]} = Lanes.update(lane, %{42 => "not a field"})
    assert {:error, [%{path: "version"}]} = Lanes.activate_version(lane, %{})
    assert [%LaneVersion{prompt: "original"}] = Lanes.versions(lane)
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
  end

  test "partial edits reload current rows instead of clobbering newer edits from stale structs" do
    {:ok, original} = create_lane(%{slug: "partial", front_matter: @front_matter, prompt: "first"})
    {:ok, renamed} = Lanes.update(original, %{name: "Renamed"})
    assert renamed.current_version_id == original.current_version_id
    {:ok, second} = Lanes.update(original, %{prompt: "second"})
    {:ok, third} = Lanes.update(original, %{config: %{"tracker" => %{"kind" => "memory"}, "codex" => %{"command" => "codex app-server"}, "polling" => %{"interval_ms" => 2000}}})
    assert third.name == "Renamed"
    assert [%LaneVersion{prompt: "second"}, %LaneVersion{id: second_id}, %LaneVersion{}] = Lanes.versions(third)
    assert second_id == second.current_version_id
    assert {:error, [%{path: "polling.interval_ms"}]} = Lanes.update(original, %{config: %{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => -1}}})
    assert Lanes.get!(original.id).current_version_id == third.current_version_id
  end

  test "activation moves the pointer without inserting and rejects another lane's version" do
    {:ok, first} = create_lane(%{slug: "rollback", front_matter: @front_matter, prompt: "first"})
    {:ok, second} = Lanes.update(first, %{prompt: "second"})
    {:ok, other} = create_lane(%{slug: "other", front_matter: @front_matter})
    assert {:ok, %{current_version_id: id}} = Lanes.activate_version(second, first.current_version_id)
    assert id == first.current_version_id
    assert length(Lanes.versions(first)) == 2
    assert {:error, [%{path: "version"}]} = Lanes.activate_version(first, other.current_version_id)
  end

  test "SQLite ID bounds reject before mutation and preserve the published runtime" do
    {:ok, lane} = create_lane(%{slug: "id-boundary", front_matter: @front_matter, prompt: "unchanged"})
    {:ok, published} = LaneStore.lookup(lane.id)
    owner = Process.whereis(LaneStore)

    for id <- [9_223_372_036_854_775_808, -9_223_372_036_854_775_809, 0] do
      assert {:error, [%{path: "version"}]} = Lanes.activate_version(lane, id)
      assert is_nil(Lanes.get(id))
      assert is_nil(Lanes.get_any(id))
      assert_raise Ecto.NoResultsError, fn -> Lanes.get!(id) end
    end

    assert Process.whereis(LaneStore) == owner
    assert {:ok, ^published} = LaneStore.lookup(lane.id)
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    assert [%LaneVersion{prompt: "unchanged"}] = Lanes.versions(lane)
  end

  @tag :tmp_dir
  test "retained workspaces reject identity changes without committing metadata or versions", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Retained owner", workspace_base: root, worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "guarded", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}, prompt: "original"})
    {:ok, settings} = LaneStore.settings(lane.id)
    File.mkdir_p!(settings.workspace.root)
    retained = Path.join(settings.workspace.root, "checkout")
    File.write!(retained, "keep")

    assert {:error, [%{path: "worker.environment"}]} = Lanes.update(lane, %{workspace_subdir: "moved", name: "must roll back", prompt: "must roll back"})
    assert Lanes.get!(lane.id).workspace_subdir == "guarded"
    assert Lanes.get!(lane.id).name == "guarded"
    assert [%LaneVersion{prompt: "original"}] = Lanes.versions(lane)
    assert {:ok, %{prompt: "original"}} = LaneStore.workflow(lane.id)
    assert File.read!(retained) == "keep"
    assert {:ok, renamed} = Lanes.update(lane, %{name: "Renamed"})
    assert renamed.name == "Renamed"
  end

  @tag :tmp_dir
  test "publication rejects an externally changed identity and rolls back metadata", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Publication owner", workspace_base: Path.join(root, "original"), worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "publication-guard", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, published} = LaneStore.lookup(lane.id)
    File.mkdir_p!(published.settings.workspace.root)
    retained = Path.join(published.settings.workspace.root, "checkout")
    File.write!(retained, "keep")
    Repo.update!(Ecto.Changeset.change(profile, workspace_base: Path.join(root, "moved")))

    assert {:error, :environment_identity_in_use} = LaneStore.refresh(lane.id)
    assert {:error, [%{path: "worker.environment"}]} = Lanes.update(lane, %{name: "must roll back"})
    assert Lanes.get!(lane.id).name == lane.name
    assert {:ok, ^published} = LaneStore.lookup(lane.id)
    assert {:ok, validated} = Lanes.resolve_lane(Lanes.get!(lane.id))
    assert {:error, :environment_identity_in_use} = LaneStore.put_entry(%{published | settings: validated.settings})
    assert {:ok, ^published} = LaneStore.lookup(lane.id)
    assert File.read!(retained) == "keep"
  end

  test "enable validates current config, disable remains available, and deleted slugs stay reserved" do
    {:ok, stale} = create_lane(%{slug: "lifecycle", front_matter: @front_matter})
    assert {:ok, %{enabled: true}} = Lanes.set_enabled(stale, true)
    assert {:error, :lane_active} = Lanes.delete(stale)
    assert :ok = Lanes.disable(stale.id, "operator stopped")
    assert :ok = Lanes.disable(-1, "missing")
    assert {:ok, %{enabled: false, error: "operator stopped"}} = LaneStore.lookup(stale.id)
    version = Lanes.current_version(stale)
    Repo.update!(Ecto.Changeset.change(version, front_matter: "tracker: ["))
    assert {:error, [%{path: "tracker.kind"}]} = Lanes.set_enabled(stale, true)
    assert {:ok, %{enabled: false}} = Lanes.update(stale, %{name: "Repair me"})
    assert :ok = Lanes.delete(stale)
    assert is_nil(Lanes.get(stale.id))
    assert :ok = Lanes.disable(stale.id, "already removed")
    assert :ok = Lanes.delete(stale)
    assert :error = LaneStore.lookup(stale.id)
    assert is_nil(Lanes.get_by_slug("lifecycle"))
    assert Repo.get!(Lane, stale.id).deleted_at
    assert {:error, [%{path: "slug", message: "has already been taken"}]} = create_lane(%{slug: "lifecycle", front_matter: @front_matter})
    assert {:error, [%{path: "lane"}]} = Lanes.update(stale, %{prompt: "resurrect"})
  end

  @tag :tmp_dir
  test "import and reimport preserve canonical LF fixtures and server config is ignored", %{tmp_dir: tmp_dir} do
    for {file, slug} <- [{"client-template.md", "features"}, {"example.md", "example"}] do
      path = Path.join(tmp_dir, "#{slug}.md")
      File.write!(path, String.replace(File.read!(Path.join(@fixtures, file)), "/workspaces", Path.join(tmp_dir, slug)))
      assert {:ok, lane, warnings} = Lanes.import_file(path, slug: slug, name: "Imported")
      refute lane.enabled
      assert lane.workspace_subdir == "."
      assert Enum.any?(warnings, &String.contains?(&1, "execution profile"))
      assert Enum.any?(warnings, &String.contains?(&1, "server"))
      assert {:ok, exported} = Lanes.export(lane)
      assert {:ok, parsed_export} = Workflow.parse(exported)
      assert parsed_export.config["tracker"]
      profile_id = lane.execution_profile_id
      assert {:ok, updated, reimport_warnings} = Lanes.import_file(path, slug: slug, note: "again")
      assert updated.id == lane.id
      refute updated.execution_profile_id == profile_id
      assert Enum.any?(reimport_warnings, &String.contains?(&1, "execution profile"))
      assert [%LaneVersion{note: "again"}, %LaneVersion{}] = Lanes.versions(updated)
    end

    existing = Lanes.get_by_slug("features")
    profile_count = length(ExecutionProfiles.list())
    version_count = length(Lanes.versions(existing))
    current_version_id = existing.current_version_id
    profile_id = existing.execution_profile_id
    {:ok, published} = LaneStore.lookup(existing.id)
    failed = Path.join(tmp_dir, "failed.md")
    File.write!(failed, "---\ntracker:\n  kind: memory\npolling:\n  interval_ms: nope\n---\n")
    assert {:error, _} = Lanes.import_file(failed, slug: "features")
    assert length(ExecutionProfiles.list()) == profile_count
    unchanged = Lanes.get!(existing.id)
    assert unchanged.execution_profile_id == profile_id
    assert unchanged.current_version_id == current_version_id
    assert length(Lanes.versions(unchanged)) == version_count
    assert {:ok, ^published} = LaneStore.lookup(existing.id)

    assert {:ok, workflow} = Workflow.parse_parts(@front_matter <> "\nserver: invalid-but-ignored", "")
    {profile, config} = Configuration.split(workflow.config)

    assert {:ok, validated} =
             Configuration.resolve(
               Map.put_new(
                 profile,
                 "workspace_base",
                 %SymphonyElixir.Config.Schema.Workspace{}.root
               ),
               config,
               ".",
               ""
             )

    assert Enum.any?(validated.warnings, &String.contains?(&1, "ignored"))
    assert is_nil(validated.settings.server.port)
    assert {:error, [%{path: "file"}]} = Lanes.import_file("/nope/WORKFLOW.md", slug: "missing")
    assert {:error, [%{path: "slug"}]} = Lanes.import_file(Path.join(@fixtures, "example.md"), slug: nil, name: "Missing slug")
    assert Enum.map(Lanes.list(), & &1.slug) == ["features", "example"]
    assert {:error, :no_version} = Lanes.export(%Lane{current_version_id: nil})
  end

  test "error formatting retains actionable field paths" do
    assert [%{path: "worker"}] = Lanes.errors_for({:invalid_workflow_config, "managed and static worker settings conflict"})
    assert {:error, structured_error} = Schema.parse(%{"polling" => %{"interval_ms" => "invalid"}}, errors: :list)
    assert [%{path: "polling.interval_ms"}] = Lanes.errors_for(structured_error)
    assert [%{path: "codex.command"}] = Lanes.errors_for({:invalid_workflow_config, "codex.command can't be blank"})
    assert [%{path: "tracker.kind"}] = Lanes.errors_for(:missing_tracker_kind)
    assert [%{path: "tracker"}] = Lanes.errors_for(:missing_linear_scope)
    assert [%{path: "front_matter"}] = Lanes.errors_for({:weird, 1})
  end

  test "profile references must exist before a lane or version can be committed" do
    for profile_id <- [nil, 0, 9_223_372_036_854_775_807] do
      assert {:error, [%{path: "execution_profile_id"}]} =
               Lanes.create(%{slug: "missing-profile", execution_profile_id: profile_id, config: %{"tracker" => %{"kind" => "memory"}}})
    end

    assert {:error, [%{path: "execution_profile_id"}]} = Lanes.create(%{slug: "missing-profile", config: %{"tracker" => %{"kind" => "memory"}}})
    assert Lanes.list() == []
    assert Repo.aggregate(LaneVersion, :count) == 0
  end

  @tag :tmp_dir
  test "malformed imported YAML reports its field and writes no profile or lane", %{tmp_dir: root} do
    path = Path.join(root, "invalid.md")
    File.write!(path, "---\n- not\n- a map\n---\n")
    assert {:error, [%{path: "front_matter"}]} = Lanes.import_file(path, slug: "invalid-yaml")
    assert Lanes.warnings("- not\n- a map") == []
    assert ExecutionProfiles.list() == []
    assert Lanes.list() == []
    assert Repo.aggregate(LaneVersion, :count) == 0
  end

  @tag :tmp_dir
  test "offline import preserves an occupied identity and rolls back around unverifiable ownership", %{tmp_dir: root} do
    stop_store()
    path = Path.join(root, "workflow.md")
    owned = Path.join(root, "owned")
    config = %{"tracker" => %{"kind" => "memory"}, "workspace" => %{"root" => owned}}
    File.write!(path, Workflow.render(Workflow.encode_config(config), "first"))
    assert {:ok, lane, _warnings} = Lanes.import_file(path, slug: "offline-import")
    File.mkdir_p!(owned)
    File.write!(Path.join(owned, "checkout"), "keep")
    File.write!(path, Workflow.render(Workflow.encode_config(config), "second"))
    assert {:ok, updated, _warnings} = Lanes.import_file(path, slug: lane.slug)
    assert updated.id == lane.id
    assert [%LaneVersion{prompt: "second"}, %LaneVersion{prompt: "first"}] = Lanes.versions(updated)
    assert File.read!(Path.join(owned, "checkout")) == "keep"

    Repo.update!(Ecto.Changeset.change(Lanes.current_version(updated), front_matter: "tracker: ["))
    Repo.update!(Ecto.Changeset.change(ExecutionProfiles.get(updated.execution_profile_id), repair_error: "unrecoverable legacy infrastructure"))
    profile_count = length(ExecutionProfiles.list())
    File.write!(path, Workflow.render(Workflow.encode_config(put_in(config, ["workspace", "root"], Path.join(root, "other"))), "other"))
    assert {:error, _errors} = Lanes.import_file(path, slug: "offline-other")
    assert is_nil(Lanes.get_by_slug("offline-other"))
    assert length(ExecutionProfiles.list()) == profile_count
    assert {:error, :no_version} = Lanes.export(updated)
  end

  @tag :remediation
  @tag :tmp_dir
  test "remediation: identical offline managed reimport preserves non-memory tracker ownership", %{tmp_dir: root} do
    stop_store()
    path = Path.join(root, "managed.md")

    config = %{
      "tracker" => %{"kind" => "linear", "api_key" => "$LINEAR_API_KEY", "project_slug" => "test-project"},
      "workspace" => %{"root" => "/managed/reimport"},
      "worker" => %{
        "environment" => %{
          "kind" => "google_workstations",
          "deployment_id" => "managed-reimport",
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
    }

    File.write!(path, Workflow.render(Workflow.encode_config(config), "managed prompt"))
    assert {:ok, lane, _warnings} = Lanes.import_file(path, slug: "managed-reimport")
    assert {:ok, %{settings: original_settings}} = Lanes.resolve_lane(lane)
    original_identity = EnvironmentConfig.identity(original_settings)
    assert is_binary(original_identity)

    assert {:ok, reimported, _warnings} = Lanes.import_file(path, slug: lane.slug)
    assert reimported.id == lane.id
    refute reimported.enabled
    assert reimported.current_version_id != lane.current_version_id
    assert {:ok, %{settings: settings}} = Lanes.resolve_lane(reimported)
    assert settings.tracker.kind == "linear"
    assert EnvironmentConfig.identity(settings) == original_identity

    File.write!(path, Workflow.render(Workflow.encode_config(Map.put(config, "tracker", %{"kind" => "memory"})), "changed tracker"))
    assert {:error, errors} = Lanes.import_file(path, slug: lane.slug)
    assert Enum.any?(errors, &(&1.path == "worker.environment"))
    assert Lanes.get!(lane.id).current_version_id == reimported.current_version_id
    assert {:ok, %{settings: ^settings}} = Lanes.resolve_lane(Lanes.get!(lane.id))
  end

  @tag :tmp_dir
  test "offline deletion retains ownership until local inventory is empty", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Offline deletion", workspace_base: root, worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "offline-delete", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, settings} = LaneStore.settings(lane.id)
    File.mkdir_p!(settings.workspace.root)
    retained = Path.join(settings.workspace.root, "checkout")
    File.write!(retained, "keep")
    stop_store()

    assert {:error, [%{path: "lane"}]} = Lanes.delete(lane)
    assert Lanes.get!(lane.id).deleted_at == nil
    assert File.read!(retained) == "keep"

    File.rm!(retained)
    assert :ok = Lanes.delete(lane)
    assert is_nil(Lanes.get(lane.id))
  end

  @tag :tmp_dir
  test "offline import rejects overlapping roots and retained identity changes", %{tmp_dir: root} do
    owned_root = Path.join(root, "owned")
    {:ok, profile} = ExecutionProfiles.create(%{name: "Offline owner", workspace_base: owned_root, worker: %{}})

    {:ok, lane} =
      Lanes.create(%{
        slug: "offline-owner",
        execution_profile_id: profile.id,
        workspace_subdir: ".",
        config: %{"tracker" => %{"kind" => "memory"}}
      })

    File.mkdir_p!(owned_root)
    File.write!(Path.join(owned_root, "retained"), "keep")
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, LaneStore)

    on_exit(fn ->
      if is_nil(Process.whereis(LaneStore)), do: Supervisor.restart_child(SymphonyElixir.Supervisor, LaneStore)
    end)

    overlap = Path.join(root, "overlap.md")
    File.write!(overlap, Workflow.render(Workflow.encode_config(%{"workspace" => %{"root" => owned_root}, "tracker" => %{"kind" => "memory"}}), ""))
    assert {:error, overlap_errors} = Lanes.import_file(overlap, slug: "offline-overlap")
    assert Enum.any?(overlap_errors, &String.contains?(&1.message, "conflicts"))
    assert is_nil(Lanes.get_by_slug("offline-overlap"))

    moved = Path.join(root, "moved.md")
    File.write!(moved, Workflow.render(Workflow.encode_config(%{"workspace" => %{"root" => Path.join(root, "moved")}, "tracker" => %{"kind" => "memory"}}), ""))
    assert {:error, identity_errors} = Lanes.import_file(moved, slug: lane.slug)
    assert Enum.any?(identity_errors, &String.contains?(&1.message, "guarded field"))
    assert Lanes.get!(lane.id).execution_profile_id == profile.id

    assert {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, LaneStore)
  end

  @tag :remediation
  @tag :tmp_dir
  test "remediation: offline target imports repair independent legacy overlap groups sequentially", %{tmp_dir: root} do
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

    stop_store()
    path = Path.join(root, "repair.md")
    second_root = Path.join(root, "repaired-second")
    config = %{"tracker" => %{"kind" => "memory"}, "workspace" => %{"root" => second_root}}
    File.write!(path, Workflow.render(Workflow.encode_config(config), "repaired second"))

    assert {:ok, repaired_second, _warnings} = Lanes.import_file(path, slug: second.slug)
    assert repaired_second.id == second.id
    refute repaired_second.enabled
    assert repaired_second.execution_profile_id != second.execution_profile_id
    assert {:ok, %{settings: second_settings}} = Lanes.resolve_lane(repaired_second)
    assert second_settings.workspace.root == second_root
    assert Lanes.get!(first.id) == first
    assert Lanes.get!(third.id) == third
    assert Lanes.get!(fourth.id) == fourth

    first_root = ExecutionProfiles.get(first.execution_profile_id).workspace_base
    File.write!(path, Workflow.render(Workflow.encode_config(put_in(config, ["workspace", "root"], first_root)), "collision"))
    profiles = ExecutionProfiles.list()
    assert {:error, errors} = Lanes.import_file(path, slug: fourth.slug)
    assert Enum.any?(errors, &String.contains?(&1.message, "conflicts"))
    assert Lanes.get!(fourth.id) == fourth
    assert ExecutionProfiles.list() == profiles

    fourth_root = Path.join(root, "repaired-fourth")
    File.write!(path, Workflow.render(Workflow.encode_config(put_in(config, ["workspace", "root"], fourth_root)), "repaired fourth"))
    assert {:ok, repaired_fourth, _warnings} = Lanes.import_file(path, slug: fourth.slug)
    assert repaired_fourth.id == fourth.id
    refute repaired_fourth.enabled
    assert {:ok, %{settings: fourth_settings}} = Lanes.resolve_lane(repaired_fourth)
    assert fourth_settings.workspace.root == fourth_root
    assert Lanes.get!(first.id) == first
    assert Lanes.get!(third.id) == third
    assert [%LaneVersion{prompt: "repaired second"}, %LaneVersion{}] = Lanes.versions(repaired_second)
    assert [%LaneVersion{prompt: "repaired fourth"}, %LaneVersion{}] = Lanes.versions(repaired_fourth)
  end

  @tag :tmp_dir
  test "offline imports repair independent invalid lanes without abandoning known retained ownership", %{tmp_dir: root} do
    lanes =
      for slug <- ["invalid-first", "invalid-second"] do
        workspace_root = Path.join(root, slug)
        raw = %{"tracker" => %{"kind" => "memory"}, "workspace" => %{"root" => workspace_root}}
        {:ok, lane} = create_lane(%{slug: slug, workspace_subdir: ".", front_matter: Workflow.encode_config(raw)})
        version = Lanes.current_version(lane)
        invalid = raw |> Map.put("codex", %{"command" => ""}) |> Workflow.encode_config()
        Repo.update!(Ecto.Changeset.change(version, front_matter: invalid))
        profile = ExecutionProfiles.get(lane.execution_profile_id)
        Repo.update!(Ecto.Changeset.change(profile, repair_error: "invalid legacy command"))
        File.mkdir_p!(workspace_root)
        File.write!(Path.join(workspace_root, "retained"), slug)
        lane
      end

    stop_store()
    [first, second] = lanes
    path = Path.join(root, "repair-invalid.md")
    config = %{"tracker" => %{"kind" => "memory"}, "workspace" => %{"root" => Path.join(root, first.slug)}}
    File.write!(path, Workflow.render(Workflow.encode_config(config), "repaired"))
    assert {:ok, repaired_first, _warnings} = Lanes.import_file(path, slug: first.slug)
    assert repaired_first.id == first.id
    refute repaired_first.enabled
    assert Lanes.get!(second.id) == second
    assert ExecutionProfiles.get(second.execution_profile_id).repair_error

    assert {:error, errors} = Lanes.import_file(path, slug: "new-collision")
    assert Enum.any?(errors, &String.contains?(&1.message, "conflicts"))
    refute Lanes.get_by_slug("new-collision")

    second_config = put_in(config, ["workspace", "root"], Path.join(root, second.slug))
    File.write!(path, Workflow.render(Workflow.encode_config(second_config), "repaired second"))
    assert {:ok, repaired_second, _warnings} = Lanes.import_file(path, slug: second.slug)
    assert repaired_second.id == second.id
    refute repaired_second.enabled

    for lane <- lanes do
      assert File.read!(Path.join([root, lane.slug, "retained"])) == lane.slug
      assert [_new, old] = Lanes.versions(Lanes.get!(lane.id))
      assert {:ok, old_workflow} = Workflow.parse_parts(old.front_matter, old.prompt)
      assert old_workflow.config["codex"]["command"] == ""
    end
  end

  defp stop_store do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, LaneStore)

    on_exit(fn ->
      if is_nil(Process.whereis(LaneStore)), do: Supervisor.restart_child(SymphonyElixir.Supervisor, LaneStore)
    end)
  end

  defp profile_id do
    {:ok, profile} =
      ExecutionProfiles.create(%{
        name: "Test profile #{System.unique_integer([:positive])}",
        workspace_base: Path.join(System.tmp_dir!(), "symphony-workspaces-#{System.unique_integer([:positive])}"),
        worker: %{}
      })

    profile.id
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
