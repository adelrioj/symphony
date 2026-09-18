defmodule SymphonyElixir.Agent.ClaudeRealSSHTest do
  @moduledoc """
  Drives the remote-turn path over a REAL `ssh` client and a REAL `sshd`.

  `claude_ssh_test.exs` covers the same protocol with a shell shim standing in for
  ssh (`/bin/sh -c "$last_arg"`), which hands the remote script the port's own stdin
  fd. That skips every hop the live path actually takes: the ssh client's stdin
  reader, the SSH channel, and sshd writing into the remote command's pipe. This
  test exercises those hops, so a stall that only appears over real ssh is caught
  here instead of on hardware.

  Needs a reachable sshd; `test/support/real_ssh_harness.sh` provisions one and
  exports the environment below. Without it the test is skipped, so the default
  suite stays fast and toolchain-free.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{Claude, Result}
  alias SymphonyElixir.SSH

  @moduletag :real_ssh

  setup do
    config =
      Enum.reduce_while(
        ~w(SYMPHONY_REAL_SSH_HOST SYMPHONY_REAL_SSH_PORT SYMPHONY_REAL_SSH_USER SYMPHONY_REAL_SSH_KEY SYMPHONY_REAL_SSH_KNOWN_HOSTS SYMPHONY_REAL_SSH_STUB),
        %{},
        fn name, acc ->
          case System.get_env(name) do
            value when is_binary(value) and value != "" -> {:cont, Map.put(acc, name, value)}
            _ -> {:halt, nil}
          end
        end
      )

    if config, do: {:ok, ssh: config}, else: {:ok, ssh: nil}
  end

  test "a remote turn over real ssh delivers the prompt and folds the stream", %{ssh: ssh} do
    if ssh == nil do
      IO.puts(:stderr, "skipping: run test/support/real_ssh_harness.sh to provide an sshd")
    else
      workspace = Path.join(System.tmp_dir!(), "symphony-real-ssh-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      write_real_ssh_workflow!(ssh["SYMPHONY_REAL_SSH_STUB"])

      # Mirrors ExecutionEnvironment.Kubernetes.connect_private/7 exactly: the live
      # managed path builds this prefix, so a flag that breaks stdin breaks it here too.
      prefix = [
        "-F",
        "/dev/null",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "ForwardAgent=no",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" <> ssh["SYMPHONY_REAL_SSH_KNOWN_HOSTS"],
        "-o",
        "HostKeyAlias=symphony-realssh",
        "-o",
        "ConnectTimeout=10",
        "-i",
        ssh["SYMPHONY_REAL_SSH_KEY"],
        "-p",
        ssh["SYMPHONY_REAL_SSH_PORT"],
        "-l",
        ssh["SYMPHONY_REAL_SSH_USER"],
        ssh["SYMPHONY_REAL_SSH_HOST"]
      ]

      target = %SSH.Target{executable: System.find_executable("ssh"), prefix: prefix, label: "real-ssh"}
      context = %SymphonyElixir.ExecutionContext{mode: :ssh, workspace_root: workspace, target: target, worker_host: "real-ssh"}

      {:ok, session} = Claude.start_session(workspace, execution_context: context)
      on_exit(fn -> Claude.stop_session(session) end)

      prompt = "probe prompt\nsecond line"
      parent = self()

      assert {:ok, %Result{} = result} =
               Claude.run_turn(session, prompt, %{}, on_message: fn m -> send(parent, {:update, m}) end)

      assert result.status == :done
      assert result.session_id == "real-ssh-run"
      assert_received {:update, %{event: :session_started, session_id: "real-ssh-run"}}

      # The stub writes back what it read on stdin, which is the only proof the
      # length-prefixed payload survived the ssh hops byte-for-byte.
      assert File.read!(Path.join(workspace, "stub-stdin.txt")) == prompt
    end
  end

  defp write_real_ssh_workflow!(stub_command) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      active_states: ["Candidate"]
      terminal_states: ["Done"]
    codex: {turn_timeout_ms: 60000, stall_timeout_ms: 30000}
    claude:
      command: #{Jason.encode!(stub_command)}
      linear_mcp_command: "/bin/true"
      allowed_tools: null
    ---
    body
    """)

    assert :ok = reload_workflow!()
    :ok
  end
end
