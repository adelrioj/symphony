defmodule SymphonyElixir.Agent.ClaudeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Claude
  alias SymphonyElixir.Agent.Result

  test "start_session writes a 0600 mcp config outside the workspace and stop_session removes it" do
    workspace = Path.join(System.tmp_dir!(), "some-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    {:ok, session} = Claude.start_session(workspace, [])

    on_exit(fn ->
      _ = Claude.stop_session(session)
      File.rm_rf(workspace)
    end)

    assert File.exists?(session.mcp_config_path)
    refute path_inside?(session.mcp_config_path, workspace)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(session.mcp_config_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    config =
      session.mcp_config_path
      |> File.read!()
      |> Jason.decode!()

    encoded_config = Jason.encode!(config)
    refute encoded_config =~ "LINEAR_API_KEY"
    refute encoded_config =~ "token"

    args = get_in(config, ["mcpServers", "symphony", "args"])
    assert "--linear-mcp" in args
    assert "--workflow" in args
    assert Workflow.current_path() in args

    assert :ok = Claude.stop_session(session)
    refute File.exists?(session.mcp_config_path)
  end

  test "run_turn launches with argv, real mcp config path, and prompt as one argument" do
    tmp = Path.join(System.tmp_dir!(), "symphony-claude-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    script = Path.join(tmp, "fake_claude")
    capture = Path.join(tmp, "argv.txt")
    hacked = Path.join(tmp, "hacked")

    File.mkdir_p!(workspace)
    write_fake_claude!(script)

    previous_capture = System.get_env("CLAUDE_ARGV_CAPTURE")

    on_exit(fn ->
      restore_env("CLAUDE_ARGV_CAPTURE", previous_capture)
      File.rm_rf(tmp)
    end)

    System.put_env("CLAUDE_ARGV_CAPTURE", capture)
    write_claude_workflow!(script)

    {:ok, session} = Claude.start_session(workspace, [])

    on_exit(fn ->
      _ = Claude.stop_session(session)
    end)

    prompt = "please keep ; echo unsafe && $(touch #{hacked}) as literal text"
    parent = self()

    assert {:ok, %Result{} = result} =
             Claude.run_turn(session, prompt, %{}, on_message: fn message -> send(parent, {:claude_update, message}) end)

    assert result.status == :done
    assert result.session_id == "sess-run"
    assert result.tokens == %{input: 1, output: 2, total: 3}
    assert result.summary == "ok"

    args =
      capture
      |> File.read!()
      |> String.split("\n", trim: true)

    assert "-p" in args
    assert "--output-format" in args
    assert "stream-json" in args
    assert "--mcp-config" in args
    assert Enum.at(args, Enum.find_index(args, &(&1 == "--mcp-config")) + 1) == session.mcp_config_path
    assert Enum.at(args, -2) == "--"
    assert Enum.count(args, &(&1 == prompt)) == 1
    assert List.last(args) == prompt
    refute File.exists?(hacked)

    assert_received {:claude_update, %{event: :session_started, session_id: "sess-run"}}
    assert_received {:claude_update, %{event: :completed, session_id: "sess-run", usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}}}
  end

  defp path_inside?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp write_fake_claude!(path) do
    File.write!(path, """
    #!/bin/sh
    : > "$CLAUDE_ARGV_CAPTURE"
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$CLAUDE_ARGV_CAPTURE"
    done
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-run"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3},"result":"ok"}'
    """)

    File.chmod!(path, 0o700)
  end

  defp write_claude_workflow!(command) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker: {kind: memory}
    codex: {turn_timeout_ms: 1000, stall_timeout_ms: 1000}
    claude:
      command: #{Jason.encode!(command)}
      allowed_tools: ["Read", "mcp__symphony__linear_graphql", "mcp__symphony__approval_prompt"]
    ---
    body
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
    :ok
  end
end
