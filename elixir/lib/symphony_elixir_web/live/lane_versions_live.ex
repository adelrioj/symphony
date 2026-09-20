defmodule SymphonyElixirWeb.LaneVersionsLive do
  @moduledoc "Version history of a lane; rollback is a pointer move."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.ExecutionProfiles
  alias SymphonyElixir.Lanes
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe_lane(slug)

    case Lanes.get_by_slug(slug) do
      nil -> {:ok, socket |> put_flash(:error, "No lane with slug #{slug}") |> push_navigate(to: "/")}
      lane -> {:ok, assign(socket, lane: lane, profile: ExecutionProfiles.get(lane.execution_profile_id), versions: Lanes.versions(lane), errors: [])}
    end
  end

  @impl true
  def handle_event("activate", params, socket) do
    result =
      with {version_id, ""} when version_id > 0 <- parse_id(params["id"]),
           lane when not is_nil(lane) <- Lanes.get_by_slug(socket.assigns.lane.slug) do
        Lanes.activate_version(lane, version_id)
      else
        _ -> {:error, [%{path: "version_id", message: "Select an existing version of this lane"}]}
      end

    case result do
      {:ok, lane} ->
        {:noreply,
         socket
         |> assign(lane: lane, profile: ExecutionProfiles.get(lane.execution_profile_id), versions: Lanes.versions(lane), errors: [])
         |> put_flash(:info, "Historical lane settings use the currently selected profile; infrastructure is not rolled back.")}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  @impl true
  def handle_info({:lane_updated, _slug}, socket) do
    case Lanes.get_by_slug(socket.assigns.lane.slug) do
      nil -> {:noreply, socket |> put_flash(:error, "Lane no longer exists") |> push_navigate(to: "/")}
      lane -> {:noreply, assign(socket, lane: lane, profile: ExecutionProfiles.get(lane.execution_profile_id), versions: Lanes.versions(lane))}
    end
  end

  defp parse_id(id) when is_binary(id), do: Integer.parse(id)
  defp parse_id(_id), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <p class="eyebrow">Versions</p>
        <h1 class="hero-title">{@lane.name} <span class="muted mono">{@lane.slug}</span></h1>
        <p class="hero-copy"><a class="issue-link" href={"/lanes/#{@lane.slug}"}>Back to lane</a> · <a :if={@profile} class="issue-link" href={"/execution-profiles/#{@profile.id}"}>profile: {@profile.name}</a></p>
        <p class="section-copy">History changes lane-owned settings only. Activating a record resolves it against the current profile and does not roll back infrastructure.</p>
      </header>
      <ul :if={@errors != []} id="version-errors" class="error-copy" role="alert"><li :for={error <- @errors}>{error.path}: {error.message}</li></ul>
      <section class="section-card">
        <div class="table-wrap">
          <table class="data-table" id="versions">
            <thead><tr><th>Version</th><th>Saved</th><th>Note</th><th></th></tr></thead>
            <tbody>
              <tr :for={version <- @versions} id={"version-#{version.id}"}>
                <td class="mono">#{version.id}</td>
                <td class="mono">{DateTime.to_iso8601(version.inserted_at)}</td>
                <td>{version.note}</td>
                <td>
                  <%= if version.id == @lane.current_version_id do %>
                    <span class="state-badge state-badge-active">current</span>
                  <% else %>
                    <button type="button" class="subtle-button" phx-click="activate" phx-value-id={version.id}>Make current</button>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </section>
    """
  end
end
