defmodule SymphonyElixir.Agent.ClaudeSSHTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Claude
  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{ExecutionContext, Repo}

  test "remote_command/2 never contains the prompt text" do
    prompt = ~s|"; rm -rf / ; echo $(whoami) `id`|
    command = Claude.remote_command("/work/dir", prompt)

    refute command =~ "rm -rf"
    refute command =~ "whoami"
    assert command =~ "claude"
    assert command =~ "--output-format stream-json"
    assert command =~ "--permission-prompt-tool"
    refute command =~ "symphony_prompt_file"
  end

  for transport <- [:static, :structured] do
    test "run_turn over #{transport} ssh delivers the prompt through stdin and folds the stream" do
      tmp = Path.join(System.tmp_dir!(), "symphony-claude-ssh-test-#{System.unique_integer([:positive])}")
      workspace = Path.join(tmp, "workspace")
      fake_claude = Path.join(tmp, "fake_claude")
      ssh_trace = Path.join(tmp, "ssh.trace")
      stdin_capture = Path.join(tmp, "stdin.txt")
      argv_capture = Path.join(tmp, "argv.txt")
      mcp_config_capture = Path.join(tmp, "mcp.json")
      hacked = Path.join(tmp, "hacked")
      previous_path = System.get_env("PATH")
      previous_stdin_capture = System.get_env("CLAUDE_STDIN_CAPTURE")
      previous_argv_capture = System.get_env("CLAUDE_ARGV_CAPTURE")
      previous_mcp_config_capture = System.get_env("CLAUDE_MCP_CONFIG_CAPTURE")
      previous_secret_capture = System.get_env("CLAUDE_SECRET_CAPTURE")
      secret_name = "SYMPHONY_CLAUDE_REMOTE_SECRET"
      secret_value = "never-put-this-in-ssh-argv"
      previous_secret = System.get_env(secret_name)
      secret_capture = Path.join(tmp, "secret.txt")

      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("CLAUDE_STDIN_CAPTURE", previous_stdin_capture)
        restore_env("CLAUDE_ARGV_CAPTURE", previous_argv_capture)
        restore_env("CLAUDE_MCP_CONFIG_CAPTURE", previous_mcp_config_capture)
        restore_env("CLAUDE_SECRET_CAPTURE", previous_secret_capture)
        restore_env(secret_name, previous_secret)
        File.rm_rf(tmp)
      end)

      File.mkdir_p!(workspace)
      write_fake_ssh!(tmp, ssh_trace)
      write_fake_claude!(fake_claude)

      System.put_env("CLAUDE_STDIN_CAPTURE", stdin_capture)
      System.put_env("CLAUDE_ARGV_CAPTURE", argv_capture)
      System.put_env("CLAUDE_MCP_CONFIG_CAPTURE", mcp_config_capture)
      System.put_env("CLAUDE_SECRET_CAPTURE", secret_capture)
      System.put_env(secret_name, secret_value)
      write_claude_workflow!(fake_claude)

      target =
        case unquote(transport) do
          :static ->
            "localhost"

          :structured ->
            %SymphonyElixir.SSH.Target{executable: Path.join([tmp, "bin", "ssh"]), prefix: [], label: "fixture"}
        end

      {:ok, session} =
        Claude.start_session(workspace,
          execution_context:
            SymphonyElixir.ExecutionContext.ssh(SymphonyElixir.Config.settings!().workspace.root, target)
        )

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
      assert ssh_args =~ "unset "
      assert ssh_args =~ secret_name
      refute ssh_args =~ secret_value

      args =
        argv_capture
        |> File.read!()
        |> String.split("\n", trim: true)

      assert "-p" in args
      assert "--mcp-config" in args
      assert "--strict-mcp-config" in args
      assert "--allowedTools" in args
      assert "--permission-prompt-tool" in args

      assert Enum.at(args, Enum.find_index(args, &(&1 == "--permission-prompt-tool")) + 1) ==
               "mcp__symphony__approval_prompt"

      refute prompt in args

      allowed_tools = Enum.at(args, Enum.find_index(args, &(&1 == "--allowedTools")) + 1)
      refute allowed_tools =~ "mcp__symphony__approval_prompt"

      mcp_config = mcp_config_capture |> File.read!() |> Jason.decode!()
      assert get_in(mcp_config, ["mcpServers", "symphony", "env", secret_name]) == secret_value
      assert File.read!(secret_capture) == "unset"
      remote_args = get_in(mcp_config, ["mcpServers", "symphony", "args"])
      workflow_index = Enum.find_index(remote_args, &(&1 == "--workflow"))
      remote_workflow_path = Enum.at(remote_args, workflow_index + 1)

      assert remote_workflow_path =~ "/tmp/symphony-claude-workflow."
      refute remote_workflow_path == Workflow.workflow_file_path()

      assert_received {:claude_update, %{event: :session_started, session_id: "ssh-run"}}

      assert_received {:claude_update,
                       %{
                         event: :completed,
                         session_id: "ssh-run",
                         usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
                       }}
    end
  end

  for {transport, slug, route, live_state, labels} <- [
        {:local, "bonbons-delivery", "bug", "In Progress", ["groomed", "Bug"]},
        {:ssh, "chorus-delivery", "qa", "In Review", ["groomed"]}
      ] do
    @tag :tmp_dir
    test "#{transport} Claude uses just Common and its selected pinned procedure on every turn", %{tmp_dir: root} do
      previous_path = System.get_env("PATH")
      on_exit(fn -> restore_env("PATH", previous_path) end)
      trace = Path.join(root, "ssh.trace")
      write_fake_ssh!(root, trace)

      route = unquote(route)

      issue = %Issue{
        id: "bound-test-issue",
        identifier: "TEST-1",
        state: unquote(live_state),
        dispatchable: true,
        labels: unquote(labels)
      }

      procedures = %{"qa" => "PINNED_QA", "bug" => "PINNED_BUG", "deliver" => "PINNED_DELIVER"}

      procedures =
        if unquote(slug) == "bonbons-delivery",
          do: Map.put(procedures, "error-reporting", "PINNED_ERROR_REPORTING"),
          else: procedures

      run_log = Path.join(root, "model-boundary.jsonl")
      claude = write_procedure_claude!(root, run_log, route)
      mcp = write_procedure_mcp!(root, issue)

      {:ok, lane} =
        create_lane_from_front_matter(%{
          slug: unquote(slug),
          procedures: procedures,
          prompt: "PINNED_COMMON",
          front_matter: """
          tracker:
            kind: memory
            active_states: ["Todo", "In Progress", "In Review"]
          workspace:
            root: #{Jason.encode!(Path.join(root, "workspaces"))}
          codex: {turn_timeout_ms: 15000, stall_timeout_ms: 15000}
          claude:
            command: #{Jason.encode!(claude)}
            linear_mcp_command: #{Jason.encode!(mcp)}
            allowed_tools: ["Read"]
          """
        })

      {:ok, pinned} = LaneStore.lookup(lane.id)
      LaneContext.install(pinned)
      assert pinned.version_id == lane.current_version_id
      assert pinned.procedures == procedures
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      context =
        case unquote(transport) do
          :local ->
            ExecutionContext.local(pinned.settings.workspace.root)

          :ssh ->
            target = %SymphonyElixir.SSH.Target{
              executable: Path.join([root, "bin", "ssh"]),
              prefix: [],
              label: "fixture",
              env: [{"BASH_ENV", Path.join(root, "fixture-bash-env")}]
            }

            ExecutionContext.ssh(pinned.settings.workspace.root, target)
        end

      current_procedures = Map.replace!(procedures, route, "CURRENT_REPLACEMENT")

      fetch_issue = fn [id] ->
        assert id == issue.id

        if LaneStore.lookup(lane.id) == {:ok, pinned} do
          assert {:ok, updated} = Lanes.update(lane, %{prompt: "CURRENT_COMMON", procedures: current_procedures})
          assert updated.current_version_id != pinned.version_id
        end

        {:ok, [issue]}
      end

      opts = [execution_context: context, backend_module: Claude]
      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 2, issue_state_fetcher: fetch_issue])

      [first, continuation] = read_boundary(run_log)
      refute first["prompt"] =~ "Continuation guidance"
      assert continuation["prompt"] =~ "Continuation guidance"

      for capture <- [first, continuation] do
        assert capture["prompt"] =~ "PINNED_COMMON"
        refute capture["prompt"] =~ "CURRENT_COMMON"
        assert capture["selected"] == Map.fetch!(procedures, route)
        assert capture["error_reporting_denied"]
        assert capture["tool_allowed"]
        assert capture["private_outside_workspace"]
        refute File.exists?(capture["procedure_path"])
        refute File.exists?(capture["procedure_path"] <> ".outcome")

        for marker <- Map.values(procedures) ++ ["CURRENT_REPLACEMENT"] do
          refute capture["prompt"] =~ marker
          refute capture["mcp_list"] =~ marker
        end
      end

      if unquote(transport) == :ssh do
        ssh_args = File.read!(trace)
        for marker <- ["PINNED_COMMON" | Map.values(procedures)], do: refute(ssh_args =~ marker)
      end

      mode = Path.join(root, "fixture-mode")
      File.write!(mode, "exit_81")

      assert_raise RuntimeError, ~r/nonzero exit after successful result/, fn ->
        AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      end

      File.write!(mode, "unread")

      assert_raise RuntimeError, ~r/procedure_not_read/, fn ->
        AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      end

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | labels: ["human"]}])
      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      refute_received {:codex_worker_update, _, _, %{event: :attempt_blocked}}
      File.rm!(mode)

      # The new run sees a damaged lane version. The MCP sees the original route, but
      # preflight and the final tracker read see a route that does not need the missing section.
      updated = Lanes.get!(lane.id)
      version = Lanes.current_version(updated)
      Repo.update!(Ecto.Changeset.change(version, procedures: Map.delete(current_procedures, route)))
      assert :ok = LaneStore.refresh(lane.id)
      {:ok, new_run} = LaneStore.lookup(lane.id)
      LaneContext.install(new_run)
      refute new_run.version_id == pinned.version_id

      recheck =
        if route == "qa",
          do: %{issue | state: "In Progress"},
          else: %{issue | state: "In Review"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [recheck])

      if unquote(transport) == :ssh do
        LaneContext.install(put_in(new_run.settings.codex.turn_timeout_ms, 5_000))
        File.write!(mode, "stall")

        try do
          assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
        after
          File.rm!(mode)
          LaneContext.install(new_run)
        end
      else
        assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      end

      refute_received {:codex_worker_update, _, _, %{event: :attempt_blocked}}
      assert Tracker.Memory.calls() == []
      captures = read_boundary(run_log)
      assert List.last(captures)["selected_error"]
      assert List.last(captures)["prompt"] =~ "CURRENT_COMMON"

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      assert_received {:codex_worker_update, _, _, %{event: :attempt_blocked, payload: detail}}
      assert detail =~ route

      assert Tracker.Memory.calls() == [
               {:create_comment, issue.id},
               {:update_issue_state, issue.id, new_run.settings.agent.blocked_state}
             ]

      assert read_boundary(run_log) == captures

      version = Lanes.current_version(updated)
      Repo.update!(Ecto.Changeset.change(version, prompt: "LEGACY_INLINE", procedures: %{}))
      assert :ok = LaneStore.refresh(lane.id)
      {:ok, legacy} = LaneStore.lookup(lane.id)
      LaneContext.install(legacy)
      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      assert_received {:codex_worker_update, _, _, %{event: :attempt_blocked, payload: detail}}
      assert detail =~ "bundle is missing or blank"
      assert read_boundary(run_log) == captures

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | labels: ["human"]}])
      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      refute_received {:codex_worker_update, _, _, %{event: :attempt_blocked}}
      assert read_boundary(run_log) == captures

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Repo.update!(Ecto.Changeset.change(version, prompt: " ", procedures: current_procedures))
      assert :ok = LaneStore.refresh(lane.id)
      {:ok, blank_common} = LaneStore.lookup(lane.id)
      LaneContext.install(blank_common)
      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      assert_received {:codex_worker_update, _, _, %{event: :attempt_blocked, payload: detail}}
      assert detail =~ "Common prompt is missing or blank"
      assert read_boundary(run_log) == captures
    end
  end

  defp read_boundary(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp write_procedure_mcp!(root, issue) do
    path = Path.join(root, "fixture-mcp")
    alias SymphonyElixir.Agent.CliHarness

    code = """
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [#{inspect(issue)}])
    SymphonyElixir.CLI.main(System.argv())
    """

    beam_paths = Enum.map_join(:code.get_path(), " ", &("-pa " <> CliHarness.shell_escape(Path.expand(&1))))
    executable = CliHarness.shell_escape(System.find_executable("elixir"))

    File.write!(
      path,
      "#!/bin/sh\nexec #{executable} --erl '+S 2:2' #{beam_paths} -e #{CliHarness.shell_escape(code)} -- \"$@\"\n"
    )

    File.chmod!(path, 0o700)
    path
  end

  defp write_procedure_claude!(root, run_log, section) do
    path = Path.join(root, "fixture-claude")

    File.write!(path, """
    #!/usr/bin/env python3
    import json, os, stat, subprocess, sys, time
    from pathlib import Path

    mode_file = Path(#{Jason.encode!(Path.join(root, "fixture-mode"))})
    mode = mode_file.read_text() if mode_file.exists() else ""

    prompt = sys.stdin.read()
    index = sys.argv.index("--mcp-config") + 1
    with open(sys.argv[index]) as stream:
        config = json.load(stream)["mcpServers"]["symphony"]
    environment = config["env"]
    procedure_path = environment["SYMPHONY_CLAUDE_PROCEDURE_CONTEXT"]
    requests = [
        {"id": 1, "method": "tools/list"},
        {"id": 2, "method": "tools/call", "params": {"name": "read_procedure", "arguments": {"section": "error-reporting"}}},
        {"id": 3, "method": "tools/call", "params": {"name": "read_procedure", "arguments": {"section": #{Jason.encode!(section)}}}},
    ]
    if mode == "unread":
        requests.pop()
    result = subprocess.run(
        [config["command"], *config["args"]], check=True, text=True, capture_output=True,
        env=dict(os.environ, **environment), input="".join(json.dumps(m) + "\\n" for m in requests),
    )
    responses = [json.loads(line)["result"] for line in result.stdout.splitlines()]
    listed, rejected = responses[:2]
    selected = responses[2] if len(responses) > 2 else {"content": [{"text": ""}], "isError": True}
    allowed = sys.argv[sys.argv.index("--allowedTools") + 1].split(",")
    with open(#{Jason.encode!(run_log)}, "a") as log:
        log.write(json.dumps({
            "prompt": prompt, "mcp_list": json.dumps(listed),
            "selected": selected["content"][0]["text"], "selected_error": selected["isError"],
            "error_reporting_denied": rejected["isError"], "procedure_path": procedure_path,
            "tool_allowed": "mcp__symphony__read_procedure" in allowed,
            "private_outside_workspace": not os.path.realpath(procedure_path).startswith(os.getcwd() + "/")
                and stat.S_IMODE(os.stat(procedure_path).st_mode) == 0o600,
        }) + "\\n")
    print('{"type":"system","subtype":"init","session_id":"managed-fixture"}')
    if mode == "stall":
        sys.stdout.flush()
        deadline = time.monotonic() + 10
        while mode_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
    print('{"type":"result","subtype":"success","is_error":false,"result":"ok"}')
    if mode == "exit_81":
        sys.exit(81)
    """)

    File.chmod!(path, 0o700)
    path
  end

  test "managed MCP snapshot works without controller kubeconfig and still denies approval" do
    alias SymphonyElixir.{Config, ExecutionContext, LaneContext}
    alias SymphonyElixir.Config.Schema
    alias SymphonyElixir.MCP.LinearServer

    root = Path.join(System.tmp_dir!(), "symphony-mcp-guest-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    kubeconfig = Path.join(root, "controller.kubeconfig")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    File.mkdir_p!(workspace)
    File.write!(kubeconfig, "controller-only")
    write_fake_ssh!(root, Path.join(root, "ssh.trace"))

    provider = %{
      "kubeconfig" => kubeconfig,
      "context" => "unit",
      "namespace" => "candidate",
      "template" => "worker",
      "ssh_user" => "worker",
      "ssh_auth_volume" => "auth",
      "ssh_port" => 2222
    }

    reset_lanes!()

    :ok =
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: root,
        worker_environment: %{
          kind: "kubernetes",
          deployment_id: "mcp-guest",
          provider: provider,
          startup_timeout_ms: 1_000,
          shutdown_timeout_ms: 1_000
        }
      )

    target = %SymphonyElixir.SSH.Target{
      executable: Path.join([root, "bin", "ssh"]),
      prefix: [],
      label: "fixture",
      env: [{"BASH_ENV", Path.join(root, "fixture-bash-env")}]
    }

    context = %ExecutionContext{mode: :managed, workspace_root: root, workspace_path: workspace, target: target}
    {:ok, session} = Claude.start_session(workspace, execution_context: context)
    on_exit(fn -> Claude.stop_session(session) end)

    File.rm!(kubeconfig)
    {:ok, workflow} = Workflow.load(session.workflow_snapshot_path)
    {:ok, settings} = Schema.parse(workflow.config)
    assert :ok = Config.validate_settings(settings)

    {:ok, entry} = LaneContext.capture()
    LaneContext.install(%{entry | settings: settings, workflow: workflow})
    response = LinearServer.handle_request(%{"method" => "tools/list", "id" => 1})
    assert Enum.map(response["result"]["tools"], & &1["name"]) == ["approval_prompt"]

    denied =
      LinearServer.handle_request(%{"method" => "tools/call", "id" => 2, "params" => %{"name" => "approval_prompt"}})

    assert denied["result"]["isError"] == true
  end

  defp write_fake_ssh!(test_root, trace_file) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")
    fake_realpath = Path.join(fake_bin_dir, "realpath")

    File.mkdir_p!(fake_bin_dir)
    escaped_bin = "'" <> String.replace(fake_bin_dir, "'", "'\"'\"'") <> "'"
    File.write!(Path.join(test_root, "fixture-bash-env"), "export PATH=#{escaped_bin}:\"$PATH\"\n")

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

    File.write!(
      fake_realpath,
      "#!/bin/sh\n[ \"$1\" = -m ] && shift\n[ \"$1\" = -- ] && shift\nexec python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \"$1\"\n"
    )

    File.chmod!(fake_realpath, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp write_fake_claude!(path) do
    File.write!(path, """
    #!/bin/sh
    : > "$CLAUDE_ARGV_CAPTURE"
    previous=
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$CLAUDE_ARGV_CAPTURE"
      if [ "$previous" = "--mcp-config" ] && [ -n "$CLAUDE_MCP_CONFIG_CAPTURE" ]; then
        cp "$arg" "$CLAUDE_MCP_CONFIG_CAPTURE"
      fi
      previous=$arg
    done
    if [ -n "$CLAUDE_SECRET_CAPTURE" ]; then
      printf %s "${SYMPHONY_CLAUDE_REMOTE_SECRET-unset}" > "$CLAUDE_SECRET_CAPTURE"
    fi
    cat > "$CLAUDE_STDIN_CAPTURE"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"ssh-run"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5},"result":"ssh ok"}'
    """)

    File.chmod!(path, 0o700)
  end

  defp write_claude_workflow!(command) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: linear
      provider:
        api_key: $SYMPHONY_CLAUDE_REMOTE_SECRET
        project_slug: project
    codex: {turn_timeout_ms: 2000, stall_timeout_ms: 2000}
    claude:
      command: #{Jason.encode!(command)}
      linear_mcp_command: "/bin/true"
      allowed_tools: null
    ---
    body
    """)

    assert :ok = reload_workflow!()
    :ok
  end
end
