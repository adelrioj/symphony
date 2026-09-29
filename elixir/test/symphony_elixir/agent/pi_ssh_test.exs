defmodule SymphonyElixir.Agent.PiSSHTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{CliHarness, Pi, Result}
  alias SymphonyElixir.{Config, ExecutionContext}
  alias SymphonyElixir.SSH.Target

  @fixtures Path.expand("../../fixtures/pi", __DIR__)

  test "remote_command/2 is hermetic, quotes every interpolated value and never contains the prompt" do
    workspace = "/work/dir with 'quote"
    remote_dir = "/tmp/symphony-pi-a b"
    command = Pi.remote_command(workspace, remote_dir)

    refute command =~ "rm -rf"
    assert command =~ "cd #{CliHarness.shell_escape(workspace)}"
    assert command =~ "PI_CODING_AGENT_DIR=#{CliHarness.shell_escape(Path.join(remote_dir, "agent"))}"
    assert command =~ "SYMPHONY_BRIDGE_CONFIG=#{CliHarness.shell_escape(Path.join(remote_dir, "bridge.json"))}"
    assert command =~ "--no-extensions"
    assert command =~ "'--mode' 'json'"
    assert command =~ "'--no-approve'"
    assert command =~ "'--tools' '"
    assert command =~ "$symphony_continue"
    refute command =~ "mcp__"

    # No raw (unquoted) occurrence of the remote dir survives.
    refute command =~ ~r/(?<!')#{Regex.escape(remote_dir)}/
  end

  test "remote_command/2 installs the secret-file trap before any secret file is written" do
    command = Pi.remote_command("/work/dir", "/tmp/symphony-pi-abc")

    {trap_at, _} = :binary.match(command, "trap ")
    {mkdir_at, _} = :binary.match(command, "mkdir -p")
    {first_write_at, _} = :binary.match(command, "> '/tmp/symphony-pi-abc/WORKFLOW.md'")
    {bridge_json_at, _} = :binary.match(command, "> '/tmp/symphony-pi-abc/bridge.json'")

    assert trap_at < mkdir_at
    assert trap_at < first_write_at
    assert trap_at < bridge_json_at
    assert command =~ ~r/trap 'rm -f [^;&]*bridge\.json[^;&]*' EXIT HUP INT TERM/

    [_, trapped] = Regex.run(~r/trap ('rm -f .*?') EXIT HUP INT TERM/, command)
    assert trapped =~ "WORKFLOW.md"
    assert trapped =~ "bridge.json"
    refute trapped =~ "sessions"
    refute trapped =~ "bridge.ts"
    refute trapped =~ "settings.json"
  end

  for transport <- [:static, :structured] do
    test "run_turn over #{transport} ssh delivers the prompt through stdin, continues, folds the stream and cleans up" do
      tmp = Path.join(System.tmp_dir!(), "symphony-pi-ssh-test-#{System.unique_integer([:positive])}")
      workspace = Path.join(tmp, "workspace")
      fake_pi = Path.join(tmp, "fake_pi")
      ssh_trace = Path.join(tmp, "ssh.trace")
      capture = Path.join(tmp, "capture")
      hacked = Path.join(tmp, "hacked")
      previous_path = System.get_env("PATH")
      previous_capture = System.get_env("PI_CAPTURE_DIR")
      secret_name = "SYMPHONY_PI_REMOTE_SECRET"
      secret_value = "never-put-this-in-ssh-argv"
      previous_secret = System.get_env(secret_name)

      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("PI_CAPTURE_DIR", previous_capture)
        restore_env(secret_name, previous_secret)
        File.rm_rf(tmp)
      end)

      File.mkdir_p!(workspace)
      File.mkdir_p!(capture)
      write_fake_ssh!(tmp, ssh_trace)
      write_fake_pi!(fake_pi, File.read!(Path.join(@fixtures, "success.jsonl")))
      System.put_env("PI_CAPTURE_DIR", capture)
      System.put_env(secret_name, secret_value)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: "$#{secret_name}",
        pi_command: fake_pi
      )

      target =
        case unquote(transport) do
          :static -> "localhost"
          :structured -> %Target{executable: Path.join([tmp, "bin", "ssh"]), prefix: [], label: "fixture"}
        end

      {:ok, session} =
        Pi.start_session(workspace, execution_context: ExecutionContext.ssh(Config.settings!().workspace.root, target))

      on_exit(fn -> Pi.stop_session(session) end)

      assert "/tmp/symphony-pi-" <> _ = remote_dir = session.remote_dir
      refute File.exists?(remote_dir)

      prompt = "please keep ; rm -rf / && $(touch #{hacked}) `id`\nsecond line"
      parent = self()
      on_message = fn message -> send(parent, {:pi_update, message}) end

      assert {:ok, %Result{status: :done} = result} = Pi.run_turn(session, prompt, %{}, on_message: on_message)
      assert result.summary =~ "Hello from fake"
      assert_received {:pi_update, %{event: :session_started}}
      refute File.exists?(hacked)

      # Secret-bearing files are gone after each turn; the non-secret files and sessions/ stay.
      for file <- ["bridge.json", "WORKFLOW.md"], do: refute(File.exists?(Path.join(remote_dir, file)))
      assert File.dir?(Path.join(remote_dir, "sessions"))
      assert File.exists?(Path.join(remote_dir, "bridge.ts"))
      assert File.exists?(Path.join([remote_dir, "agent", "settings.json"]))

      assert {:ok, %Result{status: :done}} = Pi.run_turn(session, "continue", %{}, [])

      [turn1, turn2] = capture |> Path.join("argv") |> File.read!() |> String.split("TURN\n", trim: true)
      args1 = String.split(turn1, "\n", trim: true)
      args2 = String.split(turn2, "\n", trim: true)

      refute "--continue" in args1
      assert "--continue" in args2
      assert argv_value(args1, "-e") == Path.join(remote_dir, "bridge.ts")
      assert argv_value(args1, "--session-dir") == Path.join(remote_dir, "sessions")
      refute prompt in args1
      refute argv_value(args1, "--tools") =~ "mcp__"
      assert argv_value(args1, "--tools") =~ "read"
      assert argv_value(args1, "--tools") =~ "symphony_"

      assert capture |> Path.join("agent_dir") |> File.read!() |> String.split("\n", trim: true) ==
               [Path.join(remote_dir, "agent"), Path.join(remote_dir, "agent")]

      bridge_json_path = Path.join(remote_dir, "bridge.json")

      assert capture |> Path.join("bridge_config") |> File.read!() |> String.split("\n", trim: true) ==
               [bridge_json_path, bridge_json_path]

      stdins = capture |> Path.join("stdin") |> File.read!() |> String.split("STDIN_END\n", trim: true)
      assert stdins == [prompt, "continue"]

      trace = File.read!(ssh_trace)
      refute trace =~ "touch #{hacked}"
      refute trace =~ secret_value
      assert trace =~ "unset "
      assert trace =~ secret_name

      env_names = capture |> Path.join("env") |> File.read!() |> String.split("\n", trim: true)
      refute Enum.any?(env_names, &String.starts_with?(&1, secret_name <> "="))

      bridge = capture |> Path.join("bridge.json") |> File.read!() |> Jason.decode!()
      assert bridge["env"][secret_name] == secret_value
      assert bridge["timeoutMs"] == Config.settings!().codex.turn_timeout_ms
      assert bridge["command"] == "symphony"
      remote_args = bridge["args"]

      assert Enum.at(remote_args, Enum.find_index(remote_args, &(&1 == "--workflow")) + 1) ==
               Path.join(remote_dir, "WORKFLOW.md")

      assert File.read!(Path.join(capture, "settings.json")) == Pi.settings_json()
      assert File.read!(Path.join(capture, "bridge.ts")) =~ "SYMPHONY_BRIDGE_CONFIG"

      assert File.dir?(remote_dir)
      assert :ok = Pi.stop_session(session)
      assert File.read!(ssh_trace) =~ "rm -rf "
      refute File.exists?(remote_dir)
      refute File.exists?(session.session_dir)
    end
  end

  test "a terminated remote runner leaves no bridge.json or WORKFLOW.md behind" do
    tmp = Path.join(System.tmp_dir!(), "symphony-pi-trap-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    remote_dir = Path.join(tmp, "remote")
    fake_pi = Path.join(tmp, "fake_pi")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(tmp) end)

    # The fake pi terminates the runner shell while the secret files are on disk, then lingers.
    File.write!(fake_pi, "#!/bin/sh\ntest -f \"$SYMPHONY_BRIDGE_CONFIG\" || exit 3\nkill -TERM $PPID\nsleep 1\n")
    File.chmod!(fake_pi, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), pi_command: fake_pi)

    command = Pi.remote_command(workspace, remote_dir)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, :stderr_to_stdout, args: ["-c", command]])

    payload =
      CliHarness.ssh_payload(["secret-workflow", "bridge-ts", "{\"env\":{\"S\":\"v\"}}", Pi.settings_json(), "prompt"])

    Port.command(port, payload)
    assert_receive {^port, {:exit_status, _}}, 10_000

    refute File.exists?(Path.join(remote_dir, "bridge.json"))
    refute File.exists?(Path.join(remote_dir, "WORKFLOW.md"))
    assert File.dir?(Path.join(remote_dir, "sessions"))
  end

  test "stop_session removes the local dir and returns :ok even when the ssh cleanup hangs" do
    tmp = Path.join(System.tmp_dir!(), "symphony-pi-hang-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    fake_ssh = Path.join([tmp, "bin", "ssh"])
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.dirname(fake_ssh))
    File.write!(fake_ssh, "#!/bin/sh\nexec sleep 5\n")
    File.chmod!(fake_ssh, 0o755)
    on_exit(fn -> File.rm_rf(tmp) end)

    write_workflow_file!(Workflow.workflow_file_path(), pi_command: "pi")
    target = %Target{executable: fake_ssh, prefix: [], label: "fixture"}

    {:ok, session} =
      Pi.start_session(workspace, execution_context: ExecutionContext.ssh(Config.settings!().workspace.root, target))

    assert File.dir?(session.session_dir)
    started = System.monotonic_time(:millisecond)
    assert :ok = Pi.stop_session(session)
    assert System.monotonic_time(:millisecond) - started < 4_000
    refute File.exists?(session.session_dir)
  end

  test "managed contexts are required when worker.environment is configured" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-managed-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(root, "controller.kubeconfig"), "controller-only")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(root)
    end)

    write_fake_ssh!(root, Path.join(root, "ssh.trace"))
    reset_lanes!()

    :ok =
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: root,
        worker_environment: %{
          kind: "kubernetes",
          deployment_id: "pi-managed",
          provider: %{
            "kubeconfig" => Path.join(root, "controller.kubeconfig"),
            "context" => "unit",
            "namespace" => "candidate",
            "template" => "worker",
            "ssh_user" => "worker",
            "ssh_auth_volume" => "auth",
            "ssh_port" => 2222
          },
          startup_timeout_ms: 1_000,
          shutdown_timeout_ms: 1_000
        }
      )

    assert {:error, :managed_context_required} =
             Pi.start_session(workspace, execution_context: ExecutionContext.local(root))

    target = %Target{
      executable: Path.join([root, "bin", "ssh"]),
      prefix: [],
      label: "fixture",
      env: [{"BASH_ENV", Path.join(root, "fixture-bash-env")}]
    }

    context = %ExecutionContext{mode: :managed, workspace_root: root, workspace_path: workspace, target: target}

    assert {:ok, session} = Pi.start_session(workspace, execution_context: context)
    assert "/tmp/symphony-pi-" <> _ = session.remote_dir
    assert :ok = Pi.stop_session(session)
  end

  defp argv_value(argv, flag), do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)

  defp write_fake_ssh!(test_root, trace_file) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    last_arg=
    for arg in "$@"; do
      last_arg=$arg
    done
    /bin/sh -c "$last_arg"
    """)

    File.chmod!(fake_ssh, 0o755)
    File.write!(Path.join(test_root, "fixture-bash-env"), "export PATH='#{fake_bin_dir}':\"$PATH\"\n")
    fake_realpath = Path.join(fake_bin_dir, "realpath")

    File.write!(
      fake_realpath,
      "#!/bin/sh\n[ \"$1\" = -m ] && shift\n[ \"$1\" = -- ] && shift\nexec python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \"$1\"\n"
    )

    File.chmod!(fake_realpath, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp write_fake_pi!(path, events) do
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$PI_CODING_AGENT_DIR" >> "$PI_CAPTURE_DIR/agent_dir"
    printf '%s\\n' "$SYMPHONY_BRIDGE_CONFIG" >> "$PI_CAPTURE_DIR/bridge_config"
    cp "$SYMPHONY_BRIDGE_CONFIG" "$PI_CAPTURE_DIR/bridge.json"
    cp "$PI_CODING_AGENT_DIR/settings.json" "$PI_CAPTURE_DIR/settings.json"
    env | cut -d= -f1-2 >> "$PI_CAPTURE_DIR/env"
    printf 'TURN\\n' >> "$PI_CAPTURE_DIR/argv"
    prev=""
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$PI_CAPTURE_DIR/argv"
      if [ "$prev" = "--session-dir" ]; then touch "$arg/session.jsonl"; fi
      if [ "$prev" = "-e" ]; then cp "$arg" "$PI_CAPTURE_DIR/bridge.ts"; fi
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
