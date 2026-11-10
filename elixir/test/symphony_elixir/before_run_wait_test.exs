defmodule SymphonyElixir.BeforeRunWaitStubBackend do
  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Result

  @impl true
  def start_session(_workspace, opts) do
    if pid = opts[:test_pid], do: send(pid, :wait_stub_session_started)
    {:ok, %{test_pid: opts[:test_pid]}}
  end

  @impl true
  def run_turn(_session, _prompt, _issue, opts) do
    if pid = opts[:test_pid], do: send(pid, :wait_stub_turn_ran)
    {:ok, Result.new(status: :done, session_id: "wait-stub")}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.BeforeRunWaitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionContext

  @wait 75

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-before-run-wait-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "hooks.before_run_wait_* configuration" do
    test "defaults keep the contract disabled" do
      {:ok, settings} = Schema.parse(%{})
      hooks = settings.hooks

      assert hooks.before_run_wait_exit_code == nil
      assert hooks.before_run_wait_poll_ms == 60_000
      assert hooks.before_run_wait_hold_ms == 0
      assert hooks.before_run_wait_retry_ms == 300_000
    end

    test "only an unambiguous exit status can mean wait" do
      for code <- [3, 75, 125] do
        assert {:ok, %{hooks: %{before_run_wait_exit_code: ^code}}} =
                 Schema.parse(%{"hooks" => %{"before_run_wait_exit_code" => code}})
      end

      for code <- [0, 1, 2, 64, 126, 127, 130, 255, -1] do
        assert {:error, _} = Schema.parse(%{"hooks" => %{"before_run_wait_exit_code" => code}})
      end
    end

    test "durations are validated" do
      assert {:error, _} = Schema.parse(%{"hooks" => %{"before_run_wait_poll_ms" => 0}})
      assert {:error, _} = Schema.parse(%{"hooks" => %{"before_run_wait_hold_ms" => -1}})
      assert {:error, _} = Schema.parse(%{"hooks" => %{"before_run_wait_retry_ms" => 0}})
      assert {:ok, _} = Schema.parse(%{"hooks" => %{"before_run_wait_hold_ms" => 0}})
    end
  end

  describe "AgentRunner before_run wait" do
    test "without the contract a wait status stays an ordinary hook failure", %{root: root} do
      write!(root, "exit #{@wait}", [])

      assert_raise RuntimeError, ~r/workspace_hook_failed/, fn -> run!(root, "unconfigured") end

      refute_received {:agent_run_deferred, _, _}
      refute_received :wait_stub_turn_ran
    end

    test "a zero hold defers at once without starting an agent", %{root: root} do
      write!(root, "printf x >> checks; exit #{@wait}", exit_code: @wait, hold_ms: 0)

      assert :ok = run!(root, "deferred")

      assert_received {:agent_run_deferred, "issue-wait", "deferred"}
      refute_received :wait_stub_session_started
      refute_received :wait_stub_turn_ran
      assert checks(root) == 1
      assert File.read!(workspace(root, "after")) == "after"
    end

    test "any other failure status is still a failure while the contract is enabled", %{root: root} do
      write!(root, "exit 7", exit_code: @wait, hold_ms: 1_000, poll_ms: 10)

      assert_raise RuntimeError, ~r/workspace_hook_failed/, fn -> run!(root, "other-status") end
      refute_received {:agent_run_deferred, _, _}
    end

    test "the hold re-runs before_run in the same attempt until it passes", %{root: root} do
      hook = "printf x >> checks; test \"$(wc -c < checks)\" -ge 3 || exit #{@wait}"
      write!(root, hook, exit_code: @wait, hold_ms: 60_000, poll_ms: 5)

      assert :ok = run!(root, "held")

      assert checks(root) == 3
      assert_received {:sleep, 5}
      assert_received {:sleep, 5}
      refute_received {:sleep, _}
      refute_received {:agent_run_deferred, _, _}
      assert_received :wait_stub_turn_ran
      # One attempt, one workspace creation and one after_create for every re-check.
      assert File.read!(workspace(root, "created")) == "x"
    end

    test "a spent hold ends the attempt deferred", %{root: root} do
      write!(root, "printf x >> checks; exit #{@wait}", exit_code: @wait, hold_ms: 200, poll_ms: 60)

      assert :ok = run!(root, "spent", sleep_fun: &Process.sleep/1)

      assert_received {:agent_run_deferred, "issue-wait", "spent"}
      refute_received :wait_stub_turn_ran
      assert checks(root) in 2..4
    end

    test "a tracker change during the hold ends the attempt without an agent or a deferral", %{root: root} do
      write!(root, "printf x >> checks; exit #{@wait}", exit_code: @wait, hold_ms: 60_000, poll_ms: 5)
      moved = %{issue() | state: "Done"}

      assert :ok = run!(root, "moved", issue_state_fetcher: fn _ -> {:ok, [moved]} end)

      assert checks(root) == 1
      refute_received {:agent_run_deferred, _, _}
      refute_received :wait_stub_turn_ran
    end

    test "an excluded label added during the hold ends the attempt without an agent or a deferral",
         %{root: root} do
      write!(root, "printf x >> checks; exit #{@wait}",
        exit_code: @wait,
        hold_ms: 60_000,
        poll_ms: 5,
        excluded: ["human"]
      )

      labelled = %{issue() | labels: ["human"]}

      assert :ok = run!(root, "excluded", issue_state_fetcher: fn _ -> {:ok, [labelled]} end)

      assert checks(root) == 1
      refute_received {:agent_run_deferred, _, _}
      refute_received :wait_stub_turn_ran
    end

    test "a failed tracker refresh during the hold defers instead of launching", %{root: root} do
      write!(root, "printf x >> checks; exit #{@wait}", exit_code: @wait, hold_ms: 60_000, poll_ms: 5)

      assert :ok = run!(root, "refresh-failed", issue_state_fetcher: fn _ -> {:error, :boom} end)

      assert_received {:agent_run_deferred, "issue-wait", "refresh-failed"}
      refute_received :wait_stub_turn_ran
      assert checks(root) == 1
    end

    test "every re-check reports a hook event so stall detection sees progress", %{root: root} do
      hook = "printf x >> checks; test \"$(wc -c < checks)\" -ge 2 || exit #{@wait}"
      write!(root, hook, exit_code: @wait, hold_ms: 60_000, poll_ms: 5)

      assert :ok = run!(root, "events")

      payloads = hook_payloads("events")
      assert Enum.any?(payloads, &(&1 =~ "before_run waiting (check 1)"))
      assert Enum.count(payloads, &(&1 =~ "before_run started")) == 2
    end

    test "a managed context re-checks over its one connection", %{root: root} do
      write!(root, "printf x >> checks; test \"$(wc -c < checks)\" -ge 2 || exit #{@wait}",
        exit_code: @wait,
        hold_ms: 60_000,
        poll_ms: 5
      )

      context = managed_context!(root)

      assert :ok = run!(root, "managed", execution_context: context)

      assert File.read!(Path.join(context.workspace_path, "checks")) == "xx"
      assert_received :wait_stub_turn_ran
      refute_received {:agent_run_deferred, _, _}
    end
  end

  describe "Orchestrator wait retry (unmanaged)" do
    test "a deferred run is retried on the wait cadence without advancing the failure attempt", %{root: root} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: root,
        max_concurrent_agents: 1,
        hook_before_run_wait: [exit_code: @wait, retry_ms: 600_000]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: "wait-run", identifier: "WAIT-2", title: "Wait", state: "Todo", dispatchable: true}
      ])

      parent = self()

      runner = fn issue, recipient, opts ->
        send(recipient, {:agent_run_deferred, issue.id, opts[:attempt_id]})
        send(parent, {:deferred_attempt, opts[:attempt_id]})
        :ok
      end

      {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, WaitRetry), runner_fun: runner)
      assert_receive {:deferred_attempt, attempt_id}, 5_000
      retry = wait_for_retry(pid, "wait-run")

      assert retry.attempt == 1
      assert retry.error =~ "before_run deferred"
      assert retry.due_at_ms - System.monotonic_time(:millisecond) > 500_000
      assert %SymphonyElixir.Runs.Run{status: "deferred"} = SymphonyElixir.Runs.get_by_attempt(attempt_id)
    end
  end

  defp wait_for_retry(pid, id, attempts \\ 200) do
    case :sys.get_state(pid).retry_attempts[id] do
      nil when attempts > 0 -> Process.sleep(10) && wait_for_retry(pid, id, attempts - 1)
      nil -> flunk("no retry was scheduled")
      retry -> retry
    end
  end

  defp write!(root, hook, wait) do
    {excluded, wait} = Keyword.pop(wait, :excluded, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_excluded_labels: excluded,
      workspace_root: root,
      hook_after_create: "printf x >> created",
      hook_before_run: hook,
      hook_after_run: "printf after > after",
      hook_before_run_wait: wait
    )
  end

  defp run!(root, attempt_id, opts \\ []) do
    test_pid = self()
    issue = issue()

    defaults = [
      attempt_id: attempt_id,
      test_pid: test_pid,
      backend_module: SymphonyElixir.BeforeRunWaitStubBackend,
      execution_context: ExecutionContext.local(root),
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      sleep_fun: fn ms -> send(test_pid, {:sleep, ms}) end
    ]

    AgentRunner.run(issue, self(), Keyword.merge(defaults, opts))
  end

  defp issue do
    %Issue{
      id: "issue-wait",
      identifier: "WAIT-1",
      title: "Wait for QA",
      description: "",
      state: "In Progress",
      url: "https://example.org/issues/WAIT-1",
      labels: [],
      dispatchable: true
    }
  end

  defp workspace(root, file), do: Path.join([root, "WAIT-1", file])

  defp checks(root), do: byte_size(File.read!(workspace(root, "checks")))

  defp hook_payloads(attempt_id) do
    Stream.repeatedly(fn ->
      receive do
        {:codex_worker_update, "issue-wait", ^attempt_id, %{event: :hook, payload: payload}} -> payload
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
  end

  defp managed_context!(root) do
    realpath =
      System.find_executable("grealpath") || System.find_executable("realpath") || flunk("realpath is required")

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.ln_s!(realpath, Path.join(bin, "realpath"))
    bash_env = Path.join(root, "bash-env")
    File.write!(bash_env, "export PATH='#{bin}':\"$PATH\"\n")

    target = %SymphonyElixir.SSH.Target{
      executable: "/bin/sh",
      prefix: ["-c"],
      label: "fixture",
      env: [{"BASH_ENV", bash_env}]
    }

    %ExecutionContext{
      mode: :managed,
      workspace_root: root,
      workspace_path: Path.join(root, "ticket"),
      target: target
    }
  end
end
