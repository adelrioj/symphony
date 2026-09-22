defmodule SymphonyElixir.Runs do
  @moduledoc """
  Best-effort durable attempt history. Scheduler writes only enqueue commands on a
  single supervised writer; they never call or wait for Repo. Pending commands are
  volatile and database failures are logged, not retried.

  Reads and `flush/0` wait for preceding commands from the caller. They belong on
  observation/maintenance paths, never the scheduler's dispatch or cleanup path.
  """

  use Supervisor
  import Ecto.Query

  alias SymphonyElixir.{LaneStore, Repo}
  alias SymphonyElixir.Runs.{Event, Retention, Run, Writer}
  alias SymphonyElixir.Tracker.Issue

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([Writer, Retention], strategy: :rest_for_one)

  @spec started(map()) :: :ok
  def started(%{lane_id: lane_id, issue: %Issue{} = issue, attempt_id: attempt_id} = attrs) do
    snapshot = dispatch_snapshot(attrs, lane_id)

    enqueue(
      {:started,
       %{
         lane_id: lane_id,
         lane_version_id: Map.get(snapshot, :lane_version_id),
         execution_profile_id: Map.get(snapshot, :execution_profile_id),
         config_identity: Map.get(snapshot, :config_identity),
         executor: Map.get(snapshot, :executor),
         issue_id: issue.id,
         issue_identifier: issue.identifier,
         issue_state: issue.state,
         attempt_id: attempt_id,
         attempt: Map.get(attrs, :attempt),
         worker_ref: Map.get(attrs, :worker_ref),
         owner_pid: Map.get(attrs, :owner_pid, self()),
         status: "running",
         started_at: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    )
  end

  @spec event(String.t(), map(), map(), non_neg_integer()) :: :ok
  def event(attempt_id, %{event: _event} = update, token_delta, turns) when is_binary(attempt_id) do
    enqueue({:event, attempt_id, update, token_delta, turns, DateTime.utc_now()})
  end

  @spec finished(String.t(), String.t()) :: :ok
  def finished(attempt_id, status) when is_binary(attempt_id), do: enqueue({:finished, attempt_id, status, now()})

  @doc "Finalizes only running attempts; use stopped for disable and failed for runtime death."
  @spec finish_lane(term(), String.t()) :: :ok
  def finish_lane(lane_id, status), do: enqueue({:finish_lane, lane_id, status, now()})

  @spec flush() :: :ok
  def flush, do: GenServer.call(Writer, :flush, :infinity)

  @spec get_by_attempt(String.t()) :: Run.t() | nil
  def get_by_attempt(attempt_id) when is_binary(attempt_id) do
    flush()
    Repo.get_by(Run, attempt_id: attempt_id)
  end

  @spec events(integer()) :: [Event.t()]
  def events(run_id) do
    flush()
    Repo.all(from(e in Event, where: e.run_id == ^run_id, order_by: e.id))
  end

  @spec list_for_lane(term(), pos_integer()) :: [Run.t()]
  def list_for_lane(lane_id, limit) do
    flush()
    Repo.all(from(r in Run, where: r.lane_id == ^lane_id, order_by: [desc: r.started_at, desc: r.id], limit: ^limit))
  end

  @doc "Synchronously prunes events only, serialized with history writes. Failures return zero and warn."
  @spec prune_events(pos_integer()) :: non_neg_integer()
  def prune_events(days) when is_integer(days) and days > 0, do: GenServer.call(Writer, {:prune_events, days}, :infinity)

  @spec kind_for(term()) :: String.t()
  def kind_for(event) when is_atom(event), do: event |> Atom.to_string() |> kind_for()

  def kind_for(event) when is_binary(event) do
    cond do
      event in ~w(session_started turn_started) -> "turn_started"
      event in ~w(turn_completed turn_finished result completed) -> "turn_finished"
      event in ~w(blocked attempt_blocked turn_input_required input_required needs_input approval_required) -> "blocked"
      event in ~w(error turn_failed startup_failed session_failed turn_cancelled) -> "error"
      event == "hook" or String.starts_with?(event, "hook_") -> "hook"
      true -> "agent_message"
    end
  end

  def kind_for(_event), do: "agent_message"

  defp dispatch_snapshot(attrs, lane_id) do
    current =
      case LaneStore.lookup(lane_id) do
        {:ok, entry} ->
          %{
            lane_version_id: entry.version_id,
            execution_profile_id: entry.profile_id,
            config_identity: entry.config_identity,
            executor: entry.executor
          }

        _ ->
          %{}
      end

    Map.merge(current, Map.take(attrs, [:lane_version_id, :execution_profile_id, :config_identity, :executor]))
  end

  defp enqueue(command), do: GenServer.cast(Writer, command)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
