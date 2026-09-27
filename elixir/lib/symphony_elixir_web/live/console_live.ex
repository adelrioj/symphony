defmodule SymphonyElixirWeb.ConsoleLive do
  @moduledoc "Operator console: each lane's live agents above one ticket list, with a run panel."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import SymphonyElixirWeb.ConsoleComponents

  alias SymphonyElixir.{LaneStore, Runs}
  alias SymphonyElixirWeb.{Console, ObservabilityPubSub, Presenter}

  @snapshot_timeout_ms 2_000
  @history_limit 20
  @event_limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()
    {:ok, assign(socket, :panel, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    nav = %{
      lane: blank_to_nil(params["lane"]),
      group: if(params["group"] == "tracker", do: :tracker, else: :status),
      attention: params["attention"] == "1",
      selected: blank_to_nil(params["ticket"])
    }

    {:noreply, socket |> assign(nav: nav, panel: nil) |> load()}
  end

  @impl true
  # ponytail: reloads every lane on each broadcast; debounce here if many lanes make this slow.
  def handle_info(:observability_updated, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="console" id="console">
      <aside class="console-side">
        <.lane_nav nav={@nav} entries={@entries} tickets={@tickets} />
      </aside>
      <section class="console-main">
        <header class="console-top">
          <h1 class="console-heading">Tickets</h1>
          <div class="console-seg" role="group" aria-label="Group by">
            <.link id="group-status" patch={console_path(@nav, group: :status)} aria-current={to_string(@nav.group == :status)}>Run status</.link>
            <.link id="group-tracker" patch={console_path(@nav, group: :tracker)} aria-current={to_string(@nav.group == :tracker)}>Tracker state</.link>
          </div>
        </header>
        <.strip nav={@nav} strips={@strips} tickets={@tickets} />
        <.ticket_list nav={@nav} groups={@groups} />
      </section>
      <aside class="console-detail" id="console-detail" aria-label="Ticket detail">
        <p :if={is_nil(@ticket)} class="empty-state">Select a ticket or agent to see its run.</p>
        <div :if={@ticket} class="console-detail-body">
          <p class="console-detail-head">
            <span class="muted">{@ticket.lane}</span> › <strong class="mono">{@ticket.identifier}</strong>
            <a :if={@ticket.url} class="subtle-button" href={@ticket.url} target="_blank" rel="noopener noreferrer">Open in tracker</a>
          </p>
          <h2 class="console-detail-title">{@ticket.title || @ticket.identifier}</h2>
          <p :if={@ticket.labels != []}><span :for={label <- @ticket.labels} class="console-chip">{label}</span></p>
          <dl class="console-kv">
            <dt>Tracker state</dt>
            <dd>{@ticket.tracker_state || "unknown"}</dd>
            <dt>Run status</dt>
            <dd><span class={"console-pill console-pill--#{@ticket.status}"}>{@ticket.status}</span></dd>
            <dt :if={@ticket.turn_count}>Turns</dt>
            <dd :if={@ticket.turn_count}>{@ticket.turn_count} / {Console.agent_setting(@detail.entry, :max_turns, 0)}</dd>
            <dt :if={@ticket.tokens}>Tokens</dt>
            <dd :if={@ticket.tokens} class="mono">{@ticket.tokens.input_tokens} in · {@ticket.tokens.output_tokens} out</dd>
            <dt :if={@ticket.blocked_by != []}>Blocked by</dt>
            <dd :if={@ticket.blocked_by != []}>{Enum.join(@ticket.blocked_by, ", ")}</dd>
          </dl>
          <p :if={@ticket.error} class="error-copy">{@ticket.error}</p>
          <section :if={@ticket.last_message}>
            <h3 class="console-h">Latest agent message</h3>
            <p class="console-msg">{@ticket.last_message}</p>
          </section>
          <section :if={@detail.attempts != []}>
            <h3 class="console-h">Attempts</h3>
            <a :for={run <- @detail.attempts} class="console-chip" href={"/runs/#{run.attempt_id}"}>attempt {run.attempt || 1} · {run.status}</a>
          </section>
          <section :if={@detail.events != []}>
            <h3 class="console-h">Activity</h3>
            <ol class="console-events">
              <li :for={event <- @detail.events}>
                <time class="mono muted" datetime={DateTime.to_iso8601(event.at)}>{Calendar.strftime(event.at, "%H:%M:%S")}</time>
                <span class={"console-k console-k--#{event.kind}"}></span>
                <strong>{event.kind}</strong>
                <span>{Console.describe_event(event.payload)}</span>
              </li>
            </ol>
          </section>
          <footer class="console-actions">
            <a :if={@detail.attempts != []} class="subtle-button" href={"/runs/#{hd(@detail.attempts).attempt_id}"}>Full run log</a>
          </footer>
        </div>
      </aside>
    </section>
    """
  end

  defp load(socket) do
    %{nav: nav} = socket.assigns
    entries = LaneStore.list()
    views = Enum.map(entries, &%{entry: &1, payload: Presenter.lane_payload(&1, @snapshot_timeout_ms), runs: Runs.list_for_lane(&1.lane_id, @history_limit)})
    tickets = Console.tickets(views)
    scoped = Enum.filter(entries, &(is_nil(nav.lane) or &1.slug == nav.lane))
    visible = Enum.filter(tickets, &((is_nil(nav.lane) or &1.lane == nav.lane) and (not nav.attention or &1.status == "blocked")))
    ticket = Enum.find(tickets, &(&1.key == nav.selected))

    assign(socket,
      entries: entries,
      tickets: tickets,
      strips: Enum.map(scoped, &{&1, Console.strip(&1, tickets)}),
      groups: Console.groups(visible, nav.group, scoped),
      ticket: ticket,
      detail: detail(ticket, entries)
    )
  end

  defp detail(nil, _entries), do: nil

  defp detail(ticket, entries) do
    entry = Enum.find(entries, &(&1.slug == ticket.lane))
    attempts = Runs.for_issue(entry.lane_id, ticket.issue_id, @history_limit)

    events =
      case attempts do
        [latest | _] -> latest.id |> Runs.events() |> Enum.take(-@event_limit)
        [] -> []
      end

    %{entry: entry, attempts: attempts, events: events}
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
