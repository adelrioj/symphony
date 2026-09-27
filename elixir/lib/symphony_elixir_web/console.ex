defmodule SymphonyElixirWeb.Console do
  @moduledoc """
  Pure projections for the operator console. Flattens lane snapshots and durable
  run history into tickets, groups them by run status or tracker state, and
  sizes each lane's agent strip.
  """

  alias SymphonyElixir.LaneStore.Entry
  alias SymphonyElixir.Runs.Run

  @type lane_view :: %{entry: Entry.t(), payload: map(), runs: [Run.t()]}
  @type ticket :: map()
  @type group :: %{
          key: String.t(),
          label: String.t(),
          icon: String.t(),
          category: String.t() | nil,
          tickets: [ticket()]
        }

  @finished_limit 20
  @live_statuses ~w(running blocked retrying queued)
  # Live groups take live tickets by status; "finished" takes every history ticket, whatever its run status.
  @status_groups [
    {"running", "Running"},
    {"blocked", "Needs attention"},
    {"retrying", "Retry queue"},
    {"queued", "Queued"},
    {"finished", "Finished"}
  ]
  @category_order %{"active" => 0, "blocked" => 1, "terminal" => 2}

  @spec tickets([lane_view()]) :: [ticket()]
  def tickets(views), do: Enum.flat_map(views, &lane_tickets/1)

  @spec groups([ticket()], :status | :tracker, [Entry.t()]) :: [group()]
  def groups(tickets, :status, _entries) do
    for {key, label} <- @status_groups do
      %{
        key: key,
        label: label,
        icon: key,
        category: nil,
        tickets: Enum.filter(tickets, &if(key == "finished", do: &1.history, else: not &1.history and &1.status == key))
      }
    end
  end

  def groups(tickets, :tracker, entries) do
    {finished, live} = Enum.split_with(tickets, & &1.history)

    {state_groups, other} =
      Enum.map_reduce(tracker_states(entries), live, fn {state, category}, remaining ->
        {mine, rest} =
          Enum.split_with(remaining, &same_state?(&1.tracker_state, state))

        {%{
           key: "state:" <> state,
           label: state,
           icon: category,
           category: category,
           tickets: mine
         }, rest}
      end)

    Enum.reject(
      state_groups ++
        [
          %{
            key: "other",
            label: "Other states",
            icon: "queued",
            category: nil,
            tickets: other
          },
          %{
            key: "finished",
            label: "Finished runs",
            icon: "finished",
            category: nil,
            tickets: finished
          }
        ],
      &(&1.tickets == [])
    )
  end

  @spec strip(Entry.t(), [ticket()]) ::
          %{agents: [ticket()], idle: non_neg_integer(), max: non_neg_integer()}
  def strip(%Entry{} = entry, tickets) do
    agents =
      Enum.filter(
        tickets,
        &(&1.lane == entry.slug and not &1.history and &1.status in ["running", "blocked"])
      )

    max =
      if entry.enabled,
        do: agent_setting(entry, :max_concurrent_agents, 0),
        else: 0

    running = Enum.count(agents, &(&1.status == "running"))
    %{agents: agents, idle: max(max - running, 0), max: max}
  end

  @spec agent_setting(Entry.t(), atom(), term()) :: term()
  def agent_setting(%Entry{settings: %{agent: agent}}, key, _default) do
    Map.get(agent, key)
  end

  def agent_setting(_entry, _key, default), do: default

  @spec describe_event(map()) :: String.t()
  def describe_event(%{"message" => message})
      when is_binary(message) and message != "" do
    message
  end

  def describe_event(%{"total_tokens" => total} = payload) do
    "in #{payload["input_tokens"]} / out #{payload["output_tokens"]} / " <>
      "cached #{payload["cached_tokens"] || 0} / total #{total}"
  end

  def describe_event(%{"event" => event}) when is_binary(event), do: event
  def describe_event(payload), do: Jason.encode!(payload)

  @spec external_url(term()) :: String.t() | nil
  def external_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  def external_url(_url), do: nil

  defp lane_tickets(%{entry: entry, payload: payload, runs: runs}) do
    live =
      Enum.flat_map(@live_statuses, fn status ->
        payload
        |> Map.get(String.to_existing_atom(status), [])
        |> Enum.map(&live_ticket(entry, status, &1))
      end)

    live_ids = MapSet.new(live, & &1.issue_id)

    finished =
      runs
      |> Enum.reject(&(&1.status == "running" or MapSet.member?(live_ids, &1.issue_id)))
      |> Enum.uniq_by(& &1.issue_id)
      |> Enum.take(@finished_limit)
      |> Enum.map(&run_ticket(entry, &1))

    live ++ finished
  end

  defp live_ticket(entry, status, item) do
    %{
      key: entry.slug <> ":" <> item.issue_id,
      lane: entry.slug,
      issue_id: item.issue_id,
      identifier: item.issue_identifier,
      title: Map.get(item, :title),
      tracker_state: Map.get(item, :state),
      status: status,
      history: false,
      labels: Map.get(item, :labels) || [],
      url: external_url(Map.get(item, :issue_url)),
      blocked_by: Map.get(item, :blocked_by, []),
      attempt: Map.get(item, :attempt),
      turn_count: Map.get(item, :turn_count),
      last_message: Map.get(item, :last_message),
      error: Map.get(item, :error),
      due_at: Map.get(item, :due_at),
      started_at: Map.get(item, :started_at),
      tokens: Map.get(item, :tokens)
    }
  end

  defp run_ticket(entry, %Run{} = run) do
    %{
      key: entry.slug <> ":" <> run.issue_id,
      lane: entry.slug,
      issue_id: run.issue_id,
      identifier: run.issue_identifier,
      title: run.issue_title,
      tracker_state: run.issue_state,
      status: run.status,
      history: true,
      labels: [],
      url: nil,
      blocked_by: [],
      attempt: run.attempt,
      turn_count: run.turns,
      last_message: nil,
      error: nil,
      due_at: nil,
      started_at: DateTime.to_iso8601(run.started_at),
      tokens: %{
        input_tokens: run.input_tokens,
        output_tokens: run.output_tokens,
        total_tokens: run.input_tokens + run.output_tokens
      }
    }
  end

  # Merged case-insensitively in category order; the first spelling seen
  # names the group.
  defp tracker_states(entries) do
    entries
    |> Enum.flat_map(fn
      %Entry{settings: %{tracker: tracker, agent: agent}} ->
        Enum.map(tracker.active_states || [], &{&1, "active"}) ++
          [{agent.blocked_state, "blocked"}] ++
          Enum.map(tracker.terminal_states || [], &{&1, "terminal"})

      _entry ->
        []
    end)
    |> Enum.sort_by(fn {_state, category} -> Map.fetch!(@category_order, category) end)
    |> Enum.uniq_by(fn {state, _category} -> String.downcase(state) end)
  end

  defp same_state?(state, group_state) when is_binary(state) do
    String.downcase(state) == String.downcase(group_state)
  end

  defp same_state?(_state, _group_state), do: false
end
