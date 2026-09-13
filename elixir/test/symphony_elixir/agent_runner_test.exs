defmodule SymphonyElixir.AgentRunnerStubBackend do
  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Result

  @impl true
  def start_session(_workspace, opts) do
    if pid = opts[:test_pid], do: send(pid, {:stub_backend, :start_session, opts[:execution_context].worker_host})

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

      {:raise, message} ->
        raise ArgumentError, message

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

  test "managed settings reject missing or local contexts before workspace and hooks" do
    root = Path.join(System.tmp_dir!(), "symphony-managed-guard-#{System.unique_integer([:positive])}")
    sentinel = Path.join(root, "hook-ran")
    on_exit(fn -> File.rm_rf(root) end)

    environment = %{
      "kind" => "google_workstations",
      "deployment_id" => "runner-guard",
      "startup_timeout_ms" => 10_000,
      "shutdown_timeout_ms" => 10_000,
      "provider" => %{
        "project" => "p",
        "location" => "l",
        "cluster" => "c",
        "config" => "cfg",
        "credential_configuration" => "deploy",
        "impersonate_service_account" => "sa@example.com",
        "ssh_user" => "user"
      }
    }

    options = [
      workspace_root: root,
      hook_after_create: "touch #{sentinel}",
      worker_environment: environment
    ]

    assert :ok = write_workflow_file!(Workflow.workflow_file_path(), options)

    assert {:error, :managed_context_required} = AgentRunner.run(build_issue([]), nil, [])

    assert {:error, :managed_context_required} =
             AgentRunner.run(build_issue([]), nil, execution_context: SymphonyElixir.ExecutionContext.local(root))

    for backend <- [SymphonyElixir.Agent.Codex, SymphonyElixir.Agent.Claude] do
      assert {:error, :managed_context_required} = backend.start_session(root, [])

      assert {:error, :managed_context_required} =
               backend.start_session(root, execution_context: SymphonyElixir.ExecutionContext.local(root))
    end

    refute File.exists?(sentinel)
    refute File.exists?(root)
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
               attempt_id: "runner-attempt",
               execution_context: SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()),
               issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
               test_pid: self()
             )

    assert_received :stub_turn_ran
    assert_received {:worker_runtime_info, "issue-stub-backend", "runner-attempt", %{workspace_path: workspace}}
    assert File.dir?(workspace)
    assert_received :stub_session_stopped

    assert_received {:codex_worker_update, "issue-stub-backend", "runner-attempt",
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

    assert_received {:codex_worker_update, "issue-blocked", _attempt_id, ^native_update}
  end

  test "configured attempt hooks report execution outcomes and skip after-create on workspace reuse" do
    issue = build_issue(state: "Done")
    root = hook_workspace_root!()

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      tracker_kind: "memory",
      hook_after_create: "printf created > created",
      hook_before_run: "test -f created; printf before >> before",
      hook_after_run: "printf after >> after; exit 9"
    )

    opts = [
      backend_module: SymphonyElixir.AgentRunnerStubBackend,
      execution_context: SymphonyElixir.ExecutionContext.local(root),
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      attempt_id: "hooks"
    ]

    assert :ok = AgentRunner.run(issue, self(), opts)
    assert_hook_update("hooks", "after_create", "started")
    assert_hook_update("hooks", "after_create", "finished")
    assert_hook_update("hooks", "before_run", "started")
    assert_hook_update("hooks", "before_run", "finished")
    assert_hook_update("hooks", "after_run", "started")
    assert_hook_update("hooks", "after_run", "failed")
    workspace = Path.join(root, issue.identifier)
    assert File.read!(Path.join(workspace, "after")) == "after"

    assert :ok = AgentRunner.run(issue, self(), Keyword.put(opts, :attempt_id, "reused"))
    assert_hook_update("reused", "before_run", "started")
    assert_hook_update("reused", "before_run", "finished")
    assert_hook_update("reused", "after_run", "started")
    assert_hook_update("reused", "after_run", "failed")
    refute_received {:codex_worker_update, _, "reused", %{event: :hook}}
    assert File.read!(Path.join(workspace, "after")) == "afterafter"
  end

  test "failed after-create reports failure before removing the partial workspace" do
    root = hook_workspace_root!()
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_after_create: "touch partial; exit 7")
    issue = build_issue([])

    assert_raise RuntimeError, ~r/workspace_hook_failed/, fn ->
      AgentRunner.run(issue, self(), attempt_id: "create-failed", execution_context: SymphonyElixir.ExecutionContext.local(root))
    end

    assert_hook_update("create-failed", "after_create", "started")
    assert_hook_update("create-failed", "after_create", "failed")
    refute File.exists?(Path.join(root, issue.identifier))
  end

  test "before-run timeout reports failure and still observes best-effort after-run" do
    assert_raise RuntimeError, ~r/workspace_hook_timeout/, fn ->
      run_stub!(build_issue([]),
        attempt_id: "timed-out",
        test_pid: self(),
        workflow: [hook_before_run: "sleep 1", hook_after_run: "exit 8", hook_timeout_ms: 20]
      )
    end

    assert_hook_update("timed-out", "before_run", "started")
    assert_hook_update("timed-out", "before_run", "failed")
    assert_hook_update("timed-out", "after_run", "started")
    assert_hook_update("timed-out", "after_run", "failed")
    refute_received :stub_turn_ran
  end

  test "blocked result emits its authoritative update before tracker parking and after-run failure" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    MemoryTracker.fail(:update_issue_state)
    result = Result.new(status: :blocked, session_id: "blocked-result", blocked_action: "Approve deployment")

    assert :ok =
             run_stub!(build_issue([]),
               attempt_id: "blocked-hooks",
               test_result: result,
               test_message: %{event: :completed, timestamp: DateTime.utc_now(), session_id: "blocked-result"},
               workflow: [hook_after_run: "exit 9"]
             )

    assert_received {:codex_worker_update, "issue-blocked", "blocked-hooks", %{event: :completed}}
    assert_receive {:worker_runtime_info, "issue-blocked", "blocked-hooks", _}
    assert_receive next
    assert {:codex_worker_update, "issue-blocked", "blocked-hooks", update} = next
    assert %{event: :attempt_blocked, session_id: "blocked-result", timestamp: %DateTime{}, payload: detail} = update
    assert detail =~ "Approve deployment"
    assert_receive {:memory_tracker_comment, "issue-blocked", _body}
    assert_hook_update("blocked-hooks", "after_run", "started")
    assert_hook_update("blocked-hooks", "after_run", "failed")
    refute_received {:agent_turns_exhausted, _, _, _}
  end

  test "managed exceptional cleanup reports after-run failure without replacing the backend exception" do
    root = hook_workspace_root!()
    context = managed_hook_context!(root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_after_run: "printf attempted > after; exit 9")

    assert_raise ArgumentError, "backend exploded", fn ->
      AgentRunner.run(build_issue([]), self(),
        attempt_id: "managed-failed",
        execution_context: context,
        backend_module: SymphonyElixir.AgentRunnerStubBackend,
        run_result: {:raise, "backend exploded"}
      )
    end

    assert_hook_update("managed-failed", "after_run", "started")
    assert_hook_update("managed-failed", "after_run", "failed")
    assert File.read!(Path.join(context.workspace_path, "after")) == "attempted"
  end

  test "managed timeout reports an unknown hook outcome without running cleanup" do
    root = hook_workspace_root!()
    context = managed_hook_context!(root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_before_run: "sleep 2",
      hook_after_run: "touch after",
      hook_timeout_ms: 500
    )

    assert {:managed_execution_unknown, {:remote_command_timeout, "before_run", 500}} =
             catch_exit(AgentRunner.run(build_issue([]), self(), execution_context: context, attempt_id: "managed-timeout"))

    assert_hook_update("managed-timeout", "before_run", "started")
    assert_hook_update("managed-timeout", "before_run", "failed")
    refute_received {:codex_worker_update, _, "managed-timeout", %{event: :hook}}
    assert File.dir?(context.workspace_path)
    refute File.exists?(Path.join(context.workspace_path, "after"))
  end

  test "a hook command task exception is reported before its linked runner exits" do
    root = hook_workspace_root!()

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_create: "rmdir \"$PWD\"",
      hook_before_run: "true"
    )

    {:ok, snapshot} = SymphonyElixir.LaneContext.capture()
    recipient = self()

    {pid, ref} =
      spawn_monitor(fn ->
        SymphonyElixir.LaneContext.install(snapshot)

        AgentRunner.run(build_issue([]), recipient,
          execution_context: SymphonyElixir.ExecutionContext.local(root),
          attempt_id: "hook-exception"
        )
      end)

    assert_hook_update("hook-exception", "after_create", "started")
    assert_hook_update("hook-exception", "after_create", "finished")
    assert_hook_update("hook-exception", "before_run", "started")
    assert_hook_update("hook-exception", "before_run", "failed")
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    refute reason == :normal
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

  test "exhausting the turn budget on a still-active issue notifies the orchestrator" do
    issue = build_issue(state: "In Progress")

    assert :ok = run_stub!(issue, max_turns: 1, attempt_id: "exhausted-attempt")

    assert_received {:agent_turns_exhausted, "issue-blocked", "exhausted-attempt", "In Progress"}
  end

  test "an issue that leaves its active state does not notify the orchestrator" do
    issue = build_issue(state: "Done")

    assert :ok = run_stub!(issue, max_turns: 1)

    refute_received {:agent_turns_exhausted, _issue_id, _attempt_id, _state}
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
               execution_context: SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()),
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

  defp hook_workspace_root! do
    root = Path.join(System.tmp_dir!(), "symphony-runner-hooks-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp managed_hook_context!(root) do
    realpath = System.find_executable("grealpath") || System.find_executable("realpath") || flunk("realpath is required")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.ln_s!(realpath, Path.join(bin, "realpath"))
    bash_env = Path.join(root, "bash-env")
    File.write!(bash_env, "export PATH='#{bin}':\"$PATH\"\n")
    target = %SymphonyElixir.SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "fixture", env: [{"BASH_ENV", bash_env}]}
    %SymphonyElixir.ExecutionContext{mode: :managed, workspace_root: root, workspace_path: Path.join(root, "ticket"), target: target}
  end

  defp assert_hook_update(attempt_id, hook_name, outcome) do
    assert_receive {:codex_worker_update, "issue-blocked", ^attempt_id, %{event: :hook} = update}, 1_000
    assert %{timestamp: %DateTime{}, payload: payload} = update
    assert payload =~ hook_name
    assert payload =~ outcome
  end

  defp run_stub!(issue, opts) do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-stub-#{System.unique_integer([:positive])}"
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(workspace_root) end)

    {workflow, opts} = Keyword.pop(opts, :workflow, [])

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([tracker_kind: "memory", workspace_root: workspace_root], workflow)
    )

    AgentRunner.run(
      issue,
      self(),
      opts ++
        [
          backend_module: SymphonyElixir.AgentRunnerStubBackend,
          execution_context: SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()),
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
      execution_context: SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()),
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      test_result: result,
      test_pid: self()
    )
  end
end
