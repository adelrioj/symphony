defmodule SymphonyElixirWeb.ConsoleComponents do
  @moduledoc "Function components for the operator console."

  import Phoenix.Component, only: [sigil_H: 2, link: 1]

  alias SymphonyElixirWeb.Console

  @doc "Builds a console URL from the current view, applying `overrides` (lane, group, attention, selected)."
  @spec console_path(map(), keyword()) :: String.t()
  def console_path(nav, overrides \\ []) do
    nav = Map.merge(nav, Map.new(overrides))

    query =
      Enum.reject(
        [
          lane: nav.lane,
          group: if(nav.group in [:tracker, "tracker"], do: "tracker"),
          attention: if(nav.attention, do: "1"),
          ticket: nav.selected
        ],
        fn {_key, value} -> is_nil(value) end
      )

    if query == [], do: "/", else: "/?" <> URI.encode_query(query)
  end

  @spec lane_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def lane_nav(assigns) do
    ~H"""
    <a class="console-brand" href="/">Symphony</a>
    <nav class="console-lanes" aria-label="Lanes">
      <.link patch={console_path(@nav, lane: nil)} class="console-lane" aria-current={to_string(is_nil(@nav.lane))}>
        All lanes <span class="console-count">{length(@tickets)}</span>
      </.link>
      <%= for entry <- @entries do %>
        <.link
          id={"lane-nav-#{entry.slug}"}
          patch={console_path(@nav, lane: entry.slug)}
          class="console-lane"
          aria-current={to_string(@nav.lane == entry.slug)}
        >
          <span class={"console-dot console-dot--#{lane_health(entry, @tickets)}"}></span>
          {entry.name}
          <.backend name={Console.agent_setting(entry, :backend, "codex")} />
          <span :if={entry.enabled} class="console-count">{count(@tickets, entry.slug, "running")}/{Console.agent_setting(entry, :max_concurrent_agents, 0)}</span>
          <span :if={not entry.enabled} class="console-count">off</span>
        </.link>
        <p :if={Console.recent_crash?(entry, @now)} id={"lane-crash-#{entry.slug}"} class="console-restarts">
          restarted {entry.runtime.restarts}× · last crash {Calendar.strftime(entry.runtime.last_crash.at, "%H:%M")}
        </p>
      <% end %>
      <.link
        id="attention-toggle"
        patch={console_path(@nav, attention: not @nav.attention)}
        class="console-lane"
        aria-current={to_string(@nav.attention)}
      >
        Needs attention <span class="console-count">{Enum.count(@tickets, &(not &1.history and &1.status == "blocked"))}</span>
      </.link>
    </nav>
    <nav class="console-configure" aria-label="Configure">
      <p class="console-h">Configure</p>
      <a class="console-lane" href="/lanes">Lanes</a>
      <a class="console-lane" href="/execution-profiles">Execution profiles</a>
    </nav>
    """
  end

  @spec ticket_list(map()) :: Phoenix.LiveView.Rendered.t()
  def ticket_list(assigns) do
    ~H"""
    <div class="console-list" id="console-list" role="listbox" aria-label="Tickets">
      <p :if={@groups == []} class="empty-state">No tickets match.</p>
      <section :for={group <- @groups} class="console-group" data-group={group.key}>
        <h2 class="console-group-head">
          <span class={"console-st console-st--#{group.icon}"}></span>
          {group.label}
          <span :if={group.category} class="console-cat">{group.category}</span>
          <span class="console-count">{length(group.tickets)}</span>
        </h2>
        <p :if={group.tickets == []} class="console-empty">Nothing here.</p>
        <.link
          :for={ticket <- group.tickets}
          patch={console_path(@nav, selected: ticket.key)}
          class="console-row"
          role="option"
          data-ticket={ticket.key}
          aria-selected={to_string(@nav.selected == ticket.key)}
        >
          <span class="console-id mono">{ticket.identifier}</span>
          <span class={"console-st console-st--#{ticket.status}"}></span>
          <span class="console-title">
            {ticket.title || ticket.identifier}
            <span :for={blocker <- ticket.blocked_by} class="console-chip">⊘ {blocker}</span>
          </span>
          <span class="console-meta">
            <span :if={ticket.attempt && ticket.attempt > 1} class="console-attempt">attempt {ticket.attempt}</span>
            <span class="console-chip">{if @nav.group == :status and not ticket.history, do: ticket.tracker_state, else: ticket.status}</span>
            <.backend name={ticket.backend} />
            <span :if={is_nil(@nav.lane)} class="console-lane-tag">{ticket.lane}</span>
          </span>
          <span :if={ticket.status == "running"} class="console-sub">
            <span class="console-live"></span><span class="mono">{Console.duration(ticket.started_at, @now)}</span>
            · Turn {ticket.turn_count}
            <span :if={ticket.tokens} class="mono">
              · {Console.format_tokens(ticket.tokens.input_tokens)} in · {Console.format_tokens(ticket.tokens.output_tokens)} out
            </span>
            <span :if={ticket.last_message}>· {ticket.last_message}</span>
          </span>
          <span :if={not ticket.history and ticket.status in ["blocked", "retrying"]} class="console-sub console-sub--warn">
            {ticket.error}{if ticket.due_at, do: " · retry in #{Console.duration(@now, ticket.due_at)}"}
          </span>
        </.link>
      </section>
    </div>
    """
  end

  defp backend(assigns), do: ~H(<span class={"console-backend console-backend--#{@name}"}>{@name}</span>)

  defp count(tickets, slug, status),
    do: Enum.count(tickets, &(&1.lane == slug and not &1.history and &1.status == status))

  defp lane_health(entry, tickets) do
    cond do
      not entry.enabled -> "off"
      count(tickets, entry.slug, "blocked") > 0 -> "warn"
      count(tickets, entry.slug, "running") > 0 -> "on"
      true -> "idle"
    end
  end
end
