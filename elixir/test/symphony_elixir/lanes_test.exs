defmodule SymphonyElixir.LanesTest do
  use ExUnit.Case
  alias SymphonyElixir.{ExecutionProfiles, LaneContext, Lanes, LaneStore, Repo, TestSupport, Workflow}
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.Lanes.{Lane, LaneVersion}

  @front_matter "tracker:\n  kind: memory\ncodex:\n  command: codex app-server"
  @fixtures Path.expand("../fixtures/lanes", __DIR__)
  @managed """
  tracker:
    kind: memory
  workspace:
    root: /state/workspaces
  worker:
    environment:
      kind: kubernetes
      deployment_id: guarded
      startup_timeout_ms: 1000
      shutdown_timeout_ms: 1000
      provider:
        kubeconfig: /etc/symphony/kubeconfig
        context: development-cluster
        namespace: symphony-workers
        template: linux-kata-v1
        ssh_user: developer
        ssh_port: 2222
        ssh_auth_volume: ssh-auth
  """

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
      assert_raise Ecto.NoResultsError, fn -> Lanes.get!(id) end
    end

    assert Process.whereis(LaneStore) == owner
    assert {:ok, ^published} = LaneStore.lookup(lane.id)
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    assert [%LaneVersion{prompt: "unchanged"}] = Lanes.versions(lane)
  end

  @tag :tmp_dir
  test "guarded update and rollback reject before committing metadata or version rows", %{tmp_dir: tmp_dir} do
    _managed_config = managed_front_matter(tmp_dir)
    {:ok, lane} = create_lane(%{slug: "guarded", front_matter: @front_matter, prompt: "local"})
    local_version = lane.current_version_id

    {:ok, managed_profile} =
      ExecutionProfiles.create(%{
        name: "Managed",
        workspace_base: tmp_dir,
        worker: %{
          "environment" => %{
            "kind" => "kubernetes",
            "deployment_id" => "guarded",
            "startup_timeout_ms" => 1000,
            "shutdown_timeout_ms" => 1000,
            "provider" => %{
              "kubeconfig" => Jason.encode!(Path.join(tmp_dir, "kubeconfig")),
              "context" => "development-cluster",
              "namespace" => "symphony-workers",
              "template" => "linux-kata-v1",
              "ssh_user" => "developer",
              "ssh_port" => 2222,
              "ssh_auth_volume" => "ssh-auth"
            }
          }
        }
      })

    assert {:error, managed_errors} = Lanes.update(lane, %{execution_profile_id: managed_profile.id})
    assert managed_errors != []
    managed = Lanes.get!(lane.id)
    # Managed publication reserves its identity even before an orchestrator claims it.
    assert {:ok, _} = Lanes.update(managed, %{name: "renamed"})
    assert Lanes.get!(lane.id).name == "renamed"
    assert Lanes.get!(lane.id).current_version_id == local_version
    assert {:ok, %{version_id: version_id}} = LaneStore.lookup(lane.id)
    assert version_id == managed.current_version_id
  end

  @tag :tmp_dir
  test "guard rejection at publication rolls back metadata even after an external DB version change", %{tmp_dir: tmp_dir} do
    managed_config = managed_front_matter(tmp_dir)
    {:ok, lane} = create_lane(%{slug: "publication-guard", front_matter: @front_matter})
    {:ok, published} = LaneStore.lookup(lane.id)
    {:ok, _token} = LaneStore.protect_environment(lane.id, nil)
    version = Lanes.current_version(lane)
    Repo.update!(Ecto.Changeset.change(version, front_matter: managed_config))
    assert :ok = LaneStore.refresh(lane.id)
    assert {:ok, _} = Lanes.update(lane, %{name: "must stick"})
    assert Lanes.get!(lane.id).name == "must stick"
    assert {:ok, %{name: "must stick"}} = LaneStore.lookup(lane.id)
    assert [%LaneVersion{id: version_id}] = Lanes.versions(lane)
    assert version_id == published.version_id
    assert {:ok, workflow} = Workflow.parse_parts(managed_config, "")
    {profile, config} = Configuration.split(workflow.config)
    assert {:ok, validated} = Configuration.resolve(profile, config, ".", "")
    assert :ok = LaneStore.put_entry(%{published | settings: validated.settings})
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
    assert [%{path: "codex.command", message: "can't be blank"}] = Lanes.errors_for({:invalid_workflow_config, "codex.command can't be blank"})
    assert [%{path: "tracker.kind"}] = Lanes.errors_for(:missing_tracker_kind)
    assert [%{path: "tracker", message: "missing linear scope"}] = Lanes.errors_for(:missing_linear_scope)
    assert [%{path: "front_matter"}] = Lanes.errors_for({:weird, 1})
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

  defp managed_front_matter(tmp_dir) do
    kubeconfig = Path.join(tmp_dir, "kubeconfig")
    File.write!(kubeconfig, "apiVersion: v1\nkind: Config\n")
    String.replace(@managed, "/etc/symphony/kubeconfig", Jason.encode!(kubeconfig))
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
