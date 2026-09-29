defmodule SymphonyElixir.Agent.CliHarnessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{Claude, CliHarness, Result}

  @claude_opts [stream: Claude.Stream, error_tag: :claude_port, label: "Claude"]

  test "ssh_payload/1 length-prefixes every part" do
    assert IO.iodata_to_binary(CliHarness.ssh_payload(["ab", "", "xyz"])) == "2\nab0\n3\nxyz"
  end

  test "mkdir_private/1 creates a 0700 directory" do
    dir = Path.join(System.tmp_dir!(), "harness-#{System.unique_integer([:positive])}/a/b")
    assert :ok = CliHarness.mkdir_private(dir)
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
    File.rm_rf!(Path.dirname(Path.dirname(dir)))
  end

  test "new_remote_dir/2 is nil for local contexts and prefixed for remote ones" do
    assert CliHarness.new_remote_dir("symphony-x", SymphonyElixir.ExecutionContext.local("/tmp")) == nil
    remote = SymphonyElixir.ExecutionContext.ssh("/tmp", "host")
    assert "/tmp/symphony-x-" <> _ = CliHarness.new_remote_dir("symphony-x", remote)
  end

  test "create_session_dir/2 returns directory errors" do
    assert {:error, {:mcp_config_dir, %FunctionClauseError{}}} =
             CliHarness.create_session_dir("symphony-claude-mcp", :bad_workspace)
  end

  test "default_mcp_command/1 accepts only an existing executable regular file" do
    executable = System.find_executable("sh")
    assert CliHarness.default_mcp_command(String.to_charlist(executable)) == executable

    missing = "definitely_missing_symphony_escript_#{System.unique_integer([:positive])}"

    assert CliHarness.default_mcp_command(String.to_charlist(missing)) in [
             System.find_executable("symphony"),
             "symphony"
           ]

    assert CliHarness.default_mcp_command(~c"--i-understand-that-this-will-be-running-without-the-usual-guardrails") in [
             System.find_executable("symphony"),
             "symphony"
           ]
  end

  test "default_mcp_command bypasses unusable escript argv under Burrito" do
    previous_burrito = System.get_env("__BURRITO")
    on_exit(fn -> restore_env("__BURRITO", previous_burrito) end)
    System.put_env("__BURRITO", "1")

    fallback = System.find_executable("symphony") || "symphony"

    assert CliHarness.default_mcp_command() == fallback
    refute CliHarness.default_mcp_command() =~ "--i-understand"
    refute CliHarness.default_mcp_command() =~ "WORKFLOW.md"
  end

  test "close_port/1 tolerates live and already-closed ports" do
    live_port = Port.open({:spawn, "cat"}, [:binary])
    assert :ok = CliHarness.close_port(live_port)

    exited_port = Port.open({:spawn, "true"}, [:exit_status])

    receive do
      {^exited_port, {:exit_status, 0}} -> :ok
    after
      500 -> flunk("expected fake port to exit")
    end

    assert :ok = CliHarness.close_port(exited_port)

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
    assert :ok = CliHarness.close_port(owned_port)
    send(owner, :stop)
  end

  test "drive_port/7 reports port startup errors" do
    assert {:error, {:claude_port, _error}} =
             CliHarness.drive_port(<<0>>, [], File.cwd!(), nil, nil, [], @claude_opts)
  end

  test "drive_port/7 folds direct process output" do
    tmp = Path.join(System.tmp_dir!(), "symphony-harness-direct-port-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    script = Path.join(tmp, "direct_claude")
    File.mkdir_p!(workspace)

    write_fake_claude_lines!(script, [
      %{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "direct ok"}
    ])

    on_exit(fn -> File.rm_rf(tmp) end)

    assert {:ok, %Result{status: :done, summary: "direct ok"}} =
             CliHarness.drive_port(script, [], workspace, nil, nil, [], @claude_opts)
  end

  test "local direct and redirected ports scrub adapter-declared tracker secrets" do
    tmp = Path.join(System.tmp_dir!(), "symphony-harness-secret-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    script = Path.join(tmp, "fake_claude")
    prompt_path = Path.join(tmp, "prompt")
    secret_name = "SYMPHONY_CLAUDE_TEST_SECRET"
    previous_secret = System.get_env(secret_name)

    File.mkdir_p!(workspace)
    File.write!(prompt_path, "prompt")

    File.write!(script, """
    #!/bin/sh
    if [ -n "$#{secret_name}" ]; then summary=leaked; else summary=scrubbed; fi
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"'"$summary"'"}'
    """)

    File.chmod!(script, 0o700)
    System.put_env(secret_name, "never-inherit-this")

    on_exit(fn ->
      restore_env(secret_name, previous_secret)
      File.rm_rf(tmp)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{secret_name}",
      claude_command: script
    )

    secret_names = SymphonyElixir.Tracker.bind_agent_tools().secret_environment_names

    assert {:ok, %Result{summary: "scrubbed"}} =
             CliHarness.drive_port(script, [], workspace, nil, nil, secret_names, @claude_opts)

    assert {:ok, %Result{summary: "scrubbed"}} =
             CliHarness.drive_port(script, [], workspace, nil, prompt_path, secret_names, @claude_opts)
  end

  test "drive_port/7 reports redirected port startup errors" do
    assert {:error, {:claude_port, _error}} =
             CliHarness.drive_port("/bin/true", [], <<0>>, nil, "/tmp/prompt", [], @claude_opts)
  end

  test "collect_port_stream folds split no-eol chunks before exit" do
    result_json =
      Jason.encode!(%{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "split ok"})

    {head, tail} = String.split_at(result_json, 12)

    with_collect_port(fn port ->
      send(self(), {port, {:data, {:noeol, head}}})
      send(self(), {port, {:data, {:eol, tail}}})
      send(self(), {port, {:exit_status, 0}})

      assert {:ok, %Result{status: :done, summary: "split ok"}} =
               CliHarness.collect_port_stream(port, nil, Claude.Stream, "Claude")
    end)
  end

  test "collect_port_stream drains queued eol data after exit_status" do
    result_json =
      Jason.encode!(%{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "drained ok"})

    with_collect_port(fn port ->
      send(self(), {port, {:exit_status, 0}})
      send(self(), {port, {:data, {:eol, result_json}}})

      assert {:ok, %Result{status: :done, summary: "drained ok"}} =
               CliHarness.collect_port_stream(port, nil, Claude.Stream, "Claude")
    end)
  end

  test "collect_port_stream logs and skips an undecodable line, still folding the valid result" do
    result_json =
      Jason.encode!(%{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "after bad line"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        with_collect_port(fn port ->
          send(self(), {port, {:data, {:eol, "{not valid json"}}})
          send(self(), {port, {:data, {:eol, result_json}}})
          send(self(), {port, {:exit_status, 0}})

          assert {:ok, %Result{status: :done, summary: "after bad line"}} =
                   CliHarness.collect_port_stream(port, nil, Claude.Stream, "Claude")
        end)
      end)

    assert log =~ "Claude stream line dropped (undecodable)"
  end

  defp write_fake_claude_lines!(path, events) do
    lines = Enum.map_join(events, "\n", &Jason.encode!/1)

    File.write!(path, """
    #!/bin/sh
    cat <<'SYMPHONY_CLAUDE_EVENTS'
    #{lines}
    SYMPHONY_CLAUDE_EVENTS
    """)

    File.chmod!(path, 0o700)
  end

  defp with_collect_port(fun) do
    port = Port.open({:spawn, "sleep 5"}, [:binary, :exit_status])

    try do
      fun.(port)
    after
      _ = CliHarness.close_port(port)
      flush_port_messages(port)
    end
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _message} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end
end
