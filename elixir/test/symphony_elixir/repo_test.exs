defmodule SymphonyElixir.RepoTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, Repo}

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
    assert :ok = Repo.migrate()

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
  end

  test "database rejects unsupported lane executors and duplicate lane slugs" do
    isolated_repo()
    :ok = Repo.migrate()

    insert = "INSERT INTO lanes (slug, name, executor, inserted_at, updated_at) VALUES (?, 'Features', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    assert {:error, %Exqlite.Error{}} = Repo.query(insert, ["features", "kubernetes"])
    assert {:ok, _} = Repo.query(insert, ["features", "local"])
    assert {:error, %Exqlite.Error{}} = Repo.query(insert, ["features", "local"])
    assert {:error, %Exqlite.Error{}} = Repo.query("UPDATE lanes SET executor = 'remote' WHERE slug = 'features'")
    assert [["local"]] = Repo.query!("SELECT executor FROM lanes").rows
  end

  test "foreign keys protect history while run deletion cascades to events" do
    isolated_repo()
    :ok = Repo.migrate()

    assert {:error, %Exqlite.Error{}} =
             Repo.query("INSERT INTO lane_versions (lane_id, front_matter, prompt, inserted_at) VALUES (999, '', '', CURRENT_TIMESTAMP)")

    Repo.query!("INSERT INTO lanes (id, slug, name, inserted_at, updated_at) VALUES (1, 'features', 'Features', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
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
end
