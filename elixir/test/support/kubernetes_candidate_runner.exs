if Mix.env() != :test, do: raise("candidate runner requires a MIX_ENV=test artifact")
Code.require_file("managed_environment_fixture/provider.exs", __DIR__)
Code.require_file("managed_environment_fixture/control.exs", __DIR__)
Code.require_file("kubernetes_candidate_evidence.exs", __DIR__)

defmodule SymphonyElixir.KubernetesCandidateRunner do
  @moduledoc false
  alias SymphonyElixir.{AgentRunner, AgentRuntimeSupervisor, ExecutionContext, Lanes, LaneStore, Orchestrator, SSH}
  alias SymphonyElixir.ExecutionEnvironment.{Command, Kubernetes, Operations}
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.{Candidate, Client}
  alias SymphonyElixir.ExecutionEnvironment.Lifecycle
  alias SymphonyElixir.KubernetesCandidateEvidence, as: Evidence
  alias SymphonyElixir.ManagedEnvironmentFixture.{Control, Provider}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @runtime __MODULE__.Runtime
  @scheduler __MODULE__.Scheduler
  @tasks __MODULE__.Tasks
  @scheduler_observation_limit 32
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
         true <- authorized_backend?(input),
         true <- authorized_mode?(input),
         true <- is_map(input["pins"]),
         true <- Enum.all?(~w(workflow_path output_path), &(is_binary(input[&1]) and Path.type(input[&1]) == :absolute)),
         true <- Enum.all?(~w(timeout_ms cleanup_timeout_ms), &(is_integer(input[&1]) and input[&1] in 1_000..900_000)),
         true <- is_integer(input["worker_count"]) and input["worker_count"] in 1..5,
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

  defp authorized_backend?(input) do
    input["authorization"] in ["disposable-namespace-non-model", "disposable-namespace-model"] and
      input["backend"] in [nil, "claude", "codex"] and
      (input["backend"] == nil or input["authorization"] == "disposable-namespace-model")
  end

  # A held probe exists only to keep one real non-model environment occupied across a restart.
  defp authorized_mode?(input) do
    input["mode"] in ["run", "cleanup", "hold"] and
      (input["mode"] != "hold" or
         (input["authorization"] == "disposable-namespace-non-model" and input["backend"] == nil and input["worker_count"] == 1))
  end

  defp run(input) do
    output = input["output_path"]
    directory = Path.dirname(output)
    # Evidence is always a fresh file in a caller-owned private directory; never overwrite a prior receipt.
    with {:ok, stat} <- File.lstat(directory),
         true <- stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700,
         {:ok, file} <- File.open(output, [:write, :exclusive, :binary]) do
      File.chmod!(output, 0o600)
      IO.binwrite(file, Jason.encode!(Map.merge(%{stage: "candidate-unqualified", qualified: false, status: "initializing"}, model_counts(%{}))))
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

    {:ok, observations} =
      Agent.start_link(fn ->
        %{
          status: "initializing",
          protocol_observations: [],
          cleanup: "not_started",
          runner: "not_run",
          workers: %{},
          dispatches: %{}
        }
      end)

    try do
      # Memory tracker state is application-global; never share this harness with another lane.
      true = LaneStore.list() == []
      {:ok, document} = Workflow.load(input["workflow_path"])
      raw = candidate_workflow(document.config, input["pins"]["deployment_id"], input["worker_count"], input["backend"])
      prompt = if input["backend"], do: "{{ issue.description }}\n", else: "Non-model candidate lifecycle probe.\n"
      :ok = File.write(workflow, "---\n" <> Jason.encode!(raw) <> "\n---\n" <> prompt, [:exclusive])
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
        if probe_mode?(input), do: true = inventory.records == [] and Map.get(inventory, :retained_guards, []) == []
        issues = issues(input, inventory.records)
        GenServer.call(control, {:issues, issues})
        GenServer.call(control, :allocation_started)
        update(ctx, %{status: "running", workers: Map.new(issues, &{&1.id, %{outcome: "pending", environment_id: nil}})})

        try do
          if probe_mode?(input) do
            start_runtime(ctx)
            :ok = await(input["timeout_ms"], fn -> Agent.get(observations, &(&1.runner in ["passed", "failed"])) end)
            true = Agent.get(observations, &(&1.runner == "passed"))
            update(ctx, %{status: probe_status(input)})
            hold_until_timeout(ctx)
          end
        after
          cleanup(ctx, issues)
        end

        {:ok, after_snapshot} = Provider.unrelated_snapshot(config, input["negative_control_paths"], options(ctx))
        true = Control.unrelated_unchanged?(GenServer.call(control, :snapshot), after_snapshot)
        final = Agent.get(observations, & &1)
        true = final.cleanup == "complete"
        true = Map.get(final, :guard_observation_incomplete, false) == false
        if probe_mode?(input), do: true = Map.get(final, :retained_guards, []) != []
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
    # The guest login PATH excludes these installed agent and tracker MCP executables.
    |> Map.put("claude", %{"command" => "/opt/symphony-worker/bin/claude", "linear_mcp_command" => "/opt/symphony-worker/bin/symphony"})
    # Pin codex's invocation for the same reason claude's is pinned: the candidate run must not
    # inherit how the agent under test is launched from an operator-supplied workflow. The
    # `app-server` subcommand is the load-bearing part — a bare `codex` starts the interactive
    # TUI, which exits 1 with "stdin is not a terminal" the moment it is driven over a pipe.
    |> Map.put("codex", %{"command" => "/usr/local/bin/codex app-server"})
    |> update_in(["worker", "environment"], &Map.merge(&1, %{"deployment_id" => deployment, "terminal_retention_ms" => 0}))
  end

  # The model task is deliberately trivial and self-evidencing: the agent writes a
  # nonce we chose into a file we name, so the probe can prove a real session did
  # real work in the guest rather than trusting the backend's own transcript.
  defp issues(%{"mode" => mode, "pins" => pins, "worker_count" => workers} = input, _) when mode in ["run", "hold"] do
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
          candidate_discover(ctx, config, opts)
        else
          Operations.run(Kubernetes, config, entry, op, opts)
        end

      capture(ctx, result)
      result
    end

    runner = fn issue, recipient, opts ->
      :ok = GenServer.call(ctx.control, {:event, %{event: :runner_invocation, issue_id: issue.id, options: opts}})
      context = opts[:execution_context]

      %ExecutionContext{
        mode: :managed,
        connection: %{target: target},
        environment: %{config: config, record: record}
      } = context

      true = ExecutionContext.managed(config, record, context.connection) == context

      run_probe(ctx, issue, recipient, opts, target, record)
    end

    {:ok, runtime} =
      AgentRuntimeSupervisor.start_link(
        lane_id: ctx.lane_id,
        name: @runtime,
        task_supervisor_name: @tasks,
        orchestrator_name: @scheduler,
        environment_operation_fun: operation,
        runner_fun: runner
      )

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

  defp candidate_discover(ctx, config, opts) do
    with :ok <- Kubernetes.candidate_preflight(config, ctx.input["pins"], opts), do: Kubernetes.discover(config, opts)
  end

  defp cleanup(ctx, issues) do
    stop_runtime()
    update(ctx, %{cleanup: "unknown"})
    GenServer.call(ctx.control, {:issues, Enum.map(issues, &%{&1 | state: "Done", dispatchable: false})})
    start_runtime(ctx)

    result =
      await(ctx.input["cleanup_timeout_ms"], fn ->
        state = :sys.get_state(@scheduler, 2_000)
        # Persist the held barrier before inventory can block on pending deletion.
        capture_scheduler(ctx, state, nil)
        observed = inventory(ctx)
        state = :sys.get_state(@scheduler, 2_000)
        capture_scheduler(ctx, state, live_worker_counts(observed))

        case observed do
          {:ok, %{records: [], live_worker_counts: counts}} ->
            state.environment_guard == nil and map_size(state.environment_jobs) == 0 and map_size(state.environment_entries) == 0 and Enum.all?(counts, &(elem(&1, 1) == 0))

          _ ->
            false
        end
      end)

    stop_runtime()
    :ok = await(5_000, fn -> Agent.get(ctx.observations, &Enum.all?(&1.dispatches, fn {_, dispatch} -> Map.has_key?(dispatch, "ended_at") end)) end)
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

    %{outcome: "passed"}
  end

  # A real backend session in the guest. The transcript is the backend's own claim,
  # so it is not the evidence: the file the agent was asked to write is read back
  # over the managed connection and must carry the nonce we chose.
  defp model_probe(ctx, issue, recipient, opts, target, record) do
    result = AgentRunner.run(issue, recipient, opts)
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

    %{
      outcome: if(result == :ok and observed == expected, do: "passed", else: "failed"),
      dispatch: elem_tag(result),
      artifact_matched: observed == expected
    }
  end

  defp elem_tag({tag, _}), do: tag
  defp elem_tag(tag), do: tag

  def worker_result(state, issue_id, environment_id, outcome) when outcome in ["passed", "failed"] do
    previous = Map.fetch!(state.workers, issue_id)
    result = if previous.outcome == "failed", do: previous, else: %{outcome: outcome, environment_id: environment_id}
    workers = Map.put(state.workers, issue_id, result)
    results = Map.values(workers)

    runner =
      cond do
        Enum.any?(results, &(&1.outcome == "failed")) ->
          "failed"

        Enum.all?(results, &(&1.outcome == "passed")) and
            length(Enum.uniq_by(results, & &1.environment_id)) == map_size(workers) ->
          "passed"

        true ->
          "running"
      end

    %{state | workers: workers, runner: runner}
  end

  def model_dispatch_ready?(state) do
    active = for {_, dispatch} <- state.dispatches, not Map.has_key?(dispatch, "ended_at"), do: dispatch

    state.runner != "failed" and
      Enum.sort(Enum.map(active, & &1.issue_id)) == Enum.sort(Map.keys(state.workers)) and
      length(Enum.uniq_by(active, & &1.environment_id)) == map_size(state.workers)
  end

  def run_probe(ctx, issue, recipient, opts, target, record) do
    observer = observe_dispatch(ctx, self(), recipient, issue.id, opts[:attempt_id], record.key)
    monitor = Process.monitor(observer)

    if ctx.input["backend"] do
      :ok = await(ctx.input["timeout_ms"], fn -> Agent.get(ctx.observations, &model_dispatch_ready?/1) end)
    end

    result =
      if ctx.input["backend"],
        do: model_probe(ctx, issue, observer, opts, target, record),
        else: non_model_probe(ctx, target, record)

    ref = make_ref()
    send(observer, {:probe_finished, self(), ref, result})

    receive do
      {^ref, :recorded} ->
        Process.demonitor(monitor, [:flush])
        hold(ctx)

      {:DOWN, ^monitor, :process, ^observer, _reason} ->
        exit(:candidate_observer_failed)
    end
  end

  def observe_dispatch(ctx, owner, recipient, issue_id, attempt_id, environment_id) do
    dispatch = %{issue_id: issue_id, environment_id: environment_id, backend: ctx.input["backend"], lifecycle: []}
    dispatch = Map.merge(dispatch, observation_time("started"))
    change(ctx, &put_in(&1, [:dispatches, attempt_id], dispatch))

    {:ok, observer} =
      Task.Supervisor.start_child(ctx.tasks, fn ->
        ref = Process.monitor(owner)
        observe_messages(ctx, owner, ref, recipient, issue_id, attempt_id, environment_id)
      end)

    observer
  end

  defp observe_messages(ctx, owner, ref, recipient, issue_id, attempt_id, environment_id) do
    receive do
      {:codex_worker_update, ^issue_id, ^attempt_id, message} = update ->
        if is_pid(recipient), do: send(recipient, update)

        if message[:event] in [
             :session_started,
             :completed,
             :turn_completed,
             :error,
             :turn_failed,
             :turn_cancelled,
             :blocked,
             :attempt_blocked
           ] do
          event = Map.take(message, [:event, :session_id]) |> Map.merge(observation_time("observed"))
          change(ctx, &update_in(&1, [:dispatches, attempt_id, :lifecycle], fn events -> events ++ [event] end))
        end

        observe_messages(ctx, owner, ref, recipient, issue_id, attempt_id, environment_id)

      {:probe_finished, ^owner, reply_ref, result} ->
        change(ctx, fn state ->
          state
          |> worker_result(issue_id, environment_id, result.outcome)
          |> update_in([:dispatches, attempt_id], &Map.merge(&1, Map.merge(result, observation_time("probe_finished"))))
        end)

        send(owner, {reply_ref, :recorded})
        observe_messages(ctx, owner, ref, recipient, issue_id, attempt_id, environment_id)

      {:DOWN, ^ref, :process, ^owner, reason} ->
        change(ctx, fn state ->
          dispatch = state.dispatches[attempt_id]

          state =
            if Map.has_key?(dispatch, :outcome) do
              state
            else
              worker_result(state, issue_id, environment_id, "failed")
            end

          ending =
            observation_time("ended")
            |> Map.put(:termination, if(reason in [:normal, :shutdown, :killed], do: reason, else: :abnormal))
            # The exit reason is the only account of why a dispatch died. Classifying it as
            # :abnormal and dropping it makes a failed run undiagnosable from its own evidence,
            # which costs a fresh single-use namespace per hypothesis. Inspected, not raw, so the
            # evidence stays JSON-encodable, and truncated so a large reason cannot bloat it.
            |> Map.put(:termination_reason, String.slice(inspect(reason, limit: 50, printable_limit: 2_048), 0, 4_096))

          update_in(state, [:dispatches, attempt_id], &(&1 |> Map.merge(ending) |> Map.put_new(:outcome, "failed")))
        end)

      message ->
        if is_pid(recipient), do: send(recipient, message)
        observe_messages(ctx, owner, ref, recipient, issue_id, attempt_id, environment_id)
    end
  end

  defp observation_time(prefix) do
    %{
      (prefix <> "_at") => DateTime.to_iso8601(DateTime.utc_now()),
      (prefix <> "_monotonic_ms") => System.monotonic_time(:millisecond)
    }
  end

  defp change(ctx, fun) do
    Agent.update(ctx.observations, fun)
    :ok = persist(ctx)
  end

  def model_counts(dispatches) do
    sessions =
      for {attempt_id, dispatch} <- dispatches,
          event <- dispatch.lifecycle,
          is_binary(event[:session_id]),
          do: {attempt_id, event.session_id, event.event}

    %{
      model_probes_completed: Enum.count(dispatches, fn {_, dispatch} -> is_binary(dispatch.backend) and Map.has_key?(dispatch, "probe_finished_at") end),
      model_sessions_started: sessions |> Enum.filter(&(elem(&1, 2) == :session_started)) |> Enum.uniq_by(&{elem(&1, 0), elem(&1, 1)}) |> length(),
      model_sessions_completed: sessions |> Enum.filter(&(elem(&1, 2) in [:completed, :turn_completed])) |> Enum.uniq_by(&{elem(&1, 0), elem(&1, 1)}) |> length()
    }
  end

  # Remain a real occupied runner until the authority initiates terminal cleanup.
  defp hold(ctx) do
    receive do
      :candidate_release -> :ok
    after
      ctx.input["timeout_ms"] -> :ok
    end
  end

  defp probe_mode?(input), do: input["mode"] in ["run", "hold"]
  defp probe_status(%{"mode" => "hold"}), do: "probe_held"
  defp probe_status(_input), do: "probe_passed"

  # A held probe stays a real occupied runner so the authority can kill this whole process
  # mid-hold; reaching the timeout instead falls through to the same conservative cleanup.
  defp hold_until_timeout(%{input: %{"mode" => "hold"} = input}), do: await(input["timeout_ms"], fn -> false end)
  defp hold_until_timeout(_ctx), do: :ok
  defp live_worker_counts({:ok, %{live_worker_counts: counts}}), do: counts
  defp live_worker_counts(_), do: nil

  # Scheduler-side capacity facts only: booleans, counts and identity strings that the
  # actual State and Lifecycle.Entry types already carry. Never refs, pids, credentials
  # or config, so a receipt can be read by the authority without leaking runtime handles.
  defp scheduler_observation(%Orchestrator.State{} = state, counts) do
    entries =
      state.environment_entries
      |> Map.values()
      |> Enum.map(&entry_observation/1)
      |> Enum.sort_by(& &1.issue_id)

    sample = %{
      guard_held: is_reference(state.environment_guard),
      discovery: discovery_state(state.environment_discovery),
      jobs: map_size(state.environment_jobs),
      entries: entries,
      live_worker_counts: counts
    }

    Map.merge(sample, observation_time("observed"))
  end

  defp record_scheduler_observation(history, observation) do
    signature = scheduler_signature(observation)
    duplicate? = Enum.any?(history, &(scheduler_signature(&1) == signature))
    if duplicate? or length(history) >= @scheduler_observation_limit, do: history, else: history ++ [observation]
  end

  defp capture_scheduler(ctx, state, counts) do
    observation = scheduler_observation(state, counts)
    change(ctx, &Map.put(&1, :scheduler_observations, record_scheduler_observation(Map.get(&1, :scheduler_observations, []), observation)))
  end

  defp entry_observation(%Lifecycle.Entry{record: record} = entry),
    do: %{issue_id: record.issue_id, environment_id: record.key, status: Atom.to_string(entry.phase), occupied: Lifecycle.occupied?(entry)}

  defp discovery_state(state) when state in [:ready, :pending], do: Atom.to_string(state)
  defp discovery_state({:error, _}), do: "error"
  defp discovery_state(_), do: "unknown"
  defp scheduler_signature(observation), do: Map.take(observation, [:guard_held, :discovery, :jobs, :entries, :live_worker_counts])

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
         observations = Agent.get(ctx.observations, & &1)

         evidence =
           observations
           |> Map.merge(model_counts(observations.dispatches))
           |> Map.merge(%{
             stage: "candidate-unqualified",
             qualified: false,
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
      Map.merge(evidence, %{"stage" => "candidate-unqualified", "qualified" => false, "status" => "harness_failed", "production_allocation" => "stopped"})
    )
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp restore(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
