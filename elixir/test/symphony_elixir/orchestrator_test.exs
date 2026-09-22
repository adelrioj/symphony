defmodule SymphonyElixir.OrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExecutionEnvironment.Command

  @tag :remediation
  @tag :tmp_dir
  test "remediation: SSH startup cleanup cannot delete through a stable root symlink outside its profile", %{tmp_dir: root} do
    bin = Path.join(root, "fixture-bin")
    File.mkdir_p!(bin)
    realpath = System.find_executable("grealpath") || System.find_executable("realpath") || flunk("SSH fixtures require realpath supporting -m")
    File.ln_s!(realpath, Path.join(bin, "realpath"))
    File.ln_s!("/bin/bash", Path.join(bin, "bash"))
    ssh = Path.join(bin, "ssh")

    File.write!(ssh, """
    #!/bin/sh
    for argument in "$@"; do command=$argument; done
    exec /bin/sh -c "$command"
    """)

    File.chmod!(ssh, 0o700)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":/usr/bin:/bin")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    # Establish the local transport and GNU realpath prerequisite before the
    # production two-second SSH deadline, without retrying any lane operation.
    fixture =
      Command.run(
        ssh,
        ["controlled-fixture", SymphonyElixir.SSH.remote_shell_command("realpath -m -- / /symphony-fixture-missing/..")],
        timeout_ms: 5_000,
        task_supervisor: SymphonyElixir.TaskSupervisor
      )

    assert fixture == {:ok, %{output: "/\n/\n", status: 0}},
           "controlled SSH fixture requires a ready shell and realpath -m: #{inspect(fixture)}"

    assert_startup_cleanup_retains_base(root)
  end

  test "an issue whose state maps to an unknown backend is logged and not claimed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_active_states: ["Implemented"],
      poll_interval_ms: 30_000,
      agent_backend: "codex",
      agent_backend_by_state: %{"implemented" => "gemini"},
      codex_command: "/bin/false"
    )

    issue = %Issue{
      id: "issue-invalid-backend",
      identifier: "MT-BACKEND",
      title: "Unknown backend",
      description: "Should not be claimed",
      state: "Implemented",
      url: "https://example.org/issues/MT-BACKEND",
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :InvalidBackendOrchestrator)
    {:ok, pid} = start_test_orchestrator(name: orchestrator_name)

    wait_for_state(pid, fn state ->
      state.poll_check_in_progress == false and is_integer(state.next_poll_due_at_ms)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)

        wait_for_state(pid, fn state ->
          state.poll_check_in_progress == false and is_integer(state.next_poll_due_at_ms)
        end)
      end)

    state = :sys.get_state(pid)

    assert log =~ "invalid_agent_backend"
    assert log =~ issue.identifier
    refute MapSet.member?(state.claimed, issue.id)
    refute Map.has_key?(state.running, issue.id)
  end

  test "an issue with an invalid global backend is logged and not claimed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_active_states: ["Implemented"],
      poll_interval_ms: 30_000,
      agent_backend: "gemini",
      agent_backend_by_state: %{},
      codex_command: "/bin/false"
    )

    issue = %Issue{
      id: "issue-invalid-global-backend",
      identifier: "MT-GLOBAL",
      title: "Unknown global backend",
      description: "Should not be claimed",
      state: "Implemented",
      url: "https://example.org/issues/MT-GLOBAL",
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :InvalidGlobalBackendOrchestrator)
    {:ok, pid} = start_test_orchestrator(name: orchestrator_name)

    wait_for_state(pid, fn state ->
      state.poll_check_in_progress == false and is_integer(state.next_poll_due_at_ms)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)

        wait_for_state(pid, fn state ->
          state.poll_check_in_progress == false and is_integer(state.next_poll_due_at_ms)
        end)
      end)

    state = :sys.get_state(pid)

    assert log =~ "invalid_agent_backend"
    assert log =~ issue.identifier
    refute MapSet.member?(state.claimed, issue.id)
    refute Map.has_key?(state.running, issue.id)
  end

  test "a claude per-state backend override is dispatched through Claude" do
    tmp = Path.join(System.tmp_dir!(), "symphony-orchestrator-claude-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(tmp, "workspaces")
    fake_claude = Path.join(tmp, "fake_claude")
    argv_capture = Path.join(tmp, "claude.argv")
    File.mkdir_p!(tmp)
    File.mkdir_p!(workspace_root)

    File.write!(fake_claude, """
    #!/bin/sh
    : > "#{argv_capture}"
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "#{argv_capture}"
    done
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"orch-claude"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"result":"done"}'
    """)

    File.chmod!(fake_claude, 0o700)

    on_exit(fn -> File.rm_rf(tmp) end)

    write_claude_dispatch_workflow!(workspace_root, fake_claude)

    issue = %Issue{
      id: "issue-claude-dispatch",
      identifier: "MT-CLAUDE",
      title: "Claude dispatch",
      description: "Should run the Claude backend",
      state: "Implemented",
      url: "https://example.org/issues/MT-CLAUDE",
      labels: [],
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :ClaudeDispatchOrchestrator)
    {:ok, pid} = start_test_orchestrator(name: orchestrator_name)

    wait_for_state(pid, fn state ->
      state.poll_check_in_progress == false and is_integer(state.next_poll_due_at_ms)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    send(pid, :run_poll_cycle)

    wait_until(fn -> File.exists?(argv_capture) end)
    wait_until(fn -> File.read!(argv_capture) =~ "--permission-prompt-tool" end)

    args = argv_capture |> File.read!() |> String.split("\n", trim: true)
    assert "-p" in args
    assert "--permission-prompt-tool" in args
    refute "/bin/false" in args
  end

  test "a dispatched worker that exhausts its turn budget is parked as blocked" do
    tmp = Path.join(System.tmp_dir!(), "symphony-orchestrator-exhaustion-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(tmp, "workspaces")
    fake_claude = Path.join(tmp, "fake_claude")
    File.mkdir_p!(workspace_root)

    File.write!(fake_claude, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"orch-exhausted"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"result":"done"}'
    """)

    File.chmod!(fake_claude, 0o700)

    on_exit(fn -> File.rm_rf(tmp) end)

    write_claude_dispatch_workflow!(workspace_root, fake_claude, 1)

    issue = %Issue{
      id: "issue-claude-exhausted",
      identifier: "MT-EXHAUST",
      title: "Never finishes",
      description: "Stays in the same active state after every run",
      state: "Implemented",
      url: "https://example.org/issues/MT-EXHAUST",
      labels: [],
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

    orchestrator_name = Module.concat(__MODULE__, :ExhaustionOrchestrator)
    {:ok, pid} = start_test_orchestrator(name: orchestrator_name)

    wait_for_state(pid, fn state ->
      state.poll_check_in_progress == false and is_integer(state.next_poll_due_at_ms)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    send(pid, :run_poll_cycle)

    state = wait_for_state(pid, fn state -> Map.has_key?(state.blocked, issue.id) end, 20_000)

    assert %{identifier: "MT-EXHAUST", error: error} = state.blocked[issue.id]
    assert error == "reached agent.max_turns (1) 1 runs in a row without leaving state=Implemented"
    refute Map.has_key?(state.retry_attempts, issue.id)
    refute Map.has_key?(state.running, issue.id)

    assert_receive {:memory_tracker_comment, "issue-claude-exhausted", body}, 5_000
    assert body =~ "Symphony parked this work item"
    assert_receive {:memory_tracker_state_update, "issue-claude-exhausted", "Blocked / Needs Attention"}, 5_000
  end

  # Symphony moves a claimed work item itself. The prompt used to ask the agent to do it in
  # step 1, and on 2026-09-05 an agent ran for 25 minutes without ever making the move, so a
  # human reading the board saw an untouched work item. The orchestrator already knows it
  # dispatched; bookkeeping it can do deterministically does not belong to a model.
  test "a claimed work item is moved to In Progress by the orchestrator" do
    {issue, pid} = start_claim_dispatch("issue-claim-todo", "MT-CLAIM-TODO", "Todo")

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_state_update, "issue-claim-todo", "In Progress"}, 5_000
    assert issue.state == "Todo"
  end

  # A retry and a resume both re-dispatch a work item that is already In Progress. Neither may
  # spend a tracker write saying what is already true.
  test "a claimed work item already In Progress is not moved again" do
    {_issue, pid} = start_claim_dispatch("issue-claim-active", "MT-CLAIM-ACTIVE", "In Progress")

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)

        wait_for_state(pid, fn state -> MapSet.member?(state.claimed, "issue-claim-active") end, 10_000)
      end)

    assert log =~ "Dispatching issue to agent"
    refute_receive {:memory_tracker_state_update, "issue-claim-active", _state}, 2_000
  end

  # The move is bookkeeping, not a precondition. Linear was unreachable from the host earlier on
  # the same day the move was written; a tracker outage must not cost the run.
  test "a failed claim state move is logged and the agent still runs" do
    {_issue, pid} = start_claim_dispatch("issue-claim-fails", "MT-CLAIM-FAILS", "Todo")

    Tracker.Memory.fail(:update_issue_state)

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)

        wait_for_state(pid, fn state -> MapSet.member?(state.claimed, "issue-claim-fails") end, 10_000)
      end)

    assert log =~ "Claim state move failed"
    assert log =~ "MT-CLAIM-FAILS"
    assert log =~ "Dispatching issue to agent"
  end

  # The QA lane dispatches from `In Review`. `In Progress` is an active state of the two
  # other lanes, so a move there would hand the ticket back to them. An empty
  # `agent.in_progress_state` turns the move off for that instance.
  test "an empty agent.in_progress_state leaves a claimed work item in its state" do
    {_issue, pid} = start_claim_dispatch("issue-claim-qa", "MT-CLAIM-QA", "In Review", in_progress_state: "")

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)

        wait_for_state(pid, fn state -> MapSet.member?(state.claimed, "issue-claim-qa") end, 10_000)
      end)

    assert log =~ "Dispatching issue to agent"
    refute_receive {:memory_tracker_state_update, "issue-claim-qa", _state}, 2_000
  end

  test "a configured agent.in_progress_state is the state a claimed work item moves to" do
    {_issue, pid} = start_claim_dispatch("issue-claim-named", "MT-CLAIM-NAMED", "Todo", in_progress_state: "Doing")

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_state_update, "issue-claim-named", "Doing"}, 5_000
  end

  defp start_claim_dispatch(issue_id, identifier, state, opts \\ []) do
    tmp = Path.join(System.tmp_dir!(), "symphony-orchestrator-claim-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(tmp, "workspaces")
    fake_claude = Path.join(tmp, "fake_claude")
    File.mkdir_p!(workspace_root)

    File.write!(fake_claude, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"orch-claim"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"result":"done"}'
    """)

    File.chmod!(fake_claude, 0o700)
    on_exit(fn -> File.rm_rf(tmp) end)

    write_claude_dispatch_workflow!(
      workspace_root,
      fake_claude,
      3,
      Keyword.merge(
        [
          active_states: ["Todo", "In Progress", "In Review"],
          backend_by_state: ~s({"todo": "claude", "in progress": "claude", "in review": "claude"})
        ],
        opts
      )
    )

    issue = %Issue{
      id: issue_id,
      identifier: identifier,
      title: "Claim bookkeeping",
      description: "The orchestrator owns the state move",
      state: state,
      url: "https://example.org/issues/#{identifier}",
      labels: [],
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :"ClaimOrchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = start_test_orchestrator(name: orchestrator_name)

    wait_for_state(pid, fn state ->
      state.poll_check_in_progress == false and is_integer(state.next_poll_due_at_ms)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    {issue, pid}
  end

  defp assert_startup_cleanup_retains_base(root) do
    base = Path.join(root, "profile-base")
    File.mkdir_p!(base)
    {:ok, profile} = ExecutionProfiles.create(%{name: "Startup containment", workspace_base: base, worker: %{"ssh_hosts" => ["controlled-fixture"]}})

    {:ok, lane} =
      Lanes.create(%{
        slug: "startup-containment",
        execution_profile_id: profile.id,
        workspace_subdir: "lane",
        config: %{"tracker" => %{"kind" => "memory", "terminal_states" => ["Done"]}, "polling" => %{"interval_ms" => 60_000}}
      })

    LaneContext.put(lane.id)
    {:ok, entry} = LaneStore.lookup(lane.id)
    workspace_root = entry.settings.workspace.root
    terminal = %Issue{id: "terminal-cleanup", identifier: "CLEANUP-1", title: "Finished", state: "Done", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal])
    terminal_workspace = Path.join(workspace_root, terminal.identifier)
    File.mkdir_p!(terminal_workspace)
    File.write!(Path.join(terminal_workspace, "remove-me"), "terminal workspace")

    safe_name = Module.concat(__MODULE__, :"SafeStartup#{System.unique_integer([:positive])}")
    {:ok, safe_owner} = start_test_orchestrator(name: safe_name)
    assert %{running: []} = Orchestrator.snapshot(safe_owner, 1_000)
    refute File.exists?(terminal_workspace)
    stop_supervised!(Module.concat(safe_name, RuntimeSupervisor))

    outside = Path.join(root, "outside-profile")
    outside_workspace = Path.join(outside, terminal.identifier)
    File.mkdir_p!(outside_workspace)
    marker = Path.join(outside_workspace, "keep")
    File.write!(marker, "outside data")
    File.rm_rf!(workspace_root)
    File.ln_s!(outside, workspace_root)

    escaped_name = Module.concat(__MODULE__, :"EscapedStartup#{System.unique_integer([:positive])}")
    {:ok, escaped_owner} = start_test_orchestrator(name: escaped_name)
    assert %{running: []} = Orchestrator.snapshot(escaped_owner, 1_000)
    assert File.read!(marker) == "outside data"
  end

  defp wait_for_state(pid, predicate, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_state(pid, predicate, deadline)
  end

  defp do_wait_for_state(pid, predicate, deadline) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for orchestrator state")

      true ->
        Process.sleep(10)
        do_wait_for_state(pid, predicate, deadline)
    end
  end

  defp wait_until(predicate, timeout_ms \\ 1_000) when is_function(predicate, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(predicate, deadline)
  end

  defp do_wait_until(predicate, deadline) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for condition")

      true ->
        Process.sleep(10)
        do_wait_until(predicate, deadline)
    end
  end

  defp write_claude_dispatch_workflow!(workspace_root, fake_claude, max_turn_exhaustions \\ 3, opts \\ []) do
    active_states = Keyword.get(opts, :active_states, ["Implemented"])
    backend_by_state = Keyword.get(opts, :backend_by_state, ~s({"implemented": "claude"}))
    in_progress_state = Keyword.get(opts, :in_progress_state, "In Progress")
    File.rm_rf!(Config.local_workspace_root())

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      active_states: #{Jason.encode!(active_states)}
      terminal_states: ["Done"]
    polling:
      interval_ms: 30000
    workspace:
      root: #{Jason.encode!(workspace_root)}
    agent:
      max_concurrent_agents: 1
      max_turns: 1
      max_turn_exhaustions: #{max_turn_exhaustions}
      backend: codex
      backend_by_state: #{backend_by_state}
      blocked_state: "Blocked / Needs Attention"
      in_progress_state: #{Jason.encode!(in_progress_state)}
    codex:
      command: "/bin/false"
      turn_timeout_ms: 2000
      stall_timeout_ms: 2000
    claude:
      command: #{Jason.encode!(fake_claude)}
      allowed_tools: null
    ---
    body
    """)

    assert :ok = reload_workflow!()
    :ok
  end
end
