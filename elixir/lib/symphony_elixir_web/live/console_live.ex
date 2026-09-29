defmodule SymphonyElixirWeb.ConsoleLive do
  @moduledoc "Operator console: a lane sidebar, one ticket list, and a run panel."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import SymphonyElixirWeb.ConsoleComponents

  alias SymphonyElixir.{LaneStore, OperatorActions, Runs}
  alias SymphonyElixirWeb.{Console, ObservabilityPubSub, Presenter}

  @snapshot_timeout_ms 2_000
  @history_limit 20
  @event_limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()
    {:ok, assign(socket, panel: nil, collapsed: MapSet.new(), detail_open: true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    nav = %{
      lane: blank_to_nil(params["lane"]),
      group: if(params["group"] == "tracker", do: :tracker, else: :status),
      attention: params["attention"] == "1",
      selected: blank_to_nil(params["ticket"])
    }

    socket = assign(socket, nav: nav, panel: nil)
    socket = if nav.selected, do: assign(socket, :detail_open, true), else: socket
    {:noreply, load(socket)}
  end

  @impl true
  # ponytail: reloads every lane on each broadcast; debounce here if many lanes make this slow.
  def handle_info(:observability_updated, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("panel", _params, %{assigns: %{ticket: %{source: :environment}}} = socket),
    do: reject_environment_action(socket)

  def handle_event("panel", %{"panel" => panel}, socket) when panel in ["stop", "reply"],
    do: {:noreply, assign(socket, :panel, panel)}

  def handle_event("poll", _params, socket) do
    %{entries: entries, nav: nav} = socket.assigns

    refreshed =
      for entry <- entries,
          is_nil(nav.lane) or entry.slug == nav.lane,
          match?({:ok, _}, Presenter.refresh_payload(Presenter.orchestrator_for(entry))),
          do: entry

    socket =
      if refreshed == [],
        do: put_flash(socket, :error, "No lane is running, so nothing was polled."),
        else: put_flash(socket, :info, "Polling #{length(refreshed)} lane(s) now.")

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :panel, nil)}

  def handle_event("toggle_detail", _params, socket),
    do: {:noreply, update(socket, :detail_open, &(not &1))}

  def handle_event("toggle_group", %{"group" => key}, socket) do
    collapsed = socket.assigns.collapsed
    collapsed = if MapSet.member?(collapsed, key), do: MapSet.delete(collapsed, key), else: MapSet.put(collapsed, key)
    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  def handle_event("deselect", _params, socket),
    do: {:noreply, push_patch(socket, to: console_path(socket.assigns.nav, selected: nil))}

  def handle_event("stop", _params, socket), do: act(socket, "stopped", &OperatorActions.stop/2)
  def handle_event("retry_now", _params, socket), do: act(socket, "dispatched", &OperatorActions.retry_now/2)
  def handle_event("approve", _params, socket), do: act(socket, "resumed", &OperatorActions.resume(&1, &2, nil))

  def handle_event("reply", %{"message" => message}, socket),
    do: act(socket, "resumed with your reply", &OperatorActions.resume(&1, &2, message))

  @impl true
  def render(assigns) do
    ~H"""
    <section class={["console", not @detail_open && "console--closed"]} id="console">
      <aside class="console-side">
        <.lane_nav nav={@nav} entries={@entries} tickets={@tickets} now={@now} />
      </aside>
      <section class="console-main">
        <header class="console-top">
          <h1 class="console-heading">Tickets</h1>
          <div class="console-seg" role="group" aria-label="Group by">
            <.link id="group-status" patch={console_path(@nav, group: :status)} aria-current={to_string(@nav.group == :status)}>Run status</.link>
            <.link id="group-tracker" patch={console_path(@nav, group: :tracker)} aria-current={to_string(@nav.group == :tracker)}>Tracker state</.link>
          </div>
          <button id="poll-trackers" type="button" class="subtle-button" phx-click="poll">↻ Poll trackers</button>
        </header>
        <.ticket_list nav={@nav} groups={@groups} now={@now} collapsed={@collapsed} />
      </section>
      <button
        id="detail-toggle"
        type="button"
        class="console-tab"
        phx-click="toggle_detail"
        aria-expanded={to_string(@detail_open)}
        aria-controls="console-detail"
        title={if @detail_open, do: "Hide details", else: "Show details"}
      >
        {if @detail_open, do: ">", else: "<"}
      </button>
      <aside class="console-detail" id="console-detail" aria-label="Ticket detail">
        <div id="detail-resize" class="console-resize" phx-hook="DetailResize" title="Drag to resize"></div>
        <p :if={is_nil(@ticket)} class="empty-state">Select a ticket or agent to see its run.</p>
        <p :if={@ticket} class="console-detail-head">
          <span class="muted">{@ticket.lane}</span> › <strong class="mono">{@ticket.identifier}</strong>
          <a :if={@ticket.url} class="subtle-button" href={@ticket.url} target="_blank" rel="noopener noreferrer">Open in tracker</a>
        </p>
        <div :if={@ticket} class="console-detail-body">
          <h2 class="console-detail-title">{@ticket.title || @ticket.identifier}</h2>
          <p :if={@ticket.labels != []}><span :for={label <- @ticket.labels} class="console-chip">{label}</span></p>
          <dl class="console-kv">
            <dt>{if @ticket.history, do: "Tracker state at dispatch", else: "Tracker state"}</dt>
            <dd>{@ticket.tracker_state || "unknown"}</dd>
            <dt>Run status</dt>
            <dd><span class={"console-pill console-pill--#{@ticket.status}"}>{@ticket.status}</span></dd>
            <dt :if={@ticket.turn_count}>Turns</dt>
            <dd :if={@ticket.turn_count}>{@ticket.turn_count} / {Console.agent_setting(@detail.entry, :max_turns, 0)}</dd>
            <dt :if={@ticket.status == "running" and @ticket.started_at}>Elapsed</dt>
            <dd :if={@ticket.status == "running" and @ticket.started_at} class="mono">{Console.duration(@ticket.started_at, @now)}</dd>
            <dt :if={@ticket.tokens}>Tokens</dt>
            <dd :if={@ticket.tokens} class="mono">
              {Console.format_tokens(@ticket.tokens.input_tokens)} in · {Console.format_tokens(@ticket.tokens.output_tokens)} out
              <span :if={@detail.attempts != []}>· {Console.format_tokens(hd(@detail.attempts).cached_tokens)} cached</span>
            </dd>
            <dt :if={@ticket.session_id}>Session</dt>
            <dd :if={@ticket.session_id} class="mono">{@ticket.session_id}</dd>
            <dt :if={@ticket.worker_host}>Worker</dt>
            <dd :if={@ticket.worker_host} class="mono">{@ticket.worker_host}</dd>
            <dt :if={@ticket.workspace_path}>Workspace</dt>
            <dd :if={@ticket.workspace_path} class="mono">{@ticket.workspace_path}</dd>
            <dt :if={@ticket.blocked_by != []}>Blocked by</dt>
            <dd :if={@ticket.blocked_by != []}>{Enum.join(@ticket.blocked_by, ", ")}</dd>
          </dl>
          <section :if={@ticket.environment} id="environment-detail">
            <h3 class="console-h">Workstation</h3>
            <dl class="console-kv">
              <dt>Phase</dt>
              <dd>{@ticket.environment[:phase] || "unknown"}</dd>
              <dt>Desired state</dt>
              <dd>{@ticket.environment[:desired] || "unknown"}</dd>
              <dt>Occupies slot</dt>
              <dd>{slot_occupancy(@ticket.environment[:occupies_slot])}</dd>
              <dt :if={@ticket.environment[:credential]}>Credential stage</dt>
              <dd :if={@ticket.environment[:credential]}>{@ticket.environment.credential[:stage] || "unknown"}</dd>
              <dt :if={get_in(@ticket.environment, [:credential, :reason])}>Credential reason</dt>
              <dd :if={get_in(@ticket.environment, [:credential, :reason])}>{@ticket.environment.credential.reason}</dd>
              <dt :if={get_in(@ticket.environment, [:unresolved, :code])}>Unresolved code</dt>
              <dd :if={get_in(@ticket.environment, [:unresolved, :code])}>{@ticket.environment.unresolved.code}</dd>
            </dl>
          </section>
          <p :if={@ticket.error} class="error-copy">{@ticket.error}</p>
          <p :if={@ticket.status == "queued"} id="queued-note" class="muted">
            No run yet. {if @ticket.blocked_by != [],
              do: "Waiting on #{Enum.join(@ticket.blocked_by, ", ")}.",
              else: "Dispatches when a slot frees up."}
          </p>
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
              <li :for={event <- @detail.events} class={if event.kind == "turn_started", do: "console-turn"}>
                <time class="mono muted" datetime={DateTime.to_iso8601(event.at)}>{Calendar.strftime(event.at, "%H:%M:%S")}</time>
                <span :if={event.kind == "turn_started"}>New turn</span>
                <span :if={event.kind != "turn_started"} class={"console-k console-k--#{event.kind}"} title={event.kind}></span>
                <span :if={event.kind != "turn_started"}>{event.text}</span>
              </li>
            </ol>
          </section>
          </div>
          <footer :if={@ticket} class="console-actions">
            <div :if={@ticket.source == :runtime and @panel == "stop"} class="console-confirm" id="stop-confirm">
              <p>
                <strong>Stop this run?</strong>
                The agent session ends now and the workspace is kept. The ticket stays in
                "{@ticket.tracker_state}" and is dispatched again on the next poll unless you move it.
              </p>
              <p>
                <button type="button" class="subtle-button" phx-click="cancel">Keep running</button>
                <button type="button" class="danger-button" phx-click="stop">Stop run</button>
              </p>
            </div>
            <form :if={@ticket.source == :runtime and @panel == "reply"} id="reply-form" class="console-reply" phx-submit="reply">
              <label for="reply-message">
                Message to the agent. It is posted on the ticket, and the ticket moves back to an active state.
              </label>
              <textarea id="reply-message" name="message" required></textarea>
              <p>
                <button type="button" class="subtle-button" phx-click="cancel">Cancel</button>
                <button type="submit">Send and resume</button>
              </p>
            </form>
            <button :if={is_nil(@panel) and @ticket.source == :runtime and @ticket.status == "blocked"} type="button" phx-click="approve">
              Approve &amp; resume
            </button>
            <button
              :if={is_nil(@panel) and @ticket.source == :runtime and @ticket.status == "blocked"}
              type="button"
              class="subtle-button"
              phx-click="panel"
              phx-value-panel="reply"
            >
              Reply to agent
            </button>
            <button :if={is_nil(@panel) and @ticket.source == :runtime and @ticket.status == "retrying"} type="button" phx-click="retry_now">
              Retry now
            </button>
            <button
              :if={is_nil(@panel) and @ticket.source == :runtime and @ticket.status == "running"}
              type="button"
              class="danger-button"
              phx-click="panel"
              phx-value-panel="stop"
            >
              Stop run
            </button>
            <a :if={is_nil(@panel) and @detail.attempts != []} class="subtle-button" href={"/runs/#{hd(@detail.attempts).attempt_id}"}>
              Full run log
            </a>
          </footer>
      </aside>
    </section>
    """
  end

  defp load(socket) do
    %{nav: nav} = socket.assigns
    entries = LaneStore.list()

    views =
      Enum.map(
        entries,
        &%{
          entry: &1,
          payload: Presenter.lane_payload(&1, @snapshot_timeout_ms),
          runs: Runs.list_for_lane(&1.lane_id, @history_limit)
        }
      )

    tickets = Console.tickets(views)
    scoped = Enum.filter(entries, &(is_nil(nav.lane) or &1.slug == nav.lane))

    visible =
      Enum.filter(
        tickets,
        &((is_nil(nav.lane) or &1.lane == nav.lane) and
            (not nav.attention or (not &1.history and &1.status == "blocked")))
      )

    ticket = Enum.find(tickets, &(&1.key == nav.selected))

    assign(socket,
      now: DateTime.utc_now(),
      entries: entries,
      tickets: tickets,
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
        # Token rows and repeats are dropped from the feed, so read past them to fill it.
        [latest | _] ->
          latest.id |> Runs.recent_events(@event_limit * 3) |> Console.activity() |> Enum.take(-@event_limit)

        [] ->
          []
      end

    %{entry: entry, attempts: attempts, events: events}
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp slot_occupancy(true), do: "yes"
  defp slot_occupancy(false), do: "no"
  defp slot_occupancy(_value), do: "unknown"

  defp reject_environment_action(socket) do
    {:noreply,
     socket
     |> assign(:panel, nil)
     |> put_flash(:error, "No agent run is available for this workstation.")}
  end

  defp act(%{assigns: %{ticket: %{source: :environment}}} = socket, _verb, _action),
    do: reject_environment_action(socket)

  defp act(%{assigns: %{ticket: %{} = ticket, detail: %{entry: entry}}} = socket, verb, action) do
    socket =
      case action.(Presenter.orchestrator_for(entry), ticket.issue_id) do
        :ok -> put_flash(socket, :info, "#{ticket.identifier} #{verb}.")
        {:error, reason} -> put_flash(socket, :error, "#{ticket.identifier} was not changed: #{reason_text(reason)}.")
      end

    {:noreply, socket |> assign(:panel, nil) |> load()}
  end

  defp act(socket, _verb, _action), do: {:noreply, put_flash(socket, :error, "Select a ticket first.")}

  defp reason_text(:not_running), do: "its run already ended"
  defp reason_text(:not_retrying), do: "it is no longer waiting to retry"
  defp reason_text(:unavailable), do: "the lane is not running"
  defp reason_text(:not_blocked), do: "it is no longer blocked"
  defp reason_text(:no_active_state), do: "the lane has no active state to move it to"
  defp reason_text(reason), do: "the tracker returned #{inspect(reason)}"
end
