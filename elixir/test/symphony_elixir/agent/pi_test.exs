defmodule SymphonyElixir.Agent.PiTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{Pi, Result}
  alias SymphonyElixir.ExecutionContext

  @fixtures Path.expand("../../fixtures/pi", __DIR__)

  test "settings_json disables project trust and packages" do
    assert %{"defaultProjectTrust" => "never", "packages" => []} = Jason.decode!(Pi.settings_json())
  end

  test "bridge_config carries the tracker server launch and timeout" do
    cfg = Pi.bridge_config("/bin/symphony", ["--linear-mcp", "--workflow", "/w"], %{"T" => "t"}, 30_000)

    assert cfg == %{
             "command" => "/bin/symphony",
             "args" => ["--linear-mcp", "--workflow", "/w"],
             "env" => %{"T" => "t"},
             "timeoutMs" => 30_000
           }
  end

  test "allowlist is explicit names: built-ins plus symphony_ tool names" do
    tools = Pi.tool_allowlist(%{allowed_tools: nil}, [%{"name" => "linear_graphql"}])
    assert tools == ~w(read bash edit write grep find ls symphony_linear_graphql)
    assert Pi.tool_allowlist(%{allowed_tools: ["read"]}, [%{"name" => "x"}]) == ["read", "symphony_x"]
  end

  test "argv is hermetic, turn 1 has no --continue, later turns do" do
    pi = %{args: ["--foo"], model: "openrouter/x/y", thinking: "high", allowed_tools: nil}
    paths = %{sessions_dir: "/s/sessions", bridge_path: "/s/bridge.ts"}
    first = Pi.argv(paths, pi, [%{"name" => "linear_graphql"}], false)
    later = Pi.argv(paths, pi, [%{"name" => "linear_graphql"}], true)

    assert hd(first) == "--foo"

    for f <-
          ~w(-p --offline --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve) do
      assert f in first
    end

    assert value(first, "--mode") == "json" and value(first, "-e") == "/s/bridge.ts"
    assert value(first, "--session-dir") == "/s/sessions"
    assert value(first, "--model") == "openrouter/x/y" and value(first, "--thinking") == "high"
    assert "symphony_linear_graphql" in String.split(value(first, "--tools"), ",")
    assert "--continue" in later and "--continue" not in first
  end

  test "end to end: private agent dir, bridge config, stdin prompt, --continue on the second turn" do
    tmp = Path.join(System.tmp_dir!(), "symphony-pi-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    script = Path.join(tmp, "fake_pi")
    capture = Path.join(tmp, "capture")
    secret_name = "SYMPHONY_PI_TEST_SECRET"
    previous_secret = System.get_env(secret_name)
    previous_capture = System.get_env("PI_CAPTURE_DIR")

    File.mkdir_p!(workspace)
    File.mkdir_p!(capture)
    write_fake_pi!(script, File.read!(Path.join(@fixtures, "success.jsonl")))

    System.put_env(secret_name, "pi-secret-value")
    System.put_env("PI_CAPTURE_DIR", capture)

    on_exit(fn ->
      restore_env(secret_name, previous_secret)
      restore_env("PI_CAPTURE_DIR", previous_capture)
      File.rm_rf(tmp)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "$#{secret_name}", pi_command: script)

    {:ok, session} =
      Pi.start_session(workspace, execution_context: ExecutionContext.local(Config.local_workspace_root()))

    on_exit(fn -> Pi.stop_session(session) end)

    agent_dir = Path.join(session.session_dir, "agent")
    bridge_path = Path.join(session.session_dir, "bridge.ts")
    bridge_json = Path.join(session.session_dir, "bridge.json")

    assert File.read!(Path.join(agent_dir, "settings.json")) == Pi.settings_json()
    assert File.read!(bridge_path) =~ "SYMPHONY_BRIDGE_CONFIG"
    assert File.stat!(bridge_json).mode |> Bitwise.band(0o777) == 0o600

    prompt = "please keep ; echo unsafe && $(touch #{Path.join(tmp, "hacked")}) as literal text"
    parent = self()
    on_message = fn message -> send(parent, {:pi_update, message}) end

    assert {:ok, %Result{status: :done} = result} = Pi.run_turn(session, prompt, %{}, on_message: on_message)
    assert result.summary =~ "Hello from fake"
    assert result.tokens.total > 0
    assert_received {:pi_update, %{event: :session_started}}

    assert {:ok, %Result{status: :done}} = Pi.run_turn(session, "continue", %{}, [])

    [turn1, turn2] = capture |> Path.join("argv") |> File.read!() |> String.split("TURN\n", trim: true)
    args1 = String.split(turn1, "\n", trim: true)
    args2 = String.split(turn2, "\n", trim: true)

    refute "--continue" in args1
    assert "--continue" in args2
    assert value(args1, "-e") == bridge_path
    assert value(args1, "--session-dir") == Path.join(session.session_dir, "sessions")
    refute prompt in args1
    refute File.exists?(Path.join(tmp, "hacked"))

    assert capture |> Path.join("agent_dir") |> File.read!() |> String.split("\n", trim: true) ==
             [agent_dir, agent_dir]

    assert capture |> Path.join("bridge_config") |> File.read!() |> String.split("\n", trim: true) ==
             [bridge_json, bridge_json]

    bridge = bridge_json |> File.read!() |> Jason.decode!()
    assert %{"command" => command, "args" => args, "env" => env, "timeoutMs" => timeout} = bridge
    assert is_binary(command)
    assert args == ["--linear-mcp", "--workflow", session.workflow_snapshot_path]
    assert env[secret_name] == "pi-secret-value"
    assert timeout == Config.settings!().codex.turn_timeout_ms

    stdins = capture |> Path.join("stdin") |> File.read!() |> String.split("STDIN_END\n", trim: true)
    assert stdins == [prompt, "continue"]

    env_names = capture |> Path.join("env") |> File.read!() |> String.split("\n", trim: true)
    refute Enum.any?(env_names, &String.starts_with?(&1, secret_name <> "="))

    assert :ok = Pi.stop_session(session)
    refute File.exists?(session.session_dir)
  end

  test "a stream with a failing stopReason yields a pi_error" do
    tmp = Path.join(System.tmp_dir!(), "symphony-pi-error-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    script = Path.join(tmp, "fake_pi")
    capture = Path.join(tmp, "capture")
    previous_capture = System.get_env("PI_CAPTURE_DIR")
    File.mkdir_p!(workspace)
    File.mkdir_p!(capture)
    System.put_env("PI_CAPTURE_DIR", capture)

    on_exit(fn ->
      restore_env("PI_CAPTURE_DIR", previous_capture)
      File.rm_rf(tmp)
    end)

    write_fake_pi!(script, File.read!(Path.join(@fixtures, "error.jsonl")))
    write_workflow_file!(Workflow.workflow_file_path(), pi_command: script)

    {:ok, session} =
      Pi.start_session(workspace, execution_context: ExecutionContext.local(Config.local_workspace_root()))

    assert {:error, {:pi_error, "error"}} = Pi.run_turn(session, "prompt", %{}, [])
    assert :ok = Pi.stop_session(session)
  end

  test "run_turn returns command resolution errors" do
    tmp = Path.join(System.tmp_dir!(), "symphony-pi-command-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(tmp) end)
    write_workflow_file!(Workflow.workflow_file_path(), pi_command: "definitely_missing_pi_for_symphony")

    {:ok, session} =
      Pi.start_session(workspace, execution_context: ExecutionContext.local(Config.local_workspace_root()))

    assert Pi.run_turn(session, "prompt", %{}, []) ==
             {:error, {:executable_not_found, "definitely_missing_pi_for_symphony"}}

    assert :ok = Pi.stop_session(session)
  end

  # Task 6 replaces this with real remote execution and deletes this test.
  test "remote contexts are unavailable until Task 6" do
    session = %{workspace: "/w", execution_context: ExecutionContext.ssh("/w", "host")}
    assert Pi.run_turn(session, "p", %{}, []) == {:error, :pi_remote_unavailable}
  end

  defp value(argv, flag), do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)

  defp write_fake_pi!(path, events) do
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$PI_CODING_AGENT_DIR" >> "$PI_CAPTURE_DIR/agent_dir"
    printf '%s\\n' "$SYMPHONY_BRIDGE_CONFIG" >> "$PI_CAPTURE_DIR/bridge_config"
    env | cut -d= -f1-2 >> "$PI_CAPTURE_DIR/env"
    printf 'TURN\\n' >> "$PI_CAPTURE_DIR/argv"
    prev=""
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$PI_CAPTURE_DIR/argv"
      if [ "$prev" = "--session-dir" ]; then touch "$arg/session.jsonl"; fi
      prev="$arg"
    done
    cat >> "$PI_CAPTURE_DIR/stdin"
    printf 'STDIN_END\\n' >> "$PI_CAPTURE_DIR/stdin"
    cat <<'SYMPHONY_PI_EVENTS'
    #{events}
    SYMPHONY_PI_EVENTS
    """)

    File.chmod!(path, 0o700)
  end
end
