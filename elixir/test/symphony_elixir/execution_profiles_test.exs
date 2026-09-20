defmodule SymphonyElixir.ExecutionProfilesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Repo, TestSupport}
  alias SymphonyElixir.ExecutionProfiles.Configuration
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

    conflict_root = Path.join(root, "conflict")
    {:ok, blocker_profile} = ExecutionProfiles.create(%{name: "Blocker", workspace_base: Path.join(conflict_root, "first"), worker: %{}})
    {:ok, _blocker} = Lanes.create(%{slug: "blocker", execution_profile_id: blocker_profile.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})

    assert {:error, errors} = ExecutionProfiles.update(updated, %{workspace_base: conflict_root})
    assert errors != []
    assert ExecutionProfiles.get(profile.id).worker == updated.worker
    assert ExecutionProfiles.get(profile.id).workspace_base == root
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

  @tag :tmp_dir
  test "relative local workspace bases resolve against the data root", %{tmp_dir: root} do
    previous = Application.get_env(:symphony_elixir, :data_root)
    Application.put_env(:symphony_elixir, :data_root, root)
    on_exit(fn -> Application.put_env(:symphony_elixir, :data_root, previous) end)

    assert {:ok, value} =
             Configuration.resolve(
               %{"workspace_base" => "relative", "worker" => %{}},
               %{"tracker" => %{"kind" => "memory"}},
               ".",
               "work"
             )

    assert value.settings.workspace.root == Path.join(root, "relative")
  end

  @tag :tmp_dir
  test "cyclic local symlinks fail without hanging", %{tmp_dir: root} do
    loop = Path.join(root, "loop")
    :ok = File.ln_s("loop", loop)

    task =
      Task.async(fn ->
        Configuration.resolve(
          %{"workspace_base" => loop, "worker" => %{}},
          %{"tracker" => %{"kind" => "memory"}},
          ".",
          "work"
        )
      end)

    assert {:error, errors} = Task.await(task, 1_000)
    assert Enum.any?(errors, &(&1.path == "workspace_subdir"))
  end

  test "remote workspace roots fail closed when the target cannot canonicalize them" do
    profile = %{
      "workspace_base" => "/remote/does-not-exist",
      "worker" => %{"ssh_hosts" => ["worker.example"]}
    }

    assert {:error, errors} =
             Configuration.resolve(profile, %{"tracker" => %{"kind" => "memory"}}, "lane", "work")

    assert Enum.any?(errors, &(&1.path == "config"))
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

  test "managed workspace overlaps use provider ownership scope instead of lane identity" do
    worker = managed_worker()
    {:ok, first_profile} = ExecutionProfiles.create(%{name: "Managed first", workspace_base: "/managed/root", worker: worker})
    {:ok, second_profile} = ExecutionProfiles.create(%{name: "Managed second", workspace_base: "/managed/root/nested", worker: worker})

    assert {:ok, _lane} =
             Lanes.create(%{
               slug: "managed-first",
               execution_profile_id: first_profile.id,
               workspace_subdir: ".",
               config: %{"tracker" => %{"kind" => "memory"}}
             })

    assert {:error, errors} =
             Lanes.create(%{
               slug: "managed-second",
               execution_profile_id: second_profile.id,
               workspace_subdir: ".",
               config: %{"tracker" => %{"kind" => "memory"}}
             })

    assert Enum.any?(errors, &String.contains?(&1.message, "conflicts"))
  end

  @tag :tmp_dir
  test "SSH overlaps use shared targets and canonical nested roots", %{tmp_dir: root} do
    fake_ssh = Path.join(root, "ssh")
    previous_path = System.get_env("PATH")

    File.write!(fake_ssh, """
    #!/bin/sh
    case "$*" in
      *"find "*) exit 0 ;;
      *"/remote/root/nested"*) root=/remote/root/nested ;;
      *"/remote/disjoint"*) root=/remote/disjoint ;;
      *) root=/remote/root ;;
    esac
    printf '%s\t%s\n' "$root" "$root"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))
    on_exit(fn -> if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH") end)

    {:ok, first_profile} =
      ExecutionProfiles.create(%{
        name: "SSH first",
        workspace_base: "/remote/root",
        worker: %{"ssh_hosts" => ["host-a", "host-b"]}
      })

    {:ok, first} =
      Lanes.create(%{
        slug: "ssh-first",
        execution_profile_id: first_profile.id,
        config: %{"tracker" => %{"kind" => "memory"}}
      })

    {:ok, nested_profile} =
      ExecutionProfiles.create(%{
        name: "SSH nested",
        workspace_base: "/remote/root/nested",
        worker: %{"ssh_hosts" => ["host-b", "host-c"]}
      })

    assert {:error, _} =
             Lanes.create(%{
               slug: "ssh-nested",
               execution_profile_id: nested_profile.id,
               config: %{"tracker" => %{"kind" => "memory"}}
             })

    {:ok, disjoint_host_profile} =
      ExecutionProfiles.create(%{
        name: "SSH disjoint host",
        workspace_base: "/remote/root",
        worker: %{"ssh_hosts" => ["host-c"]}
      })

    assert {:ok, _} =
             Lanes.create(%{
               slug: "ssh-disjoint-host",
               execution_profile_id: disjoint_host_profile.id,
               config: %{"tracker" => %{"kind" => "memory"}}
             })

    {:ok, disjoint_root_profile} =
      ExecutionProfiles.create(%{
        name: "SSH disjoint root",
        workspace_base: "/remote/disjoint",
        worker: %{"ssh_hosts" => ["host-b"]}
      })

    assert {:ok, _} =
             Lanes.create(%{
               slug: "ssh-disjoint-root",
               execution_profile_id: disjoint_root_profile.id,
               config: %{"tracker" => %{"kind" => "memory"}}
             })

    assert :ok = Lanes.delete(first)
  end

  @tag :tmp_dir
  test "deletion refuses retained local workspaces", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Delete guard", workspace_base: root, worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "delete-guard", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, entry} = LaneStore.lookup(lane.id)
    File.mkdir_p!(entry.settings.workspace.root)
    File.write!(Path.join(entry.settings.workspace.root, "retained"), "owned")

    assert {:error, errors} = Lanes.delete(lane)
    assert Enum.any?(errors, &(&1.path == "lane"))
    assert Lanes.get(lane.id)

    File.rm_rf!(entry.settings.workspace.root)
    assert :ok = Lanes.delete(lane)
  end

  test "managed lanes can be deleted after authoritative empty inventory release" do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Managed delete", workspace_base: "/managed/delete", worker: managed_worker()})
    {:ok, lane} = Lanes.create(%{slug: "managed-delete", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, %{settings: settings}} = LaneStore.lookup(lane.id)

    assert {:error, _errors} = Lanes.delete(lane)
    identity = EnvironmentConfig.identity(settings)
    assert {:ok, token} = LaneStore.protect_environment(lane.id, identity)
    assert :ok = LaneStore.release_environment(lane.id, token, :empty_inventory)
    assert {:ok, lane} = Lanes.update(lane, %{name: "Still released"})
    assert :ok = Lanes.delete(lane)
  end

  @tag :tmp_dir
  test "repair markers clear only after every linked lane validates", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Repair", workspace_base: root, worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "repair-lane", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    version = Lanes.current_version(lane)
    Repo.update!(Ecto.Changeset.change(profile, repair_error: "repair required"))
    Repo.update!(Ecto.Changeset.change(version, front_matter: "tracker: ["))

    assert {:error, _errors} = ExecutionProfiles.update(profile, %{description: "still invalid"})
    assert ExecutionProfiles.get(profile.id).repair_error == "repair required"

    assert {:ok, _lane} = Lanes.update(lane, %{config: %{"tracker" => %{"kind" => "memory"}}, prompt: "repaired"})
    assert is_nil(ExecutionProfiles.get(profile.id).repair_error)
    assert {:ok, %{error: nil}} = LaneStore.lookup(lane.id)
  end

  @tag :tmp_dir
  test "non-location SSH edits reuse the published canonical root while the host is unavailable", %{tmp_dir: root} do
    fake_ssh = Path.join(root, "ssh")
    previous_path = System.get_env("PATH")

    File.write!(fake_ssh, "#!/bin/sh\nprintf '/remote/base\\t/remote/base/lane\\n'\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))
    on_exit(fn -> if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH") end)

    {:ok, profile} = ExecutionProfiles.create(%{name: "SSH cached", workspace_base: "/remote/base", worker: %{"ssh_hosts" => ["host-a"]}})
    {:ok, lane} = Lanes.create(%{slug: "lane", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    File.rm!(fake_ssh)

    assert {:ok, updated} = ExecutionProfiles.update(profile, %{description: "host is down"})
    assert updated.description == "host is down"
    assert {:ok, renamed} = Lanes.update(lane, %{name: "Renamed"})
    assert renamed.name == "Renamed"
    assert {:error, _errors} = ExecutionProfiles.update(updated, %{workspace_base: "/remote/other"})
  end

  @tag :tmp_dir
  test "dispatch reservations survive owner death until explicitly released", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Reserved", workspace_base: Path.join(root, "one"), worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "reserved", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, lane} = Lanes.set_enabled(lane, true)
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, token, _entry} = LaneStore.reserve_dispatch(lane.id)

        runner =
          spawn(fn ->
            :ok = LaneStore.claim_dispatch(lane.id, token)
            send(parent, {:claimed, self()})
            receive do: (:stop -> :ok)
          end)

        send(parent, {:reserved, token, runner})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:reserved, token, runner}
    assert_receive {:claimed, ^runner}
    assert {:error, _errors} = ExecutionProfiles.update(profile, %{workspace_base: Path.join(root, "two")})
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert {:error, _errors} = ExecutionProfiles.update(profile, %{workspace_base: Path.join(root, "two")})
    Process.exit(runner, :kill)
    assert {:error, _errors} = ExecutionProfiles.update(profile, %{workspace_base: Path.join(root, "two")})
    assert :ok = LaneStore.release_dispatch(lane.id, token)
    assert {:ok, updated} = ExecutionProfiles.update(profile, %{workspace_base: Path.join(root, "two")})
    assert updated.workspace_base == Path.join(root, "two")
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

  defp managed_worker do
    %{
      "environment" => %{
        "kind" => "google_workstations",
        "deployment_id" => "shared-deployment",
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
end
