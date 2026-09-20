defmodule SymphonyElixir.LaneStore do
  @moduledoc "Runtime lane authority: lock-free ETS reads, serialized writes and environment ownership, and fenced runtime lifecycle."
  use GenServer
  require Logger

  alias SymphonyElixir.{Config, LaneRegistry, Lanes, LaneSupervisor, Repo, Runs, Workflow, Workspace}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixirWeb.ObservabilityPubSub

  @table :symphony_lanes
  @max_crashes 5
  @crash_window_ms 60_000
  @restart_delay_ms 1_000

  defmodule Entry do
    @moduledoc "One published lane configuration and its runtime health."
    defstruct [
      :lane_id,
      :slug,
      :name,
      :enabled,
      :executor,
      :profile_id,
      :profile_name,
      :workspace_subdir,
      :version_id,
      :config_identity,
      :settings,
      :workflow,
      :front_matter,
      :prompt,
      :error,
      :generation,
      warnings: [],
      runtime: %{restarts: 0, last_crash: nil, started_at: nil, crashes: []}
    ]

    @type t :: %__MODULE__{}
  end

  @type lane_id :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec file_lane_id() :: 0
  def file_lane_id, do: 0

  @spec lookup(lane_id()) :: {:ok, Entry.t()} | :error
  def lookup(lane_id) do
    case :ets.lookup(@table, lane_id) do
      [{^lane_id, %Entry{} = entry}] -> {:ok, entry}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @spec by_slug(String.t()) :: {:ok, Entry.t()} | :error
  def by_slug(slug) do
    case Enum.find(list(), &(&1.slug == slug)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @spec list() :: [Entry.t()]
  def list do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.lane_id)
  rescue
    ArgumentError -> []
  end

  @spec settings(lane_id()) :: {:ok, Schema.t()} | {:error, term()}
  def settings(lane_id) do
    case lookup(lane_id) do
      {:ok, %Entry{settings: %Schema{} = settings}} -> {:ok, settings}
      {:ok, %Entry{error: error}} -> {:error, {:lane_invalid, error}}
      :error -> {:error, {:lane_unavailable, lane_id}}
    end
  end

  @spec settings!(lane_id()) :: Schema.t()
  def settings!(lane_id) do
    case settings(lane_id) do
      {:ok, settings} -> settings
      {:error, reason} -> raise ArgumentError, "lane #{inspect(lane_id)} is unavailable: #{inspect(reason)}"
    end
  end

  @spec workflow(lane_id()) :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def workflow(lane_id) do
    case lookup(lane_id) do
      {:ok, %Entry{workflow: %{} = workflow}} -> {:ok, workflow}
      {:ok, %Entry{error: error}} -> {:error, {:lane_invalid, error}}
      :error -> {:error, {:lane_unavailable, lane_id}}
    end
  end

  @spec validate(lane_id()) :: :ok | {:error, term()}
  def validate(lane_id), do: with({:ok, _} <- settings(lane_id), do: :ok)

  @spec put_entry(Entry.t()) :: :ok | {:error, :environment_identity_in_use}
  def put_entry(%Entry{} = entry), do: GenServer.call(__MODULE__, {:put_entry, entry})

  @spec mark_error(lane_id(), String.t()) :: :ok
  def mark_error(lane_id, message), do: GenServer.call(__MODULE__, {:mark_error, lane_id, message})

  @spec refresh(lane_id()) :: :ok | {:error, :environment_identity_in_use}
  def refresh(lane_id), do: GenServer.call(__MODULE__, {:refresh, lane_id}, :infinity)

  @doc false
  @spec reserve_dispatch(lane_id()) :: {:ok, reference(), Entry.t()} | {:error, term()}
  def reserve_dispatch(lane_id), do: GenServer.call(__MODULE__, {:reserve_dispatch, lane_id, self()}, :infinity)

  @doc false
  @spec release_dispatch(lane_id(), reference()) :: :ok
  def release_dispatch(lane_id, token), do: GenServer.call(__MODULE__, {:release_dispatch, lane_id, token})

  @doc "Quiesces and removes a lane from this authority, including queued preflights and restarts."
  @spec remove(lane_id()) :: :ok
  def remove(lane_id), do: GenServer.call(__MODULE__, {:remove, lane_id}, :infinity)

  @doc "Executes a DB mutation and publishes it under the same authority as guard acquisition. The callback receives an identity checker and must return a committed transaction result."
  @spec mutate(lane_id() | nil, ((Schema.t() -> :ok | {:error, term()}) -> term()), String.t() | nil) :: term()
  def mutate(lane_id, fun, reason) do
    case Process.whereis(__MODULE__) do
      nil -> :global.trans({__MODULE__, self()}, fn -> fun.(&allow_identity/1) end)
      pid -> GenServer.call(pid, {:mutate, lane_id, fun, reason}, :infinity)
    end
  end

  @spec check_identity(lane_id() | nil, Schema.t()) :: :ok | {:error, :environment_identity_in_use}
  def check_identity(nil, _settings), do: :ok

  def check_identity(lane_id, settings) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, {:check_identity, lane_id, effective_identity(settings), settings})
    end
  end

  @spec protect_environment(lane_id(), binary() | nil) :: {:ok, reference()} | {:error, term()}
  def protect_environment(lane_id, identity), do: GenServer.call(__MODULE__, {:protect_environment, lane_id, identity})

  @spec protect_environment(lane_id(), binary() | nil, reference()) :: {:ok, reference()} | {:error, term()}
  def protect_environment(lane_id, identity, token), do: GenServer.call(__MODULE__, {:protect_environment, lane_id, identity, token})

  @spec release_environment(lane_id(), reference(), :empty_inventory) :: :ok | {:error, term()}
  def release_environment(lane_id, token, :empty_inventory), do: GenServer.call(__MODULE__, {:release_environment, lane_id, token})

  @doc false
  @spec preflight_result(Entry.t(), :ok | {:error, term()}, (-> :ok | {:ok, pid()} | {:error, term()})) :: :ok
  def preflight_result(entry, result, on_ok), do: GenServer.cast(__MODULE__, {:preflight_result, entry, result, on_ok})

  @doc false
  @spec stop_runtime(lane_id()) :: :ok
  def stop_runtime(lane_id), do: GenServer.call(__MODULE__, {:stop_runtime, lane_id}, :infinity)

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    state = %{
      guards: %{},
      monitors: %{},
      reservation_monitors: %{},
      reservations: %{},
      retained: %{},
      pending_preflights: %{},
      file?: Keyword.has_key?(opts, :file)
    }

    case Keyword.fetch(opts, :file) do
      {:ok, path} ->
        case load_file(path) do
          {:ok, entry} ->
            publish(entry)
            {:ok, ensure_guard(state, entry)}

          {:error, reason} ->
            {:stop, reason}
        end

      :error ->
        :ok = Repo.migrate()

        state = Enum.reduce(Lanes.list(), state, &restore_lane/2)

        {:ok, state, {:continue, :start_lanes}}
    end
  end

  @impl true
  def handle_continue(:start_lanes, state) do
    {:noreply, Enum.reduce(list(), state, &apply_runtime(nil, &1, &2))}
  end

  @impl true
  def handle_call({:mutate, lane_id, fun, reason}, _from, state) do
    result = Repo.transaction(fn -> prepare_mutation(lane_id, fun, state) end)
    publish_mutation(result, reason, state)
  end

  def handle_call({:refresh, id}, _from, state) do
    case refresh_lane(id, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reserve_dispatch, id, owner}, _from, state) do
    case lookup(id) do
      {:ok, %Entry{enabled: true, error: nil, settings: %Schema{}} = entry} ->
        token = make_ref()
        monitor = Process.monitor(owner)
        reservation = %{lane_id: id, owner: owner, monitor: monitor, identity: effective_identity(entry.settings)}

        state = %{state | reservations: Map.put(state.reservations, token, reservation), reservation_monitors: Map.put(state.reservation_monitors, monitor, token)}
        {:reply, {:ok, token, entry}, state}

      {:ok, %Entry{error: error}} ->
        {:reply, {:error, {:lane_invalid, error}}, state}

      _ ->
        {:reply, {:error, {:lane_unavailable, id}}, state}
    end
  end

  def handle_call({:release_dispatch, id, token}, _from, state) do
    {:reply, :ok, release_reservation(state, id, token)}
  end

  def handle_call({:remove, id}, _from, state), do: {:reply, :ok, remove_lane(id, state)}

  def handle_call({:stop_runtime, id}, _from, state) do
    update_entry(id, &%{&1 | enabled: false, generation: make_ref(), runtime: %{&1.runtime | started_at: nil}})
    Runs.finish_lane(id, "stopped")
    LaneSupervisor.stop_lane(id)
    {:reply, :ok, state |> forget_monitors(id) |> forget_preflight(id)}
  end

  def handle_call({:put_entry, entry}, _from, state) do
    if identity_allowed?(state, entry) do
      entry = %{entry | generation: make_ref()}
      publish(entry)
      {:reply, :ok, ensure_guard(state, entry)}
    else
      {:reply, {:error, :environment_identity_in_use}, state}
    end
  end

  def handle_call({:mark_error, id, message}, _from, state) do
    update_entry(id, &%{&1 | error: message, generation: make_ref()})
    {:reply, :ok, state}
  end

  def handle_call({:check_identity, id, identity, settings}, _from, state), do: {:reply, identity_check(state, id, identity, settings), state}

  def handle_call({:protect_environment, id, identity, token}, _from, state) do
    case Map.get(state.guards, id) do
      %{identity: ^identity, token: ^token} -> {:reply, {:ok, token}, state}
      _ -> {:reply, {:error, :invalid_environment_guard}, state}
    end
  end

  def handle_call({:protect_environment, id, identity}, _from, state) do
    if state.file? and id == file_lane_id() and is_nil(identity) do
      token = make_ref()
      {:reply, {:ok, token}, put_in(state.guards[id], %{identity: nil, token: token})}
    else
      current =
        case settings(id) do
          {:ok, settings} ->
            if is_nil(EnvironmentConfig.identity(settings)), do: nil, else: effective_identity(settings)

          _ ->
            :unavailable
        end

      if current == identity and identity_check(state, id, identity) == :ok do
        token = make_ref()
        {:reply, {:ok, token}, put_in(state.guards[id], %{identity: identity, token: token})}
      else
        {:reply, {:error, :environment_identity_in_use}, state}
      end
    end
  end

  def handle_call({:release_environment, id, token}, _from, state) do
    case Map.get(state.guards, id) do
      %{token: ^token} -> {:reply, :ok, %{state | guards: Map.delete(state.guards, id)}}
      _ -> {:reply, {:error, :invalid_environment_guard}, state}
    end
  end

  @impl true
  def handle_cast({:preflight_result, captured, result, on_ok}, state) do
    case lookup(captured.lane_id) do
      {:ok, %Entry{enabled: true, error: nil} = current} when current.generation == captured.generation ->
        state = forget_preflight(state, current.lane_id)
        {:noreply, complete_preflight(result, current, on_ok, state)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.reservation_monitors, ref) do
      {token, reservation_monitors} when not is_nil(token) ->
        state = %{state | reservation_monitors: reservation_monitors, reservations: Map.delete(state.reservations, token)}
        {:noreply, state}

      {nil, _} ->
        handle_runtime_down(ref, reason, state)
    end
  end

  def handle_info({:restart_lane, id, generation}, state) do
    state =
      case lookup(id) do
        {:ok, %Entry{generation: ^generation, enabled: true, error: nil} = entry} -> apply_runtime(nil, entry, state)
        _ -> state
      end

    {:noreply, state}
  end

  defp handle_runtime_down(ref, reason, state) do
    {id, monitors} = Map.pop!(state.monitors, ref)
    {:ok, entry} = lookup(id)
    state = %{state | monitors: monitors}
    # Explicit stops detach their monitors; a monitored :shutdown is supervisor failure.
    normal? = reason == :normal
    Runs.finish_lane(id, if(normal?, do: "stopped", else: "failed"))

    if normal? do
      publish(%{entry | runtime: %{entry.runtime | started_at: nil}})
      {:noreply, state}
    else
      {:noreply, record_crash(entry, reason, state)}
    end
  end

  defp allow_identity(_settings), do: :ok

  defp restore_lane(lane, state) do
    # A previous authority's runtimes hold stale environment tokens. Restart them
    # together rather than letting those tokens outlive their owner.
    if LaneSupervisor.running?(lane.id), do: LaneSupervisor.stop_lane(lane.id)
    Runs.finish_lane(lane.id, "failed")

    entry =
      case build_entry(lane, nil) do
        {:ok, entry} ->
          entry

        {:error, error} ->
          persist_disabled(lane.id)
          invalid_entry(lane, nil, error)
      end

    publish(entry)
    ensure_guard(state, entry)
  end

  defp prepare_mutation(lane_id, fun, state) do
    check = fn settings -> identity_check(state, lane_id, effective_identity(settings), settings) end

    case fun.(check) do
      {:ok, value} -> prepare_publication(value, lane_id, state)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp prepare_publication({:batch, value, ids}, _lane_id, state) when is_list(ids) do
    entries = Enum.map(ids, &prepare_entry!(&1, state, false))
    validate_location_ownership!(entries)
    {:mutation, value, entries, ids}
  end

  defp prepare_publication(lane, lane_id, state) do
    id = if lane, do: lane.id, else: lane_id
    ids = if is_nil(id), do: [], else: [id]
    entries = Enum.map(ids, &prepare_entry!(&1, state, true))
    validate_location_ownership!(entries)
    {:mutation, lane, entries, ids}
  end

  defp validate_location_ownership!(prepared) do
    current = Map.new(list(), &{&1.lane_id, &1})

    current =
      Enum.reduce(prepared, current, fn
        %{id: id, entry: nil}, acc -> Map.delete(acc, id)
        %{id: id, entry: entry}, acc -> Map.put(acc, id, entry)
      end)

    entries = Map.values(current)

    case Enum.find_value(entries, fn left ->
           Enum.find_value(entries, fn right ->
             if left.lane_id < right.lane_id and locations_overlap?(left.settings, right.settings),
               do: {:workspace_identity_in_use, left.lane_id, right.lane_id}
           end)
         end) do
      nil -> :ok
      reason -> Repo.rollback(reason)
    end
  end

  defp locations_overlap?(%Schema{} = left, %Schema{} = right) do
    left = EnvironmentConfig.location(left)
    right = EnvironmentConfig.location(right)

    targets_overlap?(left.targets, right.targets) and roots_overlap?(left.root, right.root)
  end

  defp locations_overlap?(_, _), do: false

  defp targets_overlap?(left, right), do: Enum.any?(left, &(&1 in right))

  defp roots_overlap?(left, right) when is_binary(left) and is_binary(right) do
    left_parts = Path.split(left)
    right_parts = Path.split(right)
    prefix?(left_parts, right_parts) or prefix?(right_parts, left_parts)
  end

  defp roots_overlap?(_, _), do: false

  defp prefix?(parts, prefix), do: Enum.take(parts, length(prefix)) == prefix

  defp prepare_entry!(id, state, allow_invalid) do
    lane = Lanes.get_any(id)
    previous = previous_entry(id)

    case lane do
      nil ->
        %{id: id, lane: nil, previous: previous, entry: nil}

      %{deleted_at: nil} ->
        case build_entry(lane, previous) do
          {:ok, entry} ->
            if identity_allowed?(state, entry), do: %{id: id, lane: lane, previous: previous, entry: entry}, else: Repo.rollback(:environment_identity_in_use)

          {:error, error} when allow_invalid and not lane.enabled ->
            %{id: id, lane: lane, previous: previous, entry: invalid_entry(lane, previous, error)}

          {:error, error} ->
            Repo.rollback({:lane_invalid, id, error})
        end

      lane ->
        if allow_invalid do
          %{id: id, lane: lane, previous: previous, entry: nil}
        else
          case build_entry(lane, previous) do
            {:ok, entry} ->
              if identity_allowed?(state, entry), do: %{id: id, lane: lane, previous: previous, entry: nil}, else: Repo.rollback(:environment_identity_in_use)

            {:error, error} ->
              Repo.rollback({:lane_invalid, id, error})
          end
        end
    end
  end

  defp publish_mutation({:ok, {:mutation, value, prepared, _ids}}, reason, state) do
    entries = Enum.map(prepared, &maybe_reason(&1.entry, reason))

    true =
      :ets.insert(
        @table,
        Enum.flat_map(entries, fn
          nil -> []
          entry -> [{entry.lane_id, entry}]
        end)
      )

    Enum.each(entries, fn entry ->
      if entry do
        broadcast(entry)
        log_entry(entry)
      end
    end)

    state =
      Enum.zip(prepared, entries)
      |> Enum.reduce(state, fn
        {%{previous: _previous}, nil}, acc ->
          acc

        {%{previous: previous}, entry}, acc ->
          acc
          |> ensure_guard(entry)
          |> then(fn acc ->
            if entry.enabled, do: acc, else: forget_monitors(acc, entry.lane_id)
          end)
          |> then(&apply_runtime(previous, entry, &1))
      end)

    removed = Enum.filter(prepared, &is_nil(&1.entry))
    state = Enum.reduce(removed, state, fn %{id: id}, acc -> remove_lane(id, acc) end)
    {:reply, {:ok, value}, state}
  end

  defp publish_mutation({:error, error}, _reason, state), do: {:reply, {:error, error}, state}

  defp maybe_reason(nil, _reason), do: nil
  defp maybe_reason(entry, nil), do: entry
  defp maybe_reason(entry, reason), do: %{entry | error: reason}

  defp publish_runtime(previous, entry, state) do
    publish(entry)
    if previous && previous.slug != entry.slug, do: ObservabilityPubSub.broadcast_lane(previous.slug)
    state = ensure_guard(state, entry)
    state = if entry.enabled, do: state, else: forget_monitors(state, entry.lane_id)
    apply_runtime(previous, entry, state)
  end

  defp complete_preflight(:ok, entry, on_ok, state) do
    case on_ok.() do
      {:ok, pid} when is_pid(pid) -> attach_runtime(state, entry.lane_id, pid)
      {:error, reason} -> disable_entry(entry, "runtime failed to start: #{inspect(reason)}", state)
      :ok -> state
    end
  end

  defp complete_preflight({:error, reason}, entry, _on_ok, state) do
    message = "Tracker preflight failed: #{format_preflight_error(reason)}"
    Logger.error("Lane disabled lane_id=#{entry.lane_id} lane=#{entry.slug} reason=#{message}")
    disable_entry(entry, message, state)
  end

  defp previous_entry(id) do
    case lookup(id) do
      {:ok, entry} -> entry
      :error -> nil
    end
  end

  defp refresh_lane(id, state) do
    previous = previous_entry(id)

    case Lanes.get(id) do
      nil ->
        {:ok, remove_lane(id, state)}

      lane ->
        refresh_entry(lane, previous, state)
    end
  end

  defp refresh_entry(lane, previous, state) do
    case build_entry(lane, previous) do
      {:ok, entry} ->
        if identity_allowed?(state, entry) do
          {:ok, publish_runtime(previous, entry, state)}
        else
          {:error, :environment_identity_in_use}
        end

      {:error, error} ->
        persist_disabled(lane.id)
        entry = invalid_entry(lane, previous, error)

        entry =
          case previous do
            %Entry{settings: %Schema{}} ->
              %{
                previous
                | enabled: false,
                  name: lane.name,
                  slug: lane.slug,
                  profile_id: lane.execution_profile_id,
                  profile_name: profile_name(lane),
                  workspace_subdir: lane.workspace_subdir,
                  generation: entry.generation,
                  error: Lanes.format_errors(error)
              }

            _ ->
              entry
          end

        {:ok, publish_runtime(previous, entry, state)}
    end
  end

  defp build_entry(lane, previous) do
    base = %Entry{
      lane_id: lane.id,
      slug: lane.slug,
      name: lane.name,
      enabled: lane.enabled,
      executor: lane.executor,
      profile_id: lane.execution_profile_id,
      profile_name: profile_name(lane),
      workspace_subdir: lane.workspace_subdir,
      version_id: lane.current_version_id,
      generation: make_ref(),
      runtime: (previous && previous.runtime) || %Entry{}.runtime
    }

    case Lanes.resolve_lane(lane) do
      {:ok, validated} ->
        version = Lanes.current_version(lane)

        {:ok,
         %{
           base
           | config_identity: config_identity(base, validated),
             front_matter: version.front_matter,
             prompt: version.prompt,
             settings: validated.settings,
             workflow: validated.workflow,
             warnings: validated.warnings
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp invalid_entry(lane, previous, error) do
    version = Lanes.current_version(lane)

    base = %Entry{
      lane_id: lane.id,
      slug: lane.slug,
      name: lane.name,
      enabled: false,
      executor: lane.executor,
      profile_id: lane.execution_profile_id,
      profile_name: profile_name(lane),
      workspace_subdir: lane.workspace_subdir,
      version_id: lane.current_version_id,
      generation: make_ref(),
      runtime: (previous && previous.runtime) || %Entry{}.runtime
    }

    if version do
      %{base | front_matter: version.front_matter, prompt: version.prompt, error: Lanes.format_errors(error)}
    else
      %{base | error: Lanes.format_errors(error)}
    end
  end

  defp profile_name(lane) do
    case lane.execution_profile do
      %SymphonyElixir.ExecutionProfiles.Profile{name: name} ->
        name

      _ ->
        case SymphonyElixir.ExecutionProfiles.get(lane.execution_profile_id) do
          %{name: name} -> name
          _ -> nil
        end
    end
  end

  defp apply_runtime(_previous, %Entry{enabled: false} = entry, state) do
    Runs.finish_lane(entry.lane_id, "stopped")
    LaneSupervisor.stop_lane(entry.lane_id)
    update_entry(entry.lane_id, &%{&1 | runtime: %{&1.runtime | started_at: nil}})
    forget_preflight(state, entry.lane_id)
  end

  defp apply_runtime(previous, entry, state) do
    cond do
      is_binary(entry.error) ->
        state

      # A late start from an old authority must be adopted during restoration or enable.
      runtime_start_required?(previous, entry.lane_id, state.pending_preflights) ->
        LaneSupervisor.start_lane(entry)
        put_in(state.pending_preflights[entry.lane_id], :start)

      tracker_changed?(previous, entry) or Map.has_key?(state.pending_preflights, entry.lane_id) ->
        # Every publication has a new generation. Replace a still-pending check
        # even when this save changes only metadata or the prompt.
        LaneSupervisor.preflight_async(entry, fn -> notify_orchestrator(entry.lane_id) end)
        put_in(state.pending_preflights[entry.lane_id], :refresh)

      true ->
        notify_orchestrator(entry.lane_id)
        state
    end
  end

  defp runtime_start_required?(%Entry{enabled: true}, id, pending) do
    pending[id] == :start or not LaneSupervisor.running?(id)
  end

  defp runtime_start_required?(_previous, _id, _pending), do: true

  defp forget_preflight(state, id), do: %{state | pending_preflights: Map.delete(state.pending_preflights, id)}

  defp release_reservation(state, id, token) do
    case Map.get(state.reservations, token) do
      %{lane_id: ^id, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])

        %{
          state
          | reservations: Map.delete(state.reservations, token),
            reservation_monitors: Map.delete(state.reservation_monitors, monitor)
        }

      _ ->
        state
    end
  end

  # A successful start and its monitor are one serialized transition. An
  # explicit stop can never be followed by an attachment to the old runtime.
  defp attach_runtime(state, id, pid) do
    state = forget_monitors(state, id)
    ref = Process.monitor(pid)
    update_entry(id, &%{&1 | runtime: %{&1.runtime | started_at: DateTime.utc_now()}})
    %{state | monitors: Map.put(state.monitors, ref, id)}
  end

  defp tracker_changed?(%Entry{settings: %Schema{tracker: old}}, %Entry{settings: %Schema{tracker: new}}), do: old != new

  defp notify_orchestrator(id) do
    if pid = LaneRegistry.whereis(id, :orchestrator), do: send(pid, {:lane_updated, id})
    :ok
  end

  defp remove_lane(id, state) do
    previous = lookup(id)
    :ets.delete(@table, id)
    Runs.finish_lane(id, "stopped")
    LaneSupervisor.stop_lane(id)

    if match?({:ok, _}, previous) do
      {:ok, entry} = previous
      broadcast(entry)
    end

    state = state |> forget_monitors(id) |> forget_preflight(id)

    reservations =
      Enum.reduce(state.reservations, state.reservations, fn {token, reservation}, acc ->
        if reservation.lane_id == id, do: Map.delete(acc, token), else: acc
      end)

    reservation_monitors =
      Enum.reduce(state.reservation_monitors, state.reservation_monitors, fn {monitor, token}, acc ->
        if not Map.has_key?(reservations, token) do
          Process.demonitor(monitor, [:flush])
          Map.delete(acc, monitor)
        else
          acc
        end
      end)

    %{state | guards: Map.delete(state.guards, id), reservations: reservations, reservation_monitors: reservation_monitors, retained: Map.delete(state.retained, id)}
  end

  defp forget_monitors(state, id) do
    monitors =
      Enum.reduce(state.monitors, %{}, fn {ref, lane_id}, acc ->
        if lane_id == id do
          Process.demonitor(ref, [:flush])
          acc
        else
          Map.put(acc, ref, lane_id)
        end
      end)

    %{state | monitors: monitors}
  end

  defp identity_check(state, id, identity, settings \\ nil)
  defp identity_check(_state, nil, _identity, _settings), do: :ok

  defp identity_check(state, id, identity, settings) do
    reservation = Enum.find_value(state.reservations, fn {_token, value} -> if value.lane_id == id, do: value end)

    cond do
      reservation && reservation.identity != identity ->
        {:error, :environment_identity_in_use}

      reservation ->
        :ok

      true ->
        case Map.get(state.guards, id) do
          nil -> :ok
          %{identity: ^identity} -> :ok
          %{identity: old_identity} -> allow_identity_change(state, id, old_identity, settings)
        end
    end
  end

  defp identity_allowed?(_state, %Entry{settings: nil}), do: true
  defp identity_allowed?(state, entry), do: identity_check(state, entry.lane_id, effective_identity(entry.settings), entry.settings) == :ok

  defp allow_identity_change(state, id, old_identity, new_settings) do
    case Map.get(state.retained, id) || previous_entry(id) do
      %Entry{settings: %Schema{} = settings} ->
        if managed_identity?(settings) do
          {:error, :environment_identity_in_use}
        else
          case Workspace.location_inventory(settings) do
            :empty -> verify_new_location(new_settings)
            _ -> {:error, :environment_identity_in_use}
          end
        end

      _ ->
        if old_identity == nil, do: verify_new_location(new_settings), else: {:error, :environment_identity_in_use}
    end
  end

  defp verify_new_location(%Schema{} = settings) do
    if managed_identity?(settings) do
      :ok
    else
      case Workspace.location_inventory(settings) do
        :empty -> :ok
        _ -> {:error, :environment_identity_in_use}
      end
    end
  end

  defp verify_new_location(_settings), do: :ok

  defp managed_identity?(settings), do: not is_nil(EnvironmentConfig.identity(settings))

  defp effective_identity(settings) do
    EnvironmentConfig.identity(settings) || EnvironmentConfig.location_identity(settings)
  end

  defp config_identity(%Entry{profile_id: profile_id, workspace_subdir: subdir}, validated) do
    :crypto.hash(:sha256, :erlang.term_to_binary({profile_id, subdir, validated.settings, validated.workflow}))
  end

  defp ensure_guard(state, %Entry{settings: %Schema{} = settings, lane_id: id}) do
    identity = effective_identity(settings)

    case Map.get(state.guards, id) do
      %{identity: ^identity} -> state
      _ -> put_in(state.guards[id], %{identity: identity, token: make_ref()})
    end
  end

  defp ensure_guard(state, _entry), do: state

  defp publish(entry) do
    :ets.insert(@table, {entry.lane_id, entry})
    log_entry(entry)
    broadcast(entry)
    :ok
  end

  defp log_entry(entry) do
    Enum.each(entry.warnings, &Logger.warning("Lane configuration warning lane_id=#{entry.lane_id} lane=#{entry.slug} message=#{&1}"))
    if entry.error, do: Logger.error("Lane configuration error lane_id=#{entry.lane_id} lane=#{entry.slug} reason=#{entry.error}")
  end

  defp broadcast(entry) do
    ObservabilityPubSub.broadcast_update()
    ObservabilityPubSub.broadcast_lane(entry.slug)
  end

  defp update_entry(id, fun) do
    case lookup(id) do
      {:ok, entry} -> publish(fun.(entry))
      :error -> :ok
    end
  end

  defp record_crash(entry, reason, state) do
    now = System.monotonic_time(:millisecond)
    crashes = [now | Enum.filter(entry.runtime.crashes, &(now - &1 < @crash_window_ms))]

    runtime = %{
      entry.runtime
      | crashes: crashes,
        restarts: entry.runtime.restarts + 1,
        started_at: nil,
        last_crash: %{reason: inspect(reason), at: DateTime.utc_now()}
    }

    entry = %{entry | runtime: runtime}

    if length(crashes) >= @max_crashes do
      disable_entry(entry, "runtime crashed repeatedly; last reason: #{inspect(reason)}", state)
    else
      publish(entry)
      Process.send_after(self(), {:restart_lane, entry.lane_id, entry.generation}, @restart_delay_ms)
      state
    end
  end

  defp disable_entry(entry, message, state) do
    unless state.file?, do: persist_disabled(entry.lane_id)

    entry = %{
      entry
      | enabled: false,
        error: message,
        generation: make_ref(),
        runtime: %{entry.runtime | started_at: nil}
    }

    publish(entry)
    Runs.finish_lane(entry.lane_id, "failed")
    LaneSupervisor.stop_lane(entry.lane_id)
    state |> forget_monitors(entry.lane_id) |> forget_preflight(entry.lane_id)
  end

  defp persist_disabled(id) do
    id |> Lanes.get!() |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
  end

  defp load_file(path) do
    with {:ok, content} <- File.read(path),
         %{front_matter: front_matter, prompt: prompt} <- Workflow.split(content),
         {:ok, workflow} <- Workflow.parse_parts(front_matter, prompt),
         {:ok, settings} <- Schema.parse(Map.delete(workflow.config, "server")),
         :ok <- Config.validate_settings(settings) do
      {:ok,
       %Entry{
         lane_id: file_lane_id(),
         slug: "workflow",
         name: path,
         enabled: true,
         executor: "local",
         generation: make_ref(),
         settings: settings,
         workflow: workflow,
         front_matter: front_matter,
         prompt: prompt,
         warnings: Lanes.warnings(front_matter)
       }}
    end
  end

  defp format_preflight_error({:linear_preflight_failed, reasons}) when is_list(reasons), do: Enum.join(reasons, "; ")
  defp format_preflight_error(reason) when is_binary(reason), do: reason
  defp format_preflight_error(reason), do: inspect(reason)
end
