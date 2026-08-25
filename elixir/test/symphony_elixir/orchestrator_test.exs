defmodule SymphonyElixir.OrchestratorTest do
  use SymphonyElixir.TestSupport

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
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator(pid)
    end)

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
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator(pid)
    end)

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
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_orchestrator(pid)
    end)

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
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> stop_orchestrator(pid) end)

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

  defp stop_orchestrator(pid) do
    if Process.alive?(pid) do
      pid
      |> :sys.get_state()
      |> stop_running_tasks()

      Process.exit(pid, :normal)
    end
  end

  defp stop_running_tasks(%{running: running}) when is_map(running) do
    Enum.each(running, fn
      {_issue_id, %{pid: worker_pid}} when is_pid(worker_pid) ->
        Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker_pid)

      _entry ->
        :ok
    end)
  end

  defp write_claude_dispatch_workflow!(workspace_root, fake_claude, max_turn_exhaustions \\ 3) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      active_states: ["Implemented"]
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
      backend_by_state: {"implemented": "claude"}
      blocked_state: "Blocked / Needs Attention"
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

    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
    :ok
  end
end
