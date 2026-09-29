defmodule SymphonyElixir.Agent.OmpTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{Omp, Result}
  alias SymphonyElixir.ExecutionContext

  @fixtures Path.expand("../../fixtures/omp", __DIR__)

  test "overlay disables project MCP config and every foreign discovery provider except native" do
    yaml = Omp.overlay_yaml()
    assert yaml =~ "enableProjectConfig: false"

    for id <- ~w(omp-plugins claude agent-plugins codex agents claude-plugins gemini opencode cursor
                 windsurf cline github vscode agents-md mcp-json ssh-json) do
      assert yaml =~ id
    end

    refute yaml =~ "native"
  end

  test "mcp_config declares only symphony plus configured servers, symphony wins collisions" do
    omp = %{
      linear_mcp_command: nil,
      linear_mcp_args: ["--x"],
      extra_mcp_servers: %{"symphony" => %{"command" => "evil"}, "other" => %{"command" => "o"}}
    }

    cfg = Omp.mcp_config("/w/WORKFLOW.md", "/bin/symphony", omp, %{"TOKEN" => "t"})

    assert %{
             "command" => "/bin/symphony",
             "args" => ["--x", "--linear-mcp", "--workflow", "/w/WORKFLOW.md"],
             "env" => %{"TOKEN" => "t"}
           } = cfg["mcpServers"]["symphony"]

    assert cfg["mcpServers"]["other"]["command"] == "o"
  end

  test "argv omits --continue on turn 1 and includes it afterwards; flags are hermetic; tools never list mcp names" do
    omp = %{args: ["--foo"], model: "openrouter/x/y", thinking: "high", allowed_tools: nil}
    paths = %{sessions_dir: "/s/sessions", overlay_path: "/s/overlay.yml"}
    first = Omp.argv(paths, omp, [%{"name" => "linear_graphql"}], false)
    later = Omp.argv(paths, omp, [%{"name" => "linear_graphql"}], true)

    assert hd(first) == "--foo"
    for flag <- ~w(-p --no-extensions --no-skills --no-rules --no-title), do: assert(flag in first)
    assert ["--mode", "json"] == Enum.slice(first, Enum.find_index(first, &(&1 == "--mode")), 2)
    assert "--continue" in later and "--continue" not in first
    assert argv_value(first, "--model") == "openrouter/x/y"
    assert argv_value(first, "--thinking") == "high"
    assert argv_value(first, "--approval-mode") == "yolo"
    assert argv_value(first, "--config") == "/s/overlay.yml"
    assert argv_value(first, "--session-dir") == "/s/sessions"
    tools = first |> argv_value("--tools") |> String.split(",")
    assert tools == ~w(read grep find edit write bash)

    custom = Omp.argv(paths, %{omp | allowed_tools: ["read"]}, [%{"name" => "linear_graphql"}], false)
    assert custom |> argv_value("--tools") |> String.split(",") == ["read"]
  end

  test "end to end: private agent dir env, stdin prompt, --continue on the second turn, folded result" do
    tmp = Path.join(System.tmp_dir!(), "symphony-omp-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    script = Path.join(tmp, "fake_omp")
    capture = Path.join(tmp, "capture")
    secret_name = "SYMPHONY_OMP_TEST_SECRET"
    previous_secret = System.get_env(secret_name)
    previous_capture = System.get_env("OMP_CAPTURE_DIR")

    File.mkdir_p!(workspace)
    File.mkdir_p!(capture)
    write_fake_omp!(script, File.read!(Path.join(@fixtures, "success.jsonl")))

    System.put_env(secret_name, "omp-secret-value")
    System.put_env("OMP_CAPTURE_DIR", capture)

    on_exit(fn ->
      restore_env(secret_name, previous_secret)
      restore_env("OMP_CAPTURE_DIR", previous_capture)
      File.rm_rf(tmp)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "$#{secret_name}", omp_command: script)

    {:ok, session} =
      Omp.start_session(workspace, execution_context: ExecutionContext.local(Config.local_workspace_root()))

    on_exit(fn -> Omp.stop_session(session) end)

    agent_dir = Path.join(session.session_dir, "agent")
    overlay = Path.join(session.session_dir, "overlay.yml")
    assert File.exists?(overlay)
    assert File.read!(overlay) == Omp.overlay_yaml()

    prompt = "please keep ; echo unsafe && $(touch #{Path.join(tmp, "hacked")}) as literal text"
    parent = self()
    on_message = fn message -> send(parent, {:omp_update, message}) end

    assert {:ok, %Result{status: :done} = result} = Omp.run_turn(session, prompt, %{}, on_message: on_message)
    assert result.summary =~ "ok"
    assert_received {:omp_update, %{event: :session_started}}

    assert {:ok, %Result{status: :done}} = Omp.run_turn(session, "continue", %{}, [])

    [turn1, turn2] = capture |> Path.join("argv") |> File.read!() |> String.split("TURN\n", trim: true)
    args1 = String.split(turn1, "\n", trim: true)
    args2 = String.split(turn2, "\n", trim: true)

    refute "--continue" in args1
    assert "--continue" in args2
    assert argv_value(args1, "--config") == overlay
    assert argv_value(args1, "--session-dir") == Path.join(session.session_dir, "sessions")
    refute "--" in args1
    refute prompt in args1
    refute File.exists?(Path.join(tmp, "hacked"))

    agent_dirs = capture |> Path.join("agent_dir") |> File.read!() |> String.split("\n", trim: true)
    assert agent_dirs == [agent_dir, agent_dir]

    mcp = agent_dir |> Path.join("mcp.json") |> File.read!() |> Jason.decode!()
    assert mcp["mcpServers"]["symphony"]["env"][secret_name] == "omp-secret-value"

    stdins = capture |> Path.join("stdin") |> File.read!() |> String.split("STDIN_END\n", trim: true)
    assert stdins == [prompt, "continue"]

    env_names = capture |> Path.join("env") |> File.read!() |> String.split("\n", trim: true)
    refute Enum.any?(env_names, &String.starts_with?(&1, secret_name <> "="))

    assert :ok = Omp.stop_session(session)
    refute File.exists?(session.session_dir)
  end

  test "a stream with a failing stopReason yields an omp_error" do
    tmp = Path.join(System.tmp_dir!(), "symphony-omp-error-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    script = Path.join(tmp, "fake_omp")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(tmp) end)
    write_fake_omp!(script, File.read!(Path.join(@fixtures, "error.jsonl")))
    write_workflow_file!(Workflow.workflow_file_path(), omp_command: script)

    {:ok, session} =
      Omp.start_session(workspace, execution_context: ExecutionContext.local(Config.local_workspace_root()))

    assert {:error, {:omp_error, "error"}} = Omp.run_turn(session, "prompt", %{}, [])
    assert :ok = Omp.stop_session(session)
  end

  test "run_turn returns command resolution errors" do
    tmp = Path.join(System.tmp_dir!(), "symphony-omp-command-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(tmp) end)
    write_workflow_file!(Workflow.workflow_file_path(), omp_command: "definitely_missing_omp_for_symphony")

    {:ok, session} =
      Omp.start_session(workspace, execution_context: ExecutionContext.local(Config.local_workspace_root()))

    assert Omp.run_turn(session, "prompt", %{}, []) ==
             {:error, {:executable_not_found, "definitely_missing_omp_for_symphony"}}

    assert :ok = Omp.stop_session(session)
  end

  test "remote execution is unavailable until the remote driver lands" do
    {:ok, session} =
      Omp.start_session(File.cwd!(),
        execution_context: ExecutionContext.ssh(Config.settings!().workspace.root, "remote")
      )

    assert Omp.run_turn(session, "prompt", %{}, []) == {:error, :omp_remote_unavailable}
    assert :ok = Omp.stop_session(session)
  end

  defp argv_value(argv, flag), do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)

  # Records env var names, PI_CODING_AGENT_DIR, argv and stdin per turn, touches a file in --session-dir
  # like real omp does, then replays the given event stream.
  defp write_fake_omp!(path, events) do
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$PI_CODING_AGENT_DIR" >> "$OMP_CAPTURE_DIR/agent_dir"
    env | cut -d= -f1-2 >> "$OMP_CAPTURE_DIR/env"
    printf 'TURN\\n' >> "$OMP_CAPTURE_DIR/argv"
    prev=""
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$OMP_CAPTURE_DIR/argv"
      if [ "$prev" = "--session-dir" ]; then touch "$arg/session.jsonl"; fi
      prev="$arg"
    done
    cat >> "$OMP_CAPTURE_DIR/stdin"
    printf 'STDIN_END\\n' >> "$OMP_CAPTURE_DIR/stdin"
    cat <<'SYMPHONY_OMP_EVENTS'
    #{events}
    SYMPHONY_OMP_EVENTS
    """)

    File.chmod!(path, 0o700)
  end
end
