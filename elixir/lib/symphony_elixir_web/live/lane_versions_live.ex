defmodule SymphonyElixirWeb.LaneVersionsLive do
  @moduledoc "Version history of a lane; rollback is a pointer move."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.ExecutionProfiles
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.Lanes
  alias SymphonyElixir.Workflow
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe_lane(slug)

    case Lanes.get_by_slug(slug) do
      nil -> {:ok, socket |> put_flash(:error, "No lane with slug #{slug}") |> push_navigate(to: "/")}
      lane -> {:ok, assign(socket, lane: lane, profile: ExecutionProfiles.get(lane.execution_profile_id), versions: version_rows(lane), errors: [])}
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
         |> assign(lane: lane, profile: ExecutionProfiles.get(lane.execution_profile_id), versions: version_rows(lane), errors: [])
         |> put_flash(:info, "Historical lane settings use the currently selected profile; infrastructure is not rolled back.")}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  @impl true
  def handle_info({:lane_updated, _slug}, socket) do
    case Lanes.get_by_slug(socket.assigns.lane.slug) do
      nil -> {:noreply, socket |> put_flash(:error, "Lane no longer exists") |> push_navigate(to: "/")}
      lane -> {:noreply, assign(socket, lane: lane, profile: ExecutionProfiles.get(lane.execution_profile_id), versions: version_rows(lane))}
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
              <tr :for={row <- @versions} id={"version-#{row.version.id}"}>
                <td class="mono">#{row.version.id}</td>
                <td class="mono">{DateTime.to_iso8601(row.version.inserted_at)}</td>
                <td>{row.version.note}</td>
                <td>
                  <%= if row.version.id == @lane.current_version_id do %>
                    <span class="state-badge state-badge-active">current</span>
                  <% else %>
                    <button type="button" class="subtle-button" phx-click="activate" phx-value-id={row.version.id}>Make current</button>
                  <% end %>
                  <details class="version-inspection"><summary>Inspect</summary><p :if={row.invalid?} class="field-error">Invalid historical front matter is retained in storage but hidden because its credentials cannot be safely redacted. Repair by saving a replacement version.</p><pre class="mono">{row.content}</pre></details>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </section>
    """
  end

  defp version_rows(lane), do: lane |> Lanes.versions() |> Enum.map(&version_row/1)

  defp version_row(version) do
    case Workflow.parse_parts(version.front_matter, version.prompt) do
      {:ok, workflow} ->
        {_profile, config} = Configuration.split(workflow.config)
        %{version: version, invalid?: false, content: Workflow.render(Workflow.encode_config(Configuration.redact_secrets(config)), workflow.prompt)}

      {:error, _reason} ->
        %{version: version, invalid?: true, content: version.prompt}
    end
  end
end
