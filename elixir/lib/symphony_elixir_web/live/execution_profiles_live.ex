defmodule SymphonyElixirWeb.ExecutionProfilesLive do
  @moduledoc "Lists reusable execution profiles."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.ExecutionProfiles
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe_profiles()
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok, assign_profiles(socket)}
  end

  @impl true
  def handle_info(message, socket) when message in [:profiles_updated, :observability_updated], do: {:noreply, assign_profiles(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony</p>
            <h1 class="hero-title">Execution profiles</h1>
            <p class="hero-copy">Reusable worker, credential-reference, and workspace settings for future lane runs.</p>
          </div>
          <div class="status-stack">
            <a class="subtle-button" href="/execution-profiles/new">New profile</a>
          </div>
        </div>
      </header>

      <p :if={@profiles == []} class="empty-state">No execution profiles yet.</p>

      <section :if={@profiles != []} class="section-card">
        <div class="table-wrap">
          <table class="data-table profile-table" id="execution-profiles">
            <thead><tr><th>Name</th><th>Workspace</th><th>Worker</th><th>Linked lanes</th></tr></thead>
            <tbody>
              <tr :for={profile <- @profiles} id={"execution-profile-#{profile.id}"}>
                <td>
                  <a class="issue-id issue-id-link" href={"/execution-profiles/#{profile.id}"}>{profile.name}</a>
                  <p :if={profile.description} class="muted">{profile.description}</p>
                  <p :if={profile.repair_error} class="error-copy">Needs repair: {profile.repair_error}</p>
                </td>
                <td class="mono">{profile.workspace_base || "default"}</td>
                <td>{worker_label(profile.worker)}</td>
                <td class="numeric">{@linked_counts[profile.id]}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </section>
    """
  end

  defp assign_profiles(socket) do
    profiles = ExecutionProfiles.list()
    linked_counts = Map.new(profiles, &{&1.id, length(ExecutionProfiles.linked_lanes(&1))})
    assign(socket, profiles: profiles, linked_counts: linked_counts)
  end

  defp worker_label(worker) do
    cond do
      Map.has_key?(worker, "environment") -> "Existing managed environment"
      Map.get(worker, "ssh_hosts", []) != [] -> "Static SSH"
      true -> "Local"
    end
  end
end
