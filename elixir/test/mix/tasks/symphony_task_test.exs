defmodule Mix.Tasks.SymphonyTest do
  use ExUnit.Case, async: false

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
    task = spawn(fn -> Mix.Task.run("symphony", [#{inspect(workflow)}, "--i-understand-that-this-will-be-running-without-the-usual-guardrails"]) end)
    wait = fn wait, remaining ->
      case Process.whereis(SymphonyElixir.Orchestrator) do
        nil when remaining > 0 -> Process.sleep(10); wait.(wait, remaining - 1)
        nil -> raise "daemon did not start"
        pid -> pid
      end
    end
    pid = wait.(wait, 500)
    %{running: []} = SymphonyElixir.Orchestrator.snapshot(pid, 5000)
    true = Process.alive?(task)
    :ok = :cover.export(#{inspect(coverage_file)}, Mix.Tasks.Symphony)
    IO.puts("DAEMON_READY")
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", "-e", script],
        cd: @project_root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "DAEMON_READY"

    if :cover.is_compiled(Mix.Tasks.Symphony) != false do
      assert :ok = :cover.import(String.to_charlist(coverage_file))
    end
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
