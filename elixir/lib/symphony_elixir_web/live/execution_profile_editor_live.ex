defmodule SymphonyElixirWeb.ExecutionProfileEditorLive do
  @moduledoc "Creates or edits an execution profile without replacing its raw worker map."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.ExecutionProfiles
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.ExecutionProfiles.Profile
  alias SymphonyElixirWeb.{ConfigurationFields, ObservabilityPubSub}

  import ConfigurationFields, only: [profile_fields: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe_profiles()
      :ok = ObservabilityPubSub.subscribe()
    end

    case parse_id(id) |> then(&ExecutionProfiles.get/1) do
      nil -> {:ok, socket |> put_flash(:error, "Execution profile not found") |> push_navigate(to: "/execution-profiles")}
      profile -> {:ok, editor_assigns(socket, profile)}
    end
  end

  def mount(_params, _session, socket) do
    profile = %Profile{workspace_base: default_workspace_base(), worker: %{}}
    {:ok, editor_assigns(socket, profile)}
  end

  @impl true
  def handle_info(:profiles_updated, socket), do: refresh_profile(socket)
  def handle_info(:observability_updated, socket), do: {:noreply, assign(socket, :lanes, linked_lanes(socket.assigns.profile))}

  @impl true
  def handle_event(event, %{"profile" => incoming}, socket) when event in ["validate", "save"] and is_map(incoming) do
    params = Map.merge(socket.assigns.params, Map.take(incoming, Map.keys(socket.assigns.params)))
    {attrs, errors} = attributes(params, socket.assigns.profile)
    errors = errors ++ profile_errors(attrs)

    result = if event == "save" and errors == [], do: save(socket.assigns.profile, attrs), else: {:error, errors}

    case result do
      {:ok, profile} ->
        {:noreply, push_navigate(socket, to: "/execution-profiles/#{profile.id}")}

      {:error, save_errors} ->
        {:noreply,
         assign(socket,
           params: params,
           errors: save_errors,
           dirty: true,
           lanes: linked_lanes(socket.assigns.profile)
         )}
    end
  end

  def handle_event(event, _payload, socket) when event in ["validate", "save"], do: {:noreply, assign(socket, :errors, [%{path: "profile", message: "must be an object"}])}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <p class="eyebrow">Execution profiles</p>
        <h1 class="hero-title">{if @profile.id, do: "Edit #{@profile.name}", else: "New execution profile"}</h1>
        <p class="hero-copy">Changes apply automatically to future runs for all linked lanes. Existing attempts retain their captured settings.</p>
      </header>

      <form id="profile-form" phx-change="validate" phx-submit="save" class="section-card config-form">
        <ul :if={@errors != []} id="profile-errors" class="error-summary" role="alert">
          <li :for={error <- @errors}>
            <a :if={lane_id(error.path) && linked_lane(@lanes, lane_id(error.path)) != nil} href={"/lanes/#{linked_lane(@lanes, lane_id(error.path)).slug}"}>{error.path}</a>
            <span :if={is_nil(lane_id(error.path)) or is_nil(linked_lane(@lanes, lane_id(error.path)))}>{error.path}</span>:
            {error.message}
          </li>
        </ul>

        <fieldset class="form-section">
          <legend>Profile identity</legend>
          <label for="profile-name">Name</label>
          <input id="profile-name" type="text" name="profile[name]" value={@params["name"]} autofocus />
          <p :for={error <- field_errors(@errors, "name")} class="field-error" role="alert">{error.message}</p>

          <label for="profile-description">Description</label>
          <textarea id="profile-description" name="profile[description]" rows="3">{@params["description"]}</textarea>
          <p :for={error <- field_errors(@errors, "description")} class="field-error" role="alert">{error.message}</p>

          <label for="profile-workspace-base">Workspace base directory</label>
          <input id="profile-workspace-base" type="text" name="profile[workspace_base]" value={@params["workspace_base"]} />
          <p class="field-help">Lane subdirectories are checked against this base for local workers.</p>
          <p :for={error <- field_errors(@errors, "workspace_base")} class="field-error" role="alert">{error.message}</p>
        </fieldset>

        <.profile_fields params={@params} errors={@errors} />

        <section :if={@lanes != []} class="form-section affected-lanes">
          <h2 class="section-title">Shared-machine impact</h2>
          <p class="section-copy">This edit affects {length(@lanes)} linked lane(s) on future runs.</p>
          <ul><li :for={lane <- @lanes}><a class="issue-link" href={"/lanes/#{lane.slug}"}>{lane.name}</a></li></ul>
        </section>

        <div class="form-actions">
          <button type="submit">Save profile</button>
          <a class="issue-link" href={cancel_path(@profile)}>Cancel</a>
        </div>
      </form>
    </section>
    """
  end

  defp editor_assigns(socket, %Profile{} = profile) do
    params = profile_params(profile)
    errors = profile_errors(%{"worker" => profile.worker || %{}})
    errors = if profile.repair_error && errors == [], do: [%{path: "profile", message: "Needs repair before use; correct the linked lane configuration."}], else: errors
    assign(socket, profile: profile, params: params, errors: errors, lanes: linked_lanes(profile), dirty: false)
  end

  defp profile_params(profile) do
    worker = profile.worker || %{}
    environment = if is_map(worker["environment"]), do: worker["environment"], else: %{}
    provider = Map.get(environment, "provider", %{})

    %{
      "name" => profile.name || "",
      "description" => profile.description || "",
      "workspace_base" => profile.workspace_base || default_workspace_base(),
      "worker_mode" => ConfigurationFields.worker_mode(worker),
      "ssh_hosts" => hosts_input(Map.get(worker, "ssh_hosts", [])),
      "max_concurrent_agents_per_host" => value_string(Map.get(worker, "max_concurrent_agents_per_host")),
      "environment_kind" => value_string(Map.get(environment, "kind")),
      "deployment_id" => value_string(Map.get(environment, "deployment_id")),
      "startup_timeout" => ConfigurationFields.duration_input(Map.get(environment, "startup_timeout_ms")),
      "shutdown_timeout" => ConfigurationFields.duration_input(Map.get(environment, "shutdown_timeout_ms")),
      "terminal_retention" => ConfigurationFields.duration_input(Map.get(environment, "terminal_retention_ms", %EnvironmentConfig{}.terminal_retention_ms)),
      "provider_json" => ConfigurationFields.safe_json(provider)
    }
  end

  defp attributes(params, profile) do
    {attrs, errors} = ConfigurationFields.profile_attributes(params, profile.worker || %{})
    initial = profile_params(profile)

    if params["worker_mode"] == initial["worker_mode"] do
      worker = preserve_unchanged_fields(attrs["worker"], profile.worker || %{}, params, initial, [{"ssh_hosts", "ssh_hosts"}, {"max_concurrent_agents_per_host", "max_concurrent_agents_per_host"}])
      worker = preserve_environment(worker, profile.worker || %{}, params, initial)
      {Map.put(attrs, "worker", worker), errors}
    else
      {attrs, errors}
    end
  end

  defp preserve_environment(worker, original, params, initial) do
    fields = [
      {"environment_kind", "kind"},
      {"deployment_id", "deployment_id"},
      {"startup_timeout", "startup_timeout_ms"},
      {"shutdown_timeout", "shutdown_timeout_ms"},
      {"terminal_retention", "terminal_retention_ms"},
      {"provider_json", "provider"}
    ]

    case {Map.fetch(original, "environment"), Map.get(worker, "environment")} do
      {{:ok, environment}, candidate} when is_map(environment) and is_map(candidate) ->
        Map.put(worker, "environment", preserve_unchanged_fields(candidate, environment, params, initial, fields))

      {{:ok, environment}, _candidate} ->
        if fields_unchanged?(params, initial, fields), do: Map.put(worker, "environment", environment), else: worker

      {:error, _candidate} ->
        worker
    end
  end

  defp fields_unchanged?(params, initial, fields), do: Enum.all?(fields, fn {field, _key} -> params[field] == initial[field] end)

  defp preserve_unchanged_fields(candidate, original, params, initial, fields) do
    Enum.reduce(fields, candidate, fn {field, key}, acc ->
      if Map.has_key?(original, key) and params[field] == initial[field], do: Map.put(acc, key, original[key]), else: acc
    end)
  end

  defp profile_errors(attrs) do
    case Configuration.validate_profile(attrs) do
      :ok -> []
      {:error, errors} -> errors
    end
  end

  defp save(%Profile{id: nil}, attrs), do: ExecutionProfiles.create(attrs)
  defp save(%Profile{} = profile, attrs), do: ExecutionProfiles.update(profile, attrs)

  defp refresh_profile(socket) do
    case ExecutionProfiles.get(socket.assigns.profile.id) do
      nil -> {:noreply, socket |> put_flash(:error, "Execution profile no longer exists") |> push_navigate(to: "/execution-profiles")}
      profile -> {:noreply, refresh_existing_profile(socket, profile)}
    end
  end

  defp refresh_existing_profile(%{assigns: %{dirty: true}} = socket, profile), do: assign(socket, :lanes, linked_lanes(profile))
  defp refresh_existing_profile(socket, profile), do: editor_assigns(socket, profile)

  defp linked_lanes(%Profile{id: nil}), do: []
  defp linked_lanes(%Profile{} = profile), do: ExecutionProfiles.linked_lanes(profile)

  defp field_errors(errors, path), do: ConfigurationFields.field_errors(errors, path)
  defp value_string(nil), do: ""
  defp value_string(value) when is_binary(value) or is_number(value), do: to_string(value)
  defp value_string(value), do: ConfigurationFields.safe_json(value)
  defp hosts_input(hosts) when is_list(hosts), do: if(Enum.all?(hosts, &is_binary/1), do: Enum.join(hosts, "\n"), else: ConfigurationFields.safe_json(hosts))
  defp hosts_input(hosts), do: value_string(hosts)
  defp default_workspace_base, do: %SymphonyElixir.Config.Schema.Workspace{}.root
  defp cancel_path(%Profile{id: nil}), do: "/execution-profiles"
  defp cancel_path(%Profile{id: id}), do: "/execution-profiles/#{id}"

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> value
      _ -> 0
    end
  end

  defp lane_id("lanes." <> rest), do: rest |> String.split(".") |> List.first() |> parse_id()
  defp lane_id(_path), do: nil
  defp linked_lane(lanes, id), do: Enum.find(lanes, &(&1.id == id))
end
