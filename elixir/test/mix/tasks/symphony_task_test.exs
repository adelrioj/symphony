defmodule Mix.Tasks.SymphonyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{TestSupport, Workflow}

  @project_root Path.expand("../../..", __DIR__)
  test "Mix dispatch starts a usable daemon and remains attached while it runs" do
    root = Path.join(System.tmp_dir!(), "symphony-mix-daemon-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    coverage_file = Path.join(root, "entrypoint.coverdata")
    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nobservability:\n  dashboard_enabled: false\n---\nPrompt")

    script = """
    Mix.Task.run("app.config")
    [tools] = Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "tools-*", "ebin"]))
    Code.prepend_path(tools)
    {:ok, _} = :cover.start()
    {:ok, Mix.Tasks.Symphony} = :cover.compile_beam(Mix.Tasks.Symphony)
    {:ok, SymphonyElixir.CLI} = :cover.compile_beam(SymphonyElixir.CLI)
    Application.put_env(:symphony_elixir, SymphonyElixir.Repo, database: #{inspect(Path.join(root, "symphony.sqlite3"))}, pool_size: 1)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    :ok = SymphonyElixir.CLI.evaluate(["lanes", "import", #{inspect(workflow)}, "--slug", "smoke-lane", "--data-root", #{inspect(root)}])
    lane = SymphonyElixir.Lanes.get_by_slug("smoke-lane")
    false = lane.enabled
    {:ok, lane} = SymphonyElixir.Lanes.set_enabled(lane, true)
    :ok = Supervisor.stop(SymphonyElixir.Repo)
    task = spawn(fn ->
      Mix.Task.run("symphony", ["serve", "--data-root", #{inspect(root)}, "--port", "0", "--i-understand-that-this-will-be-running-without-the-usual-guardrails"])
    end)
    wait = fn wait, remaining ->
      case SymphonyElixir.LaneRegistry.whereis(lane.id, :orchestrator) do
        nil when remaining > 0 -> Process.sleep(10); wait.(wait, remaining - 1)
        nil -> raise "lane daemon did not start"
        pid -> pid
      end
    end
    pid = wait.(wait, 500)
    %{running: []} = SymphonyElixir.Orchestrator.snapshot(pid, 5000)
    {:ok, %{enabled: true, slug: "smoke-lane"}} = SymphonyElixir.LaneStore.lookup(lane.id)
    true = Process.alive?(task)
    :ok = :cover.export(#{inspect(coverage_file)}, Mix.Tasks.Symphony)
    :ok = :cover.export(#{inspect(Path.join(root, "cli.coverdata"))}, SymphonyElixir.CLI)
    IO.puts("DAEMON_READY")
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", "-e", script],
        cd: @project_root,
        env: [{"MIX_ENV", "test"}, {"SYMPHONY_OPERATOR_TOKEN", "isolated-smoke-operator-token"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "DAEMON_READY"

    TestSupport.import_coverage(Mix.Tasks.Symphony, coverage_file)
    TestSupport.import_coverage(SymphonyElixir.CLI, Path.join(root, "cli.coverdata"))
  end

  test "offline import and export use SQLite without starting lane runtimes and preserve stdout bytes" do
    root = Path.join(System.tmp_dir!(), "symphony-mix-offline-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    workflow = Path.join(root, "WORKFLOW.md")
    database = Path.join(root, "data/symphony.sqlite3")
    content = "---\ntracker:\n  kind: memory\n---\nExact prompt  \n"
    File.write!(workflow, content)
    import_cover = Path.join(root, "import.coverdata")
    export_cover = Path.join(root, "export.coverdata")

    prelude = """
    Mix.Task.run("app.config")
    [tools] = Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "tools-*", "ebin"]))
    Code.prepend_path(tools)
    {:ok, _} = :cover.start()
    {:ok, SymphonyElixir.CLI} = :cover.compile_beam(SymphonyElixir.CLI)
    Application.put_env(:symphony_elixir, SymphonyElixir.Repo, database: #{inspect(database)}, pool_size: 1)
    """

    imported = """
    :ok = SymphonyElixir.CLI.evaluate(["lanes", "import", #{inspect(workflow)}, "--slug", "offline-lane", "--data-root", #{inspect(Path.join(root, "data"))}])
    nil = Process.whereis(SymphonyElixir.Supervisor)
    nil = Process.whereis(SymphonyElixir.LaneStore)
    false = SymphonyElixir.Lanes.get_by_slug("offline-lane").enabled
    :ok = :cover.export(#{inspect(import_cover)}, SymphonyElixir.CLI)
    """

    exported = """
    :ok = SymphonyElixir.CLI.evaluate(["lanes", "export", "offline-lane", "--data-root", #{inspect(Path.join(root, "data"))}])
    nil = Process.whereis(SymphonyElixir.Supervisor)
    nil = Process.whereis(SymphonyElixir.LaneStore)
    :ok = :cover.export(#{inspect(export_cover)}, SymphonyElixir.CLI)
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", "-e", prelude <> imported],
        cd: @project_root,
        env: [{"MIX_ENV", "test"}, {"SYMPHONY_OPERATOR_TOKEN", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "imported lane offline-lane version"
    assert File.regular?(database)

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", "-e", prelude <> exported],
        cd: @project_root,
        env: [{"MIX_ENV", "test"}, {"SYMPHONY_OPERATOR_TOKEN", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert {:ok, parsed} = Workflow.parse(output)
    assert parsed.config["tracker"] == %{"kind" => "memory"}
    assert parsed.prompt == "Exact prompt"

    TestSupport.import_coverage(SymphonyElixir.CLI, import_cover)
    TestSupport.import_coverage(SymphonyElixir.CLI, export_cover)
  end

  test "standalone MCP serves protocol requests from its file lane without opening a database" do
    root = Path.join(System.tmp_dir!(), "symphony-mix-mcp-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    workflow = Path.join(root, "WORKFLOW.md")
    database = Path.join(root, "symphony.sqlite3")
    coverage_file = Path.join(root, "mcp.coverdata")
    File.write!(workflow, "---\ntracker:\n  kind: linear\n  api_key: test-token\n  provider:\n    project_slug: example\nserver:\n  port: 4000\n---\nStandalone MCP prompt")
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"}) <> "\n"

    script = """
    Mix.Task.run("app.config")
    [tools] = Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "tools-*", "ebin"]))
    Code.prepend_path(tools)
    {:ok, _} = :cover.start()
    {:ok, SymphonyElixir.CLI} = :cover.compile_beam(SymphonyElixir.CLI)
    Application.put_env(:symphony_elixir, SymphonyElixir.Repo, database: #{inspect(database)}, pool_size: 1)
    :ok = :logger.remove_handler(:default)
    :ok = Application.stop(:logger)
    {:ok, protocol} = StringIO.open(#{inspect(request)})
    stdout = Process.group_leader()
    Process.group_leader(self(), protocol)
    :ok = SymphonyElixir.CLI.evaluate(["--linear-mcp", "--workflow", #{inspect(workflow)}])
    {:ok, %{tracker: %{kind: "linear"}}} = SymphonyElixir.Config.settings()
    {:ok, %{prompt: "Standalone MCP prompt"}} = SymphonyElixir.Workflow.current()
    nil = Process.whereis(SymphonyElixir.Repo)
    nil = Process.whereis(SymphonyElixir.Supervisor)
    {_input, output} = StringIO.contents(protocol)
    Process.group_leader(self(), stdout)
    :ok = :cover.export(#{inspect(coverage_file)}, SymphonyElixir.CLI)
    IO.write(output)
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", "-e", script],
        cd: @project_root,
        env: [{"MIX_ENV", "test"}, {"SYMPHONY_OPERATOR_TOKEN", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert %{"id" => 7, "result" => %{"tools" => tools}} = Jason.decode!(output)
    assert Enum.any?(tools, &(&1["name"] == "linear_graphql"))
    refute File.exists?(database)

    TestSupport.import_coverage(SymphonyElixir.CLI, coverage_file)
  end

  test "invalid CLI arguments exit without starting the daemon or opening its database" do
    root = Path.join(System.tmp_dir!(), "symphony-mix-task-#{System.unique_integer([:positive, :monotonic])}")
    database = Path.join(root, "symphony.sqlite3")
    on_exit(fn -> File.rm_rf!(root) end)

    script = """
    Mix.Task.run("app.config")
    Application.put_env(:symphony_elixir, SymphonyElixir.Repo, database: #{inspect(database)}, pool_size: 1)
    Mix.Task.run("symphony", ["--not-a-symphony-option"])
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", "-e", script],
        cd: @project_root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "Usage:"
    refute File.exists?(database)
  end
end
