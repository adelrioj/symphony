defmodule SymphonyElixir.OperatorActionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{OperatorActions, Runs}
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

  test "resume comments, then moves the ticket to the first active state that is not the blocked state" do
    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, Resume))
    assert :ok = OperatorActions.resume(pid, "op-blocked", "Tokens are in design/dark.json")
    assert_receive {:memory_tracker_comment, "op-blocked", "Tokens are in design/dark.json"}
    assert_receive {:memory_tracker_state_update, "op-blocked", "Todo"}

    assert :ok = OperatorActions.resume(pid, "op-blocked", "  ")
    refute_receive {:memory_tracker_comment, _, _}, 50
    assert_receive {:memory_tracker_state_update, "op-blocked", "Todo"}
  end

  test "resume skips the blocked state and refuses when no other active state exists" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Blocked / Needs Attention", "In Progress"])
    assert :ok = OperatorActions.resume(:missing_orchestrator, "op-blocked", nil)
    assert_receive {:memory_tracker_state_update, "op-blocked", "In Progress"}

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Blocked / Needs Attention"])
    assert {:error, :no_active_state} = OperatorActions.resume(:missing_orchestrator, "op-blocked", nil)
  end

  test "resume stops at the first tracker failure" do
    Memory.fail(:create_comment)
    assert {:error, {:memory_tracker_failed, :create_comment}} = OperatorActions.resume(:missing_orchestrator, "op-blocked", "hello")
    refute_receive {:memory_tracker_state_update, _, _}, 50
  end

  test "stop and retry report an unavailable lane" do
    assert {:error, :unavailable} = OperatorActions.stop(:missing_orchestrator, "x")
    assert {:error, :unavailable} = OperatorActions.retry_now(:missing_orchestrator, "x")
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
