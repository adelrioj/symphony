defmodule SymphonyElixir.Agent.OmpSSHTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{Omp, Result}
  alias SymphonyElixir.{Config, ExecutionContext}
  alias SymphonyElixir.SSH.Target

  @fixtures Path.expand("../../fixtures/omp", __DIR__)

  test "remote_command/2 never contains the prompt text and is hermetic" do
    command = Omp.remote_command("/work/dir", "/tmp/symphony-omp-abc")

    refute command =~ "rm -rf"
    assert command =~ "PI_CODING_AGENT_DIR="
    assert command =~ "--no-extensions"
    assert command =~ "'--mode' 'json'"
    assert command =~ "--continue"
    assert command =~ "omp"
    refute command =~ "mcp__"
  end

  for transport <- [:static, :structured] do
    test "run_turn over #{transport} ssh delivers the prompt through stdin, continues, folds the stream and cleans up" do
      tmp = Path.join(System.tmp_dir!(), "symphony-omp-ssh-test-#{System.unique_integer([:positive])}")
      workspace = Path.join(tmp, "workspace")
      fake_omp = Path.join(tmp, "fake_omp")
      ssh_trace = Path.join(tmp, "ssh.trace")
      capture = Path.join(tmp, "capture")
      hacked = Path.join(tmp, "hacked")
      previous_path = System.get_env("PATH")
      previous_capture = System.get_env("OMP_CAPTURE_DIR")
      secret_name = "SYMPHONY_OMP_REMOTE_SECRET"
      secret_value = "never-put-this-in-ssh-argv"
      previous_secret = System.get_env(secret_name)

      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("OMP_CAPTURE_DIR", previous_capture)
        restore_env(secret_name, previous_secret)
        File.rm_rf(tmp)
      end)

      File.mkdir_p!(workspace)
      File.mkdir_p!(capture)
      write_fake_ssh!(tmp, ssh_trace)
      write_fake_omp!(fake_omp, File.read!(Path.join(@fixtures, "success.jsonl")))
      System.put_env("OMP_CAPTURE_DIR", capture)
      System.put_env(secret_name, secret_value)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: "$#{secret_name}",
        omp_command: fake_omp
      )

      target =
        case unquote(transport) do
          :static -> "localhost"
          :structured -> %Target{executable: Path.join([tmp, "bin", "ssh"]), prefix: [], label: "fixture"}
        end

      {:ok, session} =
        Omp.start_session(workspace, execution_context: ExecutionContext.ssh(Config.settings!().workspace.root, target))

      on_exit(fn -> Omp.stop_session(session) end)

      assert "/tmp/symphony-omp-" <> _ = remote_dir = session.remote_dir
      refute File.exists?(remote_dir)

      prompt = "please keep ; rm -rf / && $(touch #{hacked}) `id`\nsecond line"
      parent = self()
      on_message = fn message -> send(parent, {:omp_update, message}) end

      assert {:ok, %Result{status: :done} = result} = Omp.run_turn(session, prompt, %{}, on_message: on_message)
      assert result.summary =~ "ok"
      assert_received {:omp_update, %{event: :session_started}}
      refute File.exists?(hacked)

      assert {:ok, %Result{status: :done}} = Omp.run_turn(session, "continue", %{}, [])

      [turn1, turn2] = capture |> Path.join("argv") |> File.read!() |> String.split("TURN\n", trim: true)
      args1 = String.split(turn1, "\n", trim: true)
      args2 = String.split(turn2, "\n", trim: true)

      refute "--continue" in args1
      assert "--continue" in args2
      assert argv_value(args1, "--config") == Path.join(remote_dir, "overlay.yml")
      assert argv_value(args1, "--session-dir") == Path.join(remote_dir, "sessions")
      refute prompt in args1
      refute argv_value(args1, "--tools") =~ "mcp__"

      assert capture |> Path.join("agent_dir") |> File.read!() |> String.split("\n", trim: true) ==
               [Path.join(remote_dir, "agent"), Path.join(remote_dir, "agent")]

      stdins = capture |> Path.join("stdin") |> File.read!() |> String.split("STDIN_END\n", trim: true)
      assert stdins == [prompt, "continue"]

      trace = File.read!(ssh_trace)
      refute trace =~ "touch #{hacked}"
      refute trace =~ secret_value
      assert trace =~ "unset "
      assert trace =~ secret_name

      env_names = capture |> Path.join("env") |> File.read!() |> String.split("\n", trim: true)
      refute Enum.any?(env_names, &String.starts_with?(&1, secret_name <> "="))

      # The secret-bearing files are gone after the turn; sessions/ stays so --continue works.
      for file <- ["agent/mcp.json", "WORKFLOW.md", "overlay.yml"] do
        refute File.exists?(Path.join(remote_dir, file))
      end

      assert File.dir?(Path.join(remote_dir, "sessions"))

      mcp = capture |> Path.join("mcp.json") |> File.read!() |> Jason.decode!()
      assert mcp["mcpServers"]["symphony"]["env"][secret_name] == secret_value
      remote_args = mcp["mcpServers"]["symphony"]["args"]

      assert Enum.at(remote_args, Enum.find_index(remote_args, &(&1 == "--workflow")) + 1) ==
               Path.join(remote_dir, "WORKFLOW.md")

      assert File.dir?(remote_dir)
      assert :ok = Omp.stop_session(session)
      assert File.read!(ssh_trace) =~ "rm -rf "
      refute File.exists?(remote_dir)
      refute File.exists?(session.session_dir)
    end
  end

  test "stop_session removes the local dir and returns :ok even when the ssh cleanup hangs" do
    tmp = Path.join(System.tmp_dir!(), "symphony-omp-hang-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    fake_ssh = Path.join([tmp, "bin", "ssh"])
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.dirname(fake_ssh))
    File.write!(fake_ssh, "#!/bin/sh\nexec sleep 5\n")
    File.chmod!(fake_ssh, 0o755)
    on_exit(fn -> File.rm_rf(tmp) end)

    write_workflow_file!(Workflow.workflow_file_path(), omp_command: "omp")
    target = %Target{executable: fake_ssh, prefix: [], label: "fixture"}

    {:ok, session} =
      Omp.start_session(workspace, execution_context: ExecutionContext.ssh(Config.settings!().workspace.root, target))

    assert File.dir?(session.session_dir)
    started = System.monotonic_time(:millisecond)
    assert :ok = Omp.stop_session(session)
    assert System.monotonic_time(:millisecond) - started < 4_000
    refute File.exists?(session.session_dir)
  end

  test "managed contexts are required when worker.environment is configured" do
    root = Path.join(System.tmp_dir!(), "symphony-omp-managed-#{System.unique_integer([:positive])}")
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
          deployment_id: "omp-managed",
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
             Omp.start_session(workspace, execution_context: ExecutionContext.local(root))

    target = %Target{
      executable: Path.join([root, "bin", "ssh"]),
      prefix: [],
      label: "fixture",
      env: [{"BASH_ENV", Path.join(root, "fixture-bash-env")}]
    }

    context = %ExecutionContext{mode: :managed, workspace_root: root, workspace_path: workspace, target: target}

    assert {:ok, session} = Omp.start_session(workspace, execution_context: context)
    assert "/tmp/symphony-omp-" <> _ = session.remote_dir
    assert :ok = Omp.stop_session(session)
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

  defp write_fake_omp!(path, events) do
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$PI_CODING_AGENT_DIR" >> "$OMP_CAPTURE_DIR/agent_dir"
    cp "$PI_CODING_AGENT_DIR/mcp.json" "$OMP_CAPTURE_DIR/mcp.json"
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
