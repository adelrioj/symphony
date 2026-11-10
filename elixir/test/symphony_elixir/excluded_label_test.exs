defmodule SymphonyElixir.ExcludedLabelTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.Linear.Scope
  alias SymphonyElixir.WorkspaceDiscard

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-excluded-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    :ok =
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: root,
        tracker_required_labels: ["groomed"],
        tracker_excluded_labels: ["Human"]
      )

    {:ok, root: root}
  end

  describe "label policy" do
    test "an excluded label makes an issue unroutable, case-insensitively, whatever else it carries" do
      policy = %{required_labels: ["groomed"], excluded_labels: ["human", " "]}
      issue = %Issue{dispatchable: true, labels: ["groomed"]}

      assert Issue.routable?(issue, policy)
      refute Issue.routable?(%{issue | labels: ["groomed", "HUMAN"]}, policy)
      assert Issue.excluded_label(%{issue | labels: ["groomed", " Human "]}, policy) == "human"
      assert Issue.excluded_label(issue, policy) == nil
      assert Issue.excluded_label(%{issue | labels: ["groomed", ""]}, policy) == nil
      # Exclusion is an observation of labels, not of dispatchability.
      assert Issue.excluded_label(%{issue | dispatchable: false, labels: ["human"]}, policy) == "human"
      assert Issue.excluded_label(issue, %{}) == nil
    end

    test "excluded labels default to empty, are normalized, and may not overlap admitting labels" do
      assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
      assert settings.tracker.excluded_labels == []

      assert {:ok, settings} =
               Schema.parse(%{tracker: %{kind: "memory", excluded_labels: [" Human ", "human", "Hold"]}})

      assert settings.tracker.excluded_labels == ["human", "hold"]

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{tracker: %{kind: "memory", required_labels: ["Human"], excluded_labels: ["human"]}})

      assert message =~ "excluded_labels"
      assert message =~ "human"

      assert {:error, {:invalid_workflow_config, _}} =
               Schema.parse(%{tracker: %{kind: "memory", any_labels: ["hold"], excluded_labels: ["HOLD"]}})

      assert Config.settings!().tracker.excluded_labels == ["human"]
    end

    test "the Linear scope summary names excluded labels" do
      summary =
        Scope.scope_summary(%{
          provider: %{"team_keys" => ["TRA"]},
          excluded_labels: ["human"]
        })

      assert summary =~ "excluded labels human"
    end
  end

  describe "dispatch" do
    test "an excluded issue is never dispatched and becomes eligible again when the label is removed" do
      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new(), blocked: %{}}
      issue = issue(["groomed", "human"])

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
      assert Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["groomed"]}, state)
    end

    test "a retry refresh that finds the label skips dispatch" do
      fetcher = fn ["excluded-1"] -> {:ok, [issue(["groomed", "human"])]} end
      assert {:skip, %Issue{}} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue(["groomed"]), fetcher)
    end

    test "the agent runner does not start another turn once the label is added" do
      refreshed = issue(["groomed", "human"])
      fetcher = fn ["excluded-1"] -> {:ok, [refreshed]} end
      assert {:done, ^refreshed} = AgentRunner.continue_with_issue_for_test(issue(["groomed"]), fetcher)
    end
  end

  describe "removal from the lane" do
    test "a running issue that gets the label is stopped, released and its workspace discarded with a record",
         %{root: root} do
      workspace = git_workspace!(root, "TRA-1")
      pushed = pushed_sha(workspace)
      agent = spawn(fn -> receive(do: (:stop -> :ok)) end)
      issue = issue(["groomed", "human"])

      state = %Orchestrator.State{
        running: %{"excluded-1" => running_entry(agent, workspace, root)},
        claimed: MapSet.new(["excluded-1"]),
        retry_attempts: %{"excluded-1" => %{attempt: 2}},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      log =
        capture_log(fn ->
          updated = Orchestrator.reconcile_issue_states_for_test([issue], state)
          refute Map.has_key?(updated.running, "excluded-1")
          refute MapSet.member?(updated.claimed, "excluded-1")
          refute Map.has_key?(updated.retry_attempts, "excluded-1")
        end)

      refute Process.alive?(agent)
      refute File.exists?(workspace)
      assert log =~ "label=human"
      assert log =~ "branch=feature/excluded"
      assert log =~ "unpushed=1"

      assert_receive {:memory_tracker_comment, "excluded-1", body}
      assert body =~ "`human` label"
      assert body =~ "Branch: feature/excluded"
      assert body =~ "Last pushed commit: #{pushed} (origin/feature/excluded)"
      assert body =~ "Unpushed commits: 1"
      assert body =~ "Uncommitted paths: 1"
      refute_received {:memory_tracker_state_update, _, _}
    end

    test "a queued retry that finds the label is cancelled and its workspace discarded", %{root: root} do
      workspace = git_workspace!(root, "TRA-1")
      state = %Orchestrator.State{claimed: MapSet.new(["excluded-1"]), retry_attempts: %{}}

      updated =
        Orchestrator.handle_retry_issue_lookup_for_test(issue(["groomed", "human"]), state, "excluded-1", 3, %{
          identifier: "TRA-1",
          workspace_path: workspace,
          execution_context: ExecutionContext.local(root),
          error: "before_run hook failed"
        })

      refute MapSet.member?(updated.claimed, "excluded-1")
      refute Map.has_key?(updated.retry_attempts, "excluded-1")
      refute Map.has_key?(updated.running, "excluded-1")
      refute File.exists?(workspace)
      assert_receive {:memory_tracker_comment, "excluded-1", body}
      assert body =~ "Branch: feature/excluded"
    end

    test "a blocked issue that gets the label is released and its workspace discarded", %{root: root} do
      workspace = git_workspace!(root, "TRA-1")

      state = %Orchestrator.State{
        blocked: %{
          "excluded-1" => %{
            identifier: "TRA-1",
            error: "turn budget",
            workspace_path: workspace,
            execution_context: ExecutionContext.local(root)
          }
        },
        claimed: MapSet.new(["excluded-1"]),
        retry_attempts: %{}
      }

      updated = Orchestrator.reconcile_blocked_issue_states_for_test([issue(["groomed", "human"])], state)

      refute Map.has_key?(updated.blocked, "excluded-1")
      refute MapSet.member?(updated.claimed, "excluded-1")
      refute File.exists?(workspace)
      assert_receive {:memory_tracker_comment, "excluded-1", _body}
    end

    test "a merely unroutable issue keeps its workspace, unlike an excluded one", %{root: root} do
      workspace = git_workspace!(root, "TRA-1")
      agent = spawn(fn -> receive(do: (:stop -> :ok)) end)

      state = %Orchestrator.State{
        running: %{"excluded-1" => running_entry(agent, workspace, root)},
        claimed: MapSet.new(["excluded-1"]),
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      updated = Orchestrator.reconcile_issue_states_for_test([issue([])], state)

      refute Map.has_key?(updated.running, "excluded-1")
      assert File.exists?(workspace)
      refute_received {:memory_tracker_comment, _, _}
    end

    test "a failed comment or unreadable workspace never holds the exclusion back", %{root: root} do
      workspace = Path.join(root, "TRA-1")
      File.mkdir_p!(workspace)
      Tracker.Memory.fail(:create_comment)
      state = %Orchestrator.State{claimed: MapSet.new(["excluded-1"]), retry_attempts: %{}}

      log =
        capture_log(fn ->
          updated =
            Orchestrator.handle_retry_issue_lookup_for_test(issue(["groomed", "human"]), state, "excluded-1", 1, %{
              identifier: "TRA-1",
              workspace_path: workspace,
              execution_context: ExecutionContext.local(root)
            })

          refute MapSet.member?(updated.claimed, "excluded-1")
        end)

      refute File.exists?(workspace)
      assert log =~ "workspace_state=unreadable"
      assert log =~ "Could not comment on discarded workspace"
    end
  end

  describe "workspace discard report" do
    test "reads branch, upstream, pushed commit and pending work without running workspace code", %{root: root} do
      workspace = git_workspace!(root, "TRA-2")
      marker = Path.join(root, "fsmonitor-ran")
      git!(workspace, ["config", "core.fsmonitor", "touch #{marker}; false"])

      assert {:ok, report} = Workspace.discard_report(workspace, ExecutionContext.local(root))
      assert report.branch == "feature/excluded"
      assert report.upstream == "origin/feature/excluded"
      assert report.pushed == pushed_sha(workspace)
      assert report.head == String.trim(git!(workspace, ["rev-parse", "HEAD"]))
      assert report.unpushed == 1
      assert report.dirty == 1
      refute File.exists?(marker)
    end

    test "reports no pushed commit for a branch that was never pushed", %{root: root} do
      workspace = Path.join(root, "TRA-3")
      File.mkdir_p!(workspace)
      git!(workspace, ["init", "-q", "-b", "local-only"])
      commit!(workspace, "one")

      assert {:ok, report} = Workspace.discard_report(workspace, ExecutionContext.local(root))
      assert report.branch == "local-only"
      assert report.upstream == nil and report.pushed == nil and report.unpushed == nil
      assert WorkspaceDiscard.body("human", {:ok, report}) =~ "Last pushed commit: none known"
    end

    test "never describes an enclosing repository when the workspace is not a checkout", %{root: root} do
      git!(root, ["init", "-q"])
      workspace = Path.join(root, "TRA-4")
      File.mkdir_p!(workspace)
      assert {:error, {:discard_report_failed, 3}} = Workspace.discard_report(workspace, ExecutionContext.local(root))
    end

    test "refuses a path outside the workspace root and a missing workspace", %{root: root} do
      assert {:error, _} = Workspace.discard_report("/etc", ExecutionContext.local(root))
      assert {:error, _} = Workspace.discard_report(Path.join(root, "absent"), ExecutionContext.local(root))
      assert {:error, _} = Workspace.discard_report_for_issue("TRA-404", ExecutionContext.local(root))
      assert WorkspaceDiscard.body("human", {:error, :x}) =~ "could not be read"
    end
  end

  defp issue(labels) do
    %Issue{
      id: "excluded-1",
      identifier: "TRA-1",
      title: "Excluded ticket",
      state: "In Progress",
      dispatchable: true,
      labels: labels
    }
  end

  defp running_entry(agent, workspace, root) do
    %{
      pid: agent,
      ref: nil,
      attempt_id: "excluded-attempt",
      identifier: "TRA-1",
      issue: issue(["groomed"]),
      workspace_path: workspace,
      execution_context: ExecutionContext.local(root),
      started_at: DateTime.utc_now()
    }
  end

  # A clone whose branch is pushed once, then carries one unpushed commit and one untracked file.
  defp git_workspace!(root, name) do
    origin = Path.join(root, name <> "-origin.git")
    workspace = Path.join(root, name)
    git!(root, ["init", "-q", "--bare", origin])
    git!(root, ["clone", "-q", origin, workspace])
    git!(workspace, ["checkout", "-q", "-b", "feature/excluded"])
    commit!(workspace, "pushed")
    git!(workspace, ["push", "-q", "-u", "origin", "feature/excluded"])
    commit!(workspace, "unpushed")
    File.write!(Path.join(workspace, "scratch.txt"), "draft")
    workspace
  end

  defp commit!(workspace, message) do
    File.write!(Path.join(workspace, message <> ".txt"), message)
    git!(workspace, ["add", message <> ".txt"])
    git!(workspace, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message])
  end

  defp pushed_sha(workspace), do: String.trim(git!(workspace, ["rev-parse", "refs/remotes/origin/feature/excluded"]))

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
