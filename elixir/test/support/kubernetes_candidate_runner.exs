if Mix.env() != :test, do: raise("candidate runner requires a MIX_ENV=test artifact")
Code.require_file("managed_environment_fixture/provider.exs", __DIR__)
Code.require_file("managed_environment_fixture/control.exs", __DIR__)
Code.require_file("kubernetes_candidate_evidence.exs", __DIR__)

defmodule SymphonyElixir.KubernetesCandidateRunner do
  @moduledoc false
  alias SymphonyElixir.{AgentRunner, AgentRuntimeSupervisor, ExecutionContext, Lanes, LaneStore, Orchestrator, SSH, Workflow}
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.ExecutionEnvironment.{Command, Kubernetes, Operations}
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.{Candidate, Client}
  alias SymphonyElixir.ManagedEnvironmentFixture.{Control, Provider}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.KubernetesCandidateEvidence, as: Evidence

  @runtime __MODULE__.Runtime
  @scheduler __MODULE__.Scheduler
  @tasks __MODULE__.Tasks
  @input_fields ~w(authorization mode workflow_path output_path pins timeout_ms cleanup_timeout_ms runner_sha256 negative_control_paths worker_count backend)
  @source __ENV__.file
  @support_sha256 Map.new(["managed_environment_fixture/provider.exs", "managed_environment_fixture/control.exs", "kubernetes_candidate_evidence.exs"], fn file ->
                    bytes = File.read!(Path.join(__DIR__, file))
                    {file, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
                  end)

  def run_file(path) do
    with true <- System.get_env("SYMPHONY_RUN_KUBERNETES_CANDIDATE") == "1",
         {:ok, bytes} <- File.read(path),
         {:ok, input} <- Jason.decode(bytes),
         :ok <- validate_input(input) do
      run(input)
    else
      _ -> {:error, :candidate_input_rejected}
    end
  end

  def validate_input(input) do
    with true <- is_map(input) and Enum.sort(Map.keys(input)) == Enum.sort(@input_fields),
         true <- input["authorization"] in ["disposable-namespace-non-model", "disposable-namespace-model"] and input["mode"] in ["run", "cleanup"],
         true <- input["backend"] in [nil, "claude", "codex"],
         true <- input["backend"] == nil or input["authorization"] == "disposable-namespace-model",
         true <- is_map(input["pins"]),
         true <- Enum.all?(~w(workflow_path output_path), &(is_binary(input[&1]) and Path.type(input[&1]) == :absolute)),
         true <- Enum.all?(~w(timeout_ms cleanup_timeout_ms), &(is_integer(input[&1]) and input[&1] in 1_000..900_000)),
         true <- is_integer(input["worker_count"]) and input["worker_count"] in 1..4,
         true <- is_list(input["negative_control_paths"]) and input["negative_control_paths"] != [],
         true <- Enum.all?(input["negative_control_paths"], &is_binary/1),
         true <- Candidate.sha256(File.read!(@source)) == input["runner_sha256"] do
      :ok
    else
      _ -> {:error, :candidate_input_rejected}
    end
  rescue
    _ -> {:error, :candidate_input_rejected}
  end

  defp run(input) do
    output = input["output_path"]
    directory = Path.dirname(output)
    # Evidence is always a fresh file in a caller-owned private directory; never overwrite a prior receipt.
    with {:ok, stat} <- File.lstat(directory),
         true <- stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700,
         {:ok, file} <- File.open(output, [:write, :exclusive, :binary]) do
      File.chmod!(output, 0o600)
      IO.binwrite(file, Jason.encode!(%{stage: "candidate-unqualified", qualified: false, status: "initializing", backend_sessions: 0}))
      File.close(file)
      execute(input)
    else
      _ -> {:error, :candidate_private_output_required}
    end
  end

  defp execute(input) do
    original = %{
      issues: Application.get_env(:symphony_elixir, :memory_tracker_issues),
      recipient: Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    }

    workflow = input["output_path"] <> ".workflow"
    {:ok, observations} = Agent.start_link(fn -> %{status: "initializing", protocol_observations: [], cleanup: "not_started", runner: "not_run"} end)

    try do
      # Memory tracker state is application-global; never share this harness with another lane.
      true = LaneStore.list() == []
      {:ok, document} = Workflow.load(input["workflow_path"])
      raw = candidate_workflow(document.config, input["pins"]["deployment_id"], input["worker_count"], input["backend"])
      :ok = File.write(workflow, "---\n" <> Jason.encode!(raw) <> "\n---\nNon-model candidate lifecycle probe.\n", [:exclusive])
      File.chmod!(workflow, 0o600)
      {:ok, lane, _warnings} = Lanes.import_file(workflow, slug: "candidate")
      false = lane.enabled
      config = EnvironmentConfig.runtime(LaneStore.settings!(lane.id))
      true = config.kind == "kubernetes"
      {:ok, _} = Candidate.validate(config, input["pins"])
      {source, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: Path.expand("../..", __DIR__))
      true = String.trim(source) == input["pins"]["consumer_source_commit"]
      {:ok, control} = Control.start_link(config: config, checks: [], session_limit: 0)
      {:ok, tasks} = Task.Supervisor.start_link()
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, control)
      GenServer.call(control, {:issues, []})
      ctx = %{input: input, config: config, lane_id: lane.id, lane_version_id: lane.current_version_id, control: control, observations: observations, tasks: tasks, authority: self()}
      persist(ctx)

      try do
        :ok = Kubernetes.candidate_preflight(config, input["pins"], options(ctx))
        {:ok, before} = Provider.unrelated_snapshot(config, input["negative_control_paths"], options(ctx))
        GenServer.call(control, {:baseline, before})
        {:ok, inventory} = inventory(ctx)
        if input["mode"] == "run", do: true = inventory.records == [] and Map.get(inventory, :retained_guards, []) == []
        issues = issues(input, inventory.records)
        GenServer.call(control, {:issues, issues})
        GenServer.call(control, :allocation_started)
        update(ctx, %{status: "running"})

        try do
          if input["mode"] == "run" do
            start_runtime(ctx)
            :ok = await(input["timeout_ms"], fn -> Agent.get(observations, &(&1.runner == "passed")) end)
            update(ctx, %{status: "non_model_probe_passed"})
          end
        after
          cleanup(ctx, issues)
        end

        {:ok, after_snapshot} = Provider.unrelated_snapshot(config, input["negative_control_paths"], options(ctx))
        true = Control.unrelated_unchanged?(GenServer.call(control, :snapshot), after_snapshot)
        final = Agent.get(observations, & &1)
        true = final.cleanup == "complete"
        true = Map.get(final, :guard_observation_incomplete, false) == false
        if input["mode"] == "run", do: true = Map.get(final, :retained_guards, []) != []
        update(ctx, %{status: "candidate_stage_complete", unrelated_unchanged: true})
        {:ok, input["output_path"]}
      rescue
        _ ->
          update(ctx, %{status: "candidate_stage_failed"})
          {:error, :candidate_stage_failed}
      catch
        _, _ ->
          update(ctx, %{status: "candidate_stage_interrupted"})
          {:error, :candidate_stage_interrupted}
      after
        stop_runtime()
        persist(ctx)
        GenServer.stop(control)
        Supervisor.stop(tasks)
      end
    rescue
      _ ->
        write_bootstrap_failure(input)
        {:error, :candidate_setup_failed}
    catch
      _, _ ->
        write_bootstrap_failure(input)
        {:error, :candidate_setup_interrupted}
    after
      stop_runtime()
      restore(:memory_tracker_issues, original.issues)
      restore(:memory_tracker_recipient, original.recipient)
      File.rm(workflow)
      Agent.stop(observations)
    end
  end

  defp candidate_workflow(raw, deployment, workers, backend) do
    agent = %{"max_concurrent_agents" => workers, "backend" => backend || "codex", "in_progress_state" => "", "max_turns" => 1}

    raw
    |> Map.put("tracker", %{"kind" => "memory", "active_states" => ["Candidate"], "terminal_states" => ["Done"]})
    |> Map.put("hooks", %{})
    |> Map.put("polling", %{"interval_ms" => 1_000})
    |> Map.put("agent", agent)
    |> Map.put("claude", %{"command" => "/opt/symphony-worker/bin/claude"})
    |> update_in(["worker", "environment"], &Map.merge(&1, %{"deployment_id" => deployment, "terminal_retention_ms" => 0}))
  end

  # The model task is deliberately trivial and self-evidencing: the agent writes a
  # nonce we chose into a file we name, so the probe can prove a real session did
  # real work in the guest rather than trusting the backend's own transcript.
  defp issues(%{"mode" => "run", "pins" => pins, "worker_count" => workers} = input, _) do
    for index <- 1..workers do
      suffix = Integer.to_string(index)

      %Issue{
        id: pins["deployment_id"] <> "-probe-" <> suffix,
        identifier: "CANDIDATE-" <> suffix,
        title: if(input["backend"], do: "Model candidate probe", else: "Non-model candidate probe"),
        description: model_task(input, index),
        state: "Candidate",
        priority: index,
        dispatchable: true
      }
    end
  end

  defp issues(_, records) do
    Enum.map(records, &%Issue{id: &1.issue_id, identifier: &1.issue_identifier, title: "Candidate cleanup", state: "Done", dispatchable: false})
  end

  defp model_task(%{"backend" => backend, "pins" => pins}, index) when is_binary(backend) do
    "Create a file named candidate-probe.txt in the current directory. " <>
      "Its only contents must be exactly this token, with no other text: " <>
      model_nonce(pins["deployment_id"], index) <> "\nThen stop."
  end

  defp model_task(_input, _index), do: nil

  def model_nonce(deployment_id, index),
    do: "SYMPHONY-" <> (:crypto.hash(:sha256, deployment_id <> "/" <> Integer.to_string(index)) |> Base.encode16(case: :lower) |> binary_part(0, 24))

  defp start_runtime(ctx) do
    operation = fn adapter, config, entry, op, opts ->
      true = adapter == Kubernetes and config == ctx.config
      if entry, do: capture(ctx, {:ok, entry.record})
      timeout = if op in [:stop, :destroy], do: config.shutdown_timeout_ms, else: config.startup_timeout_ms
      opts = opts |> Keyword.put_new(:timeout_ms, timeout) |> Keyword.put(:candidate_baseline, ctx.input["pins"])
      callbacks = %{armed?: fn _ -> false end, disarm: fn _ -> :ok end, event: fn event -> GenServer.call(ctx.control, {:event, event}) end}
      opts = Provider.fault_options(config, entry, op, opts, callbacks)

      result =
        if op == :discover do
          with :ok <- Kubernetes.candidate_preflight(config, ctx.input["pins"], opts), do: Kubernetes.discover(config, opts)
        else
          Operations.run(Kubernetes, config, entry, op, opts)
        end

      capture(ctx, result)
      result
    end

    runner = fn issue, recipient, opts ->
      :ok = GenServer.call(ctx.control, {:event, %{event: :runner_invocation, issue_id: issue.id, options: opts}})
      %ExecutionContext{mode: :managed, connection: %{target: target}, environment: %{config: config, record: record}} = context = opts[:execution_context]
      true = ExecutionContext.managed(config, record, context.connection) == context

      if ctx.input["backend"] do
        model_probe(ctx, issue, recipient, opts, target, record)
      else
        non_model_probe(ctx, target, record)
      end
    end

    {:ok, runtime} =
      AgentRuntimeSupervisor.start_link(lane_id: ctx.lane_id, name: @runtime, task_supervisor_name: @tasks, orchestrator_name: @scheduler, environment_operation_fun: operation, runner_fun: runner)

    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)
      runtime_ref = Process.monitor(runtime)

      receive do
        {:DOWN, ^ref, :process, ^owner, _} -> Process.exit(runtime, :kill)
        {:DOWN, ^runtime_ref, :process, ^runtime, _} -> :ok
      end
    end)

    Orchestrator.request_refresh(@scheduler)
  end

  defp cleanup(ctx, issues) do
    stop_runtime()
    update(ctx, %{cleanup: "unknown"})
    GenServer.call(ctx.control, {:issues, Enum.map(issues, &%{&1 | state: "Done", dispatchable: false})})
    start_runtime(ctx)

    result =
      await(ctx.input["cleanup_timeout_ms"], fn ->
        state = :sys.get_state(@scheduler, 2_000)

        case inventory(ctx) do
          {:ok, %{records: [], live_worker_counts: counts}} ->
            state.environment_guard == nil and map_size(state.environment_jobs) == 0 and map_size(state.environment_entries) == 0 and Enum.all?(counts, fn {_, count} -> count == 0 end)

          _ ->
            false
        end
      end)

    stop_runtime()
    if result == :ok, do: update(ctx, %{cleanup: "complete"})
  rescue
    _ -> update(ctx, %{cleanup: "unknown"})
  catch
    _, _ -> update(ctx, %{cleanup: "unknown"})
  end

  defp inventory(ctx) do
    result = Provider.inventory(ctx.config, options(ctx))
    GenServer.call(ctx.control, {:event, %{event: :inventory_observation, result: result}})
    capture_guards(ctx)
    persist(ctx)
    result
  end

  defp non_model_probe(ctx, target, record) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)

    script =
      "set -eu; umask 077; mkdir -p " <>
        quote_shell(record.workspace_path) <>
        "; cd " <>
        quote_shell(record.workspace_path) <>
        "; printf %s " <>
        quote_shell(nonce) <>
        " > .symphony-candidate-probe; test \"$(cat .symphony-candidate-probe)\" = " <>
        quote_shell(nonce) <>
        "; rm .symphony-candidate-probe; printf %s " <> quote_shell(nonce)

    {:ok, %{status: 0, output: ^nonce}} =
      Command.run(target.executable, target.prefix ++ [SSH.remote_shell_command(script)],
        env: target.env,
        timeout_ms: 30_000,
        max_output_bytes: 4096,
        task_supervisor: ctx.tasks
      )

    update(ctx, %{runner: "passed"})
    hold(ctx)
  end

  # A real backend session in the guest. The transcript is the backend's own claim,
  # so it is not the evidence: the file the agent was asked to write is read back
  # over the managed connection and must carry the nonce we chose.
  defp model_probe(ctx, issue, recipient, opts, target, record) do
    started = System.monotonic_time(:millisecond)
    result = AgentRunner.run(issue, recipient, opts)
    elapsed = System.monotonic_time(:millisecond) - started
    index = issue.identifier |> String.split("-") |> List.last() |> String.to_integer()
    expected = model_nonce(ctx.input["pins"]["deployment_id"], index)

    read =
      Command.run(
        target.executable,
        target.prefix ++ [SSH.remote_shell_command("cd " <> quote_shell(record.workspace_path) <> " && cat candidate-probe.txt")],
        env: target.env,
        timeout_ms: 30_000,
        max_output_bytes: 4096,
        task_supervisor: ctx.tasks
      )

    observed =
      case read do
        {:ok, %{status: 0, output: output}} -> String.trim(output)
        _ -> nil
      end

    GenServer.call(
      ctx.control,
      {:event, %{event: :model_session, issue_id: issue.id, backend: ctx.input["backend"], elapsed_ms: elapsed, dispatch: elem_tag(result), artifact_matched: observed == expected}}
    )

    if observed == expected, do: update(ctx, %{runner: "passed"}), else: update(ctx, %{runner: "failed"})
    hold(ctx)
  end

  defp elem_tag({tag, _}), do: tag
  defp elem_tag(tag), do: tag

  # Remain a real occupied runner until the authority initiates terminal cleanup.
  defp hold(ctx) do
    receive do
      :candidate_release -> :ok
    after
      ctx.input["timeout_ms"] -> :ok
    end
  end

  defp capture(ctx, result) do
    GenServer.call(ctx.control, {:event, %{event: :record_observation, result: result}})

    records =
      case result do
        {:ok, %ExecutionContext{environment: %{record: record}}} -> [record]
        {:ok, %{metadata: _} = record} -> [record]
        {:ok, records} when is_list(records) -> records
        {:error, _, %{metadata: _} = record} -> [record]
        _ -> []
      end

    observations = records |> Enum.map(&Evidence.record(&1, ctx.config)) |> Enum.reject(&is_nil/1)

    Agent.update(ctx.observations, &Map.update!(&1, :protocol_observations, fn prior -> Enum.uniq(prior ++ observations) end))
    persist(ctx)
  end

  defp capture_guards(ctx) do
    ns = URI.encode(ctx.input["pins"]["namespace"], &URI.char_unreserved?/1)

    case Client.list(ctx.config, "/api/v1/namespaces/#{ns}/configmaps", options(ctx)) do
      {:ok, objects} ->
        observations = objects |> Enum.map(&Evidence.guard(&1, ctx.config)) |> Enum.reject(&is_nil/1)

        retained = for observation <- observations, observation["observed_receipt"]["phase"] == "Complete", do: Map.put(observation["resource"], "phase", "Complete")

        Agent.update(ctx.observations, fn prior ->
          prior |> Map.update(:guard_observations, observations, &Enum.uniq(&1 ++ observations)) |> Map.put(:retained_guards, retained)
        end)

      _ ->
        Agent.update(ctx.observations, &Map.put(&1, :guard_observation_incomplete, true))
    end
  end

  defp persist(ctx) do
    GenServer.call(
      ctx.control,
      {:persist,
       fn state ->
         evidence =
           Agent.get(ctx.observations, & &1)
           |> Map.merge(%{
             stage: "candidate-unqualified",
             qualified: false,
             backend_sessions: Enum.count(state.events, &(&1[:event] == :model_session or &1["event"] == "model_session")),
             artifact: Candidate.artifact_identity(),
             runner_sha256: ctx.input["runner_sha256"],
             pins: ctx.input["pins"],
             mode: ctx.input["mode"],
             lane_id: ctx.lane_id,
             lane_version_id: ctx.lane_version_id,
             support_sha256: @support_sha256,
             production_allocation: "stopped",
             physical_fault_and_storage_fault_qualification: "not_performed",
             allocation_started: state.allocation_started,
             inventory_complete: state.inventory_complete,
             remaining_owned_resources: state.observed_resources,
             captured_resources: state.captured_resources,
             unrelated_baseline: state.baseline,
             runner_rejected: state.runner_rejected,
             events: state.events
           })

         atomic_write(ctx.input["output_path"], evidence)
       end}
    )
  end

  defp update(ctx, values),
    do:
      (
        Agent.update(ctx.observations, &Map.merge(&1, values))
        :ok = persist(ctx)
      )

  defp options(ctx), do: [candidate_baseline: ctx.input["pins"], timeout_ms: min(ctx.input["timeout_ms"], 60_000), task_supervisor: ctx.tasks, authority: ctx.authority]

  defp stop_runtime do
    if pid = Process.whereis(@runtime), do: Supervisor.stop(pid, :normal, 10_000)
  end

  defp await(timeout, fun), do: wait_until(System.monotonic_time(:millisecond) + timeout, fun)

  defp wait_until(deadline, fun) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :candidate_deadline}

      true ->
        Process.sleep(250)
        wait_until(deadline, fun)
    end
  end

  defp atomic_write(path, evidence) do
    temp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    File.write!(temp, Jason.encode!(evidence, pretty: true), [:exclusive])
    File.chmod!(temp, 0o600)
    File.rename!(temp, path)
  end

  defp write_bootstrap_failure(input) do
    evidence =
      case File.read(input["output_path"]) do
        {:ok, bytes} ->
          case Jason.decode(bytes) do
            {:ok, value} when is_map(value) -> value
            _ -> %{}
          end

        _ ->
          %{}
      end

    atomic_write(
      input["output_path"],
      Map.merge(evidence, %{"stage" => "candidate-unqualified", "qualified" => false, "status" => "harness_failed", "backend_sessions" => 0, "production_allocation" => "stopped"})
    )
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp restore(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
