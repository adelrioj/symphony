defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Repo

  test "hook observer exceptions cannot prevent commands or replace their outcomes" do
    root = Path.join(System.tmp_dir!(), "hook-observer-#{System.unique_integer([:positive, :monotonic])}")
    on_exit(fn -> File.rm_rf!(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_create: "printf created > created",
      hook_before_run: "exit 7",
      hook_after_run: "printf cleaned > cleaned; exit 9"
    )

    issue = %Issue{id: "observer", identifier: "OBS-1"}
    context = ExecutionContext.local(root)

    capture_log(fn ->
      assert {:ok, workspace} = Workspace.create_for_issue(issue, context, fn _event -> raise "observer failure" end)
      assert File.read!(Path.join(workspace, "created")) == "created"

      assert {:error, {:workspace_hook_failed, "before_run", 7, _}} =
               Workspace.run_before_run_hook(workspace, issue, context, fn _event -> throw(:observer_failure) end)

      assert :ok = Workspace.run_after_run_hook(workspace, issue, context, fn _event -> exit(:observer_failure) end)
      assert File.read!(Path.join(workspace, "cleaned")) == "cleaned"
    end)
  end

  test "a persisted lane without an active version cannot supply agent or MCP prompts" do
    {:ok, profile} = SymphonyElixir.ExecutionProfiles.create(%{name: "Never configured", workspace_base: System.tmp_dir!(), worker: %{}})
    lane = Repo.insert!(%SymphonyElixir.Lanes.Lane{slug: "never-configured", name: "Never configured", execution_profile_id: profile.id})
    LaneContext.put(lane.id)
    assert :ok = LaneStore.refresh(lane.id)

    assert {:error, {:lane_invalid, _reason}} = Workflow.current()
    assert {:error, {:lane_invalid, _reason}} = Workflow.current_content()
    assert_raise RuntimeError, fn -> PromptBuilder.build_prompt(%Issue{id: "no-version", identifier: "NV-1"}) end
  end

  defmodule FailingManagedBackend do
    @behaviour SymphonyElixir.Agent
    alias SymphonyElixir.Agent.Claude

    @impl true
    def start_session(workspace, opts), do: Claude.start_session(workspace, opts)

    @impl true
    def run_turn(session, prompt, issue, opts) do
      {:ok, _result} = Claude.run_turn(session, prompt, issue, opts)

      case Keyword.fetch!(opts, :failure) do
        :raise -> raise ArgumentError, "ordinary backend failure"
        :exit -> exit(:ordinary_backend_exit)
        :unknown -> {:error, {:managed_execution_unknown, :fixture_transport}}
        :unknown_exit -> exit({:managed_execution_unknown, :fixture_transport})
      end
    end

    @impl true
    def stop_session(session), do: Claude.stop_session(session)
  end

  for failure <- [:raise, :exit] do
    test "managed after-run is best effort after a real session #{failure}" do
      {context, opts} = failing_managed_runner_fixture!()
      issue = %Issue{id: "failure", identifier: "FAIL-1"}
      run = fn -> AgentRunner.run(issue, nil, opts ++ [failure: unquote(failure)]) end

      case unquote(failure) do
        :raise -> assert_raise ArgumentError, "ordinary backend failure", run
        :exit -> assert catch_exit(run.()) == :ordinary_backend_exit
      end

      assert File.read!(Path.join(context.workspace_path, "turn-completed")) == "done"
      assert File.read!(Path.join(context.workspace_path, "after-run")) == "attempted"
    end
  end

  for failure <- [:unknown, :unknown_exit] do
    test "managed transport #{failure} forbids after-run following a real session" do
      {context, opts} = failing_managed_runner_fixture!()
      issue = %Issue{id: "unknown", identifier: "UNKNOWN-1"}

      assert catch_exit(AgentRunner.run(issue, nil, opts ++ [failure: unquote(failure)])) ==
               {:managed_execution_unknown, :fixture_transport}

      assert File.read!(Path.join(context.workspace_path, "turn-completed")) == "done"
      refute File.exists?(Path.join(context.workspace_path, "after-run"))
    end
  end

  defp failing_managed_runner_fixture! do
    root = Path.join(System.tmp_dir!(), "symphony-managed-runner-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    target = managed_shell_target!(root)
    command = Path.join(root, "claude")

    File.write!(command, """
    #!/bin/sh
    cat >/dev/null
    printf done > turn-completed
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"managed-failure"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
    """)

    File.chmod!(command, 0o700)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      tracker_kind: "memory",
      agent_backend: "claude",
      claude_command: command,
      claude_allowed_tools: nil,
      hook_after_run: "printf attempted > after-run; exit 9"
    )

    context = %ExecutionContext{
      mode: :managed,
      workspace_root: root,
      workspace_path: Path.join(root, "ticket"),
      target: target
    }

    {context, [backend_module: FailingManagedBackend, execution_context: context]}
  end

  test "managed workspaces retain their persisted path across issue renames" do
    root = Path.join(System.tmp_dir!(), "symphony-managed-path-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_after_create: "printf retained > retained")
    target = managed_shell_target!(root)

    context = %ExecutionContext{
      mode: :managed,
      workspace_root: root,
      workspace_path: Path.join(root, "persisted-key"),
      target: target,
      worker_host: "fixture"
    }

    assert {:ok, first} = Workspace.create_for_issue(%Issue{id: "stable", identifier: "OLD-1"}, context)
    File.write!(Path.join(first, "retained"), "local changes")
    assert {:ok, ^first} = Workspace.create_for_issue(%Issue{id: "stable", identifier: "NEW-1"}, context)
    assert File.read!(Path.join(first, "retained")) == "local changes"
    refute File.exists?(Path.join(root, "NEW-1"))
  end

  test "managed remote safety rejects root equality and symlink escape before hooks or deletion" do
    root = Path.join(System.tmp_dir!(), "symphony-managed-safety-#{System.unique_integer([:positive])}")
    outside = root <> "-outside"

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep"), "safe")
    File.ln_s!(outside, Path.join(root, "escape"))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_before_remove: "touch hook-ran")
    target = managed_shell_target!(root)

    for path <- [root, Path.join(root, "escape")] do
      context = %ExecutionContext{mode: :managed, workspace_root: root, workspace_path: path, target: target}
      assert {:error, _} = Workspace.create_for_issue("IGNORED", context)
      assert {:error, _, _} = Workspace.remove(path, context)
    end

    assert File.read!(Path.join(outside, "keep")) == "safe"
    refute File.exists?(Path.join(outside, "hook-ran"))
  end

  test "before-remove hook can run without deleting retained managed data" do
    root = Path.join(System.tmp_dir!(), "symphony-managed-retain-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "retained")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "keep"), "retained")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_before_remove: "touch hook-ran; exit 9")
    target = managed_shell_target!(root)
    context = %ExecutionContext{mode: :managed, workspace_root: root, workspace_path: workspace, target: target}
    assert :ok = Workspace.run_before_remove_hook(workspace, "RETAIN-1", context)
    assert File.exists?(Path.join(workspace, "hook-ran"))
    assert File.read!(Path.join(workspace, "keep")) == "retained"
  end

  test "managed before-run timeout reports unknown execution without running after-run" do
    {root, context, hook, release} = delayed_managed_hook_fixture!()
    hooks = [hook_before_run: hook, hook_after_run: "touch after-run", hook_timeout_ms: 2_000]
    write_workflow_file!(Workflow.workflow_file_path(), [workspace_root: root] ++ hooks)
    issue = %Issue{id: "managed-timeout", identifier: "TIMEOUT-1", state: "In Progress"}

    assert {:managed_execution_unknown, {:remote_command_timeout, "before_run", 2_000}} =
             catch_exit(AgentRunner.run(issue, nil, execution_context: context))

    assert File.exists?(Path.join(root, "started"))
    refute File.exists?(Path.join(context.workspace_path, "after-run"))
    release.()
    refute File.exists?(Path.join(context.workspace_path, "after-run"))
  end

  test "managed after-create timeout retains workspace while the remote hook is unconfirmed" do
    {root, context, hook, release} = delayed_managed_hook_fixture!()
    hooks = [hook_after_create: hook, hook_timeout_ms: 2_000]
    write_workflow_file!(Workflow.workflow_file_path(), [workspace_root: root] ++ hooks)

    assert {:error, {:managed_execution_unknown, {:remote_command_timeout, "after_create", 2_000}}} =
             Workspace.create_for_issue("TIMEOUT-2", context)

    assert File.exists?(Path.join(root, "started"))
    assert File.dir?(context.workspace_path)
    release.()
    assert File.read!(Path.join(context.workspace_path, "delayed")) == "finished"
  end

  test "managed before-remove timeout cannot authorize directory deletion" do
    {root, context, hook, release} = delayed_managed_hook_fixture!()
    File.mkdir_p!(context.workspace_path)
    File.write!(Path.join(context.workspace_path, "retained"), "keep")
    hooks = [hook_before_remove: hook, hook_timeout_ms: 2_000]
    write_workflow_file!(Workflow.workflow_file_path(), [workspace_root: root] ++ hooks)

    assert {:error, {:managed_execution_unknown, {:remote_command_timeout, "before_remove", 2_000}}, ""} =
             Workspace.remove(context.workspace_path, context)

    assert File.read!(Path.join(context.workspace_path, "retained")) == "keep"
    release.()
    assert File.read!(Path.join(context.workspace_path, "delayed")) == "finished"
  end

  defp delayed_managed_hook_fixture! do
    root = Path.join(System.tmp_dir!(), "symphony-managed-delayed-#{System.unique_integer([:positive])}")
    target = managed_shell_target!(root)
    workspace = Path.join(root, "workspace")
    pidfile = Path.join(root, "remote.pid")
    gate = Path.join(root, "release")
    started = Path.join(root, "started")
    assert {_, 0} = System.cmd("mkfifo", [gate])

    on_exit(fn ->
      # The blocked hook uses shell builtins only; its recorded shell has no child
      # work to orphan. Kill it before deleting the FIFO/workspace on a failed test.
      if File.exists?(pidfile) and not File.exists?(Path.join(workspace, "delayed")) do
        System.cmd("kill", ["-KILL", String.trim(File.read!(pidfile))], stderr_to_stdout: true)
      end

      File.rm_rf(root)
    end)

    hook = "trap '' HUP; printf '%s' \"$$\" > '#{pidfile}'; printf started > '#{started}'; IFS= read -r token < '#{gate}'; printf finished > delayed"
    context = %ExecutionContext{mode: :managed, workspace_root: root, workspace_path: workspace, target: target}

    release = fn ->
      assert {_, 0} = System.cmd("kill", ["-0", String.trim(File.read!(pidfile))], stderr_to_stdout: true)
      Task.async(fn -> File.write!(gate, "continue\n") end) |> Task.await(2_000)
      await_delayed_hook!(Path.join(workspace, "delayed"), 200)
    end

    {root, context, hook, release}
  end

  defp await_delayed_hook!(path, attempts) do
    cond do
      File.read(path) == {:ok, "finished"} ->
        :ok

      attempts == 0 ->
        flunk("remote hook did not finish after release")

      true ->
        Process.sleep(10)
        await_delayed_hook!(path, attempts - 1)
    end
  end

  defp managed_shell_target!(root) do
    realpath = System.find_executable("grealpath") || System.find_executable("realpath") || flunk("managed workspace fixtures require a real realpath executable supporting -m")
    bin = Path.join(root, "fixture-bin")
    File.mkdir_p!(bin)
    File.ln_s!(realpath, Path.join(bin, "realpath"))
    bash_env = Path.join(root, "fixture-bash-env")
    escaped_bin = "'" <> String.replace(bin, "'", "'\"'\"'") <> "'"
    File.write!(bash_env, "export PATH=#{escaped_bin}:\"$PATH\"\n")
    %SymphonyElixir.SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "fixture", env: [{"BASH_ENV", bash_env}]}
  end

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == Workspace.workspace_key("MT/Det")
    assert String.starts_with?(Path.basename(first_workspace), "MT_Det--")
  end

  test "relative local workspace roots resolve from data root rather than workflow or launcher directories" do
    data_root = Path.join(Config.data_root(), "installation")
    Application.put_env(:symphony_elixir, :data_root, data_root)
    launcher_dir = Path.join(System.tmp_dir!(), "symphony-elixir-launcher-#{System.unique_integer([:positive])}")
    original_cwd = File.cwd!()

    try do
      File.mkdir_p!(launcher_dir)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "relative-workspaces")
      File.cd!(launcher_dir)

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([data_root, "relative-workspaces", "MT-REL"]))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-REL", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))

      assert workspace == expected_workspace
      refute String.starts_with?(workspace, launcher_dir <> "/")
    after
      File.cd!(original_cwd)
      File.rm_rf(launcher_dir)
    end
  end

  test "workspace keys disambiguate identifiers that sanitize to the same path" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-collision-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      slash_issue = %Issue{id: "dispatch-slash", identifier: "team/a-1"}
      underscore_issue = %Issue{id: "dispatch-underscore", identifier: "team_a-1"}

      assert {:ok, slash_workspace} = Workspace.create_for_issue(slash_issue, SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert {:ok, ^slash_workspace} = Workspace.create_for_issue("team/a-1", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert {:ok, underscore_workspace} = Workspace.create_for_issue(underscore_issue, SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))

      refute slash_workspace == underscore_workspace
      assert Path.basename(underscore_workspace) == "team_a-1"
      assert String.starts_with?(Path.basename(slash_workspace), "team_a-1--")

      assert :ok = Workspace.remove_issue_workspaces("team/a-1", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      refute File.exists?(slash_workspace)
      assert File.exists?(underscore_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
    after
      File.rm_rf(test_root)
    end
  end

  test "recorded workspace removal rejects symlink escapes before hooks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-recorded-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      recorded_root = Path.join(test_root, "recorded-workspaces")
      current_root = Path.join(test_root, "current-workspaces")
      outside_root = Path.join(test_root, "outside")
      recorded_workspace = Path.join(recorded_root, "MT-SYM")
      hook_marker = Path.join(test_root, "before-remove-ran")

      File.mkdir_p!(recorded_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, recorded_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: current_root,
        hook_before_remove: "touch \"#{hook_marker}\""
      )

      assert {:ok, canonical_recorded_root} =
               SymphonyElixir.PathSafety.canonicalize(recorded_root)

      assert {:error, {:workspace_symlink_escape, ^recorded_workspace, ^canonical_recorded_root}, ""} =
               Workspace.remove_recorded(recorded_workspace, SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))

      refute File.exists?(hook_marker)
      assert File.exists?(outside_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root, SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace retries after_create after a failed new workspace bootstrap" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-retry-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    attempt_log = Path.join(test_root, "after-create-attempts")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        if [ -f "#{attempt_log}" ]; then count=$(wc -l < "#{attempt_log}"); else count=0; fi
        printf 'attempt\\n' >> "#{attempt_log}"
        if [ "$count" -eq 0 ]; then printf partial > partial.txt; exit 17; fi
        printf ready > READY
        """
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL-RETRY", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-FAIL-RETRY", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert File.read!(Path.join(workspace, "READY")) == "ready"
      assert String.split(String.trim(File.read!(attempt_log)), "\n") == ["attempt", "attempt"]
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil, SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
  end

  test "tracker issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      dispatchable: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.dispatchable
  end

  test "tracker issue routing requires every required label" do
    issue = %Issue{labels: [" Symphony ", "JavaScript"], dispatchable: true}

    assert Issue.routable?(issue, %{})
    assert Issue.routable?(issue, %{required_labels: []})
    assert Issue.routable?(issue, %{required_labels: ["symphony"]})
    assert Issue.routable?(issue, %{required_labels: ["SYMPHONY", "javascript"]})
    refute Issue.routable?(issue, %{required_labels: ["symph"]})
    refute Issue.routable?(issue, %{required_labels: [" "]})
    refute Issue.routable?(issue, %{required_labels: ["symphony", "security"]})
    refute Issue.routable?(%{issue | dispatchable: false}, %{required_labels: ["symphony"]})
  end

  test "tracker issue routing requires at least one any label when any are configured" do
    issue = %Issue{labels: ["Feat-Symphony"], dispatchable: true}

    assert Issue.routable?(issue, %{any_labels: []})
    assert Issue.routable?(issue, %{any_labels: ["feat-symphony", "bug-symphony"]})
    refute Issue.routable?(issue, %{any_labels: ["bug-symphony"]})
    refute Issue.routable?(issue, %{any_labels: ["   "]})
    refute Issue.routable?(%Issue{labels: [], dispatchable: true}, %{any_labels: ["feat-symphony"]})
  end

  test "tracker issue routing applies required and any label rules together" do
    issue = %Issue{labels: ["migrated", "feat-symphony"], dispatchable: true}

    assert Issue.routable?(issue, %{required_labels: ["migrated"], any_labels: ["feat-symphony", "bug-symphony"]})
    refute Issue.routable?(issue, %{required_labels: ["migrated"], any_labels: ["bug-symphony"]})
    refute Issue.routable?(issue, %{required_labels: ["ci"], any_labels: ["feat-symphony"]})
  end

  test "tracker issue routing treats missing label policy entries as no constraint" do
    issue = %Issue{labels: [], dispatchable: true}

    assert Issue.routable?(issue, %{required_labels: nil, any_labels: nil})
  end

  test "tracker issue routing raises for a label policy that is not a map" do
    issue = %Issue{labels: ["migrated"], dispatchable: true}

    assert_raise FunctionClauseError, fn -> Issue.routable?(issue, nil) end
    assert_raise FunctionClauseError, fn -> Issue.routable?(issue, ["migrated"]) end
  end

  test "tracker any_labels defaults to an empty list" do
    assert Config.settings!().tracker.any_labels == []
  end

  test "tracker any_labels is downcased and deduplicated" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_any_labels: ["Feat-Symphony", "feat-symphony", "BUG-Symphony"]
    )

    assert Config.settings!().tracker.any_labels == ["feat-symphony", "bug-symphony"]
  end

  test "tracker any_labels entries are trimmed" do
    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "linear", any_labels: ["  Feat-Symphony ", "feat-symphony"]}})

    assert settings.tracker.any_labels == ["feat-symphony"]
  end

  test "tracker provider settings keep their yaml types through the workflow file" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_provider: %{team_keys: ["MDZ"], current_cycle: true, project_slug: "acme-web"}
    )

    provider = Config.settings!().tracker.provider

    assert provider["team_keys"] == ["MDZ"]
    assert provider["current_cycle"] == true
    assert provider["project_slug"] == "acme-web"
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}, %{"name" => " backend "}, %{"name" => " "}]},
      "attachments" => %{
        "nodes" => [
          %{"title" => "MT-1-design.md", "url" => "  https://uploads.linear.app/abc  "},
          %{"title" => nil, "url" => "https://uploads.linear.app/def"},
          %{"title" => "blank", "url" => "  "},
          %{"title" => "no-url"}
        ]
      },
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]

    assert issue.attachments == [
             %{title: "MT-1-design.md", url: "https://uploads.linear.app/abc"},
             %{title: nil, url: "https://uploads.linear.app/def"}
           ]

    assert issue.native_ref == nil
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    refute issue.dispatchable
  end

  test "linear client rejects malformed issues instead of returning invalid scheduler records" do
    assert Client.normalize_issue_for_test(
             %{
               "id" => "issue-empty-title",
               "identifier" => "MT-EMPTY",
               "title" => " ",
               "state" => %{"name" => "Todo"}
             },
             nil
           ) == nil

    graphql_fun = fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-empty-title",
                 "identifier" => "MT-EMPTY",
                 "title" => " ",
                 "state" => %{"name" => "Todo"}
               }
             ]
           }
         }
       }}
    end

    assert {:error, :linear_unknown_payload} =
             Client.fetch_issues_by_ids_for_test(["issue-empty-title"], graphql_fun)
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.dispatchable
    assert issue.attachments == []
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.filter.id.in, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issues_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, first_page_variables}

    # Exact equality, not a subset pattern. Elixir map patterns are non-exact, so
    # `%{filter: %{id: %{in: ids}}}` also matches a filter carrying `and: [project…]`,
    # and asserting on document text proves nothing once the filter is a variable.
    assert first_page_variables.filter == %{id: %{in: first_batch_ids}}

    assert first_page_variables.first == 50
    assert first_page_variables.relationFirst == 50

    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ "$filter: IssueFilter!"

    assert_receive {:fetch_issue_states_page, ^query, second_page_variables}

    assert second_page_variables.filter == %{id: %{in: second_batch_ids}}

    assert second_page_variables.first == 5
    assert second_page_variables.relationFirst == 50
  end

  # The property is proven by the emitted filter, which both entry points build in
  # `do_fetch_issue_states_page/5`, so this setup is not what makes the assertion hold:
  # `fetch_issues_by_ids_for_test/2` reads no config today. It is a forward guard, so that the day
  # the by-IDs path does read the configured scope, a scope is already configured here for it to
  # wrongly apply.
  test "linear id refresh applies no scope filter even when scope is configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "acme-web",
      tracker_any_labels: ["feat-symphony"],
      tracker_provider: %{"team_keys" => ["MDZ"], "current_cycle" => true}
    )

    graphql_fun = fn _query, variables ->
      send(self(), {:by_ids, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_ids_for_test(["issue-1"], graphql_fun)

    assert_receive {:by_ids, variables}
    assert variables.filter == %{id: %{in: ["issue-1"]}}
  end

  test "linear poll sends the configured scope as one filter variable" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "acme-web")

    graphql_fun = fn query, variables ->
      send(self(), {:poll_page, query, variables})

      {:ok, %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_states_for_test(["Todo", "In Progress"], graphql_fun)

    assert_receive {:poll_page, query, variables}

    assert variables.filter == %{
             state: %{or: [%{name: %{eqIgnoreCase: "Todo"}}, %{name: %{eqIgnoreCase: "In Progress"}}]},
             and: [%{project: %{slugId: %{eq: "acme-web"}}}]
           }

    assert variables.first == 50
    assert variables.relationFirst == 50
    assert variables.attachmentFirst == 25

    assert query =~ "SymphonyLinearPoll"
    assert query =~ "$filter: IssueFilter!"
    refute query =~ "$projectSlug"
    refute query =~ "$stateNames"
  end

  test "linear poll resends the identical filter on the next page with the cursor advanced" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "acme-web")

    graphql_fun = fn query, variables ->
      send(self(), {:poll_page, query, variables})

      # Counts pages as well as matching the cursor: a regression that dropped the cursor would
      # re-enter the first-page clause forever and hang the test until ExUnit's timeout, so an
      # unexpected (page, cursor) pair has to fail loudly and name the value it saw.
      page_number = Process.get(:poll_page_number, 0) + 1
      Process.put(:poll_page_number, page_number)

      page_info =
        case {page_number, variables.after} do
          {1, nil} -> %{"hasNextPage" => true, "endCursor" => "cursor-1"}
          {2, "cursor-1"} -> %{"hasNextPage" => false, "endCursor" => nil}
          {number, cursor} -> raise "unexpected poll page #{number} with after cursor #{inspect(cursor)}"
        end

      {:ok, %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => page_info}}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_states_for_test(["Todo"], graphql_fun)

    assert_receive {:poll_page, _query, %{filter: first_filter, after: nil}}
    assert_receive {:poll_page, _query, %{filter: second_filter, after: "cursor-1"}}
    assert first_filter == second_filter
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear graphql honors a bound tracker-settings snapshot without loading live config" do
    parent = self()
    LaneContext.put(:unavailable)

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-bound"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               tracker_settings: %{
                 api_key: "bound-token",
                 endpoint: "https://bound.example.test/graphql"
               },
               request_fun: fn payload, headers ->
                 send(parent, {:bound_graphql_request, payload, headers})
                 {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-bound"}}}}}
               end
             )

    assert_receive {:bound_graphql_request, %{"query" => "query Viewer { viewer { id } }"}, [{"Authorization", "bound-token"}, {"Content-Type", "application/json"}]}
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "provider-marked blocked issue is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      dispatchable: false,
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      dispatchable: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue without every required label is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony", "javascript"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "unlabeled-1",
      identifier: "MT-1008",
      title: "Not opted in",
      state: "Todo",
      labels: ["symphony"],
      dispatchable: true
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["Symphony", "JavaScript"]}, state)
  end

  test "provider-marked ready issue remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}],
      dispatchable: true
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips an issue when provider routing changes" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      dispatchable: false,
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "dispatch revalidation skips an issue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    stale_issue = %Issue{
      id: "unlabeled-2",
      identifier: "MT-1009",
      title: "Initially opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refreshed_issue = %{stale_issue | labels: []}
    fetcher = fn ["unlabeled-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, ^refreshed_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path, SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT", SymphonyElixir.ExecutionContext.local(SymphonyElixir.Config.local_workspace_root()))
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.required_labels == []

    assert {:ok, default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert config.workspace.root == default_workspace_root
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: [" Symphony ", "SYMPHONY", "JavaScript"]
    )

    assert Config.settings!().tracker.required_labels == ["symphony", "javascript"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: [" "])
    assert Config.settings!().tracker.required_labels == [""]

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root = config.workspace.root

    explicit_workspace =
      Path.join(
        explicit_root,
        "MT-EXPLICIT-#{System.unique_integer([:positive])}"
      )

    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_workspace) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    for {overrides, path} <- [
          {[tracker_active_states: ","], "tracker.active_states"},
          {[max_concurrent_agents: "bad"], "agent.max_concurrent_agents"},
          {[worker_max_concurrent_agents_per_host: 0], "worker.max_concurrent_agents_per_host"},
          {[codex_turn_timeout_ms: "bad"], "codex.turn_timeout_ms"},
          {[codex_read_timeout_ms: "bad"], "codex.read_timeout_ms"},
          {[codex_stall_timeout_ms: "bad"], "codex.stall_timeout_ms"}
        ] do
      assert {:error, errors} = write_workflow_file!(Workflow.workflow_file_path(), overrides)
      assert Enum.any?(errors, &(&1.path == path))
      assert :ok = Config.validate!()
    end

    assert {:error, errors} =
             write_workflow_file!(Workflow.workflow_file_path(),
               tracker_active_states: %{todo: true},
               tracker_terminal_states: %{done: true},
               poll_interval_ms: %{bad: true},
               workspace_root: 123,
               max_retry_backoff_ms: 0,
               max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
               hook_timeout_ms: 0,
               observability_enabled: "maybe",
               observability_refresh_ms: %{bad: true},
               observability_render_interval_ms: %{bad: true}
             )

    assert Enum.any?(errors, &(&1.path == "tracker.active_states"))

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    assert {:error, errors} = write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert Enum.any?(errors, &(&1.path == "codex.turn_sandbox_policy"))

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.tracker.provider["api_key"] == "$#{api_key_env_var}"
    assert config.tracker.secret_environment_names == ["LINEAR_API_KEY", api_key_env_var]
    assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)
    assert config.workspace.root == canonical_workspace_root
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "schema preserves adapter-owned provider config while keeping linear aliases compatible" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{
                   endpoint: "https://linear.example.test/graphql",
                   api_key: "provider-token",
                   project_slug: "provider-project",
                   extra: %{team: "platform"}
                 }
               }
             })

    assert settings.tracker.endpoint == "https://linear.example.test/graphql"
    assert settings.tracker.api_key == "provider-token"
    assert settings.tracker.project_slug == "provider-project"
    assert settings.tracker.secret_environment_names == ["LINEAR_API_KEY"]

    assert settings.tracker.provider == %{
             "endpoint" => "https://linear.example.test/graphql",
             "api_key" => "provider-token",
             "project_slug" => "provider-project",
             "assignee" => nil,
             "extra" => %{"team" => "platform"}
           }
  end

  test "linear adapter rejects invalid provider values without crashing config parsing" do
    assert {:ok, invalid_secret_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: 123, project_slug: "project"}
               }
             })

    assert {:error, :missing_linear_api_token} =
             Config.validate_settings(invalid_secret_settings)

    assert {:ok, invalid_endpoint_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: "token", project_slug: "project", endpoint: 123}
               }
             })

    assert {:error, :invalid_linear_endpoint} =
             Config.validate_settings(invalid_endpoint_settings)

    assert {:ok, invalid_assignee_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: "token", project_slug: "project", assignee: 123}
               }
             })

    assert {:error, :invalid_linear_assignee} =
             Config.validate_settings(invalid_assignee_settings)
  end

  test "schema does not inject linear defaults before an adapter is selected" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "future-tracker"}})

    assert settings.tracker.endpoint == nil
    assert settings.tracker.api_key == nil
    assert settings.tracker.active_states == nil
    assert settings.tracker.terminal_states == nil
    assert settings.tracker.provider == %{}
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"

    assert {:ok, canonical_legacy_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(Config.data_root(), "env:#{workspace_env_var}"))

    assert config.workspace.root == canonical_legacy_root
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    tracker:
      kind: memory
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)
    assert :ok = reload_workflow!()

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{" In Progress " => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]

    whitespace_state_changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"   " => 1}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert whitespace_state_changeset.errors == [
             limits: {"state names must not be blank", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "linear", api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{granular: %{sandbox_approval: false, rules: false, mcp_elicitations: false}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "granular" => %{"sandbox_approval" => false, "rules" => false, "mcp_elicitations" => false}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "linear", api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"realpath -m"*)
          printf '%s\\t%s\\n' '/remote/home/.symphony-remote-workspaces' '/remote/home/.symphony-remote-workspaces'
          ;;
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == "/remote/home/.symphony-remote-workspaces"
      context = SymphonyElixir.ExecutionContext.ssh(workspace_root, "worker-01:2200")
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", context)
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", context)
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", context)
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", context)

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash --noprofile --norc -c"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#\\~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  test "path containment compares canonical path components" do
    root = Path.join(System.tmp_dir!(), "symphony-path-containment-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "nested"))
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, true} = SymphonyElixir.PathSafety.contained?(Path.join(root, "nested"), root)
    assert {:ok, false} = SymphonyElixir.PathSafety.contained?(root <> "-sibling", root)
  end
end
