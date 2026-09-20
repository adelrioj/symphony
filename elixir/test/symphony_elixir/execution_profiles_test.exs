defmodule SymphonyElixir.ExecutionProfilesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.{ExecutionProfiles, LaneStore, Lanes, TestSupport}
  alias SymphonyElixir.Workflow

  setup do
    TestSupport.reset_lanes!()
    on_exit(fn -> TestSupport.reset_lanes!() end)
    :ok
  end

  @tag :tmp_dir
  test "shared profile validation is all or nothing", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Shared", workspace_base: root, worker: %{}})
    {:ok, first} = Lanes.create(%{slug: "first", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, second} = Lanes.create(%{slug: "second", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    assert {:ok, updated} = ExecutionProfiles.update(profile, %{worker: %{"max_concurrent_agents_per_host" => 2}})
    assert updated.worker == %{"max_concurrent_agents_per_host" => 2}
    assert {:ok, %{settings: %{worker: %{max_concurrent_agents_per_host: 2}}}} = LaneStore.lookup(first.id)
    assert {:ok, %{settings: %{worker: %{max_concurrent_agents_per_host: 2}}}} = LaneStore.lookup(second.id)
    {:ok, before_invalid_first} = LaneStore.lookup(first.id)
    {:ok, before_invalid_second} = LaneStore.lookup(second.id)

    assert {:error, errors} = ExecutionProfiles.update(updated, %{worker: %{"max_concurrent_agents_per_host" => -1}})
    assert errors != []
    assert ExecutionProfiles.get(profile.id).worker == updated.worker
    assert {:ok, ^before_invalid_first} = LaneStore.lookup(first.id)
    assert {:ok, ^before_invalid_second} = LaneStore.lookup(second.id)
  end

  @tag :tmp_dir
  test "profile infrastructure cannot be shadowed and nested lane values survive", %{tmp_dir: root} do
    profile = %{"name" => "Local", "workspace_base" => root, "worker" => %{}}
    config = %{"tracker" => %{"kind" => "memory"}, "extension" => %{"nested" => [1, true]}}

    assert {:ok, value} = Configuration.resolve(profile, config, "features", "Do work")
    assert value.settings.workspace.root == Path.join(root, "features")
    assert value.workflow.config["extension"] == %{"nested" => [1, true]}

    assert {:error, errors} = Configuration.resolve(profile, Map.put(config, "worker", %{}), "features", "Do work")
    assert Enum.any?(errors, &(&1.path == "config.worker"))
    assert {:error, _} = Configuration.resolve(profile, config, "../outside", "Do work")
  end

  @tag :tmp_dir
  test "absolute and traversal workspace subdirectories are rejected", %{tmp_dir: root} do
    profile = %{"workspace_base" => root, "worker" => %{}}
    config = %{"tracker" => %{"kind" => "memory"}}

    assert {:error, absolute_errors} = Configuration.resolve(profile, config, Path.join(root, "features"), "work")
    assert Enum.any?(absolute_errors, &(&1.path == "workspace_subdir"))

    assert {:error, traversal_errors} = Configuration.resolve(profile, config, "nested/../features", "work")
    assert Enum.any?(traversal_errors, &(&1.path == "workspace_subdir"))
  end

  @tag :tmp_dir
  test "a local symlink cannot escape the profile workspace base", %{tmp_dir: root} do
    base = Path.join(root, "base")
    outside = Path.join(root, "outside")
    File.mkdir_p!(base)
    File.mkdir_p!(outside)
    :ok = File.ln_s(outside, Path.join(base, "link"))

    profile = %{"workspace_base" => base, "worker" => %{}}
    config = %{"tracker" => %{"kind" => "memory"}}

    assert {:error, errors} = Configuration.resolve(profile, config, "link", "work")
    assert Enum.any?(errors, &(&1.path == "workspace_subdir"))
  end

  @tag :tmp_dir
  test "identity subdirectory keeps the exact local workspace root", %{tmp_dir: root} do
    profile = %{"workspace_base" => root, "worker" => %{}}
    config = %{"tracker" => %{"kind" => "memory"}}

    assert {:ok, value} = Configuration.resolve(profile, config, ".", "  work\n")
    assert value.settings.workspace.root == root
    assert value.workflow.prompt == "work"
  end

  test "remote workspace roots are not canonicalized on the daemon host" do
    profile = %{
      "workspace_base" => "/remote/does-not-exist",
      "worker" => %{"ssh_hosts" => ["worker.example"]}
    }

    assert {:ok, value} =
             Configuration.resolve(profile, %{"tracker" => %{"kind" => "memory"}}, "lane", "work")

    assert value.settings.workspace.root == "/remote/does-not-exist/lane"
  end

  @tag :tmp_dir
  test "split removes only profile-owned infrastructure and resolve merges it losslessly", %{tmp_dir: root} do
    raw = %{
      "worker" => %{"ssh_hosts" => [], "future" => %{"keep" => true}},
      "workspace" => %{"root" => root, "future" => [%{"value" => 1}]},
      "tracker" => %{"kind" => "memory"},
      "extension" => %{"nested" => [1, true]}
    }

    assert {profile, lane_config} = Configuration.split(raw)
    assert profile == %{"worker" => raw["worker"], "workspace_base" => root}

    assert lane_config == %{
             "workspace" => %{"future" => [%{"value" => 1}]},
             "tracker" => %{"kind" => "memory"},
             "extension" => %{"nested" => [1, true]}
           }

    assert {:ok, value} = Configuration.resolve(profile, lane_config, ".", "work")
    assert value.workflow.config["worker"] == raw["worker"]
    assert value.workflow.config["workspace"] == %{"root" => root, "future" => [%{"value" => 1}]}
    assert value.workflow.config["extension"] == raw["extension"]
  end

  @tag :tmp_dir
  test "encoded raw configuration preserves secret references", %{tmp_dir: root} do
    config = %{
      "tracker" => %{"kind" => "memory", "api_key" => "$LINEAR_API_KEY"},
      "extension" => %{"secret" => "$OTHER_SECRET"}
    }

    encoded = Workflow.encode_config(config)
    assert Jason.decode!(encoded) == config
    assert encoded =~ "$LINEAR_API_KEY"
    assert encoded =~ "$OTHER_SECRET"

    assert {:ok, value} = Configuration.resolve(%{"workspace_base" => root, "worker" => %{}}, config, ".", "work")
    assert value.workflow.config["tracker"]["api_key"] == "$LINEAR_API_KEY"
  end

  test "absence uses schema defaults while supplied invalid infrastructure is rejected" do
    assert {%{}, %{"tracker" => %{"kind" => "memory"}}} = Configuration.split(%{"tracker" => %{"kind" => "memory"}})

    assert {:error, errors} =
             Configuration.resolve(%{"workspace_base" => nil, "worker" => %{}}, %{"tracker" => %{"kind" => "memory"}}, ".", "work")

    assert Enum.any?(errors, &(&1.path == "profile.workspace_base"))
  end

  @tag :tmp_dir
  test "location changes fail closed when the new SSH target cannot be inventoried", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "SSH target", workspace_base: root, worker: %{}})
    {:ok, _lane} = Lanes.create(%{slug: "ssh-target", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})

    assert {:error, errors} =
             ExecutionProfiles.update(profile, %{
               workspace_base: "/remote/workspaces",
               worker: %{"ssh_hosts" => ["127.0.0.1:1"]}
             })

    assert errors != []
    assert ExecutionProfiles.get(profile.id).workspace_base == root
  end

  @tag :tmp_dir
  test "disabled lanes still prevent overlapping effective workspaces", %{tmp_dir: root} do
    {:ok, first_profile} = ExecutionProfiles.create(%{name: "First", workspace_base: root, worker: %{}})
    {:ok, second_profile} = ExecutionProfiles.create(%{name: "Second", workspace_base: root, worker: %{}})
    {:ok, _first} = Lanes.create(%{slug: "first", execution_profile_id: first_profile.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})

    assert {:error, errors} =
             Lanes.create(%{slug: "second", execution_profile_id: second_profile.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})

    assert errors != []
  end

  @tag :tmp_dir
  test "concurrent profile edits, relinking and deletion leave complete results", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Concurrent", workspace_base: root, worker: %{"max_concurrent_agents_per_host" => 2}})
    {:ok, other} = ExecutionProfiles.create(%{name: "Other", workspace_base: Path.join(root, "other"), worker: %{"max_concurrent_agents_per_host" => 7}})
    {:ok, first} = Lanes.create(%{slug: "concurrent-first", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, second} = Lanes.create(%{slug: "concurrent-second", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})

    results =
      [
        Task.async(fn -> ExecutionProfiles.update(profile, %{worker: %{"max_concurrent_agents_per_host" => 5}}) end),
        Task.async(fn -> Lanes.update(second, %{execution_profile_id: other.id}) end),
        Task.async(fn -> ExecutionProfiles.delete(profile) end)
      ]
      |> Enum.map(&Task.await(&1, 5_000))

    assert [{:ok, _updated}, {:ok, _relinked}, {:error, errors}] = results
    assert Enum.any?(errors, &(&1.path == "lanes"))

    assert {:ok, first_entry} = LaneStore.lookup(first.id)
    assert {:ok, second_entry} = LaneStore.lookup(second.id)
    assert first_entry.settings.worker.max_concurrent_agents_per_host == 5
    assert second_entry.settings.worker.max_concurrent_agents_per_host == 7
    assert Lanes.get!(second.id).execution_profile_id == other.id
  end
end
