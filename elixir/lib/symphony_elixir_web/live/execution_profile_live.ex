defmodule SymphonyElixirWeb.ExecutionProfileLive do
  @moduledoc "Shows one execution profile and its linked lanes."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{ExecutionProfiles, LaneStore}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe_profiles()

    case parse_id(id) |> then(&ExecutionProfiles.get/1) do
      nil -> {:ok, socket |> put_flash(:error, "Execution profile not found") |> push_navigate(to: "/execution-profiles")}
      profile -> {:ok, assign_profile(socket, profile) |> assign(:errors, []) |> assign(:confirm_delete, false)}
    end
  end

  @impl true
  def handle_info(:profiles_updated, socket), do: refresh(socket)
  def handle_info(:observability_updated, socket), do: refresh(socket)

  @impl true
  def handle_event("prepare_delete", _params, socket), do: {:noreply, assign(socket, :confirm_delete, true)}

  def handle_event("cancel_delete", _params, socket), do: {:noreply, assign(socket, :confirm_delete, false)}

  def handle_event("delete", _params, socket) do
    case ExecutionProfiles.delete(socket.assigns.profile) do
      :ok -> {:noreply, push_navigate(socket, to: "/execution-profiles")}
      {:error, errors} -> {:noreply, assign(socket, errors: errors, confirm_delete: false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Execution profile</p>
            <h1 class="hero-title">{@profile.name}</h1>
            <p :if={@profile.description} class="hero-copy">{@profile.description}</p>
          </div>
          <div class="status-stack profile-actions">
            <a class="subtle-button" href={"/execution-profiles/#{@profile.id}/edit"}>Edit</a>
            <button type="button" class="subtle-button danger-button" phx-click="prepare_delete">Delete profile</button>
          </div>
        </div>
      </header>

      <ul :if={@errors != []} id="profile-errors" class="error-summary" role="alert">
        <li :for={error <- @errors}>
          <a :if={lane_id(error.path) && linked_lane(@lanes, lane_id(error.path)) != nil} href={"/lanes/#{linked_lane(@lanes, lane_id(error.path)).slug}"}>{error.path}</a>
          <span :if={is_nil(lane_id(error.path)) or is_nil(linked_lane(@lanes, lane_id(error.path)))}>{error.path}</span>:
          {error.message}
        </li>
      </ul>

      <section :if={@confirm_delete} class="error-card" id="delete-confirmation" role="alert">
        <h2 class="error-title">Delete this execution profile?</h2>
        <p class="error-copy">This is permanent for the profile record. Linked lanes and execution resources are never deleted; a referenced profile cannot be deleted.</p>
        <button type="button" class="danger-button" phx-click="delete">Confirm delete</button>
        <button type="button" class="subtle-button" phx-click="cancel_delete">Cancel</button>
      </section>

      <section class="metric-grid">
        <article class="metric-card"><p class="metric-label">Worker type</p><p class="metric-value">{worker_label(@profile.worker)}</p></article>
        <article class="metric-card"><p class="metric-label">Linked lanes</p><p class="metric-value numeric">{length(@lanes)}</p><p class="metric-detail">Changes apply automatically to future runs.</p></article>
        <article class="metric-card"><p class="metric-label">Aggregate agent capacity</p><p class="metric-value numeric">{@aggregate_capacity}</p><p class="metric-detail">Configured shared-machine load across linked lanes.</p></article>
      </section>

      <section class="section-card">
        <h2 class="section-title">Environment summary</h2>
        <dl class="summary-grid">
          <dt>Workspace base</dt><dd class="mono">{@profile.workspace_base || "schema default"}</dd>
          <dt>Worker</dt><dd>{environment_detail(@profile.worker)}</dd>
          <dt>Credential references</dt><dd>{credential_summary(@profile.worker)}</dd>
        </dl>
      </section>

      <section class="section-card">
        <div class="section-header"><div><h2 class="section-title">Linked lanes</h2><p class="section-copy">{@affected_count} lane(s) receive this profile on future dispatch.</p></div></div>
        <p :if={@lanes == []} class="empty-state">No lanes reference this profile.</p>
        <div :if={@lanes != []} class="table-wrap">
          <table class="data-table" id="profile-lanes">
            <thead><tr><th>Lane</th><th>Subdirectory</th><th>Status</th><th></th></tr></thead>
            <tbody>
              <tr :for={lane <- @lanes} id={"profile-lane-#{lane.id}"}>
                <td><a class="issue-id-link" href={"/lanes/#{lane.slug}"}>{lane.name}</a><span class="muted mono"> {lane.slug}</span></td>
                <td class="mono">{lane.workspace_subdir}</td>
                <td>{if lane.enabled, do: "enabled", else: "disabled"}</td>
                <td><a class="issue-link" href={"/lanes/#{lane.slug}/edit"}>Edit lane</a></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </section>
    """
  end

  defp refresh(socket) do
    case ExecutionProfiles.get(socket.assigns.profile.id) do
      nil -> {:noreply, socket |> put_flash(:error, "Execution profile no longer exists") |> push_navigate(to: "/execution-profiles")}
      profile -> {:noreply, assign_profile(socket, profile)}
    end
  end

  defp assign_profile(socket, profile) do
    lanes = ExecutionProfiles.linked_lanes(profile)
    assign(socket, profile: profile, lanes: lanes, affected_count: length(lanes), aggregate_capacity: aggregate_capacity(lanes))
  end

  defp aggregate_capacity(lanes) do
    Enum.reduce(lanes, 0, fn lane, total ->
      case LaneStore.lookup(lane.id) do
        {:ok, %{settings: %{agent: %{max_concurrent_agents: count}}}} when is_integer(count) -> total + count
        _ -> total
      end
    end)
  end

  defp worker_label(worker) when is_map(worker) do
    cond do
      is_map(Map.get(worker, "environment")) -> "Managed"
      Map.get(worker, "ssh_hosts", []) != [] -> "Static SSH"
      true -> "Local"
    end
  end

  defp worker_label(_worker), do: "Unknown"

  defp environment_detail(worker) do
    case Map.get(worker || %{}, "environment") do
      %{"kind" => kind, "deployment_id" => deployment} -> "#{kind} deployment #{deployment}"
      _ -> if Map.get(worker || %{}, "ssh_hosts", []) == [], do: "Local machine", else: "SSH: #{Enum.join(Map.get(worker, "ssh_hosts", []), ", ")}"
    end
  end

  defp credential_summary(worker) do
    provider = get_in(worker || %{}, ["environment", "provider"])

    if is_map(provider) and
         Enum.any?(provider, fn {key, value} ->
           String.contains?(to_string(key), "credential") or String.contains?(to_string(key), "token") or String.contains?(to_string(key), "secret") or
             (is_binary(value) and String.starts_with?(value, "$"))
         end), do: "References configured", else: "None shown"
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> value
      _ -> 0
    end
  end

  defp parse_id(_id), do: 0
  defp lane_id("lanes." <> rest), do: rest |> String.split(".") |> List.first() |> parse_id()
  defp lane_id(_path), do: nil
  defp linked_lane(lanes, id), do: Enum.find(lanes, &(&1.id == id))
end
