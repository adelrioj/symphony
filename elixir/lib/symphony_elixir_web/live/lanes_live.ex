defmodule SymphonyElixirWeb.LanesLive do
  @moduledoc "Landing page: one card per lane."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{LaneRegistry, Lanes, LaneStore, LaneSupervisor, Orchestrator}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @snapshot_timeout_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()
    {:ok, assign(socket, :lanes, load_lanes())}
  end

  @impl true
  def handle_info(:observability_updated, socket), do: {:noreply, assign(socket, :lanes, load_lanes())}

  @impl true
  def handle_event("toggle", params, socket) do
    result =
      with {lane_id, ""} when lane_id > 0 <- parse_id(params["id"]),
           lane when not is_nil(lane) <- Lanes.get(lane_id) do
        Lanes.set_enabled(lane, not lane.enabled)
      else
        _ -> {:error, [%{path: "lane", message: "Lane no longer exists or has an invalid ID"}]}
      end

    socket =
      case result do
        {:ok, _lane} -> clear_flash(socket, :error)
        {:error, errors} -> put_flash(socket, :error, Enum.map_join(errors, "; ", &"#{&1.path}: #{&1.message}"))
      end

    {:noreply, assign(socket, :lanes, load_lanes())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony</p>
            <h1 class="hero-title">Lanes</h1>
            <p class="hero-copy">Each lane polls one tracker scope with its own prompt, workspace root, and agent settings.</p>
          </div>
          <div class="status-stack">
            <a class="subtle-button" href="/lanes/new">New lane</a>
          </div>
        </div>
      </header>

      <p :if={@lanes == []} class="empty-state">No lanes yet. Import one with <code>mix symphony lanes import</code> or create it here.</p>

      <section class="lane-grid">
        <article :for={lane <- @lanes} class="metric-card" id={"lane-#{lane.entry.slug}"}>
          <p class="metric-label">
            <a class="issue-id issue-id-link" href={"/lanes/#{lane.entry.slug}"}>{lane.entry.name}</a>
            <span class="muted mono">{lane.entry.slug}</span>
          </p>
          <p class="metric-detail">
            <span class={"state-badge " <> badge_class(lane)}>{status_label(lane)}</span>
            <a :if={lane.entry.profile_id} class="issue-link" href={"/execution-profiles/#{lane.entry.profile_id}"}>profile: {lane.entry.profile_name || lane.entry.profile_id}</a>
            <span class="muted mono">workspace {lane.entry.workspace_subdir}</span>
          </p>
          <p :if={lane.counts} class="metric-detail numeric">
            running {lane.counts.running} · claimed {lane.counts.claimed} · blocked {lane.counts.blocked} · next poll {format_ms(lane.counts.next_poll_in_ms)}
          </p>
          <p :if={lane.entry.error} class="error-copy">{lane.entry.error}</p>
          <p :if={lane.entry.runtime.last_crash} class="muted">
            restarts {lane.entry.runtime.restarts} · last crash {lane.entry.runtime.last_crash.reason} at {DateTime.to_iso8601(lane.entry.runtime.last_crash.at)}
          </p>
          <p :for={warning <- lane.entry.warnings} class="muted">{warning}</p>
          <p class="metric-detail">
            <button type="button" class="subtle-button" phx-click="toggle" phx-value-id={lane.entry.lane_id}>
              {if lane.entry.enabled, do: "Disable", else: "Enable"}
            </button>
            <a class="issue-link" href={"/lanes/#{lane.entry.slug}/edit"}>Edit</a>
            <a class="issue-link" href={"/lanes/#{lane.entry.slug}/versions"}>Versions</a>
          </p>
        </article>
      </section>
    </section>
    """
  end

  defp load_lanes do
    Enum.map(LaneStore.list(), fn entry ->
      running? = LaneSupervisor.running?(entry.lane_id)
      %{entry: entry, running?: running?, counts: counts(entry, running?)}
    end)
  end

  defp counts(entry, true) do
    case LaneRegistry.whereis(entry.lane_id, :orchestrator) do
      pid when is_pid(pid) ->
        snapshot_counts(Orchestrator.snapshot(pid, @snapshot_timeout_ms))

      nil ->
        nil
    end
  end

  defp counts(_entry, false), do: nil

  defp snapshot_counts(%{running: running, claimed: claimed, blocked: blocked, polling: polling}) do
    %{running: length(running), claimed: claimed, blocked: length(blocked), next_poll_in_ms: polling.next_poll_in_ms}
  end

  defp snapshot_counts(_snapshot), do: nil

  defp parse_id(id) when is_binary(id), do: Integer.parse(id)
  defp parse_id(_id), do: :error

  defp status_label(%{entry: %{enabled: false}}), do: "disabled"
  defp status_label(%{entry: %{error: error}}) when is_binary(error), do: "error"
  defp status_label(%{running?: true}), do: "running"
  defp status_label(_lane), do: "starting"

  defp badge_class(lane) do
    case status_label(lane) do
      "running" -> "state-badge-active"
      "error" -> "state-badge-danger"
      "starting" -> "state-badge-warning"
      _ -> ""
    end
  end

  defp format_ms(nil), do: "n/a"
  defp format_ms(ms) when is_integer(ms), do: "#{div(max(ms, 0) + 999, 1000)}s"
end
