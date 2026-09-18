defmodule SymphonyElixir.LanesTest do
  use ExUnit.Case
  alias SymphonyElixir.{Lanes, LaneStore, Repo, TestSupport}
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
             Lanes.create(%{slug: "features", front_matter: @front_matter, prompt: "Do work", note: "first"})

    assert lane.name == "features"
    assert [%LaneVersion{id: id, note: "first", prompt: "Do work", front_matter: @front_matter}] = Lanes.versions(lane)
    assert lane.current_version_id == id
    assert Lanes.get_by_slug("features").id == lane.id
    assert Lanes.get!(lane.id).id == lane.id
    assert [^lane] = Lanes.list()
    assert {:ok, %{version_id: ^id}} = LaneStore.lookup(lane.id)
  end

  test "invalid config and invalid metadata never write a lane or a version" do
    assert {:error, errors} = Lanes.create(%{slug: "bugs", front_matter: "polling:\n  interval_ms: nope", prompt: ""})
    assert Enum.any?(errors, &(&1.path == "polling.interval_ms"))
    assert {:error, [%{path: "front_matter"}]} = Lanes.create(%{slug: "bugs", front_matter: "tracker: ["})
    assert {:error, [%{path: "front_matter"}]} = Lanes.create(%{slug: "sequence", front_matter: "- tracker\n- memory"})
    assert {:error, [%{path: "tracker.kind"}]} = Lanes.create(%{slug: "unsupported", front_matter: "tracker:\n  kind: unsupported"})
    assert {:error, [%{path: "slug"}]} = Lanes.create(%{slug: "Bad Slug", front_matter: @front_matter})
    assert {:error, [%{path: "slug"}]} = Lanes.create(%{slug: "x", front_matter: @front_matter})
    assert {:error, [%{path: "executor"}]} = Lanes.create(%{slug: "okay", executor: "kubernetes", front_matter: @front_matter})
    assert Lanes.list() == []
    assert Repo.aggregate(LaneVersion, :count) == 0
  end

  test "the reserved creation slug cannot be imported or assigned by an update" do
    assert {:error, [%{path: "slug"}]} = Lanes.import_file(Path.join(@fixtures, "example.md"), slug: "new")
    assert Lanes.list() == []
    assert Repo.aggregate(LaneVersion, :count) == 0

    {:ok, lane} = Lanes.create(%{slug: "new-work", front_matter: @front_matter, prompt: "original"})
    assert {:error, [%{path: "slug"}]} = Lanes.update(lane, %{slug: "new", prompt: "must not be saved"})
    assert is_nil(Lanes.get_by_slug("new"))
    assert Lanes.get_by_slug("new-work").id == lane.id
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    assert [%LaneVersion{prompt: "original"}] = Lanes.versions(lane)
  end

  test "wrong JSON types return field errors and cannot overwrite a current version" do
    {:ok, lane} = Lanes.create(%{slug: "typed", front_matter: @front_matter, prompt: "original"})

    for {field, value} <- [{"slug", nil}, {"name", []}, {"enabled", "false"}, {"enabled", nil}, {"executor", %{}}, {"front_matter", nil}, {"prompt", []}, {"note", false}] do
      assert {:error, errors} = Lanes.update(lane, %{field => value})
      assert Enum.any?(errors, &(&1.path == field))
    end

    assert {:error, [%{path: "lane"}]} = Lanes.create([])
    assert {:error, [%{path: "lane"}]} = Lanes.update(lane, nil)
    assert {:error, [%{path: "lane"}]} = Lanes.update(lane, %{42 => "not a field"})
    assert {:error, [%{path: "version"}]} = Lanes.activate_version(lane, %{})
    assert {:error, [%{path: "front_matter"}, %{path: "prompt"}]} = Lanes.validate_version(nil, nil, nil)
    assert [%LaneVersion{prompt: "original"}] = Lanes.versions(lane)
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
  end

  test "partial edits reload current rows instead of clobbering newer edits from stale structs" do
    {:ok, original} = Lanes.create(%{slug: "partial", front_matter: @front_matter, prompt: "first"})
    {:ok, renamed} = Lanes.update(original, %{name: "Renamed"})
    assert renamed.current_version_id == original.current_version_id
    {:ok, second} = Lanes.update(original, %{prompt: "second"})
    {:ok, third} = Lanes.update(original, %{front_matter: @front_matter <> "\npolling:\n  interval_ms: 2000"})
    assert third.name == "Renamed"
    assert [%LaneVersion{prompt: "second"}, %LaneVersion{id: second_id}, %LaneVersion{}] = Lanes.versions(third)
    assert second_id == second.current_version_id
    assert {:error, [%{path: "polling.interval_ms"}]} = Lanes.update(original, %{front_matter: "polling:\n  interval_ms: -1"})
    assert Lanes.get!(original.id).current_version_id == third.current_version_id
  end

  test "activation moves the pointer without inserting and rejects another lane's version" do
    {:ok, first} = Lanes.create(%{slug: "rollback", front_matter: @front_matter, prompt: "first"})
    {:ok, second} = Lanes.update(first, %{prompt: "second"})
    {:ok, other} = Lanes.create(%{slug: "other", front_matter: @front_matter})
    assert {:ok, %{current_version_id: id}} = Lanes.activate_version(second, first.current_version_id)
    assert id == first.current_version_id
    assert length(Lanes.versions(first)) == 2
    assert {:error, [%{path: "version"}]} = Lanes.activate_version(first, other.current_version_id)
  end

  test "SQLite ID bounds reject before mutation and preserve the published runtime" do
    {:ok, lane} = Lanes.create(%{slug: "id-boundary", front_matter: @front_matter, prompt: "unchanged"})
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
    managed_config = managed_front_matter(tmp_dir)
    {:ok, lane} = Lanes.create(%{slug: "guarded", front_matter: @front_matter, prompt: "local"})
    local_version = lane.current_version_id
    {:ok, managed} = Lanes.update(lane, %{front_matter: managed_config})
    # Managed publication reserves its identity even before an orchestrator claims it.
    assert {:error, [%{path: "worker.environment"}]} = Lanes.update(managed, %{name: "must not stick", front_matter: @front_matter})
    assert {:error, [%{path: "worker.environment"}]} = Lanes.activate_version(lane, local_version)
    assert length(Lanes.versions(lane)) == 2
    assert Lanes.get!(lane.id).name == "guarded"
    assert Lanes.get!(lane.id).current_version_id == managed.current_version_id
    assert {:ok, %{version_id: version_id}} = LaneStore.lookup(lane.id)
    assert version_id == managed.current_version_id
  end

  @tag :tmp_dir
  test "guard rejection at publication rolls back metadata even after an external DB version change", %{tmp_dir: tmp_dir} do
    managed_config = managed_front_matter(tmp_dir)
    {:ok, lane} = Lanes.create(%{slug: "publication-guard", front_matter: @front_matter})
    {:ok, published} = LaneStore.lookup(lane.id)
    {:ok, token} = LaneStore.protect_environment(lane.id, nil)
    version = Lanes.current_version(lane)
    Repo.update!(Ecto.Changeset.change(version, front_matter: managed_config))
    assert {:error, :environment_identity_in_use} = LaneStore.refresh(lane.id)
    assert {:error, [%{path: "worker.environment"}]} = Lanes.update(lane, %{name: "must roll back"})
    assert Lanes.get!(lane.id).name == "publication-guard"
    assert {:ok, ^published} = LaneStore.lookup(lane.id)
    assert [%LaneVersion{id: version_id}] = Lanes.versions(lane)
    assert version_id == published.version_id
    assert {:ok, validated} = Lanes.validate_version(nil, managed_config, "")
    assert {:error, :environment_identity_in_use} = LaneStore.put_entry(%{published | settings: validated.settings})
    assert {:ok, ^token} = LaneStore.protect_environment(lane.id, nil, token)
    assert :ok = LaneStore.release_environment(lane.id, token, :empty_inventory)
  end

  test "enable validates current config, disable remains available, and deleted slugs stay reserved" do
    {:ok, stale} = Lanes.create(%{slug: "lifecycle", front_matter: @front_matter})
    assert {:ok, %{enabled: true}} = Lanes.set_enabled(stale, true)
    assert {:error, :lane_active} = Lanes.delete(stale)
    assert :ok = Lanes.disable(stale.id, "operator stopped")
    assert :ok = Lanes.disable(-1, "missing")
    assert {:ok, %{enabled: false, error: "operator stopped"}} = LaneStore.lookup(stale.id)
    version = Lanes.current_version(stale)
    Repo.update!(Ecto.Changeset.change(version, front_matter: "tracker: ["))
    assert {:error, [%{path: "front_matter"}]} = Lanes.set_enabled(stale, true)
    assert {:ok, %{enabled: false}} = Lanes.update(stale, %{name: "Repair me"})
    assert :ok = Lanes.delete(stale)
    assert is_nil(Lanes.get(stale.id))
    assert :ok = Lanes.disable(stale.id, "already removed")
    assert :ok = Lanes.delete(stale)
    assert :error = LaneStore.lookup(stale.id)
    assert is_nil(Lanes.get_by_slug("lifecycle"))
    assert Repo.get!(Lane, stale.id).deleted_at
    assert {:error, [%{path: "slug", message: "has already been taken"}]} = Lanes.create(%{slug: "lifecycle", front_matter: @front_matter})
    assert {:error, [%{path: "lane"}]} = Lanes.update(stale, %{prompt: "resurrect"})
  end

  test "import and reimport preserve canonical LF fixtures and server config is ignored" do
    for {file, slug} <- [{"client-template.md", "features"}, {"example.md", "example"}] do
      path = Path.join(@fixtures, file)
      content = File.read!(path)
      assert {:ok, lane, warnings} = Lanes.import_file(path, slug: slug, name: "Imported")
      refute lane.enabled
      assert Enum.any?(warnings, &String.contains?(&1, "server"))
      assert {:ok, ^content} = Lanes.export(lane)
      assert {:ok, updated, _} = Lanes.import_file(path, slug: slug, note: "again")
      assert updated.id == lane.id
      assert [%LaneVersion{note: "again"}, %LaneVersion{}] = Lanes.versions(updated)
    end

    assert {:ok, validated} = Lanes.validate_version(nil, @front_matter <> "\nserver: invalid-but-ignored", "")
    assert Enum.any?(validated.warnings, &String.contains?(&1, "ignored"))
    assert is_nil(validated.settings.server.port)
    assert {:error, [%{path: "file"}]} = Lanes.import_file("/nope/WORKFLOW.md", slug: "missing")
    assert {:error, [%{path: "slug"}]} = Lanes.import_file(Path.join(@fixtures, "example.md"), slug: nil, name: "Missing slug")
    assert Enum.map(Lanes.list(), & &1.slug) == ["features", "example"]
    assert {:error, :no_version} = Lanes.export(%Lane{current_version_id: nil})
  end

  @tag :tmp_dir
  test "credential-free imports preserve raw references and remain disabled across edits and rollback", %{tmp_dir: tmp_dir} do
    System.delete_env("LINEAR_API_KEY")
    front = "tracker:\n  kind: linear\n  api_key: $LINEAR_API_KEY\n  project_slug: offline-project"
    content = "---\n#{front}\n---\nOffline prompt\n"
    path = Path.join(tmp_dir, "offline.md")
    File.write!(path, content)

    assert {:ok, lane, []} = Lanes.import_file(path, slug: "offline")
    refute lane.enabled
    assert {:ok, ^content} = Lanes.export(lane)
    assert Lanes.current_version(lane).front_matter == front
    assert {:ok, %{settings: %{tracker: %{api_key: "$LINEAR_API_KEY"}}}} = Lanes.validate_version(nil, front, "", :structure)
    assert {:ok, updated, []} = Lanes.import_file(path, slug: "offline")
    assert {:ok, %{enabled: false}} = Lanes.activate_version(updated, lane.current_version_id)
    assert {:error, [%{path: "tracker"}]} = Lanes.set_enabled(lane, true)
    assert {:error, [%{path: "tracker"}]} = Lanes.validate_version(nil, front, "")
    refute Lanes.get!(lane.id).enabled
  end

  @tag :tmp_dir
  test "enabled records cannot use offline import or version mutation to bypass credentials", %{tmp_dir: tmp_dir} do
    System.delete_env("LINEAR_API_KEY")
    front = "tracker:\n  kind: linear\n  api_key: $LINEAR_API_KEY\n  project_slug: offline-project"
    path = Path.join(tmp_dir, "offline.md")
    File.write!(path, "---\n#{front}\n---\n")

    assert {:error, [%{path: "tracker"}]} = Lanes.create(%{slug: "enabled-create", enabled: true, front_matter: front})
    assert {:ok, lane, []} = Lanes.import_file(path, slug: "enabled-existing")
    Repo.update!(Ecto.Changeset.change(lane, enabled: true))
    assert {:error, [%{path: "tracker"}]} = Lanes.import_file(path, slug: lane.slug)
    assert {:error, [%{path: "tracker"}]} = Lanes.update(lane, %{prompt: "must not save"})
    assert {:error, [%{path: "tracker"}]} = Lanes.activate_version(lane, lane.current_version_id)
    assert [%LaneVersion{prompt: ""}] = Lanes.versions(lane)
    assert {:ok, %{enabled: false}} = Lanes.set_enabled(lane, false)
  end

  test "offline validation rejects malformed tracker, managed provider and backend settings without credentials" do
    System.delete_env("LINEAR_API_KEY")
    front = "tracker:\n  kind: linear\n  api_key: $LINEAR_API_KEY\n  project_slug: offline-project"
    invalid_provider = """

    worker:
      environment:
        kind: google_workstations
        deployment_id: offline
        startup_timeout_ms: 1000
        shutdown_timeout_ms: 1000
        provider:
          project: offline
    """

    for {slug, config, path} <- [
          {"bad-scope", String.replace(front, "project_slug: offline-project", "provider:\n    team_keys: wrong"), "tracker"},
          {"bad-key", String.replace(front, "$LINEAR_API_KEY", "[]"), "tracker.api_key"},
          {"bad-provider-key", front <> "\n  provider:\n    api_key: []", "tracker"},
          {"bad-provider", front <> invalid_provider, "worker"},
          {"bad-backend", front <> "\ncodex:\n  command: ' '", "codex.command"}
        ] do
      assert {:error, errors} = Lanes.create(%{slug: slug, front_matter: config})
      assert Enum.any?(errors, &(&1.path == path))
    end

    assert Lanes.list() == []
    assert Repo.aggregate(LaneVersion, :count) == 0
  end

  test "all tracker adapters defer credential readiness but retain provider validation for disabled lanes" do
    for name <- ["LINEAR_API_KEY", "GITHUB_TOKEN", "GITLAB_PAT", "ASANA_PAT", "JIRA_API_TOKEN", "JIRA_EMAIL"] do
      previous = System.get_env(name)
      System.delete_env(name)
      on_exit(fn -> TestSupport.restore_env(name, previous) end)
    end

    for {kind, provider, active, terminal, invalid_provider} <- [
          {"linear", %{project_slug: "offline"}, ["Todo"], ["Done"], %{team_keys: "wrong"}},
          {"github", %{repo: "owner/repo"}, ["open"], ["closed"], %{repo: "not-a-repo"}},
          {"gitlab", %{project_path: "group/repo"}, ["opened"], ["closed"], %{project_path: "group / repo"}},
          {"asana", %{project_gid: "123"}, ["Todo"], ["Done"], %{project_gid: 123}},
          {"jira", %{base_url: "https://example.atlassian.net", project_key: "OFF"}, ["Todo"], ["Done"], %{base_url: "http://insecure"}}
        ] do
      tracker = %{kind: kind, provider: provider, active_states: active, terminal_states: terminal}
      front = Jason.encode!(%{tracker: tracker})
      assert {:ok, lane} = Lanes.create(%{slug: "offline-#{kind}", front_matter: front})
      assert {:error, [%{path: "tracker"}]} = Lanes.set_enabled(lane, true)
      assert {:error, [%{path: "tracker"}]} = Lanes.validate_version(nil, front, "")
      invalid_front = Jason.encode!(%{tracker: %{tracker | provider: invalid_provider}})
      assert {:error, [%{path: "tracker"}]} = Lanes.update(lane, %{front_matter: invalid_front})
      refute Lanes.get!(lane.id).enabled
      assert [%LaneVersion{front_matter: ^front}] = Lanes.versions(lane)
    end
  end

  test "error formatting retains actionable field paths" do
    assert [%{path: "worker"}] = Lanes.errors_for({:invalid_workflow_config, "managed and static worker settings conflict"})
    assert [%{path: "codex.command", message: "can't be blank"}] = Lanes.errors_for({:invalid_workflow_config, "codex.command can't be blank"})
    assert [%{path: "tracker.kind"}] = Lanes.errors_for(:missing_tracker_kind)
    assert [%{path: "tracker", message: "missing linear scope"}] = Lanes.errors_for(:missing_linear_scope)
    assert [%{path: "front_matter"}] = Lanes.errors_for({:weird, 1})
  end

  defp managed_front_matter(tmp_dir) do
    kubeconfig = Path.join(tmp_dir, "kubeconfig")
    File.write!(kubeconfig, "apiVersion: v1\nkind: Config\n")
    String.replace(@managed, "/etc/symphony/kubeconfig", Jason.encode!(kubeconfig))
  end
end
