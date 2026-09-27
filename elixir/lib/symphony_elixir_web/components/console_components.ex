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
        [lane: nav.lane, group: if(nav.group in [:tracker, "tracker"], do: "tracker"), attention: if(nav.attention, do: "1"), ticket: nav.selected],
        fn {_key, value} -> is_nil(value) end
      )

    if query == [], do: "/", else: "/?" <> URI.encode_query(query)
  end

  @spec lane_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def lane_nav(assigns) do
    ~H"""
    <nav class="console-lanes" aria-label="Lanes">
      <.link patch={console_path(@nav, lane: nil)} class="console-lane" aria-current={to_string(is_nil(@nav.lane))}>
        All lanes <span class="console-count">{length(@tickets)}</span>
      </.link>
      <.link
        :for={entry <- @entries}
        id={"lane-nav-#{entry.slug}"}
        patch={console_path(@nav, lane: entry.slug)}
        class="console-lane"
        aria-current={to_string(@nav.lane == entry.slug)}
      >
        <span class={"console-dot console-dot--#{lane_health(entry, @tickets)}"}></span>
        {entry.name}
        <span class="console-backend">{Console.agent_setting(entry, :backend, "codex")}</span>
        <span class="console-count">{count(@tickets, entry.slug, "running")}/{Console.agent_setting(entry, :max_concurrent_agents, 0)}</span>
      </.link>
      <.link
        id="attention-toggle"
        patch={console_path(@nav, attention: not @nav.attention)}
        class="console-lane"
        aria-current={to_string(@nav.attention)}
      >
        Needs attention <span class="console-count">{Enum.count(@tickets, &(&1.status == "blocked"))}</span>
      </.link>
      <a class="console-lane console-lane--manage" href="/lanes">Manage lanes</a>
    </nav>
    """
  end

  @spec strip(map()) :: Phoenix.LiveView.Rendered.t()
  def strip(assigns) do
    ~H"""
    <section class="console-strip" aria-label="Live agents">
      <div :for={{entry, strip} <- @strips} class="console-strip-lane" id={"strip-#{entry.slug}"}>
        <p class="console-strip-head">
          <span class={"console-dot console-dot--#{lane_health(entry, @tickets)}"}></span>
          {entry.name}
          <span class="console-backend">{Console.agent_setting(entry, :backend, "codex")}</span>
        </p>
        <div class="console-tiles">
          <.link
            :for={ticket <- strip.agents}
            patch={console_path(@nav, selected: ticket.key)}
            class={"console-tile console-tile--#{ticket.status}"}
            data-ticket={ticket.key}
          >
            <span class="console-tile-head">
              <span class="mono">{ticket.identifier}</span>
              <span :if={ticket.status == "running"} class="mono muted">T{ticket.turn_count}/{Console.agent_setting(entry, :max_turns, 0)}</span>
              <span :if={ticket.status == "blocked"} class="console-pill console-pill--blocked">blocked</span>
            </span>
            <span class="console-tile-title">{ticket.title || ticket.identifier}</span>
            <span class="console-tile-msg">{ticket.error || ticket.last_message}</span>
          </.link>
          <span :if={strip.idle > 0} class="console-tile console-tile--idle">{strip.idle} idle</span>
          <span :if={not entry.enabled} class="console-tile console-tile--idle">Disabled</span>
        </div>
      </div>
    </section>
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
            <span :if={ticket.attempt && ticket.attempt > 1} class="mono muted">attempt {ticket.attempt}</span>
            <span class="console-chip">{if @nav.group == :status, do: ticket.tracker_state, else: ticket.status}</span>
            <span :if={is_nil(@nav.lane)} class="console-lane-tag">{ticket.lane}</span>
          </span>
          <span :if={ticket.status == "running"} class="console-sub">
            <span class="console-live"></span>Turn {ticket.turn_count} · {ticket.last_message}
          </span>
          <span :if={ticket.status in ["blocked", "retrying"]} class="console-sub console-sub--warn">
            {ticket.error}{if ticket.due_at, do: " · next attempt #{ticket.due_at}"}
          </span>
        </.link>
      </section>
    </div>
    """
  end

  defp count(tickets, slug, status), do: Enum.count(tickets, &(&1.lane == slug and &1.status == status))

  defp lane_health(entry, tickets) do
    cond do
      not entry.enabled -> "off"
      count(tickets, entry.slug, "blocked") > 0 -> "warn"
      count(tickets, entry.slug, "running") > 0 -> "on"
      true -> "idle"
    end
  end
end
