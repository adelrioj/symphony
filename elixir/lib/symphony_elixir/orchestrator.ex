# credo:disable-for-this-file Credo.Check.Refactor.FunctionArity
defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to the selected agent backend.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.BlockedIssue
  alias SymphonyElixir.Config
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.ExecutionEnvironment.Lifecycle
  alias SymphonyElixir.ExecutionEnvironment.Lifecycle.Entry
  alias SymphonyElixir.ExecutionEnvironment.Operations
  alias SymphonyElixir.ExecutionEnvironment.Record
  alias SymphonyElixir.LaneContext
  alias SymphonyElixir.LaneStore
  alias SymphonyElixir.Runs
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workspace
  alias SymphonyElixirWeb.ObservabilityPubSub

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @derive {Inspect, only: [:poll_interval_ms, :max_concurrent_agents, :environment_discovery]}
    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :lane_id,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      environment_entries: %{},
      environment_jobs: %{},
      environment_discovery: :ready,
      environment_discovery_token: nil,
      environment_inventory_due_at_ms: nil,
      environment_config: nil,
      environment_identity: nil,
      environment_guard: nil,
      environment_store: nil,
      environment_operation_fun: &Operations.run/5,
      runner_fun: &AgentRunner.run/3,
      running: %{},
      dispatch_tokens: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      turn_exhaustions: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Keyword.put_new_lazy(opts, :lane_id, &LaneContext.current!/0)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    lane_id = Keyword.fetch!(opts, :lane_id)
    LaneContext.put(lane_id)

    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)

        state = %State{
          lane_id: lane_id,
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          environment_operation_fun: Keyword.get(opts, :environment_operation_fun, &Operations.run/5),
          runner_fun: Keyword.get(opts, :runner_fun, &AgentRunner.run/3),
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil
        }

        # LaneStore owns runtime startup; guard acquisition must happen after init
        # returns so the store is free to answer the first tick's request.
        if is_nil(EnvironmentConfig.runtime(config)), do: run_terminal_workspace_cleanup()
        state = schedule_tick(state, 0)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = state |> refresh_runtime_config() |> refresh_environment_inventory()

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = state |> refresh_runtime_config() |> refresh_environment_inventory()

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({ref, {operation_id, result}}, state) when is_reference(ref) do
    case Map.pop(state.environment_jobs, ref) do
      {nil, _} ->
        close_stale_prepared(result, state)
        {:noreply, state}

      {job, jobs} ->
        Process.demonitor(ref, [:flush])
        state = %{state | environment_jobs: jobs}

        state =
          if job.operation_id == operation_id do
            environment_result(state, job, result)
          else
            close_stale_prepared(result, state)
            environment_task_failed(state, job)
          end

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{environment_jobs: jobs} = state) when is_map_key(jobs, ref) do
    {job, jobs} = Map.pop(jobs, ref)
    {:noreply, environment_task_failed(%{state | environment_jobs: jobs}, job)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        Runs.finished(running_entry.attempt_id, run_status(reason, running_entry))
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          with_lane_snapshot(Map.get(running_entry, :lane_snapshot), fn ->
            complete_running_entry(state, issue_id, running_entry, reason, session_id)
          end)

        state =
          if managed_entry?(state, issue_id),
            do: state,
            else: release_dispatch_token(state, issue_id, Map.get(running_entry, :dispatch_token))

        Logger.info("Agent task finished for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, attempt_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      %{attempt_id: ^attempt_id} = running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, attempt_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      %{attempt_id: ^attempt_id} = running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        Runs.event(
          attempt_id,
          %{event: update.event, message: updated_running_entry.last_codex_message, session_id: updated_running_entry.session_id},
          token_delta,
          Map.get(updated_running_entry, :turn_count, 0)
        )

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _attempt_id, _update}, state), do: {:noreply, state}

  def handle_info({:agent_turns_exhausted, issue_id, attempt_id, state_name}, %{running: running} = state)
      when is_binary(issue_id) and is_binary(state_name) do
    case Map.get(running, issue_id) do
      %{attempt_id: ^attempt_id} = running_entry ->
        running_entry = Map.put(running_entry, :turns_exhausted_state, state_name)
        {:noreply, %{state | running: Map.put(running, issue_id, running_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:lane_updated, lane_id}, %{lane_id: lane_id} = state) do
    state = refresh_runtime_config(state)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    Logger.debug("Orchestrator ignored an unrecognized message")
    {:noreply, state}
  end

  defp run_status(_reason, %{attempt_outcome: :blocked}), do: "blocked"
  defp run_status(:normal, %{turns_exhausted_state: name}) when is_binary(name), do: "turns_exhausted"
  defp run_status(:normal, entry), do: if(input_required_blocker?(entry), do: "blocked", else: "done")
  defp run_status(_reason, entry), do: if(input_required_blocker?(entry), do: "blocked", else: "failed")

  defp complete_running_entry(state, issue_id, running_entry, reason, session_id) do
    if managed_entry?(state, issue_id) do
      managed_stop(state, issue_id, {:agent_down, safe_agent_reason(reason), running_entry})
    else
      handle_agent_down(reason, state, issue_id, running_entry, session_id)
    end
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      handle_agent_completion(state, issue_id, running_entry, session_id)
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      execution_context: Map.get(running_entry, :execution_context),
      lane_snapshot: Map.get(running_entry, :lane_snapshot)
    })
  end

  # A worker that exits normally without leaving its tracker state has burned its whole
  # turn budget without progress. Retrying such a run forever is a token furnace, so the
  # issue is parked as blocked once it exhausts agent.max_turn_exhaustions in a row.
  defp handle_agent_completion(state, issue_id, running_entry, session_id) do
    case record_turn_exhaustion(state, issue_id, running_entry) do
      {:exhausted, count, state} ->
        block_exhausted_agent_down(state, issue_id, running_entry, session_id, count)

      {:continue, state} ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path),
          execution_context: Map.get(running_entry, :execution_context),
          lane_snapshot: Map.get(running_entry, :lane_snapshot)
        })
    end
  end

  defp record_turn_exhaustion(%State{} = state, issue_id, running_entry) do
    case {Config.settings!().agent.max_turn_exhaustions, Map.get(running_entry, :turns_exhausted_state)} do
      {0, _} ->
        {:continue, clear_turn_exhaustions(state, issue_id)}

      {limit, state_name} when is_binary(state_name) ->
        head = workspace_head(running_entry)
        count = next_turn_exhaustion_count(state, issue_id, state_name, head)

        state = %{
          state
          | turn_exhaustions:
              Map.put(state.turn_exhaustions, issue_id, %{
                state: normalize_issue_state(state_name),
                count: count,
                head: head
              })
        }

        if count >= limit do
          {:exhausted, count, state}
        else
          {:continue, state}
        end

      _ ->
        {:continue, clear_turn_exhaustions(state, issue_id)}
    end
  end

  # Exhausting the turn budget is not by itself a wedge. A stage that only leaves its
  # state once every task is done (subagent-driven development) ALWAYS burns its whole
  # budget, so counting exhaustions alone parks tickets that are advancing normally.
  # The distinguishing signal is the workspace HEAD: a run that exhausted its budget
  # and left HEAD exactly where the previous exhausted run left it did no committed
  # work, and only those runs accumulate toward max_turn_exhaustions.
  #
  # HEAD is nil when it cannot be read (no workspace recorded, a remote worker_host,
  # or git failing): unreadable falls back to the old exhaustion-only counting rather
  # than to never parking, so a wedge is still bounded.
  defp next_turn_exhaustion_count(%State{} = state, issue_id, state_name, head) do
    normalized_state = normalize_issue_state(state_name)

    case Map.get(state.turn_exhaustions, issue_id) do
      %{state: ^normalized_state, count: count, head: previous_head} when previous_head == head ->
        count + 1

      %{state: ^normalized_state, count: count} ->
        Logger.info("Turn budget exhausted for issue_id=#{issue_id} but the workspace advanced (#{inspect(head)}); resetting the exhaustion count from #{count}")

        1

      _ ->
        1
    end
  end

  defp workspace_head(running_entry) do
    with %ExecutionContext{mode: :local} = context <- Map.get(running_entry, :execution_context),
         path when is_binary(path) and path != "" <- Map.get(running_entry, :workspace_path),
         :ok <- Workspace.validate_workspace_path(path, context),
         {output, 0} <- System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      String.trim(output)
    else
      _ -> nil
    end
  end

  defp clear_turn_exhaustions(%State{} = state, issue_id) do
    %{state | turn_exhaustions: Map.delete(state.turn_exhaustions, issue_id)}
  end

  defp block_exhausted_agent_down(%State{} = state, issue_id, running_entry, session_id, count) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    issue_state = Map.get(running_entry, :turns_exhausted_state)
    max_turns = Config.settings!().agent.max_turns

    error = "reached agent.max_turns (#{max_turns}) #{count} runs in a row without leaving state=#{issue_state}"

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id}: #{error}")

    BlockedIssue.park(issue_id, identifier, blocked_park_detail(error, count, max_turns), session_id)

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp blocked_park_detail(error, count, max_turns) do
    """
    Symphony parked this work item: #{error}.

    Each of the last #{count} agent runs used all #{max_turns} of its turns, left the work item in the
    same state, and ended with the workspace on the same commit as the run before it — no committed
    work, so Symphony stopped restarting it. Split the remaining work into smaller items, raise
    `agent.max_turns`, or move this item back to an active state once it is workable again.
    """
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()
      |> reconcile_environments()

    with true <- managed_dispatch_ready?(state),
         :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_scope} ->
        Logger.error("Tracker scope missing in WORKFLOW.md: set tracker.provider.team_keys, tracker.provider.current_cycle, or tracker.provider.project_slug")
        state

      {:error, :missing_linear_team_keys} ->
        Logger.error("Tracker scope invalid in WORKFLOW.md: tracker.provider.current_cycle requires tracker.provider.team_keys")
        state

      {:error, :invalid_linear_team_keys} ->
        Logger.error("Tracker scope invalid in WORKFLOW.md: tracker.provider.team_keys must be a list of non-empty team keys")
        state

      {:error, :invalid_linear_current_cycle} ->
        Logger.error("Tracker scope invalid in WORKFLOW.md: tracker.provider.current_cycle must be true or false")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)

    state.running
    |> Enum.group_by(fn {_id, entry} -> get_in(entry, [:lane_snapshot, Access.key(:config_identity)]) || get_in(entry, [:lane_snapshot, Access.key(:version_id)]) end)
    |> Enum.reduce(state, fn {_config_identity, entries}, acc ->
      {_id, first} = hd(entries)
      ids = Enum.map(entries, &elem(&1, 0))

      with_lane_snapshot(Map.get(first, :lane_snapshot), fn ->
        refresh_running_issue_group(acc, ids)
      end)
    end)
  end

  defp refresh_running_issue_group(state, ids) do
    case Tracker.fetch_issues_by_ids(ids) do
      {:ok, issues} ->
        issues
        |> reconcile_running_issue_states(state, active_state_set(), terminal_state_set())
        |> reconcile_missing_running_issue_ids(ids, issues)

      {:error, reason} ->
        Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")
        state
    end
  end

  defp with_lane_snapshot(nil, fun), do: fun.()

  defp with_lane_snapshot(snapshot, fun) do
    lane_id = LaneContext.current!()
    previous = LaneContext.snapshot()
    LaneContext.install(snapshot)

    try do
      fun.()
    after
      case previous do
        {:ok, entry} -> LaneContext.install(entry)
        :error -> LaneContext.put(lane_id)
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        state |> observe_terminal(issue.id) |> terminate_running_issue(issue.id, true)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        unless managed_entry?(state, issue.id), do: cleanup_issue_workspace(issue, Map.get(state.blocked, issue.id, %{}))
        release_issue_claim(state, issue.id)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{environment_entries: entries} = state, issue_id, _cleanup_workspace) when is_map_key(entries, issue_id) do
    managed_stop(state, issue_id, :release)
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        Runs.finished(running_entry.attempt_id, "stopped")

        stop_running_task(pid, ref, state.task_supervisor)

        if cleanup_workspace do
          cleanup_issue_workspace(Map.get(running_entry, :issue, identifier), running_entry)
        end

        state = release_dispatch_token(state, issue_id, Map.get(running_entry, :dispatch_token))

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            turn_exhaustions: Map.delete(state.turn_exhaustions, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    now = DateTime.utc_now()

    Enum.reduce(state.running, state, fn {issue_id, entry}, acc ->
      with_lane_snapshot(Map.get(entry, :lane_snapshot), fn ->
        reconcile_stalled_running_issue(acc, issue_id, entry, now)
      end)
    end)
  end

  defp reconcile_stalled_running_issue(state, issue_id, entry, now) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms
    if timeout_ms > 0, do: maybe_restart_stalled_issue(state, issue_id, entry, now, timeout_ms), else: state
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_unmanaged_completion(issue_id, running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: identifier,
          issue_url: running_entry.issue.url,
          error: "stalled for #{elapsed_ms}ms without codex activity",
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path),
          execution_context: Map.get(running_entry, :execution_context),
          lane_snapshot: Map.get(running_entry, :lane_snapshot)
        })
      end
    else
      state
    end
  end

  defp record_unmanaged_completion(state, issue_id, running_entry) do
    if managed_entry?(state, issue_id), do: state, else: record_session_completion_totals(state, running_entry)
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :attempt_outcome) == :blocked or
      Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_running_task(pid, ref, task_supervisor) do
    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{environment_entries: entries} = state, issue_id, running_entry, error) when is_map_key(entries, issue_id) do
    Runs.finished(running_entry.attempt_id, "blocked")
    managed_stop(state, issue_id, {:block, running_entry, error})
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(
      Map.get(running_entry, :pid),
      Map.get(running_entry, :ref),
      state.task_supervisor
    )

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      execution_context: Map.get(running_entry, :execution_context),
      lane_snapshot: Map.get(running_entry, :lane_snapshot),
      session_id: running_entry_session_id(running_entry),
      error: error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    Runs.finished(running_entry.attempt_id, "blocked")

    state = release_dispatch_token(state, issue_id, Map.get(running_entry, :dispatch_token))

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        turn_exhaustions: Map.delete(state.turn_exhaustions, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, capacity_running(state)) and managed_issue_available?(state, issue.id) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{unknown_state?: true}} ->
        true

      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    # Only the label fields: the tracker struct also carries the resolved Linear API token,
    # which a FunctionClauseError on this hot path would inspect/1 into the log file.
    Issue.routable?(issue, Map.take(Config.settings!().tracker, [:required_labels, :any_labels]))
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case LaneStore.reserve_dispatch(state.lane_id) do
      {:ok, token, snapshot} ->
        with_lane_snapshot(snapshot, fn ->
          dispatch_issue_from_snapshot(state, issue, attempt, preferred_worker_host, token)
        end)

      {:error, reason} ->
        Logger.warning("Skipping dispatch; lane reservation failed lane_id=#{state.lane_id} reason=#{inspect(reason)}")
        state
    end
  end

  defp dispatch_issue_from_snapshot(state, issue, attempt, preferred_worker_host, token) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        case backend_module_for_dispatch(refreshed_issue) do
          {:ok, backend_module} ->
            do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, backend_module, token)

          :error ->
            release_dispatch_token(state, refreshed_issue.id, token)
        end

      {:skip, _reason} ->
        release_dispatch_token(state, issue.id, token)

      {:error, _reason} ->
        release_dispatch_token(state, issue.id, token)
    end
  end

  defp refresh_issue_for_dispatch(issue) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issues_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        {:ok, refreshed_issue}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp backend_module_for_dispatch(%Issue{} = issue) do
    with {:ok, backend_name} <- Config.agent_backend_for_state(issue.state),
         {:ok, backend_module} <- SymphonyElixir.Agent.module_for(backend_name) do
      {:ok, backend_module}
    else
      {:error, {:invalid_agent_backend, _state, value}} ->
        Logger.error("Skipping dispatch: invalid_agent_backend value=#{value} issue_id=#{issue.id} issue_identifier=#{issue.identifier}")
        :error
    end
  end

  # Symphony owns this move, not the agent. The prompt asked for it and an agent that spent its turn
  # budget elsewhere simply never made it, so a work item sat in the intake state for 25 minutes
  # while that agent built and tested a fix. Do not put it back in the prompt.
  #
  # It runs after the spawn succeeds, so a failed spawn leaves no item showing progress with nothing
  # behind it. A failed move is logged and nothing more: it is bookkeeping, not a precondition, and
  # no later poll retries it because the item is already claimed.
  #
  # `agent.in_progress_state` names the state. An empty value turns the move off: a lane that
  # dispatches from a review state must not hand its work item back to the lanes that poll
  # `In Progress`.
  defp claim_issue_state(%Issue{} = issue) do
    target = Config.settings!().agent.in_progress_state

    cond do
      target in [nil, ""] ->
        :ok

      issue.state == target ->
        :ok

      true ->
        case Tracker.update_issue_state(issue.id, target) do
          :ok ->
            Logger.info("Moved claimed issue to #{target}: #{issue_context(issue)}")

          {:error, reason} ->
            Logger.warning("Claim state move failed for #{issue_context(issue)}: #{inspect(reason)} (issue stays in state=#{issue.state}; the agent runs anyway)")
        end

        :ok
    end
  end

  defp do_dispatch_issue(%State{environment_config: config} = state, issue, attempt, _preferred_worker_host, backend_module, token) when not is_nil(config) do
    reserve_environment(state, issue, attempt, backend_module, token)
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, backend_module, token) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        release_dispatch_token(state, issue.id, token)

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, backend_module, token)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, backend_module, token) do
    context = static_execution_context(worker_host)
    attempt_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    spawn_issue_with_context(state, issue, attempt, recipient, backend_module, context, attempt_id, true, token)
  end

  defp spawn_issue_with_context(state, issue, attempt, recipient, backend_module, context, attempt_id, claim?, dispatch_token, reserved_snapshot \\ nil) do
    worker_host = context.worker_host
    runner = state.runner_fun
    {:ok, snapshot} = if(reserved_snapshot, do: {:ok, reserved_snapshot}, else: LaneContext.capture())
    lane_id = state.lane_id

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           LaneContext.install(snapshot)
           :ok = LaneStore.claim_dispatch(lane_id, dispatch_token)

           runner.(issue, recipient,
             attempt: attempt,
             execution_context: context,
             attempt_id: attempt_id,
             backend_module: backend_module
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Runs.started(%{
          lane_id: lane_id,
          lane_version_id: snapshot.version_id,
          execution_profile_id: snapshot.profile_id,
          config_identity: snapshot.config_identity,
          executor: snapshot.executor,
          owner_pid: self(),
          issue: issue,
          attempt_id: attempt_id,
          attempt: attempt,
          worker_ref: worker_host
        })

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        if claim?, do: claim_issue_state(issue)

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            attempt_id: attempt_id,
            execution_context: context,
            identifier: issue.identifier,
            issue: issue,
            lane_snapshot: snapshot,
            worker_host: worker_host,
            workspace_path: context.workspace_path,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            dispatch_token: dispatch_token,
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            dispatch_tokens: Map.delete(state.dispatch_tokens, issue.id),
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        state = release_dispatch_token(state, issue.id, dispatch_token)

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{environment_entries: entries} = state, issue_id, attempt, metadata) when is_map_key(entries, issue_id) do
    if Lifecycle.occupied?(entries[issue_id]) do
      managed_stop(state, issue_id, {:retry, attempt, metadata})
    else
      do_schedule_issue_retry(state, issue_id, attempt, metadata)
    end
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata), do: do_schedule_issue_retry(state, issue_id, attempt, metadata)

  defp do_schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    lane_snapshot = Map.get(metadata, :lane_snapshot) || Map.get(previous_retry, :lane_snapshot)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            execution_context: Map.get(metadata, :execution_context) || Map.get(previous_retry, :execution_context),
            lane_snapshot: lane_snapshot
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          execution_context: Map.get(retry_entry, :execution_context),
          lane_snapshot: Map.get(retry_entry, :lane_snapshot)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        unless managed_entry?(state, issue_id), do: cleanup_issue_workspace(issue, metadata)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    with_lane_snapshot(Map.get(metadata, :lane_snapshot), fn ->
      case Map.get(metadata, :workspace_path) do
        workspace_path when is_binary(workspace_path) and workspace_path != "" ->
          context = Map.get(metadata, :execution_context) || static_execution_context(Map.get(metadata, :worker_host))
          Workspace.remove_recorded(workspace_path, context)

        _ ->
          cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
      end
    end)
  end

  defp cleanup_issue_workspace(issue_or_identifier, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] -> Workspace.remove_issue_workspaces(issue_or_identifier, static_execution_context(nil))
      hosts -> Enum.each(hosts, &cleanup_issue_workspace(issue_or_identifier, &1))
    end
  end

  defp cleanup_issue_workspace(issue_or_identifier, worker_host) when is_binary(worker_host) do
    Workspace.remove_issue_workspaces(issue_or_identifier, static_execution_context(worker_host))
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  defp static_execution_context(nil), do: ExecutionContext.local(Config.local_workspace_root())
  defp static_execution_context(host), do: ExecutionContext.ssh(Config.settings!().workspace.root, host)

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()

    with {:ok, lane_id} <- LaneContext.current(),
         {:ok, %{slug: slug}} <- LaneStore.lookup(lane_id) do
      ObservabilityPubSub.broadcast_lane(slug)
    else
      _ -> :ok
    end
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_dispatch_available?(state, issue, metadata) do
      dispatch_refreshed_retry(state, issue, attempt, metadata)
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")
      {:noreply, reschedule_retry_without_slots(state, issue, attempt, metadata)}
    end
  end

  defp retry_dispatch_available?(state, issue, metadata) do
    managed_dispatch_ready?(state) and managed_issue_available?(state, issue.id) and retry_candidate_issue?(issue, terminal_state_set()) and
      dispatch_slots_available?(issue, state) and
      worker_slots_available?(state, metadata[:worker_host])
  end

  defp dispatch_refreshed_retry(state, issue, attempt, metadata) do
    case LaneStore.reserve_dispatch(state.lane_id) do
      {:ok, token, snapshot} ->
        with_lane_snapshot(snapshot, fn ->
          dispatch_refreshed_retry_from_snapshot(state, issue, attempt, metadata, token)
        end)

      {:error, reason} ->
        Logger.warning("Skipping retry dispatch; lane reservation failed lane_id=#{state.lane_id} reason=#{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp dispatch_refreshed_retry_from_snapshot(state, issue, attempt, metadata, token) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        dispatch_retry_backend(state, refreshed_issue, attempt, metadata[:worker_host], token)

      {:skip, :missing} ->
        {:noreply, state |> release_dispatch_token(issue.id, token) |> release_issue_claim(issue.id)}

      {:skip, %Issue{} = refreshed_issue} ->
        state = release_dispatch_token(state, issue.id, token)
        handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

      {:error, reason} ->
        state = release_dispatch_token(state, issue.id, token)
        {:noreply, reschedule_retry_refresh_failure(state, issue, attempt, metadata, reason)}
    end
  end

  defp dispatch_retry_backend(state, issue, attempt, worker_host, token) do
    case backend_module_for_dispatch(issue) do
      {:ok, backend_module} ->
        {:noreply, do_dispatch_issue(state, issue, attempt, worker_host, backend_module, token)}

      :error ->
        {:noreply, state |> release_dispatch_token(issue.id, token) |> release_issue_claim(issue.id)}
    end
  end

  defp reschedule_retry_refresh_failure(state, issue, attempt, metadata, reason) do
    schedule_issue_retry(
      state,
      issue.id,
      attempt + 1,
      Map.merge(metadata, %{
        identifier: issue.identifier,
        error: "retry dispatch refresh failed: #{inspect(reason)}"
      })
    )
  end

  defp reschedule_retry_without_slots(state, issue, attempt, metadata) do
    schedule_issue_retry(
      state,
      issue.id,
      attempt + 1,
      Map.merge(metadata, %{
        identifier: issue.identifier,
        error: "no available orchestrator slots"
      })
    )
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    if managed_entry?(state, issue_id) and Lifecycle.occupied?(state.environment_entries[issue_id]) do
      managed_stop(state, issue_id, :release)
    else
      do_release_issue_claim(state, issue_id)
    end
  end

  defp do_release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        turn_exhaustions: Map.delete(state.turn_exhaustions, issue_id)
    }
  end

  defp release_dispatch_token(state, _issue_id, nil), do: state

  defp release_dispatch_token(state, issue_id, token) do
    _ = LaneStore.release_dispatch(state.lane_id, token)
    %{state | dispatch_tokens: Map.delete(state.dispatch_tokens, issue_id)}
  catch
    :exit, _ -> %{state | dispatch_tokens: Map.delete(state.dispatch_tokens, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(capacity_running(state)),
      0
    )
  end

  # Provider calls and remote hooks belong exclusively to supervised operation jobs.
  # The scheduler retains both the generation and the job until result or DOWN wins.
  defp capture_environment(state, settings) do
    identity = EnvironmentConfig.identity(settings)

    cond do
      identity == state.environment_identity ->
        refresh_environment_timeouts(state, settings)

      environment_in_use?(state) ->
        state

      true ->
        select_environment(state, settings, identity)
    end
  end

  defp refresh_environment_timeouts(%State{environment_config: nil} = state, _settings), do: state

  defp refresh_environment_timeouts(state, settings) do
    managed = settings.worker.environment

    config = %{
      state.environment_config
      | startup_timeout_ms: managed.startup_timeout_ms,
        shutdown_timeout_ms: managed.shutdown_timeout_ms,
        terminal_retention_ms: managed.terminal_retention_ms
    }

    %{state | environment_config: config}
  end

  defp environment_in_use?(state) do
    is_reference(state.environment_guard) or environment_work?(state)
  end

  defp environment_work?(state) do
    map_size(state.environment_entries) > 0 or map_size(state.environment_jobs) > 0
  end

  defp select_environment(state, _settings, nil) do
    state = %{state | environment_config: nil, environment_identity: nil}
    %{state | environment_guard: nil, environment_store: nil, environment_discovery: :ready}
  end

  defp select_environment(state, settings, identity) do
    config = EnvironmentConfig.runtime(settings)
    state = %{state | environment_config: config, environment_identity: identity}
    state = %{state | environment_guard: nil, environment_store: nil, environment_discovery: :pending}

    case protect_environment(state) do
      {:ok, state} -> discover_environments(state)
      {:error, state} -> state
    end
  end

  # Same-store token loss is competing authority, not permission to reacquire.
  # A replaced process may only grant our captured identity, never a new disk scope.
  defp protect_environment(state) do
    store = Process.whereis(LaneStore)

    result =
      if is_reference(state.environment_guard) and store == state.environment_store do
        LaneStore.protect_environment(state.lane_id, state.environment_identity, state.environment_guard)
      else
        LaneStore.protect_environment(state.lane_id, state.environment_identity)
      end

    case result do
      {:ok, token} when is_pid(store) ->
        if Process.whereis(LaneStore) == store do
          {:ok, %{state | environment_guard: token, environment_store: store}}
        else
          environment_authority_lost(state)
        end

      _ ->
        environment_authority_lost(state)
    end
  catch
    :exit, _ -> environment_authority_lost(state)
  end

  defp environment_authority_lost(state) do
    {:error, %{state | environment_discovery: {:error, :authority_replaced}}}
  end

  defp discover_environments(state) do
    {:ok, adapter} = ExecutionEnvironment.adapter(state.environment_config.kind)
    opts = environment_options(state)
    {:ok, task, token} = Operations.discover(state.task_supervisor, adapter, state.environment_config, opts)
    job = %{issue_id: nil, operation_id: token, operation: :discover, task: task}

    %{
      state
      | environment_jobs: Map.put(state.environment_jobs, task.ref, job),
        environment_discovery: :pending,
        environment_discovery_token: token,
        environment_inventory_due_at_ms: System.monotonic_time(:millisecond) + state.poll_interval_ms
    }
  end

  defp environment_options(state), do: [authority: self(), operation_fun: state.environment_operation_fun]
  defp managed_entry?(state, id), do: Map.has_key?(state.environment_entries, id)
  defp managed_dispatch_ready?(%State{environment_config: nil}), do: true
  defp managed_dispatch_ready?(state), do: state.environment_discovery == :ready

  defp managed_issue_available?(state, id) do
    case state.environment_entries[id] do
      nil ->
        true

      %Entry{phase: :stopped, operation_id: nil, record: %{terminal_observed_at: nil, desired: desired}} ->
        desired != :absent and not environment_job?(state, id)

      _ ->
        false
    end
  end

  defp capacity_running(state) do
    Enum.reduce(state.environment_entries, state.running, fn {id, entry}, used ->
      if Lifecycle.occupied?(entry), do: Map.put(used, id, %{issue: %Issue{state: entry.record.issue_state || ""}, unknown_state?: is_nil(entry.record.issue_state)}), else: used
    end)
  end

  defp environment_job?(state, id), do: Enum.any?(state.environment_jobs, fn {_, job} -> job.issue_id == id end)
  defp put_environment(state, entry), do: %{state | environment_entries: Map.put(state.environment_entries, entry.record.issue_id, entry)}
  defp attempt_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  defp utc_ms, do: System.system_time(:millisecond)

  defp reserve_environment(state, issue, attempt, backend, dispatch_token) do
    with true <- managed_dispatch_ready?(state) and managed_issue_available?(state, issue.id),
         true <- environment_capacity?(state, claim_capacity_issue(issue)),
         {:ok, state} <- protect_environment(state) do
      id = attempt_id()
      config = state.environment_config
      key = ExecutionEnvironment.resource_key(config.deployment_id, config.tracker_kind, issue.id)

      entry =
        case state.environment_entries[issue.id] do
          nil ->
            record = %Record{
              key: key,
              deployment_id: config.deployment_id,
              tracker_kind: config.tracker_kind,
              issue_id: issue.id,
              issue_identifier: issue.identifier,
              issue_state: issue.state,
              kind: config.kind,
              scope: EnvironmentConfig.scope(config),
              workspace_path: Path.join(config.workspace_root, key),
              template_identity: nil,
              attempt_id: id
            }

            Lifecycle.new(record, id, :agent)

          old ->
            elem(Lifecycle.step(old, {:reserve, id, :agent}, utc_ms()), 0)
        end

      # This successful claim-time move is our own baseline, not an external reroute.
      issue = managed_claim_issue(issue)

      backend =
        case backend_module_for_dispatch(issue) do
          {:ok, selected} -> selected
          _ -> backend
        end

      entry = %{
        entry
        | issue: issue,
          environment_config: config,
          lane_snapshot: current_lane_snapshot(),
          backend_module: backend,
          retry_attempt: attempt,
          agent_executable: selected_executable(backend),
          record: %{entry.record | attempt_id: id, issue_state: issue.state, issue_identifier: issue.identifier}
      }

      state = %{
        put_environment(state, entry)
        | dispatch_tokens: Map.put(state.dispatch_tokens, issue.id, dispatch_token),
          claimed: MapSet.put(state.claimed, issue.id),
          retry_attempts: Map.delete(state.retry_attempts, issue.id)
      }

      environment_step(state, issue.id, :prepare)
    else
      {:error, state} -> release_dispatch_token(state, issue.id, dispatch_token)
      _ -> release_dispatch_token(state, issue.id, dispatch_token)
    end
  end

  defp claim_capacity_issue(issue) do
    case Config.settings!().agent.in_progress_state do
      target when is_binary(target) and target != "" -> %{issue | state: target}
      _ -> issue
    end
  end

  defp managed_claim_issue(issue) do
    target = Config.settings!().agent.in_progress_state

    if target in [nil, "", issue.state] do
      issue
    else
      case Tracker.update_issue_state(issue.id, target) do
        :ok -> %{issue | state: target}
        _ -> issue
      end
    end
  end

  defp selected_executable(backend) do
    settings = Config.settings!()
    command = if backend == SymphonyElixir.Agent.Claude, do: settings.claude.command, else: settings.codex.command
    command |> OptionParser.split() |> List.first()
  rescue
    _ -> nil
  end

  defp environment_step(state, id, event) do
    {entry, effects} = Lifecycle.step(Map.fetch!(state.environment_entries, id), event, utc_ms())
    state = put_environment(state, entry)

    Enum.reduce(effects, state, fn
      {:provider, operation, _}, acc -> start_environment_job(acc, entry, operation)
      {:release, completion}, acc -> finish_environment_stop(acc, entry, completion)
      :forget, acc -> %{do_release_issue_claim(acc, id) | environment_entries: Map.delete(acc.environment_entries, id)}
      {:launch_agent, _}, acc -> launch_environment_agent(acc, entry)
    end)
  end

  defp start_environment_job(state, entry, operation) do
    if operation in [:stop, :inspect] do
      do_start_environment_job(state, entry, operation)
    else
      case protect_environment(state) do
        {:ok, state} -> do_start_environment_job(state, entry, operation)
        {:error, state} -> apply_environment_result(state, entry, operation, {:error, {:denied, :authority_replaced}, entry.record})
      end
    end
  end

  defp do_start_environment_job(state, entry, operation) do
    config = entry.environment_config || state.environment_config
    {:ok, adapter} = ExecutionEnvironment.adapter(config.kind)
    opts = environment_options(state)
    opts = if entry.purpose == :agent, do: Keyword.put(opts, :agent_executable, entry.agent_executable), else: opts

    entry =
      if operation == :stop and is_integer(entry.terminal_observation) and is_nil(entry.record.terminal_observed_at) do
        %{entry | record: %{entry.record | terminal_observed_at: entry.terminal_observation}}
      else
        entry
      end

    {:ok, task} = Operations.start(state.task_supervisor, adapter, config, entry, operation, opts)
    job = %{issue_id: entry.record.issue_id, operation_id: entry.operation_id, operation: operation, task: task}
    %{state | environment_jobs: Map.put(state.environment_jobs, task.ref, job)}
  end

  defp environment_result(state, %{operation: :discover, operation_id: token}, result) do
    if state.environment_discovery_token == token do
      apply_discovery_result(state, result)
    else
      state
    end
  end

  defp environment_result(state, job, result) do
    case state.environment_entries[job.issue_id] do
      %Entry{operation_id: id} = entry when id == job.operation_id ->
        apply_environment_result(state, entry, job.operation, result)

      _ ->
        close_stale_prepared(result, state)
        state
    end
  end

  defp apply_discovery_result(state, {:ok, records}) when is_list(records) do
    if Enum.all?(records, &valid_inventory_record?(&1, state.environment_config)) do
      state = %{state | environment_discovery: :ready, environment_discovery_token: nil}
      state = Enum.reduce(records, state, &adopt_environment/2)
      state |> maybe_release_environment_guard(records == []) |> enqueue_environment_poll()
    else
      ids = Enum.flat_map(records, &inventory_resource_ids/1)
      discovery_failed(state, {:unmapped_owned_resource, ids})
    end
  end

  defp apply_discovery_result(state, {:error, {:unknown, {code, ids}}})
       when code in [:orphan_backing_resources, :kubernetes_invalid_owned_record] and is_list(ids) do
    discovery_failed(state, {code, Enum.flat_map(ids, &orphan_resource_ids/1)})
  end

  defp apply_discovery_result(state, {:error, {category, _details}})
       when category in [:denied, :invalid, :retryable, :unknown] do
    discovery_failed(state, category)
  end

  defp apply_discovery_result(state, _result), do: discovery_failed(state, :unresolved)

  defp inventory_resource_ids(%Record{} = record), do: [safe_resource_id(record.provider_ref) || record.key]
  defp inventory_resource_ids(_record), do: []
  defp orphan_resource_ids(id) when is_binary(id), do: [id]

  defp orphan_resource_ids(item) when is_map(item) do
    item |> Map.take(["id", "name"]) |> Map.values() |> Enum.filter(&is_binary/1)
  end

  defp orphan_resource_ids(_item), do: []

  defp discovery_failed(state, error) do
    Logger.warning("Managed environment discovery unresolved")
    state = %{state | environment_discovery: {:error, error}, environment_discovery_token: nil}
    reconcile_environment_entries(state)
  end

  defp valid_inventory_record?(%Record{issue_id: id} = record, config) when is_binary(id) and id != "" do
    record.deployment_id == config.deployment_id and record.tracker_kind == config.tracker_kind and record.kind == config.kind and
      record.scope == EnvironmentConfig.scope(config) and record.key == ExecutionEnvironment.resource_key(config.deployment_id, config.tracker_kind, id)
  end

  defp valid_inventory_record?(_record, _config), do: false

  defp qualified_stopped_record?(%Record{phase: :stopped, proof: {:quiescent, evidence}, pending: pending}) when is_map(evidence) and map_size(evidence) > 0 do
    not Enum.any?(pending, &(&1.outcome in [:pending, :unknown]))
  end

  defp qualified_stopped_record?(_record), do: false

  defp adopt_environment(record, state) do
    adopt_environment_entry(state, state.environment_entries[record.issue_id], record)
  end

  defp adopt_environment_entry(state, %Entry{phase: :running} = entry, record) do
    if healthy_environment_attempt?(state, entry, record) do
      state
    else
      state |> put_environment(%{entry | record: record}) |> managed_stop(record.issue_id, :release)
    end
  end

  defp adopt_environment_entry(state, %Entry{phase: :stopped} = entry, record) do
    state = put_environment(state, %{entry | record: record})

    if qualified_stopped_record?(record) and record.attempt_id == entry.record.attempt_id do
      state
    else
      environment_step(state, record.issue_id, {:reconcile, :stop})
    end
  end

  defp adopt_environment_entry(state, %Entry{phase: :unknown} = entry, record) do
    if environment_job?(state, record.issue_id) do
      state
    else
      record = retain_absent_intent(entry.record, record)
      state |> put_environment(%{entry | record: record}) |> environment_step(record.issue_id, {:reconcile, :inspect})
    end
  end

  defp adopt_environment_entry(state, %Entry{}, _record), do: state

  defp adopt_environment_entry(state, nil, record) do
    entry = %{Lifecycle.new(record, attempt_id(), :agent) | environment_config: state.environment_config, lane_snapshot: current_lane_snapshot()}
    phase = if qualified_stopped_record?(record), do: :stopped, else: :unknown
    state = put_environment(state, %{entry | phase: phase})

    if phase == :stopped do
      state
    else
      environment_step(state, record.issue_id, {:reconcile, stop_or_destroy(record)})
    end
  end

  defp healthy_environment_attempt?(state, entry, record) do
    entry.attempt_id == record.attempt_id and record.phase == :running and
      not Enum.any?(record.pending, &(&1.outcome in [:pending, :unknown])) and
      Map.has_key?(state.running, record.issue_id)
  end

  defp retain_absent_intent(%{desired: :absent}, record), do: %{record | desired: :absent}
  defp retain_absent_intent(_previous, record), do: record
  defp stop_or_destroy(%{desired: :absent}), do: :destroy
  defp stop_or_destroy(_record), do: :stop

  defp environment_task_failed(state, %{operation: :discover} = job), do: environment_result(state, job, {:error, {:unknown, :task_down}})

  defp environment_task_failed(state, job) do
    case state.environment_entries[job.issue_id] do
      %Entry{operation_id: id} = entry when id == job.operation_id -> apply_environment_result(state, entry, job.operation, {:error, {:unknown, :task_down}, entry.record})
      _ -> state
    end
  end

  defp apply_environment_result(state, entry, :prepare, {:ok, %ExecutionContext{mode: :managed} = context}) do
    record = context.environment.record

    if record.issue_id == entry.record.issue_id and record.attempt_id == entry.attempt_id do
      state = put_environment(state, %{entry | context: context})
      state = environment_step(state, entry.record.issue_id, {:prepared, entry.operation_id, record})
      continue_prepared_environment(state, state.environment_entries[entry.record.issue_id])
    else
      close_stale_prepared({:ok, context}, state)
      apply_environment_result(state, entry, :prepare, {:error, {:invalid, :prepared_identity}, entry.record})
    end
  end

  defp apply_environment_result(state, entry, :stop, {:ok, %Record{} = record}) do
    close_stale_prepared({:ok, entry.context}, state)
    state = environment_step(state, entry.record.issue_id, {:stopped, entry.operation_id, record})
    enqueue_environment_poll(state)
  end

  defp apply_environment_result(state, entry, :destroy, {:ok, %Record{} = record}) do
    if record.absent? and not Enum.any?(record.pending, &(&1.outcome in [:pending, :unknown])) do
      state = environment_step(state, entry.record.issue_id, {:destroyed, entry.operation_id, record})
      # Confirm a complete empty inventory, not just the last known record's absence.
      if environment_work?(state), do: enqueue_environment_poll(state), else: discover_environments(state)
    else
      apply_environment_result(state, entry, :destroy, {:error, {:unknown, :absence_unconfirmed}, record})
    end
  end

  defp apply_environment_result(state, entry, :cleanup_hook, {:ok, %Record{} = record}) do
    state = environment_step(state, entry.record.issue_id, {:updated, entry.operation_id, record})
    entry = state.environment_entries[entry.record.issue_id]
    record = %{entry.record | metadata: Map.put(entry.record.metadata, "symphony_cleanup_hook_completed", true)}
    entry = %{entry | record: record, metadata_intent: %{}}
    state |> put_environment(entry) |> environment_step(entry.record.issue_id, {:reconcile, :metadata})
  end

  defp apply_environment_result(state, entry, :metadata, {:ok, %Record{} = record}) do
    state = environment_step(state, entry.record.issue_id, {:updated, entry.operation_id, record})
    current = state.environment_entries[entry.record.issue_id]

    retry_at = cleanup_retry_after_metadata(entry.metadata_intent, current.cleanup_retry_at)
    current = %{current | terminal_observation: nil, metadata_intent: nil, cleanup_retry_at: retry_at}
    state = put_environment(state, current)

    if entry.purpose == :cleanup and Lifecycle.occupied?(entry) do
      managed_stop(state, entry.record.issue_id, :release)
    else
      enqueue_environment_poll(state)
    end
  end

  defp apply_environment_result(state, entry, :inspect, {:ok, %Record{} = record}) do
    cond do
      record.absent? ->
        apply_environment_result(state, entry, :destroy, {:ok, record})

      record.desired != :absent and qualified_stopped_record?(record) ->
        apply_environment_result(state, entry, :stop, {:ok, record})

      true ->
        state = environment_step(state, entry.record.issue_id, {:updated, entry.operation_id, record})
        environment_step(state, entry.record.issue_id, {:reconcile, if(record.desired == :absent, do: :destroy, else: :stop)})
    end
  end

  defp apply_environment_result(state, entry, operation, {:error, failure, %Record{} = record}) do
    entry = failed_environment_entry(state, entry, operation)

    state = put_environment(state, entry)
    state = environment_step(state, entry.record.issue_id, {:failed, entry.operation_id, {operation, failure}, record})

    if operation in [:prepare, :cleanup_hook] or (operation == :metadata and entry.purpose == :cleanup) do
      environment_step(state, entry.record.issue_id, {:reconcile, :stop})
    else
      state
    end
  end

  defp apply_environment_result(state, entry, operation, _result), do: apply_environment_result(state, entry, operation, {:error, {:unknown, :invalid_result}, entry.record})

  defp continue_prepared_environment(state, %Entry{completion: completion} = entry) when not is_nil(completion) do
    managed_stop(state, entry.record.issue_id, completion)
  end

  defp continue_prepared_environment(state, %Entry{purpose: :cleanup} = entry) do
    with_lane_snapshot(entry.lane_snapshot, fn -> revalidate_cleanup_prepared(state, entry.record.issue_id) end)
  end

  defp continue_prepared_environment(state, entry) do
    with_lane_snapshot(entry.lane_snapshot, fn -> revalidate_prepared_environment(state, entry.record.issue_id) end)
  end

  defp cleanup_retry_after_metadata(%{terminal_observed_at: nil}, _retry_at), do: nil
  defp cleanup_retry_after_metadata(_intent, retry_at), do: retry_at

  defp failed_environment_entry(_state, %Entry{purpose: :agent, completion: nil} = entry, :prepare) do
    metadata = %{
      identifier: entry.record.issue_identifier,
      workspace_path: entry.record.workspace_path,
      lane_snapshot: entry.lane_snapshot,
      error: "managed preparation failed"
    }

    %{entry | completion: {:retry, normalize_retry_attempt(entry.retry_attempt) + 1, metadata}}
  end

  defp failed_environment_entry(state, %Entry{purpose: :cleanup} = entry, operation)
       when operation in [:prepare, :cleanup_hook, :metadata] do
    %{entry | cleanup_retry_at: utc_ms() + state.poll_interval_ms}
  end

  defp failed_environment_entry(_state, entry, _operation), do: entry

  defp revalidate_cleanup_prepared(state, id) do
    with {:ok, [issue]} <- Tracker.fetch_issues_by_ids([id]),
         true <- terminal_issue_state?(issue.state, terminal_state_set()) do
      environment_step(state, id, {:reconcile, :cleanup_hook})
    else
      _ -> managed_stop(state, id, :release)
    end
  end

  defp revalidate_prepared_environment(state, id) do
    entry = state.environment_entries[id]

    with {:ok, state} <- protect_environment(state),
         {:ok, [issue]} <- Tracker.fetch_issues_by_ids([id]),
         true <- candidate_issue?(issue, active_state_set(), terminal_state_set()),
         true <- normalize_issue_state(issue.state) == normalize_issue_state(entry.issue.state),
         {:ok, backend} <- backend_module_for_dispatch(issue),
         true <- backend == entry.backend_module and selected_executable(backend) == entry.agent_executable do
      state |> put_environment(%{entry | issue: issue}) |> environment_step(id, :launch)
    else
      {:error, %State{} = failed_state} ->
        managed_stop(failed_state, id, :release)

      _reason ->
        managed_stop(state, id, :release)
    end
  end

  defp launch_environment_agent(state, entry) do
    context = entry.context

    state =
      spawn_issue_with_context(
        state,
        entry.issue,
        entry.retry_attempt,
        self(),
        entry.backend_module,
        context,
        entry.attempt_id,
        false,
        Map.get(state.dispatch_tokens, entry.record.issue_id),
        entry.lane_snapshot
      )

    if Map.has_key?(state.running, entry.record.issue_id), do: state, else: managed_stop(state, entry.record.issue_id, state.environment_entries[entry.record.issue_id].completion || :release)
  end

  defp managed_stop(state, id, completion) do
    entry = Map.fetch!(state.environment_entries, id)

    state =
      case Map.pop(state.running, id) do
        {nil, _} ->
          state

        {running, remaining} ->
          stop_running_task(running.pid, running.ref, state.task_supervisor)
          Runs.finished(running.attempt_id, "stopped")
          record_session_completion_totals(%{state | running: remaining}, running)
      end

    entry = %{entry | completion: completion}
    state = put_environment(state, entry)

    cond do
      entry.phase == :stopped and not environment_job?(state, id) ->
        finish_environment_stop(state, entry, completion)

      entry.phase in [:stopping, :deleting] ->
        state

      environment_job?(state, id) ->
        # In-flight prepare can mutate remotely. Invalidate launch now, then let its
        # accounted result finish before issuing a fenced stop.
        state

      true ->
        environment_step(state, id, {:reconcile, :stop})
    end
  end

  defp finish_environment_stop(state, entry, completion) do
    state =
      case completion do
        {:agent_down, _reason, running} -> release_dispatch_token(state, entry.record.issue_id, Map.get(running, :dispatch_token))
        _ -> release_dispatch_token(state, entry.record.issue_id, Map.get(state.dispatch_tokens, entry.record.issue_id))
      end

    error = if entry.purpose == :cleanup and not is_nil(entry.cleanup_retry_at), do: entry.last_error, else: nil
    state = put_environment(state, %{entry | completion: nil, last_error: error})

    case completion do
      {:agent_down, reason, running} ->
        with_lane_snapshot(Map.get(running, :lane_snapshot), fn ->
          handle_agent_down(reason, state, entry.record.issue_id, running, running_entry_session_id(running))
        end)

      {:retry, attempt, metadata} ->
        schedule_issue_retry(state, entry.record.issue_id, attempt, metadata)

      {:block, running, error} ->
        block_issue_from_entry(state, entry.record.issue_id, running, error)

      _ ->
        do_release_issue_claim(state, entry.record.issue_id)
    end
  end

  defp safe_agent_reason(:normal), do: :normal
  defp safe_agent_reason(_reason), do: :managed_agent_failed

  defp close_stale_prepared({:ok, %ExecutionContext{connection: connection}}, state) when not is_nil(connection) do
    owned? = Enum.any?(state.environment_entries, fn {_, entry} -> entry.phase in [:preparing, :running] and match?(%ExecutionContext{connection: ^connection}, entry.context) end)

    unless owned? do
      Task.Supervisor.start_child(state.task_supervisor, fn -> Operations.close_connection(connection) end)
    end

    :ok
  end

  defp close_stale_prepared(_result, _state), do: :ok

  defp enqueue_environment_poll(state) do
    send(self(), :run_poll_cycle)
    state
  end

  defp maybe_release_environment_guard(state, empty?) do
    if empty? and not environment_work?(state) and is_reference(state.environment_guard) do
      case LaneStore.release_environment(state.lane_id, state.environment_guard, :empty_inventory) do
        :ok -> %{state | environment_guard: nil}
        _ -> state
      end
    else
      state
    end
  catch
    :exit, _ -> state
  end

  defp reconcile_environments(%State{environment_config: nil} = state), do: state

  defp reconcile_environments(state) do
    state = if match?({:error, _}, state.environment_discovery), do: refresh_environment_inventory(state), else: state
    if state.environment_discovery == :pending, do: state, else: reconcile_environment_entries(state)
  end

  defp reconcile_environment_entries(state) do
    state.environment_entries
    |> Map.keys()
    |> Enum.group_by(fn id ->
      snapshot = state.environment_entries[id].lane_snapshot || get_in(state.running, [id, :lane_snapshot])
      snapshot && (snapshot.config_identity || snapshot.version_id)
    end)
    |> Enum.reduce(state, fn {_config_identity, ids}, acc ->
      snapshot = state.environment_entries[hd(ids)].lane_snapshot || get_in(state.running, [hd(ids), :lane_snapshot])

      with_lane_snapshot(snapshot, fn ->
        refresh_environment_issue_group(acc, ids)
      end)
    end)
  end

  defp refresh_environment_issue_group(state, ids) do
    case Tracker.fetch_issues_by_ids(ids) do
      {:ok, issues} ->
        by_id = Map.new(issues, &{&1.id, &1})
        Enum.reduce(ids, state, fn id, current -> reconcile_environment(current, id, by_id[id]) end)

      _ ->
        Enum.reduce(ids, state, &inspect_unresolved_environment/2)
    end
  end

  defp inspect_unresolved_environment(id, state) do
    entry = state.environment_entries[id]

    if entry.phase == :unknown and not environment_job?(state, id) do
      environment_step(state, id, {:reconcile, :inspect})
    else
      state
    end
  end

  defp reconcile_environment(state, id, issue) do
    state = observe_environment_issue(state, id, issue)
    entry = state.environment_entries[id]

    if environment_job?(state, id) do
      reconcile_busy_environment(state, entry, issue)
    else
      reconcile_idle_environment(state, entry, issue)
    end
  end

  defp observe_environment_issue(state, _id, nil), do: state

  defp observe_environment_issue(state, id, %Issue{} = issue) do
    state = if terminal_issue_state?(issue.state, terminal_state_set()), do: observe_terminal(state, id), else: state
    entry = state.environment_entries[id]

    if is_nil(entry.record.issue_state) do
      put_environment(state, %{entry | record: %{entry.record | issue_state: issue.state}, issue: issue})
    else
      state
    end
  end

  defp reconcile_busy_environment(state, %Entry{phase: :preparing, purpose: :agent} = entry, issue) do
    if eligible_environment_issue?(issue) and issue.state == entry.issue.state do
      state
    else
      managed_stop(state, entry.record.issue_id, :release)
    end
  end

  defp reconcile_busy_environment(state, _entry, _issue), do: state

  defp eligible_environment_issue?(nil), do: false
  defp eligible_environment_issue?(issue), do: candidate_issue?(issue, active_state_set(), terminal_state_set())

  defp reconcile_idle_environment(state, %Entry{phase: :unknown} = entry, _issue) do
    environment_step(state, entry.record.issue_id, {:reconcile, :inspect})
  end

  defp reconcile_idle_environment(state, %Entry{phase: :running} = entry, issue) do
    if eligible_environment_issue?(issue), do: state, else: managed_stop(state, entry.record.issue_id, :release)
  end

  defp reconcile_idle_environment(state, %Entry{phase: :stopped} = entry, issue) do
    reconcile_stopped_environment(state, entry, issue)
  end

  defp reconcile_idle_environment(state, _entry, _issue), do: state

  defp reconcile_stopped_environment(state, %Entry{record: %{desired: :absent}} = entry, _issue) do
    environment_step(state, entry.record.issue_id, :destroy)
  end

  defp reconcile_stopped_environment(state, _entry, nil), do: state

  defp reconcile_stopped_environment(state, entry, issue) do
    cond do
      terminal_issue_state?(issue.state, terminal_state_set()) ->
        reconcile_terminal_environment(state, entry, issue)

      not is_nil(entry.record.terminal_observed_at) or not is_nil(entry.terminal_observation) ->
        reopen_environment(state, entry)

      true ->
        state
    end
  end

  defp reopen_environment(state, entry) do
    record = %{entry.record | metadata: Map.put(entry.record.metadata, "symphony_cleanup_hook_completed", false)}
    intent = %{terminal_observed_at: nil, desired: :stopped}
    entry = %{entry | record: record, purpose: :agent, metadata_intent: intent}
    state |> put_environment(entry) |> environment_step(record.issue_id, {:reconcile, :metadata})
  end

  defp observe_terminal(state, id) do
    case state.environment_entries[id] do
      %Entry{terminal_observation: nil, record: %{terminal_observed_at: nil}} = entry ->
        put_environment(state, %{entry | terminal_observation: utc_ms()})

      _ ->
        state
    end
  end

  defp refresh_environment_inventory(state, force? \\ false)
  defp refresh_environment_inventory(%State{environment_config: nil} = state, _force?), do: state

  defp refresh_environment_inventory(state, force?) do
    due_at = state.environment_inventory_due_at_ms
    due? = is_nil(due_at) or System.monotonic_time(:millisecond) >= due_at

    if map_size(state.environment_jobs) == 0 and (force? or due? or match?({:error, _}, state.environment_discovery)) do
      case protect_environment(state) do
        {:ok, state} -> discover_environments(state)
        {:error, state} -> state
      end
    else
      state
    end
  end

  defp reconcile_terminal_environment(state, entry, issue) do
    id = entry.record.issue_id

    cond do
      is_nil(entry.record.terminal_observed_at) ->
        intent = %{terminal_observed_at: entry.terminal_observation || utc_ms()}
        entry = %{entry | issue: issue, metadata_intent: intent}
        state |> put_environment(entry) |> environment_step(id, {:reconcile, :metadata})

      not terminal_cleanup_due?(state, entry) ->
        state

      cleanup_retry_pending?(entry) ->
        state

      cleanup_hook_complete?(entry) ->
        environment_step(state, id, :destroy)

      cleanup_capacity?(state, issue) ->
        {entry, _} = Lifecycle.step(entry, {:reserve, attempt_id(), :cleanup}, utc_ms())
        entry = %{entry | issue: issue, record: %{entry.record | issue_state: issue.state}}
        state |> put_environment(entry) |> environment_step(id, :prepare)

      true ->
        state
    end
  end

  defp terminal_cleanup_due?(state, entry) do
    config = entry.environment_config || state.environment_config
    Lifecycle.deletion_due?(entry.record, :terminal, config.terminal_retention_ms, utc_ms())
  end

  defp cleanup_capacity?(state, issue), do: managed_dispatch_ready?(state) and environment_capacity?(state, issue)

  defp cleanup_retry_pending?(entry) do
    is_integer(entry.cleanup_retry_at) and utc_ms() < entry.cleanup_retry_at
  end

  defp cleanup_hook_complete?(entry) do
    with_lane_snapshot(entry.lane_snapshot, fn ->
      Config.settings!().hooks.before_remove in [nil, ""] or
        entry.record.metadata["symphony_cleanup_hook_completed"] == true
    end)
  end

  defp current_lane_snapshot do
    case LaneContext.capture() do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  end

  defp environment_capacity?(state, issue) do
    available_slots(state) > 0 and state_slots_available?(issue, capacity_running(state))
  end

  defp environment_discovery_snapshot(%State{environment_config: nil}), do: nil

  defp environment_discovery_snapshot(state) do
    {status, error_code} =
      case state.environment_discovery do
        :ready -> {:ready, nil}
        :pending -> {:pending, nil}
        {:error, error} -> {:blocked, discovery_error_code(error)}
      end

    %{provider_kind: state.environment_config.kind, status: status, error_code: error_code}
  end

  defp discovery_error_code(error) do
    if error in [:denied, :invalid, :retryable, :unknown, :authority_replaced], do: error, else: :unresolved
  end

  defp environment_snapshot(entry) do
    record = entry.record

    %{
      environment_id: record.key,
      provider: record.kind,
      issue_id: record.issue_id,
      issue_identifier: record.issue_identifier,
      phase: entry.phase,
      desired: record.desired,
      occupies_slot: Lifecycle.occupied?(entry),
      workspace_path: record.workspace_path,
      provider_resource_id: safe_resource_id(record.provider_ref),
      terminal_observed_at: record.terminal_observed_at,
      unresolved: safe_environment_failure(entry)
    }
  end

  defp safe_resource_id(%{name: name}) when is_binary(name), do: name
  defp safe_resource_id(%{uid: uid}) when is_binary(uid), do: uid
  defp safe_resource_id(value) when is_binary(value), do: value
  defp safe_resource_id(_value), do: nil

  defp safe_environment_failure(%Entry{last_error: {operation, {category, code}}}) do
    operations = [:discover, :prepare, :stop, :destroy, :inspect, :metadata, :cleanup_hook]
    operation = if operation in operations, do: operation, else: :reconcile
    category = if category in [:invalid, :denied, :retryable, :unknown], do: category, else: :unknown
    codes = [:task_down, :invalid_result, :prepared_identity, :kubernetes_controller_cleanup_ordering_unproven]
    code = if code in codes, do: code, else: :environment_operation_unresolved
    %{operation: operation, category: category, code: code}
  end

  defp safe_environment_failure(%Entry{phase: :unknown}), do: %{operation: :reconcile, category: :unknown, code: :environment_state_unknown}
  defp safe_environment_failure(_entry), do: nil

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    GenServer.call(server, :request_refresh)
  catch
    :exit, _ -> :unavailable
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    GenServer.call(server, :snapshot, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
    :exit, _ -> :unavailable
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       claimed: MapSet.size(state.claimed),
       environments: Enum.map(state.environment_entries, fn {_id, entry} -> environment_snapshot(entry) end),
       environment_discovery: environment_discovery_snapshot(state),
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    state = state |> refresh_runtime_config() |> refresh_environment_inventory(true)
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  @impl true
  def terminate(reason, state) do
    status = if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason), do: "stopped", else: "failed"
    Enum.each(state.running, fn {_issue_id, entry} -> Runs.finished(entry.attempt_id, status) end)
    :ok
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    running_entry = reset_turn_token_usage(running_entry, update)
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        attempt_outcome: if(event == :attempt_blocked, do: :blocked, else: Map.get(running_entry, :attempt_outcome)),
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_cached_tokens: max(Map.get(running_entry, :codex_last_reported_cached_tokens, 0), token_delta.cached_reported),
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp reset_turn_token_usage(entry, %{event: :session_started, usage_scope: :turn}) do
    # Claude starts a fresh invocation each turn. Keep the worker's accumulated
    # totals, but measure this invocation from zero rather than the previous one.
    Map.merge(entry, %{
      codex_last_reported_cached_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0
    })
  end

  defp reset_turn_token_usage(entry, _update), do: entry

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
    |> capture_environment(config)
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, capacity_running(state))
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    usage = extract_token_usage(update)
    cached = compute_token_delta(running_entry, :cached, usage, :codex_last_reported_cached_tokens)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        cached_tokens: cached.delta,
        cached_reported: cached.reported,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(%{usage_scope: :turn, usage: usage}) when is_map(usage) do
    if integer_token_map?(usage), do: usage, else: %{}
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :cached_tokens,
      "cached_tokens",
      "cachedInputTokens",
      :cachedInputTokens,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :cached),
    do: payload_get(usage, [:cached_tokens, "cached_tokens", :cachedInputTokens, "cachedInputTokens", :cached_input_tokens, "cached_input_tokens", "cache_read_input_tokens"])

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
