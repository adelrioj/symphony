defmodule SymphonyElixir.AgentRunnerStubBackend do
  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Result

  @impl true
  def start_session(_workspace, opts) do
    if pid = opts[:test_pid], do: send(pid, {:stub_backend, :start_session, opts[:worker_host]})

    case opts[:start_result] do
      {:error, _reason} = error -> error
      _ -> {:ok, %{turns: 0, test_pid: opts[:test_pid]}}
    end
  end

  @impl true
  def run_turn(_session, prompt, _issue, opts) do
    if pid = opts[:test_pid], do: send(pid, :stub_turn_ran)

    if on_message = opts[:on_message] do
      message =
        Keyword.get(opts, :test_message, %{
          event: :usage_updated,
          timestamp: DateTime.utc_now(),
          session_id: "stub-1",
          usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
        })

      on_message.(message)
    end

    if pid = opts[:test_pid], do: send(pid, {:stub_backend, :prompt, prompt})

    case opts[:run_result] do
      {:error, _reason} = error ->
        error

      _ ->
        result =
          Keyword.get_lazy(opts, :test_result, fn ->
            Result.new(status: :done, session_id: "stub-1")
          end)

        {:ok, result}
    end
  end

  @impl true
  def stop_session(session) do
    if pid = session[:test_pid], do: send(pid, :stub_session_stopped)
    :ok
  end
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
               self(),
               backend_module: SymphonyElixir.AgentRunnerStubBackend,
               worker_host: nil,
               issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
               test_pid: self()
             )

    assert_received :stub_turn_ran
    assert_received :stub_session_stopped

    assert_received {:codex_worker_update, "issue-stub-backend",
                     %{
                       event: :usage_updated,
                       timestamp: %DateTime{},
                       session_id: "stub-1",
                       usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
                     }}
  end

  test "run/3 still forwards native worker update maps unchanged" do
    native_update = %{
      event: :usage_updated,
      timestamp: DateTime.utc_now(),
      session_id: "native-1",
      usage: %{input_tokens: 4, output_tokens: 5, total_tokens: 9}
    }

    issue = build_issue(state: "Done")

    assert :ok =
             run_stub!(issue,
               test_pid: self(),
               test_message: native_update
             )

    assert_received {:codex_worker_update, "issue-blocked", ^native_update}
  end

  test "run/3 reports start_session errors without calling stop_session" do
    issue = build_issue(state: "Done")

    assert_raise RuntimeError, ~r/:start_failed/, fn ->
      run_stub!(issue, start_result: {:error, :start_failed}, test_pid: self())
    end

    refute_received :stub_session_stopped
  end

  test "run/3 stops the backend session after run_turn errors" do
    issue = build_issue(state: "Done")

    assert_raise RuntimeError, ~r/:turn_failed/, fn ->
      run_stub!(issue, run_result: {:error, :turn_failed}, test_pid: self())
    end

    assert_received :stub_session_stopped
  end

  test "continuation stops when the issue moves to a different active state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Implemented", "In Review"]
    )

    issue = build_issue(state: "Implemented")
    refreshed_issue = %{issue | state: "In Review"}

    assert {:done, ^refreshed_issue} =
             AgentRunner.continue_with_issue_for_test(issue, fn [issue_id] ->
               assert issue_id == issue.id
               {:ok, [refreshed_issue]}
             end)
  end

  test "blocked result posts a comment then sets the blocked state, in order" do
    issue = build_issue(state: "Implemented")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert :ok = run_blocked!(issue, blocked_action: "approve write")

    assert MemoryTracker.calls() == [
             {:create_comment, issue.id},
             {:update_issue_state, issue.id, "Blocked / Needs Attention"}
           ]

    assert_received :stub_session_stopped
    assert_receive {:memory_tracker_comment, "issue-blocked", body}
    assert body =~ "**Symphony: blocked**"
    assert body =~ "session_id: blocked-session"
    assert body =~ "approve write"
  end

  test "blocked result uses configured blocked state" do
    issue = build_issue(state: "Implemented")

    assert :ok = run_blocked!(issue, [blocked_action: "approve write"], agent_blocked_state: "Needs Attention")

    assert MemoryTracker.calls() == [
             {:create_comment, issue.id},
             {:update_issue_state, issue.id, "Needs Attention"}
           ]
  end

  test "blocked comment falls back to summary and then no-detail text" do
    issue = build_issue(state: "Implemented")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert :ok = run_blocked!(issue, summary: "summary fallback")
    assert_receive {:memory_tracker_comment, "issue-blocked", summary_body}
    assert summary_body =~ "summary fallback"

    MemoryTracker.reset()

    assert :ok = run_blocked!(issue, [])
    assert_receive {:memory_tracker_comment, "issue-blocked", empty_body}
    assert empty_body =~ "No blocked action detail was provided."
  end

  test "blocked comment truncates long details" do
    issue = build_issue(state: "Implemented")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    detail = String.duplicate("a", 4_001)

    assert :ok = run_blocked!(issue, blocked_action: detail)

    assert_receive {:memory_tracker_comment, "issue-blocked", body}
    assert body =~ String.duplicate("a", 4_000)
    assert body =~ "... (truncated)"
    refute body =~ detail
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

  test "Claude continuation turns include the rendered issue prompt" do
    tmp = Path.join(System.tmp_dir!(), "symphony-elixir-agent-runner-claude-continuation-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(tmp, "workspaces")
    fake_claude = Path.join(tmp, "fake_claude")
    prompt_capture = Path.join(tmp, "prompts.txt")

    File.mkdir_p!(tmp)
    File.mkdir_p!(workspace_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat >> "#{prompt_capture}"
    printf '\\n---SYMPHONY-PROMPT---\\n' >> "#{prompt_capture}"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-cont"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"result":"done"}'
    """)

    File.chmod!(fake_claude, 0o700)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(tmp) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Implemented"],
      workspace_root: workspace_root,
      max_turns: 2,
      agent_backend: "claude",
      claude_command: fake_claude,
      claude_allowed_tools: nil,
      prompt: "Ticket {{ issue.identifier }}: {{ issue.description }}"
    )

    issue =
      build_issue(
        id: "issue-claude-continuation",
        identifier: "CLAUDE-2",
        description: "Preserve the original issue instructions",
        state: "Implemented"
      )

    parent = self()

    state_fetcher = fn [_issue_id] ->
      count = Process.get(:claude_continuation_fetch_count, 0) + 1
      Process.put(:claude_continuation_fetch_count, count)
      send(parent, {:issue_state_fetch, count})

      state = if count == 1, do: "Implemented", else: "Done"
      {:ok, [%{issue | state: state}]}
    end

    assert :ok =
             AgentRunner.run(issue, nil,
               backend_module: SymphonyElixir.Agent.Claude,
               worker_host: nil,
               issue_state_fetcher: state_fetcher
             )

    assert_receive {:issue_state_fetch, 1}
    assert_receive {:issue_state_fetch, 2}

    prompts =
      prompt_capture
      |> File.read!()
      |> String.split("\n---SYMPHONY-PROMPT---\n", trim: true)

    assert length(prompts) == 2
    assert Enum.at(prompts, 0) =~ "Ticket CLAUDE-2: Preserve the original issue instructions"
    assert Enum.at(prompts, 1) =~ "Ticket CLAUDE-2: Preserve the original issue instructions"
    assert Enum.at(prompts, 1) =~ "Continuation guidance:"
    assert Enum.at(prompts, 1) =~ "fresh process"
    refute Enum.at(prompts, 1) =~ "prior turn context"
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
          labels: [],
          dispatchable: true
        ],
        overrides
      )

    struct!(Issue, attrs)
  end

  defp run_stub!(issue, opts) do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-stub-#{System.unique_integer([:positive])}"
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    AgentRunner.run(
      issue,
      self(),
      opts ++
        [
          backend_module: SymphonyElixir.AgentRunnerStubBackend,
          worker_host: nil,
          issue_state_fetcher: fn _ids -> {:ok, [issue]} end
        ]
    )
  end

  defp run_blocked!(issue, result_opts, workflow_overrides \\ []) do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-blocked-#{System.unique_integer([:positive])}"
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(workspace_root) end)

    workflow_opts =
      [
        tracker_kind: "memory",
        tracker_active_states: ["Implemented"],
        workspace_root: workspace_root
      ]
      |> Keyword.merge(workflow_overrides)

    write_workflow_file!(Workflow.workflow_file_path(), workflow_opts)

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
      test_result: result,
      test_pid: self()
    )
  end
end
