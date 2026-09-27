defmodule SymphonyElixir.OperatorActionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{OperatorActions, Orchestrator, Runs}
  alias SymphonyElixir.Runs.Run
  alias SymphonyElixir.Tracker.Memory

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 1)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok
  end

  test "stop ends a running attempt as stopped and releases the ticket" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "op-run", identifier: "OP-1", title: "Stop me", state: "Todo", dispatchable: true}
    ])

    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, Stop), runner_fun: blocking_runner())
    assert_receive {:dispatched, "op-run"}, 5_000
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    %{running: [%{attempt_id: attempt_id}]} = GenServer.call(pid, :snapshot)

    assert :ok = OperatorActions.stop(pid, "op-run")
    assert %{running: [], claimed: 0} = GenServer.call(pid, :snapshot)
    assert %Run{status: "stopped"} = Runs.get_by_attempt(attempt_id)
    assert {:error, :not_running} = OperatorActions.stop(pid, "op-run")
  end

  test "retry now runs a pending retry immediately" do
    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, RetryNow), runner_fun: blocking_runner())
    wait_for_first_poll(pid)
    token = make_ref()
    timer = Process.send_after(self(), :unused_timer, 60_000)

    :sys.replace_state(pid, fn state ->
      retry_entry = %{
        attempt: 1,
        timer_ref: timer,
        retry_token: token,
        due_at_ms: System.monotonic_time(:millisecond) + 60_000,
        identifier: "OP-2"
      }

      %{state | retry_attempts: %{"op-retry" => retry_entry}}
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "op-retry", identifier: "OP-2", title: "Retry me", state: "Todo", dispatchable: true}
    ])

    assert :ok = OperatorActions.retry_now(pid, "op-retry")
    assert_receive {:dispatched, "op-retry"}, 5_000
    assert Process.read_timer(timer) == false
    assert {:error, :not_retrying} = OperatorActions.retry_now(pid, "op-retry")
  end

  test "resume comments, then moves a ticket in the blocked state to the first other active state" do
    put_blocked_issue_in_tracker("op-blocked")
    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, Resume))
    assert :ok = OperatorActions.resume(pid, "op-blocked", "Tokens are in design/dark.json")
    assert_receive {:memory_tracker_comment, "op-blocked", "Tokens are in design/dark.json"}
    assert_receive {:memory_tracker_state_update, "op-blocked", "Todo"}

    assert :ok = OperatorActions.resume(pid, "op-blocked", "  ")
    refute_receive {:memory_tracker_comment, _, _}, 50
    assert_receive {:memory_tracker_state_update, "op-blocked", "Todo"}
  end

  test "resume skips the blocked state and refuses when no other active state exists" do
    put_blocked_issue_in_tracker("op-blocked")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Blocked / Needs Attention", "In Progress"])
    assert :ok = OperatorActions.resume(:missing_orchestrator, "op-blocked", nil)
    assert_receive {:memory_tracker_state_update, "op-blocked", "In Progress"}

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Blocked / Needs Attention"])
    assert {:error, :no_active_state} = OperatorActions.resume(:missing_orchestrator, "op-blocked", nil)
  end

  test "resume stops at the first tracker failure" do
    put_blocked_issue_in_tracker("op-blocked")
    Memory.fail(:create_comment)
    assert {:error, {:memory_tracker_failed, :create_comment}} = OperatorActions.resume(:missing_orchestrator, "op-blocked", "hello")
    refute_receive {:memory_tracker_state_update, _, _}, 50
  end

  test "resume refuses a ticket that is neither held blocked nor in the blocked state" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "op-active", identifier: "OP-4", title: "Working", state: "In Progress"},
      %Issue{id: "op-stateless", identifier: "OP-5", title: "No state"}
    ])

    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, NotBlocked))
    assert {:error, :not_blocked} = OperatorActions.resume(pid, "op-active", "hello")
    assert {:error, :not_blocked} = OperatorActions.resume(pid, "op-stateless", nil)
    assert {:error, :not_blocked} = OperatorActions.resume(pid, "op-missing", nil)
    refute_receive {:memory_tracker_comment, _, _}, 50
    refute_receive {:memory_tracker_state_update, _, _}, 50
  end

  test "resume releases the orchestrator's block on a ticket in an active state so it is dispatched again" do
    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, ResumeRelease), runner_fun: blocking_runner())
    wait_for_first_poll(pid)
    issue = %Issue{id: "op-held", identifier: "OP-3", title: "Held", state: "In Progress", dispatchable: true}

    :sys.replace_state(pid, fn state ->
      entry = %{identifier: "OP-3", issue: issue, blocked_at: DateTime.utc_now()}
      %{state | blocked: %{"op-held" => entry}, claimed: MapSet.put(state.claimed, "op-held")}
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Orchestrator.request_refresh(pid)
    refute_receive {:dispatched, "op-held"}, 200
    assert %{blocked: [%{issue_id: "op-held"}]} = GenServer.call(pid, :snapshot)

    assert :ok = OperatorActions.resume(pid, "op-held", nil)
    assert_receive {:memory_tracker_state_update, "op-held", "Todo"}
    assert_receive {:dispatched, "op-held"}, 5_000
    assert %{blocked: []} = GenServer.call(pid, :snapshot)
    assert :ok = GenServer.call(pid, {:operator_release_blocked, "op-held"})
  end

  test "stop and retry report an unavailable lane" do
    assert {:error, :unavailable} = OperatorActions.stop(:missing_orchestrator, "x")
    assert {:error, :unavailable} = OperatorActions.retry_now(:missing_orchestrator, "x")
  end

  defp put_blocked_issue_in_tracker(issue_id) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: issue_id, identifier: "OP-B", title: "Blocked", state: "blocked / needs attention"}
    ])
  end

  defp blocking_runner do
    parent = self()

    fn issue, _recipient, _opts ->
      send(parent, {:dispatched, issue.id})

      receive do
        :finish -> :ok
      end
    end
  end

  defp wait_for_first_poll(pid, attempts \\ 200) do
    %{polling: polling} = GenServer.call(pid, :snapshot)

    cond do
      not polling.checking? and polling.next_poll_in_ms > 1_000 -> :ok
      attempts == 0 -> flunk("orchestrator never finished its first poll")
      true -> Process.sleep(10) && wait_for_first_poll(pid, attempts - 1)
    end
  end
end
