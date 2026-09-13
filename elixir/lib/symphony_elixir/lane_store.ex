defmodule SymphonyElixir.LaneStore do
  @moduledoc "Runtime lane authority: lock-free ETS reads, serialized writes and environment ownership, and fenced runtime lifecycle."
  use GenServer
  require Logger

  alias SymphonyElixir.{Config, LaneRegistry, Lanes, LaneSupervisor, Repo, Runs, Workflow}
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
      :version_id,
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
      pid -> GenServer.call(pid, {:check_identity, lane_id, EnvironmentConfig.identity(settings)})
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
    state = %{guards: %{}, monitors: %{}, pending_preflights: %{}, file?: Keyword.has_key?(opts, :file)}

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

  def handle_call({:check_identity, id, identity}, _from, state), do: {:reply, identity_check(state, id, identity), state}

  def handle_call({:protect_environment, id, identity, token}, _from, state) do
    case Map.get(state.guards, id) do
      %{identity: ^identity, token: ^token} -> {:reply, {:ok, token}, state}
      _ -> {:reply, {:error, :invalid_environment_guard}, state}
    end
  end

  def handle_call({:protect_environment, id, identity}, _from, state) do
    current =
      case settings(id) do
        {:ok, settings} -> EnvironmentConfig.identity(settings)
        _ -> :unavailable
      end

    if current == identity and identity_check(state, id, identity) == :ok do
      token = make_ref()
      {:reply, {:ok, token}, put_in(state.guards[id], %{identity: identity, token: token})}
    else
      {:reply, {:error, :environment_identity_in_use}, state}
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

  def handle_info({:restart_lane, id, generation}, state) do
    state =
      case lookup(id) do
        {:ok, %Entry{generation: ^generation, enabled: true, error: nil} = entry} -> apply_runtime(nil, entry, state)
        _ -> state
      end

    {:noreply, state}
  end

  defp allow_identity(_settings), do: :ok

  defp restore_lane(lane, state) do
    # A previous authority's runtimes hold stale environment tokens. Restart them
    # together rather than letting those tokens outlive their owner.
    if LaneSupervisor.running?(lane.id), do: LaneSupervisor.stop_lane(lane.id)
    Runs.finish_lane(lane.id, "failed")
    entry = lane |> build_entry(nil) |> disable_invalid_entry()
    publish(entry)
    ensure_guard(state, entry)
  end

  defp prepare_mutation(lane_id, fun, state) do
    check = fn settings -> identity_check(state, lane_id, EnvironmentConfig.identity(settings)) end

    case fun.(check) do
      {:ok, lane} -> prepare_publication(lane, lane_id, state)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp prepare_publication(lane, lane_id, state) do
    id = if lane, do: lane.id, else: lane_id
    previous = previous_entry(id)
    entry = mutation_entry(lane, previous)
    if entry && not identity_allowed?(state, entry), do: Repo.rollback(:environment_identity_in_use)
    {lane, id, previous, entry}
  end

  defp mutation_entry(nil, _previous), do: nil

  defp mutation_entry(%{deleted_at: nil} = lane, previous),
    do: lane |> build_entry(previous) |> keep_last_known_good(previous)

  defp mutation_entry(_lane, _previous), do: nil

  defp publish_mutation({:ok, {lane, id, _previous, nil}}, _reason, state),
    do: {:reply, {:ok, lane}, remove_lane(id, state)}

  defp publish_mutation({:ok, {lane, _id, previous, entry}}, reason, state) do
    entry = if reason, do: %{entry | error: reason}, else: entry
    {:reply, {:ok, lane}, publish_runtime(previous, entry, state)}
  end

  defp publish_mutation({:error, error}, _reason, state), do: {:reply, {:error, error}, state}

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
    entry = lane |> build_entry(previous) |> keep_last_known_good(previous)

    if identity_allowed?(state, entry) do
      entry = disable_invalid_entry(entry)
      {:ok, publish_runtime(previous, entry, state)}
    else
      {:error, :environment_identity_in_use}
    end
  end

  defp disable_invalid_entry(%Entry{settings: nil} = entry) do
    persist_disabled(entry.lane_id)
    %{entry | enabled: false}
  end

  defp disable_invalid_entry(entry), do: entry

  defp build_entry(lane, previous) do
    base = %Entry{
      lane_id: lane.id,
      slug: lane.slug,
      name: lane.name,
      enabled: lane.enabled,
      executor: lane.executor,
      version_id: lane.current_version_id,
      generation: make_ref(),
      runtime: (previous && previous.runtime) || %Entry{}.runtime
    }

    case Lanes.current_version(lane) do
      nil ->
        %{base | error: "lane has no version yet"}

      version ->
        base = %{base | front_matter: version.front_matter, prompt: version.prompt}

        case Lanes.validate_version(nil, version.front_matter, version.prompt) do
          {:ok, validated} ->
            %{base | settings: validated.settings, workflow: validated.workflow, warnings: validated.warnings}

          {:error, errors} ->
            %{base | error: Lanes.format_errors(errors)}
        end
    end
  end

  # Keep the effective version ID and raw content pinned to the usable settings.
  defp keep_last_known_good(%Entry{settings: nil} = entry, %Entry{settings: %Schema{}} = previous),
    do: %{previous | enabled: entry.enabled, name: entry.name, slug: entry.slug, generation: entry.generation, error: entry.error}

  defp keep_last_known_good(entry, _previous), do: entry

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
    %{state | guards: Map.delete(state.guards, id)}
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

  defp identity_check(_state, nil, _identity), do: :ok

  defp identity_check(state, id, identity) do
    case Map.get(state.guards, id) do
      nil -> :ok
      %{identity: ^identity} -> :ok
      _ -> {:error, :environment_identity_in_use}
    end
  end

  defp identity_allowed?(_state, %Entry{settings: nil}), do: true
  defp identity_allowed?(state, entry), do: identity_check(state, entry.lane_id, EnvironmentConfig.identity(entry.settings)) == :ok

  defp ensure_guard(state, %Entry{settings: %Schema{} = settings, lane_id: id}) do
    case {EnvironmentConfig.identity(settings), Map.get(state.guards, id)} do
      {nil, _} -> state
      {_, %{}} -> state
      {identity, nil} -> put_in(state.guards[id], %{identity: identity, token: make_ref()})
    end
  end

  defp ensure_guard(state, _entry), do: state

  defp publish(entry) do
    case lookup(entry.lane_id) do
      {:ok, %{generation: generation}} when generation == entry.generation ->
        :ok

      _ ->
        Enum.each(entry.warnings, &Logger.warning("Lane configuration warning lane_id=#{entry.lane_id} lane=#{entry.slug} message=#{&1}"))
        if entry.error, do: Logger.error("Lane configuration error lane_id=#{entry.lane_id} lane=#{entry.slug} reason=#{entry.error}")
    end

    :ets.insert(@table, {entry.lane_id, entry})
    broadcast(entry)
    :ok
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
