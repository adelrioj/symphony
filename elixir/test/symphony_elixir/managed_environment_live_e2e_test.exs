Code.require_file("../support/managed_environment_fixture/provider.exs", __DIR__)
Code.require_file("../support/managed_environment_fixture/control.exs", __DIR__)

defmodule SymphonyElixir.ManagedEnvironmentLiveE2ETest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.AgentRuntimeSupervisor
  alias SymphonyElixir.Config
  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.Command
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.ExecutionEnvironment.Lifecycle
  alias SymphonyElixir.ExecutionEnvironment.Operations
  alias SymphonyElixir.ManagedEnvironmentFixture.{Control, Provider}
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.SSH
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore

  @moduletag :live_e2e
  @moduletag timeout: 1_800_000
  @moduletag skip: System.get_env("SYMPHONY_RUN_MANAGED_E2E") != "1"
  @fixture_root Path.expand("../support/managed_environment_fixture", __DIR__)
  @runtime __MODULE__.Runtime
  @orchestrator __MODULE__.Orchestrator
  @worker_tasks __MODULE__.WorkerTasks
  @checks ~w(prerequisites codex_workloads five_slots_and_queue isolation denied_stop review_and_resume claude_workloads zero_retention retained_restart_and_reopen tunnel_loss attempt_fencing delayed_storage_deletion deletion_restart lost_create lost_start unrelated_resources final_absence)
  @fixture_files ["compose.yaml", "testcontainers_probe.py", "browser_probe.mjs"]

  defmodule Failure do
    defexception [:code]
    @impl true
    def message(error), do: error.code
  end

  setup do
    # Only the opt-in switch is read during module loading. No live files or credentials.
    output = required_absolute_env!("SYMPHONY_MANAGED_E2E_OUTPUT")
    require!(temporary_output?(output), "output_requires_new_file_in_empty_private_temporary_directory")
    run_id = "managed-e2e-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    run_root = Path.join(Path.dirname(output), run_id)
    File.mkdir!(run_root)
    File.chmod!(run_root, 0o700)
    original_path = Workflow.workflow_file_path()
    original_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    original_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      restore_application(:memory_tracker_issues, original_issues)
      restore_application(:memory_tracker_recipient, original_recipient)
      Workflow.set_workflow_file_path(original_path)
    end)

    result =
      try do
        input = required_absolute_env!("SYMPHONY_MANAGED_E2E_WORKFLOW")

        document =
          case Workflow.load(input) do
            {:ok, document} -> document
            _ -> require!(false, "authorized_workflow_unreadable_or_invalid")
          end

        workflow_path = Path.join(run_root, "WORKFLOW")
        # Install probes only after prerequisite validation, so absent profile values cannot crash setup.
        raw = qualification_workflow(document.config, run_id)
        write_private!(workflow_path, workflow_document(raw))
        Workflow.set_workflow_file_path(workflow_path)
        require!(match?({:ok, _}, Config.settings()), "qualification_workflow_invalid")
        config = EnvironmentConfig.runtime(Config.settings!())
        require!(is_map(config) and config.kind in ["google_workstations", "kubernetes"], "managed_provider_required")
        {:ok, adapter} = ExecutionEnvironment.adapter(config.kind)
        profile = Map.get(config.provider, "qualification", %{})
        require!(is_map(profile), "qualification_profile_required")
        check_names = if config.kind == "kubernetes", do: @checks ++ ["delayed_gate_release", "node_disconnection"], else: @checks
        control_opts = [checks: check_names, session_limit: profile["max_backend_sessions"], config: config]
        {:ok, control} = Control.start_link(control_opts)
        {:ok, tasks} = Task.Supervisor.start_link()
        Application.put_env(:symphony_elixir, :memory_tracker_recipient, control)
        GenServer.call(control, {:issues, []})

        issues =
          Enum.map(1..6, fn index ->
            %Issue{
              id: "#{run_id}-#{index}",
              identifier: "QUAL-#{index}",
              title: "Disposable managed qualification #{index}",
              description:
                "Run bash .symphony-qualification/run-probes.sh #{index}. Do not alter the fixtures, skip probes, weaken permissions, push git changes, or mutate an external tracker. Keep the foreground controlled workload alive and wait for its release file; do not finish the turn early.",
              state: "Qualification Codex",
              priority: index,
              dispatchable: true
            }
          end)

        ctx = %{
          config: config,
          adapter: adapter,
          profile: profile,
          control: control,
          tasks: tasks,
          issues: issues,
          raw: raw,
          workflow_path: workflow_path,
          run_root: run_root,
          output: output,
          run_id: run_id,
          check_names: check_names,
          fixture_images: fixture_images(),
          deadline: now() + 1_500_000
        }

        write_evidence(ctx, [], false)
        on_exit(fn -> recover_interrupted_cleanup(ctx) end)
        {:ok, ctx: ctx}
      rescue
        error in Failure -> {:setup_failed, error.code}
        _ -> {:setup_failed, "qualification_setup_failed"}
      catch
        _, _ -> {:setup_failed, "qualification_setup_interrupted"}
      end

    case result do
      {:setup_failed, code} ->
        bootstrap_blocked(output, run_id, code)
        File.rm_rf!(run_root)
        require!(false, code)

      ready ->
        ready
    end
  end

  test "real provider lifecycle, both backends, isolated Docker and durable ticket data", %{ctx: ctx} do
    begin_check("prerequisites")

    try do
      pass(ctx, "prerequisites", prerequisites!(ctx))
      baseline = unrelated_resources!(ctx)
      GenServer.call(ctx.control, {:baseline, baseline})
      install_workloads!(ctx)
      # Durable intent precedes runtime startup and publication of the first schedulable issue.
      begin_check("codex_workloads")
      GenServer.call(ctx.control, :allocation_started)
      write_evidence(ctx, [], false)
      start_runtime(ctx)
      GenServer.call(ctx.control, {:issues, ctx.issues})
      refresh()
      first_five = Enum.take(ctx.issues, 5)
      await(ctx, "five_backends_active", fn -> Enum.all?(first_five, &workload_ready?(ctx, &1)) end, ctx.config.startup_timeout_ms * 3)
      facts = Enum.map(first_five, &verify_workload!(ctx, &1))
      pass(ctx, "codex_workloads", %{issues: Enum.map(first_five, & &1.id), observations: facts})
      begin_check("five_slots_and_queue")
      state = scheduler_state()
      sixth_not_started = not Map.has_key?(state.environment_entries, issue(ctx, 6).id)
      five_occupied = map_size(state.running) == 5 and occupied_count(state) == 5
      require!(five_occupied and sixth_not_started, "sixth_worker_started_without_capacity")
      require!(length(Enum.uniq(Enum.map(facts, & &1.engine_id))) == 5, "docker_daemon_identity_shared")
      assert_no_duplicate_resources!(ctx)
      pass(ctx, "five_slots_and_queue", %{environment_ids: Enum.map(first_five, &entry!(&1.id).record.key), queued_issue: issue(ctx, 6).id})
      begin_check("isolation")
      isolation!(ctx, first_five)
      pass(ctx, "isolation", %{issues: Enum.map(first_five, & &1.id)})

      begin_check("denied_stop")
      first = issue(ctx, 1)
      review_nonce = "review-" <> ctx.run_id
      first_entry = entry!(first.id)

      remote!(
        ctx,
        first_entry,
        "printf '%s\\n' #{shell_quote(review_nonce)} >> qualification-sentinel.txt; " <>
          sql_command(ctx, 1, "INSERT INTO qualification(value) VALUES ('#{review_nonce}') ON CONFLICT DO NOTHING") <>
          "; rm .symphony-qualification/ready .symphony-qualification/testcontainers.out .symphony-qualification/browser.out"
      )

      arm(ctx, {:deny_stop, first.id})
      transition(ctx, first, "In Review")
      await(ctx, "actual_stop_denied", fn -> event?(ctx, :stop_denied, first.id) and unknown_occupied?(first.id) end)
      require!(not Map.has_key?(scheduler_state().environment_entries, issue(ctx, 6).id), "denied_stop_released_capacity")
      pass(ctx, "denied_stop", %{environment_id: first_entry.record.key})
      begin_check("review_and_resume")
      disarm(ctx, {:deny_stop, first.id})
      refresh()
      await(ctx, "review_compute_stopped", fn -> stopped?(first.id) end)
      await(ctx, "queued_sixth_started", fn -> workload_ready?(ctx, issue(ctx, 6)) end, ctx.config.startup_timeout_ms * 2)
      verify_workload!(ctx, issue(ctx, 6))
      review_before = review_response!(ctx)
      for other <- Enum.drop(ctx.issues, 1), do: transition(ctx, other, "In Review")
      await(ctx, "all_review_workers_physically_stopped", fn -> Enum.all?(ctx.issues, &stopped?(&1.id)) end)
      require!(review_response!(ctx) == review_before, "review_app_depends_on_worker_compute")
      transition(ctx, first, "Qualification Claude")
      await(ctx, "claude_resumed_workload", fn -> workload_ready?(ctx, first) end, ctx.config.startup_timeout_ms * 2)
      resumed = entry!(first.id)
      require!(resumed.record.provider_ref == first_entry.record.provider_ref and resumed.record.workspace_path == first_entry.record.workspace_path, "resume_replaced_environment_or_checkout")
      require!(remote!(ctx, resumed, "cat qualification-sentinel.txt") =~ review_nonce, "uncommitted_checkout_lost")
      require!(String.trim(remote!(ctx, resumed, sql_command(ctx, 1, "SELECT value FROM qualification WHERE value='#{review_nonce}'"))) == review_nonce, "named_volume_row_lost")
      require!(review_response!(ctx) == review_before, "independent_review_app_changed_with_worker")
      pass(ctx, "review_and_resume", %{environment_id: resumed.record.key, all_workers_stopped: true, review_response_sha256: review_before})
      begin_check("claude_workloads")
      pass(ctx, "claude_workloads", verify_workload!(ctx, first))

      begin_check("zero_retention")
      transition(ctx, issue(ctx, 6), "Done")
      await_absence(ctx, issue(ctx, 6))
      pass(ctx, "zero_retention", %{issue_id: issue(ctx, 6).id})
      begin_check("retained_restart_and_reopen")
      set_retention(ctx, 300_000)
      transition(ctx, issue(ctx, 2), "Done")
      await(ctx, "terminal_observation_persisted", fn -> is_integer(entry!(issue(ctx, 2).id).record.terminal_observed_at) end)
      retained = entry!(issue(ctx, 2).id).record
      restart_runtime(ctx)

      await(ctx, "retained_inventory_recovered", fn ->
        case scheduler_state().environment_entries[retained.issue_id] do
          nil -> false
          entry -> entry.record.terminal_observed_at == retained.terminal_observed_at and entry.record.desired != :absent
        end
      end)

      transition(ctx, issue(ctx, 2), "Qualification Codex")
      await(ctx, "retained_ticket_reopened", fn -> running?(retained.issue_id) and entry!(retained.issue_id).record.terminal_observed_at == nil end, ctx.config.startup_timeout_ms * 2)
      require!(entry!(retained.issue_id).record.provider_ref == retained.provider_ref, "retention_reopen_replaced_resource")
      pass(ctx, "retained_restart_and_reopen", %{environment_id: retained.key, first_terminal_observed_at: retained.terminal_observed_at})
      set_retention(ctx, 0)

      begin_check("tunnel_loss")
      transition(ctx, issue(ctx, 3), "Qualification Codex")
      await(ctx, "tunnel_victim_running", fn -> running?(issue(ctx, 3).id) end, ctx.config.startup_timeout_ms * 2)
      victim = entry!(issue(ctx, 3).id)
      ports = Enum.filter(Port.list(), &(Port.info(&1, :connected) == {:connected, victim.context.connection.owner}))
      require!(ports != [], "owned_tunnel_port_not_found")
      Enum.each(ports, &Command.terminate_port/1)
      await(ctx, "tunnel_loss_recovered", fn -> running?(victim.record.issue_id) and entry!(victim.record.issue_id).attempt_id != victim.attempt_id end, ctx.config.startup_timeout_ms * 3)
      current = entry!(victim.record.issue_id)
      remote!(ctx, current, "test -f qualification-sentinel.txt")
      assert_no_duplicate_resources!(ctx)
      pass(ctx, "tunnel_loss", %{environment_id: current.record.key})
      begin_check("attempt_fencing")
      send(Process.whereis(@orchestrator), {:worker_runtime_info, victim.record.issue_id, victim.attempt_id, %{workspace_path: "/must-not-become-a-local-fallback"}})
      observed = Orchestrator.snapshot(@orchestrator, 1_000).running |> Enum.find(&(&1.issue_id == victim.record.issue_id))
      require!(observed != nil and observed.workspace_path == current.record.workspace_path, "stale_attempt_changed_workspace")
      pass(ctx, "attempt_fencing", %{old_attempt: victim.attempt_id, new_attempt: current.attempt_id})

      begin_check("delayed_storage_deletion")
      storage_victim = entry!(issue(ctx, 5).id).record
      fault_driver!(ctx, "storage_deletion", "apply", storage_victim)
      transition(ctx, issue(ctx, 5), "Done")
      await(ctx, "storage_delete_accepted", fn -> event?(ctx, :delete_accepted, storage_victim.issue_id) end)
      # Natural asynchronous deletion latency is insufficient: an accepted operation must
      # actually fail/become uncertain while the exact physical storage still exists.
      await(ctx, "physical_deletion_uncertainty_observed", fn -> deletion_uncertain?(ctx, storage_victim) and storage_present?(ctx, storage_victim) end, ctx.config.shutdown_timeout_ms * 2)
      begin_check("deletion_restart")
      restart_runtime(ctx)

      await(ctx, "deletion_recovery_guard_held", fn ->
        state = scheduler_state()
        recovery_pending = state.environment_discovery != :ready
        retained_entry = Map.has_key?(state.environment_entries, storage_victim.issue_id)
        is_reference(state.environment_guard) and (recovery_pending or retained_entry)
      end)

      require!(storage_present?(ctx, storage_victim), "delayed_storage_disappeared_before_release")
      fault_driver!(ctx, "storage_deletion", "restore", storage_victim)
      await_absence(ctx, issue(ctx, 5))
      pass(ctx, "deletion_restart", %{environment_id: storage_victim.key})
      pass(ctx, "delayed_storage_deletion", %{environment_id: storage_victim.key, observed_operation_failure: true})

      begin_check("lost_create")
      for other <- Enum.take(ctx.issues, 4), do: transition(ctx, other, "In Review")
      await(ctx, "fault_scope_quiescent", fn -> Enum.all?(Enum.take(ctx.issues, 4), &stopped?(&1.id)) end)
      # Completed guard identities are permanent tombstones, never reusable tickets.
      sixth = %{issue(ctx, 6) | id: "#{ctx.run_id}-recovery", identifier: "QUAL-RECOVERY", state: "In Review"}
      GenServer.call(ctx.control, {:issues, control_snapshot(ctx).issues ++ [sixth]})
      # Persist its cleanup identity before the fresh issue can allocate.
      write_evidence(ctx, [], false)
      arm(ctx, {:lose_create, sixth.id})
      transition(ctx, sixth, "Qualification Codex")
      await(ctx, "accepted_create_response_lost", fn -> event?(ctx, :create_response_lost, sixth.id) end)
      assert_no_duplicate_resources!(ctx)
      await(ctx, "lost_create_recovered", fn -> running?(sixth.id) end, ctx.config.startup_timeout_ms * 3)
      assert_no_duplicate_resources!(ctx)
      if ctx.config.kind == "kubernetes", do: assert_exact_create_recovery!(ctx, sixth)
      pass(ctx, "lost_create", %{environment_id: entry!(sixth.id).record.key})
      begin_check("lost_start")
      transition(ctx, sixth, "In Review")
      await(ctx, "start_fault_baseline_stopped", fn -> stopped?(sixth.id) end)
      arm(ctx, {:lose_start, sixth.id})
      transition(ctx, sixth, "Qualification Codex")
      await(ctx, "accepted_start_response_lost", fn -> event?(ctx, :start_response_lost, sixth.id) and unknown_occupied?(sixth.id) end)
      assert_no_duplicate_resources!(ctx)
      await(ctx, "lost_start_recovered", fn -> running?(sixth.id) end, ctx.config.startup_timeout_ms * 3)
      assert_no_duplicate_resources!(ctx)
      pass(ctx, "lost_start", %{environment_id: entry!(sixth.id).record.key})
      if ctx.config.kind == "kubernetes", do: kubernetes_scenarios!(ctx, sixth)
    rescue
      error in Failure -> fail_current(ctx, error.code)
      _ -> fail_current(ctx, "qualification_check_failed")
    catch
      _, _ -> fail_current(ctx, "qualification_execution_interrupted")
    after
      cleanup(ctx)
    end

    evidence = Jason.decode!(File.read!(ctx.output))
    assert evidence["qualified?"], "Managed qualification did not pass; inspect the authorized evidence file for deployment #{ctx.run_id}"
  end

  defp prerequisites!(ctx) do
    profile = ctx.profile

    qualification_budget!(profile)
    quota = qualification_quota!(profile)
    qualification_runtime!(profile)
    qualification_negative_control!(profile)
    clone_hook = get_in(ctx.raw, ["hooks", "after_create"])
    require!(nonblank?(clone_hook), "disposable_repository_clone_hook_required")
    validate_fault_driver!(profile)

    case Provider.preflight(ctx.config, profile, provider_opts(ctx)) do
      {:ok, evidence} ->
        evidence
        |> Map.put(:quota_evidence, quota)
        |> Map.put(:budget, Map.take(profile, ["max_concurrent_workers", "max_retained_environments", "max_backend_sessions"]))
        |> Map.put(:review_app_probe_sha256, review_response!(ctx))

      {:error, code} ->
        provider_failure!(code)
    end
  end

  defp qualification_budget!(profile) do
    authorized = profile["paid_model_calls_authorized"] == true and profile["max_concurrent_workers"] == 5
    retained = profile["max_retained_environments"]
    sessions = profile["max_backend_sessions"]
    require!(authorized and at_least?(retained, 6) and at_least?(sessions, 20), "explicit_qualification_budget_required")
  end

  defp qualification_quota!(profile) do
    documented = nonblank?(profile["qualification_report"]) and is_map(profile["quota_evidence"])
    require!(documented, "operator_prerequisite_evidence_required")
    quota = Map.take(profile["quota_evidence"], ["concurrent_workers", "retained_environments", "persistent_disk_gib"])
    enough = numeric_at_least?(quota["concurrent_workers"], 5) and numeric_at_least?(quota["retained_environments"], 6)

    require!(
      enough and Enum.all?(quota, fn {_, value} -> numeric_at_least?(value, 0) end),
      "numeric_worker_and_storage_quota_evidence_required"
    )

    quota
  end

  defp qualification_runtime!(profile) do
    dependencies = profile["node_modules_path"]
    absolute = is_binary(dependencies) and Path.type(dependencies) == :absolute
    require!(nonblank?(profile["runtime_version"]) and absolute, "qualified_runtime_and_dependencies_required")
  end

  defp qualification_negative_control!(profile) do
    paths = profile["unrelated_resource_paths"]
    require!(is_list(paths) and paths != [], "unrelated_negative_control_required")
    url = if is_binary(profile["review_app_url"]), do: URI.parse(profile["review_app_url"]), else: %URI{}
    clean = url.userinfo == nil and url.query == nil and url.fragment == nil
    require!(url.scheme == "https" and is_binary(url.host) and clean, "independent_review_app_required")
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp at_least?(value, minimum), do: is_integer(value) and value >= minimum
  defp numeric_at_least?(value, minimum), do: is_number(value) and value >= minimum

  defp qualification_workflow(raw, run_id) do
    worker = Map.get(raw, "worker", %{})
    environment = Map.get(worker, "environment", %{})

    raw
    |> Map.put("tracker", %{"kind" => "memory", "active_states" => ["Qualification Codex", "Qualification Claude"], "terminal_states" => ["Done"]})
    |> Map.put("worker", Map.put(worker, "environment", Map.merge(environment, %{"deployment_id" => run_id, "terminal_retention_ms" => 0})))
    |> Map.put("polling", %{"interval_ms" => 5_000})
    |> Map.update("agent", %{}, &Map.merge(&1, %{"max_concurrent_agents" => 5, "backend" => "codex", "backend_by_state" => %{"Qualification Codex" => "codex", "Qualification Claude" => "claude"}}))
  end

  defp install_workloads!(ctx) do
    fixture_commands =
      for file <- @fixture_files do
        "printf %s #{shell_quote(Base.encode64(File.read!(Path.join(@fixture_root, file))))} | base64 --decode > .symphony-qualification/#{file}"
      end

    install =
      Enum.join(
        ["mkdir -p .symphony-qualification" | fixture_commands] ++
          [
            "ln -s #{shell_quote(ctx.profile["node_modules_path"])} .symphony-qualification/node_modules",
            "printf %s #{shell_quote(Base.encode64(workload_script(ctx.run_id)))} | base64 --decode > .symphony-qualification/run-probes.sh"
          ],
        "\n"
      )

    raw = put_in(ctx.raw, ["hooks", "after_create"], get_in(ctx.raw, ["hooks", "after_create"]) <> "\n" <> install)
    replace_private!(ctx.workflow_path, workflow_document(raw))
    require!(WorkflowStore.force_reload() == :ok, "qualification_workflow_reload_rejected")
  end

  defp workload_script(run_id) do
    """
    set -euo pipefail
    cd "$(git rev-parse --show-toplevel)"
    index="$1"
    case "$index" in [1-6]) ;; *) exit 2;; esac
    value="#{run_id}-$index"
    project="sq-#{run_id}-$index"
    test -f qualification-sentinel.txt || printf '%s\\n' "$value" > qualification-sentinel.txt
    docker compose -f .symphony-qualification/compose.yaml -p "$project" up -d --wait
    docker compose -f .symphony-qualification/compose.yaml -p "$project" exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS qualification(value text PRIMARY KEY); INSERT INTO qualification(value) VALUES ('$value') ON CONFLICT DO NOTHING;"
    SYMPHONY_QUALIFICATION_ID="$value" python3 .symphony-qualification/testcontainers_probe.py > .symphony-qualification/testcontainers.out
    node .symphony-qualification/browser_probe.mjs > .symphony-qualification/browser.out
    printf '%s' "$value" > .symphony-qualification/ready
    while test ! -f .symphony-qualification/release; do sleep 1; done
    """
  end

  defp workflow_document(raw),
    do:
      "---\n" <>
        Jason.encode!(raw) <>
        "\n---\n{{ issue.description }}\nRun the supplied probes under the configured backend policy. A rejected operation is a qualification failure, never permission to bypass policy.\n"

  defp start_runtime(ctx) do
    authority = self()

    operation_fun = fn adapter, config, entry, operation, opts ->
      timeout = if operation in [:stop, :destroy], do: config.shutdown_timeout_ms, else: config.startup_timeout_ms
      deadline = min(ctx.deadline, min(Keyword.get(opts, :deadline, ctx.deadline), now() + timeout))
      opts = opts |> Keyword.put(:deadline, deadline) |> Keyword.put(:timeout_ms, max(1, min(timeout, deadline - now())))
      callbacks = %{armed?: &armed?(ctx, &1), disarm: &disarm(ctx, &1), event: &event(ctx, &1)}
      opts = Provider.fault_options(config, entry, operation, opts, callbacks)
      if entry, do: capture_result(ctx, {:ok, entry.record})
      result = Operations.run(adapter, config, entry, operation, opts)
      capture_result(ctx, result)

      if entry,
        do: event(ctx, %{event: :operation_result, issue_id: entry.record.issue_id, operation: operation, attempt_id: entry.attempt_id, outcome: if(match?({:ok, _}, result), do: :ok, else: :error)})

      result
    end

    runner_fun = fn issue, recipient, opts ->
      invocation = %{event: :runner_invocation, issue_id: issue.id, options: opts}
      accepted = GenServer.call(ctx.control, {:event, invocation})
      write_evidence(ctx, [], false)
      require!(accepted == :ok, "qualification_runner_context_rejected")

      if now() < ctx.deadline and GenServer.call(ctx.control, :session) do
        write_evidence(ctx, [], false)
        AgentRunner.run(issue, recipient, opts)
      else
        exit(:qualification_backend_budget_exhausted)
      end
    end

    runtime_opts = [
      name: @runtime,
      task_supervisor_name: @worker_tasks,
      orchestrator_name: @orchestrator,
      environment_operation_fun: operation_fun,
      runner_fun: runner_fun
    ]

    case AgentRuntimeSupervisor.start_link(runtime_opts) do
      {:ok, runtime} ->
        # Supervisors trap normal linked exits; a separate monitor also fences normal owner death.
        spawn(fn ->
          owner_ref = Process.monitor(authority)
          runtime_ref = Process.monitor(runtime)

          receive do
            {:DOWN, ^owner_ref, :process, ^authority, _} -> Process.exit(runtime, :kill)
            {:DOWN, ^runtime_ref, :process, ^runtime, _} -> :ok
          after
            max(0, ctx.deadline - now()) -> Process.exit(runtime, :kill)
          end
        end)

        :ok

      _ ->
        require!(false, "qualification_runtime_start_failed")
    end
  end

  defp restart_runtime(ctx) do
    old = Process.whereis(@orchestrator)
    Process.exit(old, :kill)

    await(ctx, "orchestrator_restarted", fn ->
      pid = Process.whereis(@orchestrator)
      is_pid(pid) and pid != old
    end)

    refresh()
  end

  defp workload_ready?(ctx, issue) do
    if running?(issue.id) do
      case remote(ctx, entry!(issue.id), "cat .symphony-qualification/ready") do
        {:ok, output} -> String.trim(output) == issue.id
        _ -> false
      end
    else
      false
    end
  end

  defp verify_workload!(ctx, issue) do
    entry = entry!(issue.id)
    index = Enum.find_index(ctx.issues, &(&1.id == issue.id)) + 1
    sentinel_values = remote!(ctx, entry, "cat qualification-sentinel.txt") |> String.split("\n")
    require!(issue.id in sentinel_values, "agent_file_change_missing")
    require!(Enum.all?(ctx.issues, &(&1.id == issue.id or &1.id not in sentinel_values)), "ticket_sentinel_files_shared")
    require!(String.trim(remote!(ctx, entry, "git status --porcelain -- qualification-sentinel.txt")) != "", "agent_uncommitted_change_missing")
    require!(String.trim(remote!(ctx, entry, sql_command(ctx, index, "SELECT value FROM qualification WHERE value='#{issue.id}'"))) == issue.id, "agent_database_write_missing")
    other_ids = Enum.reject(ctx.issues, &(&1.id == issue.id)) |> Enum.map_join(",", &("'" <> &1.id <> "'"))
    require!(String.trim(remote!(ctx, entry, sql_command(ctx, index, "SELECT count(*) FROM qualification WHERE value IN (#{other_ids})"))) == "0", "ticket_database_rows_shared")
    require!(String.trim(remote!(ctx, entry, "cat .symphony-qualification/testcontainers.out")) == "testcontainers-ok", "agent_testcontainers_probe_failed")
    require!(String.trim(remote!(ctx, entry, "cat .symphony-qualification/browser.out")) == "browser-ok", "agent_browser_probe_failed")

    hashes =
      for file <- @fixture_files, into: %{} do
        expected = :crypto.hash(:sha256, File.read!(Path.join(@fixture_root, file))) |> Base.encode16(case: :lower)
        actual = remote!(ctx, entry, "sha256sum .symphony-qualification/#{file}") |> String.split() |> List.first()
        require!(actual == expected, "qualification_fixture_modified")
        {file, expected}
      end

    script_hash = :crypto.hash(:sha256, workload_script(ctx.run_id)) |> Base.encode16(case: :lower)
    require!(remote!(ctx, entry, "sha256sum .symphony-qualification/run-probes.sh") |> String.split() |> List.first() == script_hash, "qualification_workload_script_modified")
    daemon = remote!(ctx, entry, "docker info --format '{{json .}}'") |> Jason.decode!()
    require!(is_binary(daemon["ID"]) and Regex.match?(~r/\A[A-Za-z0-9:-]{8,128}\z/, daemon["ID"]), "docker_identity_unavailable")

    runtime = %{
      kernel: observed_version!(remote!(ctx, entry, "uname -r")),
      docker: observed_version!(daemon["ServerVersion"]),
      compose: observed_version!(remote!(ctx, entry, "docker compose version --short")),
      node: observed_version!(remote!(ctx, entry, "node --version")),
      codex: observed_version!(remote!(ctx, entry, "#{shell_quote(Config.settings!().codex.command |> OptionParser.split() |> hd())} --version")),
      claude: observed_version!(remote!(ctx, entry, "#{shell_quote(Config.settings!().claude.command |> OptionParser.split() |> hd())} --version")),
      testcontainers: observed_version!(remote!(ctx, entry, "python3 -c 'import importlib.metadata; print(importlib.metadata.version(\"testcontainers\"))'")),
      playwright: observed_version!(remote!(ctx, entry, "node -p 'require(\"./.symphony-qualification/node_modules/playwright/package.json\").version'"))
    }

    require!(not File.exists?(Path.join(entry.record.workspace_path, "qualification-sentinel.txt")), "managed_file_created_on_controller")
    %{issue_id: issue.id, environment_id: entry.record.key, engine_id: daemon["ID"], runtime: runtime, fixture_sha256: hashes, workload_sha256: script_hash}
  end

  defp isolation!(ctx, issues) do
    addresses =
      Map.new(issues, fn issue ->
        targets = provider_value!(Provider.runtime_targets(ctx.config, entry!(issue.id).record, provider_opts(ctx)))
        require!(targets.addresses != [], "worker_peer_address_unavailable")
        {issue.id, targets.addresses}
      end)

    for issue <- issues do
      peers = addresses |> Map.delete(issue.id) |> Map.values() |> List.flatten() |> Enum.uniq()
      require!(String.trim(remote!(ctx, entry!(issue.id), isolation_script(peers, ctx.config.provider["ssh_user"]))) == "isolation-ok", "isolation_probe_did_not_complete")
    end
  end

  defp isolation_script(peers, user) do
    payload = Base.encode64(Jason.encode!(peers))

    """
    set -euo pipefail
    for path in /run/containerd/containerd.sock /var/run/containerd/containerd.sock /run/crio/crio.sock /var/lib/kubelet /var/run/secrets/kubernetes.io/serviceaccount/token "$HOME/.kube/config" "$HOME/.config/gcloud/application_default_credentials.json" "$HOME/.config/gcloud/credentials.db"; do test ! -e "$path"; done
    python3 - #{shell_quote(payload)} #{shell_quote(user)} <<'PY'
    import base64,concurrent.futures,json,re,socket,subprocess,sys,tempfile,urllib.error,urllib.parse,urllib.request

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,request,fp,code,message,headers,new_url):
            return None

    def request(url,headers=None,method='GET'):
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
        try:
            with opener.open(urllib.request.Request(url,headers=headers or {},method=method),timeout=2) as response:
                data=response.read(65537)
                if len(data)>65536:
                    raise RuntimeError('metadata response exceeds safe bound')
                return data
        except urllib.error.HTTPError as error:
            if error.code in (400,401,403,404,405):
                return None
            raise RuntimeError('metadata endpoint did not establish credential denial') from None
        except (urllib.error.URLError,OSError,TimeoutError):
            return None

    def deny_token(url,headers):
        data=request(url,headers)
        if data is None:
            return
        try:
            value=json.loads(data)
        except (ValueError,UnicodeError):
            raise RuntimeError('metadata credential response is ambiguous') from None
        if not isinstance(value,dict):
            raise RuntimeError('metadata credential response is ambiguous')
        if value.get('access_token') or value.get('id_token'):
            raise RuntimeError('usable metadata credentials accessible')
        raise RuntimeError('metadata endpoint returned unexpected success')

    def deny_aws():
        base='http://169.254.169.254'
        token=request(base+'/latest/api/token',{'X-aws-ec2-metadata-token-ttl-seconds':'60'},'PUT')
        headers={}
        if token is not None:
            try:
                headers['X-aws-ec2-metadata-token']=token.decode('ascii').strip()
            except UnicodeError:
                raise RuntimeError('metadata session response is ambiguous') from None
            if not headers['X-aws-ec2-metadata-token']:
                raise RuntimeError('metadata session response is ambiguous')
        roles=request(base+'/latest/meta-data/iam/security-credentials/',headers)
        if roles is None:
            return
        try:
            names=roles.decode('ascii').splitlines()
        except UnicodeError:
            raise RuntimeError('metadata role response is ambiguous') from None
        if not names:
            return
        if len(names)!=1 or not re.fullmatch(r'[A-Za-z0-9+=,.@_-]{1,128}',names[0]):
            raise RuntimeError('metadata role response is ambiguous')
        credentials=request(base+'/latest/meta-data/iam/security-credentials/'+urllib.parse.quote(names[0],safe=''),headers)
        if credentials is None:
            return
        try:
            value=json.loads(credentials)
        except (ValueError,UnicodeError):
            raise RuntimeError('metadata credential response is ambiguous') from None
        if isinstance(value,dict) and (value.get('AccessKeyId') or value.get('SecretAccessKey') or value.get('Token')):
            raise RuntimeError('usable metadata credentials accessible')
        raise RuntimeError('metadata endpoint returned unexpected success')

    def deny_docker(host,port):
        try:
            connection=socket.create_connection((host,port),2)
        except (OSError,TimeoutError):
            return
        connection.close()
        raise RuntimeError('peer Docker endpoint reachable')

    def deny_ssh(host,user,known):
        args=['ssh','-F','/dev/null','-o','BatchMode=yes','-o','IdentityAgent=none',
              '-o','PubkeyAuthentication=yes','-o','PasswordAuthentication=no',
              '-o','KbdInteractiveAuthentication=no','-o','PreferredAuthentications=publickey',
              '-o','StrictHostKeyChecking=accept-new','-o','UserKnownHostsFile='+known,
              '-o','ConnectTimeout=2',user+'@'+host,'true']
        try:
            result=subprocess.run(args,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=4)
        except subprocess.TimeoutExpired:
            return
        if result.returncode==0:
            raise RuntimeError('unauthorized peer SSH access succeeded')

    # Network probes run concurrently; each socket/HTTP operation is bounded to 2s,
    # each SSH child to 4s, and the enclosing remote command to 30s.
    peers=json.loads(base64.b64decode(sys.argv[1]))
    with tempfile.TemporaryDirectory() as temporary, concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
        jobs=[]
        for index,host in enumerate(peers):
            for port in (2375,2376):
                jobs.append(executor.submit(deny_docker,host,port))
            jobs.append(executor.submit(deny_ssh,host,sys.argv[2],temporary+'/known-'+str(index)))
        for host in ('metadata.google.internal','169.254.169.254'):
            jobs.append(executor.submit(deny_token,'http://'+host+'/computeMetadata/v1/instance/service-accounts/default/token',{'Metadata-Flavor':'Google'}))
        jobs.append(executor.submit(deny_aws))
        jobs.append(executor.submit(deny_token,'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F',{'Metadata':'true'}))
        for job in jobs:
            job.result()
    print('isolation-ok')
    PY
    """
  end

  defp kubernetes_scenarios!(ctx, issue) do
    begin_check("delayed_gate_release")
    transition(ctx, issue, "In Review")
    await(ctx, "gate_baseline_stopped", fn -> stopped?(issue.id) end)
    arm(ctx, {:hold_gate, issue.id})
    transition(ctx, issue, "Qualification Codex")
    await(ctx, "gate_release_held", fn -> event?(ctx, :gate_held, issue.id) end)
    record = entry!(issue.id).record
    gate = provider_value!(Provider.gate_observation(ctx.config, record, provider_opts(ctx)))
    require!(gate.held? and occupied?(issue.id) and not running?(issue.id), "gated_worker_executed_or_released_capacity")
    disarm(ctx, {:hold_gate, issue.id})
    await(ctx, "gate_released_worker_running", fn -> running?(issue.id) end, ctx.config.startup_timeout_ms * 2)
    released = provider_value!(Provider.gate_observation(ctx.config, entry!(issue.id).record, provider_opts(ctx)))
    require!(not released.held? and released.pod_uid == gate.pod_uid, "gate_release_replaced_owned_pod")
    assert_no_duplicate_resources!(ctx)
    pass(ctx, "delayed_gate_release", %{pod_uid: gate.pod_uid})

    begin_check("node_disconnection")
    require!(ctx.profile["node_fault_authorized"] == true and is_list(ctx.profile["authorized_node_uids"]) and ctx.profile["authorized_node_uids"] != [], "explicit_dedicated_node_permission_required")
    record = entry!(issue.id).record
    before_fault = provider_value!(Provider.node_observation(ctx.config, record, ctx.profile, provider_opts(ctx)))
    require!(before_fault.ready?, "dedicated_node_not_ready_before_fault")
    # Ephemeral qualification-only capture supports exact node re-observation after Pod removal.
    record = %{record | metadata: Map.put(record.metadata, "qualification_node", before_fault.node)}
    fault_driver!(ctx, "node_disconnection", "apply", record)

    await(ctx, "authorized_node_not_ready", fn ->
      observation = provider_value!(Provider.node_observation(ctx.config, record, ctx.profile, provider_opts(ctx)))
      observation.node == before_fault.node and not observation.ready?
    end)

    transition(ctx, issue, "In Review")
    await(ctx, "disconnected_node_stop_unknown", fn -> unknown_occupied?(issue.id) end, ctx.config.shutdown_timeout_ms * 2)
    require!(not stopped?(issue.id), "node_not_ready_mistaken_for_stop_proof")
    fault_driver!(ctx, "node_disconnection", "restore", record)

    await(ctx, "dedicated_node_recovered", fn ->
      observation = provider_value!(Provider.node_observation(ctx.config, record, ctx.profile, provider_opts(ctx)))
      observation.node == before_fault.node and observation.ready?
    end)

    await(ctx, "node_fault_worker_physically_stopped", fn -> stopped?(issue.id) end, ctx.config.shutdown_timeout_ms * 2)
    pass(ctx, "node_disconnection", %{node: before_fault.node, environment_id: record.key})
  end

  defp cleanup(ctx) do
    # A new bounded authority owns cleanup; the run's expired deadline cannot prevent deletion.
    ctx = %{ctx | deadline: now() + 240_000}

    try do
      stop_runtime()

      if control_snapshot(ctx).allocation_started do
        GenServer.call(ctx.control, :clear_faults)
        fault_driver!(ctx, "all", "restore", nil)
        set_retention(ctx, 0)
        GenServer.call(ctx.control, {:issues, Enum.map(control_snapshot(ctx).issues, &%{&1 | state: "Done"})})
        start_runtime(ctx)
        refresh()
        deletion_ctx = %{ctx | deadline: ctx.deadline - 20_000}

        await(
          deletion_ctx,
          "all_owned_resources_absent",
          fn -> all_owned_absent?(deletion_ctx) end,
          remaining(deletion_ctx)
        )

        pass(ctx, "final_absence", %{deployment_id: ctx.run_id})
        stop_runtime()
        verify_unrelated_after_cleanup!(ctx)
        write_evidence(ctx, [], true)
        File.rm_rf!(ctx.run_root)
      else
        write_evidence(ctx, [], false)
        File.rm_rf!(ctx.run_root)
      end
    rescue
      error in Failure -> cleanup_failure(ctx, error.code)
      _ -> cleanup_failure(ctx, "owned_resource_cleanup_unresolved")
    catch
      _, _ -> cleanup_failure(ctx, "cleanup_execution_interrupted")
    after
      stop_runtime()
      if Process.alive?(ctx.tasks), do: Supervisor.stop(ctx.tasks, :normal, 5_000)
      if Process.alive?(ctx.control), do: GenServer.stop(ctx.control)
    end
  end

  defp all_owned_absent?(ctx) do
    state = scheduler_state()
    released = state.environment_guard == nil and map_size(state.environment_jobs) == 0

    case inventory(ctx) do
      {:ok, %{records: [], live_worker_counts: counts}} ->
        released and map_size(state.environment_entries) == 0 and Enum.all?(counts, fn {_, count} -> count == 0 end)

      _ ->
        false
    end
  end

  defp cleanup_failure(ctx, code) do
    name = if code == "unrelated_resource_identity_changed_during_cleanup", do: "unrelated_resources", else: "final_absence"
    GenServer.call(ctx.control, {:check, name, %{status: :failed, code: code}})
    stop_runtime()

    if name != "unrelated_resources" do
      try do
        verify_unrelated_after_cleanup!(ctx)
      rescue
        _ -> GenServer.call(ctx.control, {:check, "unrelated_resources", %{status: :failed, code: "post_cleanup_negative_control_unresolved"}})
      catch
        _, _ -> GenServer.call(ctx.control, {:check, "unrelated_resources", %{status: :failed, code: "post_cleanup_negative_control_unresolved"}})
      end
    end

    write_evidence(ctx, remaining_resources(ctx), false)
  end

  defp verify_unrelated_after_cleanup!(ctx) do
    baseline = control_snapshot(ctx).baseline

    observed =
      try do
        unrelated_resources!(ctx)
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    require!(
      Control.unrelated_unchanged?(control_snapshot(ctx), observed),
      "unrelated_resource_identity_changed_during_cleanup"
    )

    pass(ctx, "unrelated_resources", %{resources: baseline})
  end

  defp recover_interrupted_cleanup(ctx) do
    with {:ok, bytes} <- File.read(ctx.output),
         {:ok, evidence} <- Jason.decode(bytes),
         true <- evidence["deployment_id"] == ctx.run_id,
         true <- evidence["allocation_started"] == true and evidence["inventory_complete"] != true do
      {:ok, control} = Control.start_link(checks: ctx.check_names, session_limit: 0, config: ctx.config)
      {:ok, tasks} = Task.Supervisor.start_link()
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, control)
      GenServer.call(control, :allocation_started)

      for result <- evidence["checks"] || [], result["name"] in ctx.check_names do
        status = restored_check_status(result["status"])

        GenServer.call(control, {:check, result["name"], %{status: status, evidence: result["evidence"], code: result["code"]}})
      end

      GenServer.call(control, {:interrupted, evidence})
      cleanup(%{ctx | control: control, tasks: tasks})
    else
      _ -> :ok
    end
  rescue
    _ -> IO.puts("Managed cleanup needs operator intervention for deployment #{ctx.run_id}")
  catch
    _, _ -> IO.puts("Managed cleanup interrupted for deployment #{ctx.run_id}")
  end

  defp restored_check_status("passed"), do: :passed
  defp restored_check_status("blocked"), do: :blocked
  defp restored_check_status("failed"), do: :failed
  defp restored_check_status(_), do: :not_run

  defp remaining_resources(ctx) do
    case inventory(ctx) do
      {:ok, _} ->
        control_snapshot(ctx).observed_resources

      _ ->
        capture_result(ctx, discover_remaining(ctx))
        state = control_snapshot(ctx)
        captured = Enum.map(state.captured_resources, &Map.put(&1, "status", "captured"))
        captured ++ [%{deployment_id: ctx.run_id, status: :inventory_unresolved}]
    end
  end

  defp discover_remaining(ctx) do
    ctx.adapter.discover(ctx.config, provider_opts(ctx))
  rescue
    _ -> {:error, :qualification_inventory_unavailable}
  catch
    _, _ -> {:error, :qualification_inventory_unavailable}
  end

  defp inventory(ctx) do
    result = read_inventory(ctx)
    GenServer.call(ctx.control, {:event, %{event: :inventory_observation, result: result}})
    write_evidence(ctx, [], false)
    result
  end

  defp read_inventory(ctx) do
    Provider.inventory(ctx.config, provider_opts(ctx))
  rescue
    _ -> {:error, :qualification_inventory_unavailable}
  catch
    _, _ -> {:error, :qualification_inventory_unavailable}
  end

  defp capture_result(ctx, result) do
    GenServer.call(ctx.control, {:event, %{event: :record_observation, result: result}})
    write_evidence(ctx, [], false)
  end

  defp write_evidence(ctx, remaining, inventory_complete) do
    writer = fn state -> persist_evidence(ctx, state, remaining, inventory_complete) end
    require!(GenServer.call(ctx.control, {:persist, writer}) == :ok, "qualification_evidence_write_failed")
  end

  defp persist_evidence(ctx, state, remaining, inventory_complete) do
    checks = Enum.map(ctx.check_names, &state.checks[&1])
    prerequisite = Map.get(state.checks["prerequisites"], :evidence) || %{}

    evidence = %{
      provider: ctx.config.kind,
      deployment_id: ctx.run_id,
      scope: safe_scope(ctx),
      image_digest: Map.get(prerequisite, :image_digest, Map.get(prerequisite, "image_digest")),
      runtime_version: Map.get(prerequisite, :runtime_version, Map.get(prerequisite, "runtime_version")),
      fixture_images: ctx.fixture_images,
      checks: checks,
      backend_sessions: state.sessions,
      runner_rejected: state.runner_rejected,
      runner_invocations: state.runner_invocations,
      captured_resources: state.captured_resources,
      retained_guards: state.retained_guards,
      cleanup_issue_ids: Enum.uniq(Enum.map(ctx.issues ++ state.issues, & &1.id)),
      events: Enum.reverse(state.events),
      allocation_started: state.allocation_started,
      interrupted: state.interrupted,
      unrelated_baseline: state.baseline,
      remaining_owned_resources: remaining,
      inventory_complete: inventory_complete,
      recovery_workflow: if(inventory_complete or not state.allocation_started, do: nil, else: ctx.workflow_path),
      qualified?: inventory_complete and remaining == [] and Control.qualified?(state)
    }

    replace_private!(ctx.output, Jason.encode!(evidence, pretty: true))
  end

  defp bootstrap_blocked(output, run_id, code) do
    checks = Enum.map(@checks, fn name -> if name == "prerequisites", do: %{name: name, status: :blocked, code: code}, else: %{name: name, status: :not_run} end)

    replace_private!(
      output,
      Jason.encode!(%{deployment_id: run_id, qualified?: false, allocation_started: false, inventory_complete: false, checks: checks, remaining_owned_resources: []}, pretty: true)
    )
  end

  defp fixture_images do
    for file <- ["compose.yaml", "testcontainers_probe.py"],
        [image] <- Regex.scan(~r/(?:postgres:16|alpine:3.20|testcontainers\/ryuk:0.8.1)@sha256:[0-9a-f]{64}/, File.read!(Path.join(@fixture_root, file))),
        do: image
  end

  defp fault_driver!(ctx, scenario, phase, record) do
    case Provider.physical_fault(ctx.config, ctx.profile, scenario, phase, record, provider_opts(ctx)) do
      :ok -> :ok
      {:error, code} -> provider_failure!(code)
    end
  end

  defp validate_fault_driver!(profile) do
    path = profile["fault_driver"]
    require!(is_binary(path) and Path.type(path) == :absolute and File.regular?(path), "authorized_physical_fault_driver_required")
    digest = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    require!(digest == profile["fault_driver_sha256"] and profile["storage_fault_authorized"] == true, "physical_fault_driver_authorization_mismatch")
  end

  defp storage_present?(ctx, record), do: provider_value!(Provider.storage_present(ctx.config, record, provider_opts(ctx)))
  defp unrelated_resources!(ctx), do: provider_value!(Provider.unrelated_snapshot(ctx.config, ctx.profile["unrelated_resource_paths"], provider_opts(ctx)))

  defp review_response!(ctx) do
    timeout = min(5_000, remaining(ctx))
    require!(timeout > 0, "qualification_deadline")

    case Req.get(ctx.profile["review_app_url"], retry: false, redirect: false, receive_timeout: timeout, connect_options: [timeout: timeout]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      _ -> require!(false, "independent_review_app_unavailable")
    end
  end

  defp assert_no_duplicate_resources!(ctx) do
    %{records: records, live_worker_counts: counts} = provider_value!(inventory(ctx))
    require!(length(Enum.uniq_by(records, & &1.issue_id)) == length(records) and length(records) <= 6, "duplicate_owned_environment")
    require!(Enum.all?(counts, fn {_, count} -> is_integer(count) and count in 0..1 end) and Enum.sum(Map.values(counts)) <= 5, "duplicate_or_overbudget_actual_workers")
  end

  defp deletion_uncertain?(ctx, record) do
    failed = Enum.any?(control_snapshot(ctx).events, &(&1[:event] == :operation_result and &1[:issue_id] == record.issue_id and &1[:operation] == :destroy and &1[:outcome] == :error))

    case scheduler_state().environment_entries[record.issue_id] do
      %{record: %{desired: :absent}, phase: :unknown, last_error: error} -> failed and error != nil
      _ -> false
    end
  end

  defp remote(ctx, %{context: %{mode: :managed, target: %SSH.Target{} = target}, record: record}, command) do
    opts = Keyword.merge(provider_opts(ctx), env: target.env, timeout_ms: min(30_000, remaining(ctx)), max_output_bytes: 1_048_576)
    script = "set -e\ncd -- #{shell_quote(record.workspace_path)}\n" <> command

    case Command.run(target.executable, target.prefix ++ [SSH.remote_shell_command(script)], opts) do
      {:ok, %{status: 0, output: output}} -> {:ok, output}
      _ -> {:error, :remote_probe_failed}
    end
  end

  defp remote(_ctx, _entry, _command), do: {:error, :managed_context_unavailable}

  defp remote!(ctx, entry, command) do
    case remote(ctx, entry, command) do
      {:ok, output} -> output
      _ -> require!(false, "bounded_remote_probe_failed")
    end
  end

  defp sql_command(ctx, index, sql),
    do: "docker compose -f .symphony-qualification/compose.yaml -p sq-#{ctx.run_id}-#{index} exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 -Atc #{shell_quote(sql)}"

  defp set_retention(ctx, milliseconds) do
    # Read back the staged workflow, preserving installed hooks rather than restoring ctx.raw.
    document =
      case Workflow.load(ctx.workflow_path) do
        {:ok, document} -> document
        _ -> require!(false, "recovery_workflow_unreadable")
      end

    raw = put_in(document.config, ["worker", "environment", "terminal_retention_ms"], milliseconds)
    replace_private!(ctx.workflow_path, workflow_document(raw))
    require!(WorkflowStore.force_reload() == :ok, "retention_reload_rejected")
    if Process.whereis(@orchestrator), do: refresh()
  end

  defp await_absence(ctx, issue) do
    await(ctx, "owned_compute_and_storage_absent", fn -> issue_absent?(ctx, issue.id) end, ctx.config.shutdown_timeout_ms * 2)
  end

  defp issue_absent?(ctx, id) do
    case inventory(ctx) do
      {:ok, %{records: records, live_worker_counts: counts}} ->
        absent = not Enum.any?(records, &(&1.issue_id == id))
        absent and not Map.has_key?(scheduler_state().environment_entries, id) and bounded_worker_counts?(counts)

      _ ->
        false
    end
  end

  defp bounded_worker_counts?(counts), do: Enum.all?(counts, fn {_, count} -> count in 0..1 end)

  defp await(ctx, label, predicate, timeout \\ 180_000), do: await_loop(ctx, label, predicate, min(ctx.deadline, now() + timeout))

  defp await_loop(ctx, label, predicate, deadline) do
    require!(now() < deadline, label <> "_deadline")

    if predicate.() do
      :ok
    else
      Process.sleep(min(250, max(0, deadline - now())))
      await_loop(ctx, label, predicate, deadline)
    end
  end

  defp transition(ctx, issue, state),
    do:
      (
        GenServer.call(ctx.control, {:transition, issue.id, state})
        refresh()
      )

  defp refresh, do: Orchestrator.request_refresh(@orchestrator)
  defp scheduler_state, do: :sys.get_state(@orchestrator, 2_000)
  defp entry!(id), do: Map.fetch!(scheduler_state().environment_entries, id)

  defp running?(id) do
    state = scheduler_state()

    case state.environment_entries[id] do
      %{phase: :running, context: %{mode: :managed}} -> Map.has_key?(state.running, id)
      _ -> false
    end
  end

  defp occupied?(id) do
    case scheduler_state().environment_entries[id] do
      nil -> false
      entry -> Lifecycle.occupied?(entry)
    end
  end

  defp unknown_occupied?(id) do
    case scheduler_state().environment_entries[id] do
      %{phase: :unknown} = entry -> Lifecycle.occupied?(entry)
      _ -> false
    end
  end

  defp stopped?(id) do
    case scheduler_state().environment_entries[id] do
      %{phase: :stopped, record: %{proof: {:quiescent, _}}} = entry -> not Lifecycle.occupied?(entry)
      _ -> false
    end
  end

  defp occupied_count(state),
    do: state.environment_entries |> Enum.filter(fn {_, entry} -> Lifecycle.occupied?(entry) end) |> Enum.map(&elem(&1, 0)) |> Kernel.++(Map.keys(state.running)) |> Enum.uniq() |> length()

  defp issue(ctx, index), do: Enum.at(ctx.issues, index - 1)
  defp arm(ctx, key), do: GenServer.call(ctx.control, {:fault, :arm, key})
  defp disarm(ctx, key), do: GenServer.call(ctx.control, {:fault, :disarm, key})
  defp armed?(ctx, key), do: GenServer.call(ctx.control, {:armed?, key})
  defp event(ctx, data), do: GenServer.call(ctx.control, {:event, data})
  defp event?(ctx, event, id), do: Enum.any?(control_snapshot(ctx).events, &(&1[:event] == event and &1[:issue_id] == id))
  defp control_snapshot(ctx), do: GenServer.call(ctx.control, :snapshot)

  defp assert_exact_create_recovery!(ctx, issue) do
    invoked = Enum.filter(control_snapshot(ctx).events, &(&1[:event] == :create_invoked and &1[:issue_id] == issue.id))
    require!(length(invoked) == 1, "create_transport_replayed")
    events = Enum.filter(control_snapshot(ctx).events, &(&1[:event] == :create_accepted and &1[:issue_id] == issue.id))
    require!(length(events) == 1, "create_replayed")
    [accepted] = events
    record = entry!(issue.id).record
    require!(accepted[:resource_uid] == record.provider_ref and accepted[:environment_id] == record.key, "create_recovery_identity_changed")
    lost = Enum.filter(control_snapshot(ctx).events, &(&1[:event] == :create_response_lost and &1[:issue_id] == issue.id))
    require!(length(lost) == 1, "create_loss_not_exact")
    [lost] = lost
    keys = [:attempt_id, :create_attempt_id, :guard_uid, :resource_uid, :environment_id]
    require!(Enum.all?(keys, &(nonblank?(accepted[&1]) and accepted[&1] == lost[&1])), "create_recovery_attribution_changed")
  end

  defp begin_check(name), do: Process.put(:qualification_check, name)

  defp pass(ctx, name, evidence) do
    GenServer.call(ctx.control, {:check, name, %{status: :passed, evidence: evidence}})
    write_evidence(ctx, [], false)
  end

  defp fail_current(ctx, code) do
    name = Process.get(:qualification_check, "prerequisites")
    GenServer.call(ctx.control, {:check, name, %{status: if(name == "prerequisites", do: :blocked, else: :failed), code: code}})
    write_evidence(ctx, [], false)
  end

  defp provider_opts(ctx) do
    require!(remaining(ctx) > 0, "qualification_deadline")
    [task_supervisor: ctx.tasks, authority: self(), timeout_ms: min(60_000, remaining(ctx)), deadline: ctx.deadline]
  end

  defp provider_value!({:ok, value}), do: value
  defp provider_value!({:error, code}), do: provider_failure!(code)
  defp provider_failure!(code) when is_atom(code), do: require!(false, Atom.to_string(code))
  defp provider_failure!(_), do: require!(false, "provider_qualification_failed")

  defp observed_version!(value) do
    require!(is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9 .+()_:\/-]{1,160}\s*\z/, value), "runtime_version_unavailable")
    String.trim(value)
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(ctx), do: max(0, ctx.deadline - now())

  defp stop_runtime do
    if pid = Process.whereis(@runtime) do
      ref = Process.monitor(pid)
      Process.unlink(pid)

      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> Process.exit(pid, :kill)
      end

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> require!(false, "local_qualification_runtime_shutdown_unresolved")
      end
    end
  end

  defp safe_scope(ctx), do: EnvironmentConfig.scope(ctx.config) |> Map.take(["project", "location", "cluster", "config", "context", "namespace"])

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp require!(true, _code), do: :ok
  defp require!(_false, code), do: raise(Failure, code: code)

  defp required_absolute_env!(name) do
    value = System.get_env(name)
    require!(is_binary(value) and Path.type(value) == :absolute, name <> "_must_be_absolute")
    value
  end

  defp temporary_output?(path) do
    parent = Path.dirname(path)
    roots = [System.tmp_dir!(), "/private" <> System.tmp_dir!(), "/tmp", "/private/tmp"]
    in_temporary_root = Enum.any?(roots, &String.starts_with?(parent <> "/", Path.expand(&1) <> "/"))

    with true <- Path.expand(path) == path and in_temporary_root,
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(parent),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, []} <- File.ls(parent),
         {:error, :enoent} <- File.lstat(path) do
      parent |> Path.split() |> Enum.scan(&Path.join(&2, &1)) |> Enum.all?(fn ancestor -> match?({:ok, %{type: :directory}}, File.lstat(ancestor)) end)
    else
      _ -> false
    end
  end

  defp write_private!(path, content) do
    {:ok, io} = File.open(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, content)
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end

  defp replace_private!(path, content) do
    temp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> ".writing"

    try do
      write_private!(temp, content)
      File.rename!(temp, path)
    after
      File.rm(temp)
    end
  end

  defp restore_application(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
