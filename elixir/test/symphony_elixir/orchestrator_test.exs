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
      url: "https://example.org/issues/MT-BACKEND"
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
end
