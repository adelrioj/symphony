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
    on_message = fn message -> send(parent, {:claude_update, message}) end

    assert {:ok, %Result{} = result} =
             Claude.run_turn(session, prompt, %{}, on_message: on_message)

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
    assert "--permission-prompt-tool" in args
    assert Enum.at(args, Enum.find_index(args, &(&1 == "--permission-prompt-tool")) + 1) == "mcp__symphony__approval_prompt"

    allowed_tools = Enum.at(args, Enum.find_index(args, &(&1 == "--allowedTools")) + 1)
    refute allowed_tools =~ "mcp__symphony__approval_prompt"

    assert Enum.at(args, -2) == "--"
    assert Enum.count(args, &(&1 == prompt)) == 1
    assert List.last(args) == prompt
    refute File.exists?(hacked)

    assert_received {:claude_update, %{event: :session_started, session_id: "sess-run"}}

    assert_received {:claude_update,
                     %{
                       event: :completed,
                       session_id: "sess-run",
                       usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
                     }}
  end

  test "start_session falls back outside the workspace when system tmp is inside the workspace" do
    workspace = System.tmp_dir!()

    {:ok, session} = Claude.start_session(workspace, [])

    on_exit(fn ->
      _ = Claude.stop_session(session)
    end)

    assert session.mcp_config_path |> Path.dirname() |> String.ends_with?(".symphony-claude-mcp")
    assert File.exists?(session.mcp_config_path)
  end

  test "mcp_config_dir/1 returns directory errors" do
    assert {:error, {:mcp_config_dir, %FunctionClauseError{}}} = Claude.mcp_config_dir(:bad_workspace)
  end

  test "default_mcp_command/1 uses script name or executable fallback" do
    assert Claude.default_mcp_command(~c"/tmp/symphony") == "/tmp/symphony"
    assert Claude.default_mcp_command(~c"./bin/symphony") == Path.expand("./bin/symphony")

    sh_path = System.find_executable("sh")
    assert Claude.default_mcp_command(~c"sh") == sh_path

    missing = "definitely_missing_symphony_escript_#{System.unique_integer([:positive])}"
    assert Claude.default_mcp_command(to_charlist(missing)) == Path.expand(missing)
    assert Claude.default_mcp_command([]) in [System.find_executable("symphony"), "symphony"]
  end

  test "close_port/1 tolerates live and already-closed ports" do
    live_port = Port.open({:spawn, "cat"}, [:binary])
    assert :ok = Claude.close_port(live_port)

    exited_port = Port.open({:spawn, "true"}, [:exit_status])

    receive do
      {^exited_port, {:exit_status, 0}} -> :ok
    after
      500 -> flunk("expected fake port to exit")
    end

    assert :ok = Claude.close_port(exited_port)

    parent = self()

    owner =
      spawn(fn ->
        port = Port.open({:spawn, "cat"}, [:binary])
        send(parent, {:owned_port, port})

        receive do
          :stop -> :ok
        after
          1_000 -> :ok
        end
      end)

    assert_receive {:owned_port, owned_port}
    assert :ok = Claude.close_port(owned_port)
    send(owner, :stop)
  end

  test "run_turn returns command resolution errors" do
    tmp = Path.join(System.tmp_dir!(), "symphony-claude-command-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(tmp) end)

    write_claude_workflow!(" ")
    {:ok, blank_session} = Claude.start_session(workspace, [])
    assert Claude.run_turn(blank_session, "prompt", %{}, []) == {:error, :claude_command_not_configured}
    assert :ok = Claude.stop_session(blank_session)

    write_claude_workflow!("definitely_missing_claude_for_symphony")
    {:ok, missing_session} = Claude.start_session(workspace, [])

    assert Claude.run_turn(missing_session, "prompt", %{}, []) ==
             {:error, {:executable_not_found, "definitely_missing_claude_for_symphony"}}

    assert :ok = Claude.stop_session(missing_session)
  end

  test "run_turn resolves relative commands and commands from PATH" do
    tmp = Path.join(System.tmp_dir!(), "symphony-claude-path-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    relative_dir = Path.join("tmp", "symphony-relative-#{System.unique_integer([:positive])}")
    relative_script = Path.join(relative_dir, "fake_claude")
    path_dir = Path.join(tmp, "bin")
    path_script = Path.join(path_dir, "fake_claude_from_path")
    previous_path = System.get_env("PATH")

    File.mkdir_p!(workspace)
    File.mkdir_p!(relative_dir)
    File.mkdir_p!(path_dir)
    write_fake_claude!(relative_script)
    write_fake_claude!(path_script)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(tmp)
      File.rm_rf(relative_dir)
    end)

    write_claude_workflow!(relative_script, allowed_tools: nil)
    {:ok, relative_session} = Claude.start_session(workspace, [])
    assert {:ok, %Result{status: :done}} = Claude.run_turn(relative_session, "prompt", %{}, [])
    assert :ok = Claude.stop_session(relative_session)

    System.put_env("PATH", path_dir <> ":" <> (previous_path || ""))
    write_claude_workflow!("fake_claude_from_path", allowed_tools: nil)
    {:ok, path_session} = Claude.start_session(workspace, [])
    assert {:ok, %Result{status: :done}} = Claude.run_turn(path_session, "prompt", %{}, [])
    assert :ok = Claude.stop_session(path_session)
  end

  test "drive_port/4 reports port startup errors" do
    assert {:error, {:claude_port, _error}} = Claude.drive_port(<<0>>, [], File.cwd!(), nil)
  end

  test "run_turn reports ssh launch errors" do
    assert {:error, {:claude_ssh_port, %FunctionClauseError{}}} =
             Claude.run_turn(%{workspace: nil, worker_host: "remote", mcp_config_path: "/tmp/mcp"}, "prompt", %{}, [])
  end

  test "run_turn handles timeout and split long stream lines" do
    tmp = Path.join(System.tmp_dir!(), "symphony-claude-timeout-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    slow_script = Path.join(tmp, "slow_claude")
    long_script = Path.join(tmp, "long_claude")
    File.mkdir_p!(workspace)

    File.write!(slow_script, "#!/bin/sh\nsleep 1\n")
    File.chmod!(slow_script, 0o700)

    huge_summary = String.duplicate("a", 1_050_000)
    write_fake_claude_lines!(long_script, [%{"type" => "result", "subtype" => "success", "is_error" => false, "result" => huge_summary}])

    on_exit(fn -> File.rm_rf(tmp) end)

    write_claude_workflow!(slow_script, codex_turn_timeout_ms: 1000, codex_stall_timeout_ms: 1)
    {:ok, stall_session} = Claude.start_session(workspace, [])
    assert Claude.run_turn(stall_session, "prompt", %{}, []) == {:error, :stall_timeout}
    assert :ok = Claude.stop_session(stall_session)

    write_claude_workflow!(slow_script, codex_turn_timeout_ms: 1, codex_stall_timeout_ms: 0)
    {:ok, timeout_session} = Claude.start_session(workspace, [])
    assert Claude.run_turn(timeout_session, "prompt", %{}, []) == {:error, :turn_timeout}
    assert :ok = Claude.stop_session(timeout_session)

    write_claude_workflow!(long_script)
    {:ok, long_session} = Claude.start_session(workspace, [])
    assert {:ok, %Result{summary: ^huge_summary}} = Claude.run_turn(long_session, "prompt", %{}, [])
    assert :ok = Claude.stop_session(long_session)
  end

  test "run_turn maps varied stream events to worker updates" do
    tmp = Path.join(System.tmp_dir!(), "symphony-claude-events-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    script = Path.join(tmp, "event_claude")
    File.mkdir_p!(workspace)

    write_fake_claude_lines!(script, [
      %{"type" => "system", "subtype" => "init", "session_id" => "event-run"},
      %{"type" => "assistant", "message" => %{"usage" => %{"input_tokens" => 7, "output_tokens" => 8}}},
      %{"type" => "assistant", "message" => %{"content" => "not-list"}},
      %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "name" => "mcp__symphony__approval_prompt", "input" => %{"path" => "/tmp/outside"}}
          ]
        }
      },
      %{
        "type" => "assistant",
        "message" => %{
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2},
          "content" => [
            %{"type" => "ignored"},
            %{"type" => "tool_use", "name" => "mcp__symphony__approval_prompt", "input" => "approve shell"}
          ]
        }
      },
      %{"type" => "assistant", "message" => %{}},
      %{"type" => "result", "subtype" => "success", "is_error" => false, "duration_ms" => 1000, "result" => "ok"}
    ])

    on_exit(fn -> File.rm_rf(tmp) end)

    write_claude_workflow!(script)
    {:ok, session} = Claude.start_session(workspace, [])
    parent = self()
    on_message = fn message -> send(parent, {:claude_update, message}) end

    assert {:ok, %Result{status: :blocked, blocked_action: action}} =
             Claude.run_turn(session, "prompt", %{}, on_message: on_message)

    assert action == "approve shell"
    assert :ok = Claude.stop_session(session)

    usage = %{input_tokens: 7, output_tokens: 8, total_tokens: 15}
    blocked_usage = %{input_tokens: 1, output_tokens: 1, total_tokens: 2}

    assert_received {:claude_update, %{event: :session_started, session_id: "event-run"}}
    assert_received {:claude_update, %{event: :usage_updated, usage: ^usage}}
    assert_received {:claude_update, %{event: :blocked, usage: ^blocked_usage}}
    assert_received {:claude_update, %{event: :completed, session_id: "event-run"}}
  end

  defp path_inside?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp write_fake_claude!(path) do
    write_fake_claude_lines!(path, [
      %{"type" => "system", "subtype" => "init", "session_id" => "sess-run"},
      %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "duration_ms" => 1000,
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3},
        "result" => "ok"
      }
    ])
  end

  defp write_fake_claude_lines!(path, events) do
    lines = Enum.map_join(events, "\n", &Jason.encode!/1)

    File.write!(path, """
    #!/bin/sh
    if [ -n "$CLAUDE_ARGV_CAPTURE" ]; then
      : > "$CLAUDE_ARGV_CAPTURE"
      for arg in "$@"; do
        printf '%s\\n' "$arg" >> "$CLAUDE_ARGV_CAPTURE"
      done
    fi
    cat <<'SYMPHONY_CLAUDE_EVENTS'
    #{lines}
    SYMPHONY_CLAUDE_EVENTS
    """)

    File.chmod!(path, 0o700)
  end

  defp write_claude_workflow!(command, opts \\ []) do
    allowed_tools = Keyword.get(opts, :allowed_tools, nil)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker: {kind: memory}
    codex:
      turn_timeout_ms: #{Keyword.get(opts, :codex_turn_timeout_ms, 1000)}
      stall_timeout_ms: #{Keyword.get(opts, :codex_stall_timeout_ms, 1000)}
    claude:
      command: #{Jason.encode!(command)}
      allowed_tools: #{yaml_json(allowed_tools)}
    ---
    body
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
    :ok
  end

  defp yaml_json(nil), do: "null"
  defp yaml_json(value), do: Jason.encode!(value)
end
