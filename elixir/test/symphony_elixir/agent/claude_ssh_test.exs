defmodule SymphonyElixir.Agent.ClaudeSSHTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Claude
  alias SymphonyElixir.Agent.Result

  test "remote_command/2 never contains the prompt text" do
    prompt = ~s|"; rm -rf / ; echo $(whoami) `id`|
    command = Claude.remote_command("/work/dir", prompt)

    refute command =~ "rm -rf"
    refute command =~ "whoami"
    assert command =~ "claude"
    assert command =~ "--output-format stream-json"
  end

  test "run_turn over ssh delivers the prompt through stdin and folds the stream" do
    tmp = Path.join(System.tmp_dir!(), "symphony-claude-ssh-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    fake_claude = Path.join(tmp, "fake_claude")
    ssh_trace = Path.join(tmp, "ssh.trace")
    stdin_capture = Path.join(tmp, "stdin.txt")
    argv_capture = Path.join(tmp, "argv.txt")
    hacked = Path.join(tmp, "hacked")
    previous_path = System.get_env("PATH")
    previous_stdin_capture = System.get_env("CLAUDE_STDIN_CAPTURE")
    previous_argv_capture = System.get_env("CLAUDE_ARGV_CAPTURE")

    File.mkdir_p!(workspace)
    write_fake_ssh!(tmp, ssh_trace)
    write_fake_claude!(fake_claude)
    write_claude_workflow!(fake_claude)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("CLAUDE_STDIN_CAPTURE", previous_stdin_capture)
      restore_env("CLAUDE_ARGV_CAPTURE", previous_argv_capture)
      File.rm_rf(tmp)
    end)

    System.put_env("CLAUDE_STDIN_CAPTURE", stdin_capture)
    System.put_env("CLAUDE_ARGV_CAPTURE", argv_capture)
    {:ok, session} = Claude.start_session(workspace, worker_host: "localhost")

    on_exit(fn ->
      _ = Claude.stop_session(session)
    end)

    prompt = "please keep ; rm -rf / && $(touch #{hacked}) `id`\nsecond line"
    parent = self()
    on_message = fn message -> send(parent, {:claude_update, message}) end

    assert {:ok, %Result{} = result} =
             Claude.run_turn(session, prompt, %{}, on_message: on_message)

    assert result.status == :done
    assert result.session_id == "ssh-run"
    assert result.tokens == %{input: 2, output: 3, total: 5}
    assert result.summary == "ssh ok"

    assert File.read!(stdin_capture) == prompt
    refute File.exists?(hacked)

    ssh_args = File.read!(ssh_trace)
    refute ssh_args =~ "rm -rf"
    refute ssh_args =~ "touch #{hacked}"
    assert ssh_args =~ "--output-format stream-json"

    args =
      argv_capture
      |> File.read!()
      |> String.split("\n", trim: true)

    assert "-p" in args
    assert "--mcp-config" in args
    assert "--strict-mcp-config" in args
    assert "--allowedTools" in args
    refute prompt in args

    assert_received {:claude_update, %{event: :session_started, session_id: "ssh-run"}}

    assert_received {:claude_update,
                     %{
                       event: :completed,
                       session_id: "ssh-run",
                       usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
                     }}
  end

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
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp write_fake_claude!(path) do
    File.write!(path, """
    #!/bin/sh
    : > "$CLAUDE_ARGV_CAPTURE"
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$CLAUDE_ARGV_CAPTURE"
    done
    cat > "$CLAUDE_STDIN_CAPTURE"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"ssh-run"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5},"result":"ssh ok"}'
    """)

    File.chmod!(path, 0o700)
  end

  defp write_claude_workflow!(command) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker: {kind: memory}
    codex: {turn_timeout_ms: 2000, stall_timeout_ms: 2000}
    claude:
      command: #{Jason.encode!(command)}
      linear_mcp_command: "/bin/true"
      allowed_tools: ["Read", "mcp__symphony__linear_graphql", "mcp__symphony__approval_prompt"]
    ---
    body
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
    :ok
  end
end
