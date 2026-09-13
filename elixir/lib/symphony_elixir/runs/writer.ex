defmodule SymphonyElixir.Runs.Writer do
  @moduledoc "Serializes best-effort run writes; publishes only after the complete transaction commits."

  use GenServer
  import Ecto.Query
  require Logger

  alias SymphonyElixir.{Repo, Runs}
  alias SymphonyElixir.Runs.{Event, Run}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast(command, state) do
    result =
      best_effort(
        label(command),
        fn ->
          persist(command)
          :ok
        end,
        :error
      )

    {:noreply, if(result == :ok, do: track_owner(command, state), else: state)}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  def handle_call({:prune_events, days}, _from, state) do
    count = best_effort("prune run events", fn -> prune(days) end, 0)
    {:reply, count, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {%{attempt_id: attempt_id}, state} = Map.pop(state, ref)

    best_effort(
      "record abandoned run finish",
      fn ->
        persist({:finished, attempt_id, "failed", DateTime.utc_now() |> DateTime.truncate(:second)})
      end,
      :ok
    )

    {:noreply, state}
  end

  defp track_owner({:started, %{owner_pid: owner, attempt_id: attempt_id, lane_id: lane_id}}, state) when is_pid(owner) do
    Map.put(state, Process.monitor(owner), %{attempt_id: attempt_id, lane_id: lane_id})
  end

  defp track_owner({:finished, attempt_id, _, _}, state), do: detach_owners(state, &(&1.attempt_id == attempt_id))
  defp track_owner({:finish_lane, lane_id, _, _}, state), do: detach_owners(state, &(&1.lane_id == lane_id))
  defp track_owner(_command, state), do: state

  defp detach_owners(state, matching?) do
    Enum.reduce(state, state, fn {ref, owner}, remaining ->
      if matching?.(owner) do
        Process.demonitor(ref, [:flush])
        Map.delete(remaining, ref)
      else
        remaining
      end
    end)
  end

  defp persist({:started, attrs}) do
    log_context(attrs)
    %Run{} |> Run.changeset(attrs) |> Repo.insert!()
    ObservabilityPubSub.broadcast_update()
  end

  defp persist({:event, attempt_id, update, token_delta, turns, at}) do
    Logger.metadata(attempt_id: attempt_id, session_id: Map.get(update, :session_id))

    {:ok, events} = Repo.transaction(fn -> record_event(attempt_id, update, token_delta, turns, at) end)
    Enum.each(events, &ObservabilityPubSub.broadcast_run(attempt_id, {:run_event, &1}))
    if events != [], do: ObservabilityPubSub.broadcast_update()
  end

  defp persist({:finished, attempt_id, status, at}) do
    validate_terminal_status!(status)
    Logger.metadata(attempt_id: attempt_id)
    finish(from(r in Run, where: r.attempt_id == ^attempt_id and r.status == "running"), status, at)
  end

  defp persist({:finish_lane, lane_id, status, at}) do
    validate_terminal_status!(status)
    finish(from(r in Run, where: r.lane_id == ^lane_id and r.status == "running"), status, at)
  end

  defp record_event(attempt_id, update, token_delta, turns, at) do
    case Repo.get_by(Run, attempt_id: attempt_id) do
      %Run{status: "running"} = run -> record_running_event(run, update, token_delta, turns, at)
      _ -> []
    end
  end

  defp record_running_event(run, update, token_delta, turns, at) do
    log_context(run)
    delta = token_delta(token_delta)
    unless is_integer(turns) and turns >= 0, do: raise(ArgumentError, "invalid turn count")

    event =
      insert_event(run.id, at, Runs.kind_for(update.event), %{
        "event" => event_name(update.event),
        "message" => Map.get(update, :message),
        "session_id" => Map.get(update, :session_id)
      })

    usage = if Enum.any?(delta, fn {_key, value} -> value > 0 end), do: [insert_event(run.id, at, "usage", delta)], else: []

    from(r in Run, where: r.id == ^run.id and r.status == "running")
    |> Repo.update_all(
      set: [turns: max(turns, run.turns)],
      inc: [input_tokens: delta["input_tokens"], output_tokens: delta["output_tokens"], cached_tokens: delta["cached_tokens"]]
    )

    [event | usage]
  end

  defp finish(query, status, at) do
    {:ok, runs} =
      Repo.transaction(fn ->
        runs = Repo.all(query)
        Enum.each(runs, &log_context/1)
        Repo.update_all(query, set: [status: status, finished_at: at])
        runs
      end)

    Enum.each(runs, fn run ->
      ObservabilityPubSub.broadcast_run(run.attempt_id, {:run_updated, run.attempt_id})
    end)

    if runs != [], do: ObservabilityPubSub.broadcast_update()
  end

  defp insert_event(run_id, at, kind, payload), do: Repo.insert!(%Event{run_id: run_id, at: at, kind: kind, payload: payload})

  defp token_delta(delta) do
    Map.new([:input_tokens, :output_tokens, :cached_tokens, :total_tokens], fn key ->
      value = Map.get(delta, key, 0)
      unless is_integer(value) and value >= 0, do: raise(ArgumentError, "invalid #{key} delta")
      {Atom.to_string(key), value}
    end)
  end

  defp event_name(event) when is_atom(event), do: Atom.to_string(event)
  defp event_name(event) when is_binary(event), do: event
  defp event_name(event), do: inspect(event)

  defp validate_terminal_status!(status) do
    unless status in Run.statuses() and status != "running", do: raise(ArgumentError, "unknown terminal run status #{inspect(status)}")
  end

  defp prune(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)
    {count, _} = Repo.delete_all(from(e in Event, where: e.at < ^cutoff))
    count
  end

  defp log_context(attrs) do
    Logger.metadata(issue_id: Map.get(attrs, :issue_id), issue_identifier: Map.get(attrs, :issue_identifier), attempt_id: Map.get(attrs, :attempt_id))
  end

  defp label({:started, _}), do: "record run start"
  defp label({:event, _, _, _, _, _}), do: "record run event"
  defp label({:finished, _, _, _}), do: "record run finish"
  defp label({:finish_lane, _, _, _}), do: "record lane run finishes"

  defp best_effort(label, fun, fallback) do
    Logger.reset_metadata([])
    fun.()
  rescue
    error ->
      warn(label, Exception.message(error))
      fallback
  catch
    :exit, reason ->
      warn(label, inspect(reason))
      fallback
  end

  defp warn(label, reason) do
    context = Logger.metadata()

    Logger.warning(
      "Best-effort #{label} failed: #{reason} issue_id=#{context[:issue_id] || "unknown"} issue_identifier=#{context[:issue_identifier] || "unknown"} session_id=#{context[:session_id] || "none"}"
    )
  end
end
