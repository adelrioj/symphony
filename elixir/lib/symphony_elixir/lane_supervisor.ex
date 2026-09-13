defmodule SymphonyElixir.LaneSupervisor do
  @moduledoc "Temporary per-lane runtimes. LaneStore owns restart accounting and accepts preflight results only for the current generation."
  use DynamicSupervisor
  require Logger
  alias SymphonyElixir.{AgentRuntimeSupervisor, LaneContext, LaneRegistry, LaneStore, Tracker}
  alias SymphonyElixir.LaneStore.Entry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec running?(term()) :: boolean()
  def running?(lane_id), do: is_pid(LaneRegistry.whereis(lane_id, :runtime))

  @spec start_lane(Entry.t()) :: :ok
  def start_lane(%Entry{} = entry), do: preflight_async(entry, fn -> start_runtime(entry) end)

  @spec preflight_async(Entry.t(), (-> :ok | {:ok, pid()} | {:error, term()})) :: :ok
  def preflight_async(%Entry{} = entry, on_ok) do
    # The worker never performs mutations. Both success and failure go back through
    # the serialized store so disable/delete/update cannot race a stale result.
    {:ok, _} =
      Task.start(fn ->
        LaneContext.put(entry.lane_id)
        LaneStore.preflight_result(entry, safe_preflight(entry), on_ok)
      end)

    :ok
  end

  @spec stop_lane(term()) :: :ok
  def stop_lane(lane_id) do
    owner = Process.whereis(LaneStore)

    if is_pid(owner) and owner != self() do
      LaneStore.stop_runtime(lane_id)
    else
      terminate_runtime(lane_id)
    end
  end

  defp terminate_runtime(lane_id) do
    if supervisor = Process.whereis(__MODULE__) do
      # A dead authority's start request can be queued without a Registry entry.
      # Drain accepted starts before deciding there is no runtime to terminate.
      DynamicSupervisor.which_children(supervisor)

      case LaneRegistry.whereis(lane_id, :runtime) do
        pid when is_pid(pid) ->
          DynamicSupervisor.terminate_child(supervisor, pid)
          Logger.info("Lane runtime stopped lane_id=#{inspect(lane_id)}")

        nil ->
          :ok
      end
    end

    :ok
  end

  defp start_runtime(%Entry{lane_id: id, slug: slug}) do
    if runtime = LaneRegistry.whereis(id, :runtime) do
      {:ok, runtime}
    else
      spec =
        Supervisor.child_spec(
          {AgentRuntimeSupervisor, lane_id: id, name: LaneRegistry.via(id, :runtime), task_supervisor_name: LaneRegistry.via(id, :tasks), orchestrator_name: LaneRegistry.via(id, :orchestrator)},
          id: {:lane, id},
          restart: :temporary
        )

      case DynamicSupervisor.start_child(__MODULE__, spec) do
        {:ok, pid} ->
          Logger.info("Lane runtime started lane_id=#{inspect(id)} lane=#{slug} pid=#{inspect(pid)}")
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp safe_preflight(%Entry{settings: settings}) do
    case Tracker.preflight(settings.tracker) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
