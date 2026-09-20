defmodule SymphonyElixir.RepoTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, Lanes, Repo}
  alias SymphonyElixir.Lanes.Lane

  setup do
    keys = [:data_root, :server_port]
    previous = Map.new(keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})
    root = Path.join(System.tmp_dir!(), "symphony-repo-#{System.unique_integer([:positive, :monotonic])}")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "migration preserves existing lane versions, runs and events when repeated" do
    isolated_repo()
    assert :ok = legacy_migrate()

    Repo.query!("INSERT INTO lanes (id, slug, name, inserted_at, updated_at) VALUES (1, 'features', 'Features', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
    Repo.query!("INSERT INTO lane_versions (id, lane_id, front_matter, prompt, inserted_at) VALUES (1, 1, 'tracker: {}', 'Build it', CURRENT_TIMESTAMP)")
    Repo.query!("UPDATE lanes SET current_version_id = 1 WHERE id = 1")

    Repo.query!("""
    INSERT INTO runs (id, lane_id, lane_version_id, issue_id, issue_identifier, attempt_id, started_at)
    VALUES (1, 1, 1, 'issue-1', 'TEST-1', 'attempt-1', CURRENT_TIMESTAMP)
    """)

    Repo.query!("INSERT INTO run_events (run_id, at, kind, payload) VALUES (1, CURRENT_TIMESTAMP, 'started', '{\"turn\":1}')")

    assert :ok = Repo.migrate()

    assert [["features", "Build it", "attempt-1", "started", "{\"turn\":1}"]] =
             Repo.query!("""
             SELECT lanes.slug, lane_versions.prompt, runs.attempt_id, run_events.kind, run_events.payload
             FROM lanes
             JOIN lane_versions ON lane_versions.id = lanes.current_version_id
             JOIN runs ON runs.lane_version_id = lane_versions.id
             JOIN run_events ON run_events.run_id = runs.id
             """).rows

    assert [] = Repo.query!("PRAGMA foreign_key_check").rows
  end

  test "execution profile migration refuses a destructive rollback" do
    isolated_repo()
    :ok = Repo.migrate()

    assert_raise RuntimeError, ~r/irreversible/, fn ->
      Ecto.Migrator.down(Repo, 20_260_920_000_001, SymphonyElixir.Repo.Migrations.AddExecutionProfiles, log: false)
    end

    assert [[1]] = Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = 20260920000001").rows
    assert [["execution_profiles"]] = Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'execution_profiles'").rows
  end

  test "database rejects unsupported lane executors and duplicate lane slugs" do
    isolated_repo()
    :ok = Repo.migrate()
    profile_id = create_profile("Executor test")

    insert = "INSERT INTO lanes (slug, name, executor, execution_profile_id, inserted_at, updated_at) VALUES (?, 'Features', ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    assert {:error, %Exqlite.Error{}} = Repo.query(insert, ["features", "kubernetes", profile_id])
    assert {:ok, _} = Repo.query(insert, ["features", "local", profile_id])
    assert {:error, %Exqlite.Error{}} = Repo.query(insert, ["features", "local"])
    assert {:error, %Exqlite.Error{}} = Repo.query("UPDATE lanes SET executor = 'remote' WHERE slug = 'features'")
    assert [["local"]] = Repo.query!("SELECT executor FROM lanes").rows
  end

  @tag :tmp_dir
  test "profile migration backfills every lane without changing retained history", %{root: root} do
    isolated_repo()
    :ok = legacy_migrate()
    enabled_root = Path.join(root, "enabled")
    disabled_root = Path.join(root, "disabled")

    Repo.query!("INSERT INTO lanes (id, slug, name, enabled, inserted_at, updated_at) VALUES (1, 'enabled', 'Enabled', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")

    Repo.query!("INSERT INTO lane_versions (id, lane_id, front_matter, prompt, inserted_at) VALUES (1, 1, ?, 'run it', CURRENT_TIMESTAMP)", [
      "workspace:\n  root: #{enabled_root}\nworker:\n  ssh_hosts: [worker.example]\ntracker:\n  kind: memory"
    ])

    Repo.query!("UPDATE lanes SET current_version_id = 1 WHERE id = 1")

    Repo.query!("INSERT INTO lanes (id, slug, name, enabled, inserted_at, updated_at) VALUES (2, 'disabled', 'Disabled', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")

    Repo.query!("INSERT INTO lane_versions (id, lane_id, front_matter, prompt, inserted_at) VALUES (2, 2, ?, 'disabled', CURRENT_TIMESTAMP)", [
      "workspace:\n  root: #{disabled_root}\ntracker:\n  kind: memory"
    ])

    Repo.query!("UPDATE lanes SET current_version_id = 2 WHERE id = 2")

    Repo.query!("INSERT INTO lanes (id, slug, name, enabled, deleted_at, inserted_at, updated_at) VALUES (3, 'deleted', 'Deleted', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
    Repo.query!("INSERT INTO lane_versions (id, lane_id, front_matter, prompt, inserted_at) VALUES (3, 3, 'tracker:\n  kind: memory', 'deleted', CURRENT_TIMESTAMP)")
    Repo.query!("UPDATE lanes SET current_version_id = 3 WHERE id = 3")

    Repo.query!("INSERT INTO lanes (id, slug, name, enabled, inserted_at, updated_at) VALUES (4, 'malformed', 'Malformed', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
    Repo.query!("INSERT INTO lane_versions (id, lane_id, front_matter, prompt, inserted_at) VALUES (4, 4, 'tracker: [', 'broken', CURRENT_TIMESTAMP)")
    Repo.query!("UPDATE lanes SET current_version_id = 4 WHERE id = 4")
    Repo.query!("INSERT INTO lanes (id, slug, name, enabled, inserted_at, updated_at) VALUES (5, 'missing-version', 'Missing', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")

    Repo.query!("INSERT INTO lanes (id, slug, name, enabled, inserted_at, updated_at) VALUES (6, 'managed', 'Managed', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")

    Repo.query!("INSERT INTO lane_versions (id, lane_id, front_matter, prompt, inserted_at) VALUES (6, 6, ?, 'managed', CURRENT_TIMESTAMP)", [
      "workspace:\n  root: /home/worker/workspaces\nworker:\n  environment:\n    kind: google_workstations\n    deployment_id: migration\n    startup_timeout_ms: 1000\n    shutdown_timeout_ms: 1000\n    terminal_retention_ms: 0\n    provider:\n      project: p\n      location: l\n      cluster: c\n      config: cfg\n      credential_configuration: deploy\n      impersonate_service_account: sa@example.com\n      ssh_user: worker\ntracker:\n  kind: memory"
    ])

    Repo.query!("UPDATE lanes SET current_version_id = 6 WHERE id = 6")

    Repo.query!("INSERT INTO runs (id, lane_id, lane_version_id, issue_id, issue_identifier, attempt_id, started_at) VALUES (1, 1, 1, 'issue-1', 'TEST-1', 'migration-attempt', CURRENT_TIMESTAMP)")
    Repo.query!("INSERT INTO run_events (run_id, at, kind, payload) VALUES (1, CURRENT_TIMESTAMP, 'started', '{\"kept\":true}')")

    :ok = Repo.migrate()

    assert [[6]] = Repo.query!("SELECT count(*) FROM execution_profiles").rows
    assert [] = Repo.query!("PRAGMA foreign_key_check").rows

    assert {:error, [%{path: "config", message: ssh_error}]} = Lanes.resolve_lane(Repo.get!(Lane, 1))
    assert ssh_error =~ "remote_path_canonicalize_failed"
    assert Repo.get!(Lane, 1).enabled

    assert {:ok, canonical_disabled_root} = SymphonyElixir.PathSafety.canonicalize(disabled_root)
    assert {:ok, %{settings: %{workspace: %{root: ^canonical_disabled_root}}}} = Lanes.resolve_lane(Repo.get!(Lane, 2))

    assert [[^enabled_root, ssh_worker, nil]] =
             Repo.query!("SELECT workspace_base, worker, repair_error FROM execution_profiles WHERE name = 'Legacy enabled'").rows

    assert Jason.decode!(ssh_worker) == %{"ssh_hosts" => ["worker.example"]}

    assert [["/home/worker/workspaces", managed_worker, nil]] =
             Repo.query!("SELECT workspace_base, worker, repair_error FROM execution_profiles WHERE name = 'Legacy managed'").rows

    assert get_in(Jason.decode!(managed_worker), ["environment", "provider", "credential_configuration"]) == "deploy"

    assert [["run it", "migration-attempt", "started", "{\"kept\":true}"]] =
             Repo.query!("""
             SELECT lane_versions.prompt, runs.attempt_id, run_events.kind, run_events.payload
             FROM lane_versions JOIN runs ON runs.lane_version_id = lane_versions.id
             JOIN run_events ON run_events.run_id = runs.id WHERE lane_versions.id = 1
             """).rows

    assert [[profile_id]] = Repo.query!("SELECT execution_profile_id FROM runs WHERE attempt_id = 'migration-attempt'").rows
    assert is_integer(profile_id)

    assert [["."], ["."], ["."], ["."], ["."], ["."]] = Repo.query!("SELECT workspace_subdir FROM lanes ORDER BY id").rows
    assert [[repair_error]] = Repo.query!("SELECT repair_error FROM execution_profiles WHERE name = 'Legacy malformed'").rows
    assert repair_error =~ "repair"
    refute Repo.get!(Lane, 4).enabled
    refute Repo.get!(Lane, 5).enabled
    assert Repo.get!(Lane, 3).deleted_at
  end

  test "foreign keys protect history while run deletion cascades to events" do
    isolated_repo()
    :ok = Repo.migrate()
    profile_id = create_profile("History test")

    assert {:error, %Exqlite.Error{}} =
             Repo.query("INSERT INTO lane_versions (lane_id, front_matter, prompt, inserted_at) VALUES (999, '', '', CURRENT_TIMESTAMP)")

    Repo.query!("INSERT INTO lanes (id, slug, name, execution_profile_id, inserted_at, updated_at) VALUES (1, 'features', 'Features', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", [profile_id])
    Repo.query!("INSERT INTO lane_versions (id, lane_id, front_matter, prompt, inserted_at) VALUES (1, 1, '', '', CURRENT_TIMESTAMP)")

    insert_run = "INSERT INTO runs (id, lane_id, lane_version_id, issue_id, issue_identifier, attempt_id, started_at) VALUES (?, 1, 1, 'issue-1', 'TEST-1', 'attempt-1', CURRENT_TIMESTAMP)"
    Repo.query!(insert_run, [1])
    assert {:error, %Exqlite.Error{}} = Repo.query(insert_run, [2])
    Repo.query!("INSERT INTO run_events (run_id, at, kind) VALUES (1, CURRENT_TIMESTAMP, 'started')")
    assert {:error, %Exqlite.Error{}} = Repo.query("DELETE FROM lane_versions WHERE id = 1")
    assert {:error, %Exqlite.Error{}} = Repo.query("DELETE FROM lanes WHERE id = 1")

    Repo.query!("DELETE FROM runs WHERE id = 1")
    assert [[0]] = Repo.query!("SELECT count(*) FROM run_events").rows
    Repo.query!("DELETE FROM lanes WHERE id = 1")
    assert [[0]] = Repo.query!("SELECT count(*) FROM lane_versions").rows
  end

  test "profile references are enforced for direct SQL and soft-deleted lanes" do
    isolated_repo()
    :ok = Repo.migrate()
    profile_id = create_profile("Referenced")
    assert {:error, %Exqlite.Error{}} = Repo.query("INSERT INTO lanes (slug, name, inserted_at, updated_at) VALUES ('missing-profile', 'Missing', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")

    assert {:error, %Exqlite.Error{}} =
             Repo.query("INSERT INTO lanes (slug, name, execution_profile_id, inserted_at, updated_at) VALUES ('bad-profile', 'Bad', 999999, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")

    Repo.query!("INSERT INTO lanes (slug, name, execution_profile_id, inserted_at, updated_at) VALUES ('referenced', 'Referenced', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", [profile_id])
    assert {:error, %Exqlite.Error{}} = Repo.query("DELETE FROM execution_profiles WHERE id = ?", [profile_id])
    Repo.query!("UPDATE lanes SET deleted_at = CURRENT_TIMESTAMP WHERE slug = 'referenced'")
    assert {:error, %Exqlite.Error{}} = Repo.query("DELETE FROM execution_profiles WHERE id = ?", [profile_id])
  end

  test "an uncreated data root becomes a usable persistent database directory", %{root: root} do
    data_root = Path.join(root, "nested/data")
    Application.put_env(:symphony_elixir, :data_root, data_root)
    assert {:ok, config} = Repo.init(:runtime, [])
    assert config[:database] == Path.join(data_root, "symphony.sqlite3")
    assert File.dir?(data_root)

    pid = start_supervised!({Repo, Keyword.put(config, :name, nil)})
    previous = Repo.put_dynamic_repo(pid)

    try do
      Repo.query!("CREATE TABLE durable_value (value TEXT NOT NULL)")
      Repo.query!("INSERT INTO durable_value VALUES ('kept')")
      stop_supervised!(Repo)
      reopened = start_supervised!({Repo, Keyword.put(config, :name, nil)})
      Repo.put_dynamic_repo(reopened)
      assert [["kept"]] = Repo.query!("SELECT value FROM durable_value").rows
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "explicit memory and disk databases do not touch the installation data root", %{root: root} do
    unusable_root = Path.join(root, "not-a-directory")
    File.mkdir_p!(root)
    File.write!(unusable_root, "occupied")
    Application.put_env(:symphony_elixir, :data_root, unusable_root)

    assert {:ok, memory_config} = Repo.init(:runtime, database: ":memory:")
    assert memory_config[:database] == ":memory:"

    database = Path.join(root, "explicit/database.sqlite3")
    assert {:ok, disk_config} = Repo.init(:runtime, database: database)
    assert disk_config[:database] == database
    assert File.dir?(Path.dirname(database))
    assert File.read!(unusable_root) == "occupied"
    assert_raise File.Error, fn -> Repo.init(:runtime, []) end
  end

  test "offline migrations start a temporary repo and leave a reusable disk database", %{root: root} do
    script = """
    Application.delete_env(:symphony_elixir, SymphonyElixir.Repo)
    Application.put_env(:symphony_elixir, :data_root, #{inspect(root)})
    :ok = SymphonyElixir.Repo.migrate()
    nil = Process.whereis(SymphonyElixir.Repo)
    :ok = SymphonyElixir.Repo.migrate()
    nil = Process.whereis(SymphonyElixir.Repo)
    {:ok, _} = SymphonyElixir.Repo.start_link()
    tables = SymphonyElixir.Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table'").rows |> List.flatten()
    true = Enum.all?(~w(lanes lane_versions runs run_events), &(&1 in tables))
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", "-e", script],
        cd: Path.expand("../..", __DIR__),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert File.regular?(Path.join(root, "symphony.sqlite3"))
  end

  test "installation port supports ephemeral binding and explicit disabling" do
    Application.put_env(:symphony_elixir, :server_port, 0)
    assert Config.server_port() == 0
    Application.put_env(:symphony_elixir, :server_port, nil)
    assert Config.server_port() == nil
    Application.delete_env(:symphony_elixir, :server_port)
    assert Config.server_port() == nil
  end

  defp isolated_repo do
    pid = start_supervised!({Repo, name: nil, database: ":memory:", pool_size: 1, journal_mode: :memory})
    Repo.put_dynamic_repo(pid)
  end

  defp legacy_migrate do
    Ecto.Migrator.up(Repo, 20_260_912_000_001, SymphonyElixir.Repo.Migrations.CreateLanesAndRuns, log: false)
    :ok
  end

  defp create_profile(name) do
    Repo.query!("INSERT INTO execution_profiles (name, workspace_base, worker, inserted_at, updated_at) VALUES (?, ?, '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", [
      name,
      Path.join(System.tmp_dir!(), name)
    ])

    Repo.query!("SELECT id FROM execution_profiles WHERE name = ?", [name]).rows |> hd() |> hd()
  end
end
