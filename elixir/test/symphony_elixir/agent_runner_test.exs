defmodule SymphonyElixir.AgentRunnerStubBackend do
  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Result

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{turns: 0}}

  @impl true
  def run_turn(_session, _prompt, _issue, opts) do
    if pid = opts[:test_pid], do: send(pid, :stub_turn_ran)

    result =
      Keyword.get_lazy(opts, :test_result, fn ->
        Result.new(status: :done, session_id: "stub-1")
      end)

    {:ok, result}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.Tracker.Memory, as: MemoryTracker

  setup do
    MemoryTracker.reset()
    :ok
  end

  test "run/3 drives the injected backend module" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-backend-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-stub-backend",
      identifier: "STUB-1",
      title: "Run a stub backend",
      description: "The injected backend should receive the turn.",
      state: "Done",
      url: "https://example.org/issues/STUB-1",
      labels: []
    }

    assert :ok =
             AgentRunner.run(
               issue,
               nil,
               backend_module: SymphonyElixir.AgentRunnerStubBackend,
               worker_host: nil,
               issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
               test_pid: self()
             )

    assert_received :stub_turn_ran
  end

  test "blocked result posts a comment then sets the blocked state, in order" do
    issue = build_issue(state: "Implemented")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert :ok = run_blocked!(issue, blocked_action: "approve write")

    assert MemoryTracker.calls() == [
             {:create_comment, issue.id},
             {:update_issue_state, issue.id, "Blocked / Needs Attention"}
           ]

    assert_receive {:memory_tracker_comment, "issue-blocked", body}
    assert body =~ "**Symphony: blocked**"
    assert body =~ "session_id: blocked-session"
    assert body =~ "approve write"
  end

  test "when create_comment fails, the state is NOT updated and run returns ok" do
    issue = build_issue(state: "Implemented")
    MemoryTracker.fail(:create_comment)

    assert :ok = run_blocked!(issue, blocked_action: "approve write")
    assert MemoryTracker.calls() == [{:create_comment, issue.id}]
    refute Enum.any?(MemoryTracker.calls(), &match?({:update_issue_state, _, _}, &1))
  end

  test "when blocked state update fails, run returns ok after posting the comment" do
    issue = build_issue(state: "Implemented")
    MemoryTracker.fail(:update_issue_state)

    log =
      capture_log(fn ->
        assert :ok = run_blocked!(issue, blocked_action: "approve write")
      end)

    assert MemoryTracker.calls() == [
             {:create_comment, issue.id},
             {:update_issue_state, issue.id, "Blocked / Needs Attention"}
           ]

    assert log =~ "Blocked state update failed"
  end

  defp build_issue(overrides) do
    attrs =
      Keyword.merge(
        [
          id: "issue-blocked",
          identifier: "BLOCK-1",
          title: "Run a blocked backend",
          description: "The injected backend reports a blocked turn.",
          state: "Implemented",
          url: "https://example.org/issues/BLOCK-1",
          labels: []
        ],
        overrides
      )

    struct!(Issue, attrs)
  end

  defp run_blocked!(issue, result_opts) do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-blocked-#{System.unique_integer([:positive])}"
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Implemented"],
      workspace_root: workspace_root
    )

    result =
      result_opts
      |> Keyword.merge(status: :blocked, session_id: "blocked-session")
      |> Result.new()

    AgentRunner.run(
      issue,
      nil,
      backend_module: SymphonyElixir.AgentRunnerStubBackend,
      worker_host: nil,
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      test_result: result
    )
  end
end
