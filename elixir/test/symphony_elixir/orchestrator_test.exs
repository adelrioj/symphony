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

  # Pins every atom `Linear.Scope.validate/1` can emit to its own actionable message. Without this,
  # a typo in one of the four branch heads would silently demote a precise config error into the
  # generic "Failed to fetch from issue tracker" clause, which is the degradation those dedicated
  # branches exist to prevent.
  test "each linear scope config error is logged by its own branch, not the generic tracker failure" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)

    orchestrator_name = Module.concat(__MODULE__, :ScopeErrorOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> stop_orchestrator(pid) end)

    wait_for_state(pid, fn state ->
      state.poll_check_in_progress == false and is_integer(state.next_poll_due_at_ms)
    end)

    scope_errors = [
      {:missing_linear_scope, %{}, "Tracker scope missing in WORKFLOW.md: set tracker.provider.team_keys, tracker.provider.current_cycle, or tracker.provider.project_slug"},
      {:missing_linear_team_keys, %{"current_cycle" => true}, "Tracker scope invalid in WORKFLOW.md: tracker.provider.current_cycle requires tracker.provider.team_keys"},
      {:invalid_linear_team_keys, %{"team_keys" => "MDZ"}, "Tracker scope invalid in WORKFLOW.md: tracker.provider.team_keys must be a list of non-empty team keys"},
      {:invalid_linear_current_cycle, %{"team_keys" => ["MDZ"], "current_cycle" => "yes"}, "Tracker scope invalid in WORKFLOW.md: tracker.provider.current_cycle must be true or false"}
    ]

    for {expected_atom, provider, expected_message} <- scope_errors do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_provider: provider
      )

      # Confirms the config under test really produces the atom it is paired with, so a message
      # assertion can never pass against a different error than the one it names.
      assert {:error, ^expected_atom} = Config.validate!()

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

      assert log =~ expected_message
      refute log =~ "Failed to fetch from issue tracker"
    end
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

  defp write_claude_dispatch_workflow!(workspace_root, fake_claude) do
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
