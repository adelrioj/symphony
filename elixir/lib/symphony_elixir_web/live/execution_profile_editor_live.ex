defmodule SymphonyElixirWeb.ExecutionProfileEditorLive do
  @moduledoc "Creates or edits an execution profile without replacing its raw worker map."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.ExecutionProfiles
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.ExecutionProfiles.Profile
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixirWeb.{ConfigurationFields, ObservabilityPubSub}

  import ConfigurationFields, only: [profile_fields: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe_profiles()

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
  def handle_info(:observability_updated, socket), do: refresh_profile(socket)

  @impl true
  def handle_event(event, %{"profile" => incoming}, socket) when event in ["validate", "save"] do
    params = Map.merge(socket.assigns.params, Map.take(incoming, Map.keys(socket.assigns.params)))
    {attrs, errors} = attributes(params, socket.assigns.profile)
    errors = errors ++ profile_errors(attrs)

    result = if event == "save" and errors == [], do: save(socket.assigns.profile, attrs), else: {:error, errors}

    case result do
      {:ok, profile} -> {:noreply, push_navigate(socket, to: "/execution-profiles/#{profile.id}")}
      {:error, save_errors} -> {:noreply, assign(socket, params: params, errors: save_errors, lanes: linked_lanes(socket.assigns.profile))}
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
    worker = profile.worker || %{}
    environment = Map.get(worker, "environment", %{})
    provider = Map.get(environment, "provider", %{})

    params = %{
      "name" => profile.name || "",
      "description" => profile.description || "",
      "workspace_base" => profile.workspace_base || default_workspace_base(),
      "worker_mode" => ConfigurationFields.worker_mode(worker),
      "ssh_hosts" => worker |> Map.get("ssh_hosts", []) |> Enum.join("\n"),
      "max_concurrent_agents_per_host" => value_string(Map.get(worker, "max_concurrent_agents_per_host")),
      "environment_kind" => value_string(Map.get(environment, "kind")),
      "deployment_id" => value_string(Map.get(environment, "deployment_id")),
      "startup_timeout" => ConfigurationFields.duration_input(Map.get(environment, "startup_timeout_ms")),
      "shutdown_timeout" => ConfigurationFields.duration_input(Map.get(environment, "shutdown_timeout_ms")),
      "terminal_retention" => ConfigurationFields.duration_input(Map.get(environment, "terminal_retention_ms", %EnvironmentConfig{}.terminal_retention_ms)),
      "provider_json" => ConfigurationFields.safe_json(provider)
    }

    assign(socket, profile: profile, params: params, errors: [], lanes: linked_lanes(profile), original_worker: worker)
  end

  defp attributes(params, profile) do
    with {:ok, worker} <- worker_attributes(params, profile.worker || %{}),
         {:ok, workspace_base} <- required_text(params["workspace_base"], "workspace_base") do
      {name, name_errors} = required_text(params["name"], "name") |> result_pair()
      description = if String.trim(params["description"] || "") == "", do: nil, else: params["description"]

      {%{"name" => name, "description" => description, "workspace_base" => workspace_base, "worker" => worker}, name_errors}
    else
      {:error, errors} -> {%{"name" => params["name"], "description" => params["description"], "workspace_base" => params["workspace_base"], "worker" => profile.worker || %{}}, errors}
    end
  end

  defp worker_attributes(params, original) do
    with {:ok, provider} <- decode_provider(params["provider_json"], original),
         {:ok, worker} <- worker_mode_attributes(params, original),
         {:ok, environment} <- environment_attributes(params, provider, original) do
      worker = if params["worker_mode"] == "managed", do: Map.put(worker, "environment", environment), else: Map.delete(worker, "environment")
      {:ok, worker}
    end
  end

  defp worker_mode_attributes(%{"worker_mode" => "local"}, original), do: {:ok, original |> Map.delete("ssh_hosts") |> Map.delete("max_concurrent_agents_per_host")}

  defp worker_mode_attributes(%{"worker_mode" => "ssh"} = params, original) do
    hosts = params["ssh_hosts"] |> String.split(~r/[\r\n,]+/, trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    with {:ok, limit} <- optional_integer(params["max_concurrent_agents_per_host"], "worker.max_concurrent_agents_per_host") do
      worker = original |> Map.delete("environment") |> Map.put("ssh_hosts", hosts)
      {:ok, if(limit, do: Map.put(worker, "max_concurrent_agents_per_host", limit), else: Map.delete(worker, "max_concurrent_agents_per_host"))}
    end
  end

  defp worker_mode_attributes(%{"worker_mode" => "managed"}, original), do: {:ok, original |> Map.delete("ssh_hosts") |> Map.delete("max_concurrent_agents_per_host")}
  defp worker_mode_attributes(_params, _original), do: {:error, [%{path: "worker_mode", message: "must be local, static SSH, or managed"}]}

  defp environment_attributes(params, provider, original) do
    if params["worker_mode"] != "managed" do
      {:ok, Map.get(original, "environment", %{})}
    else
      with {:ok, startup} <- ConfigurationFields.parse_duration(params["startup_timeout"], "worker.environment.startup_timeout_ms"),
           {:ok, shutdown} <- ConfigurationFields.parse_duration(params["shutdown_timeout"], "worker.environment.shutdown_timeout_ms"),
           {:ok, retention} <- ConfigurationFields.parse_duration(params["terminal_retention"], "worker.environment.terminal_retention_ms"),
           {:ok, kind} <- required_text(params["environment_kind"], "worker.environment.kind"),
           {:ok, deployment} <- required_text(params["deployment_id"], "worker.environment.deployment_id") do
        environment = Map.get(original, "environment", %{})

        {:ok,
         Map.merge(environment, %{
           "kind" => kind,
           "deployment_id" => deployment,
           "provider" => provider,
           "startup_timeout_ms" => startup,
           "shutdown_timeout_ms" => shutdown,
           "terminal_retention_ms" => retention
         })}
      end
    end
  end

  defp decode_provider(value, original) do
    original_provider = Map.get(original, "environment", %{}) |> Map.get("provider", %{})

    case Jason.decode(value || "") do
      {:ok, provider} when is_map(provider) -> {:ok, restore_redacted(provider, original_provider)}
      {:ok, _} -> {:error, [%{path: "worker.environment.provider", message: "must be a JSON object"}]}
      {:error, reason} -> {:error, [%{path: "worker.environment.provider", message: "invalid JSON: #{Exception.message(reason)}"}]}
    end
  end

  defp restore_redacted(value, original) when value == "$REDACTED", do: original

  defp restore_redacted(map, original) when is_map(map) do
    Map.new(map, fn {key, child} -> {key, restore_redacted(child, Map.get(original || %{}, key))} end)
  end

  defp restore_redacted(value, _original), do: value

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
      profile -> {:noreply, editor_assigns(socket, profile)}
    end
  end

  defp linked_lanes(%Profile{id: nil}), do: []
  defp linked_lanes(%Profile{} = profile), do: ExecutionProfiles.linked_lanes(profile)

  defp required_text(value, path) when is_binary(value) do
    if String.trim(value) == "", do: {:error, %{path: path, message: "must not be blank"}}, else: {:ok, String.trim(value)}
  end

  defp required_text(_value, path), do: {:error, %{path: path, message: "must be a string"}}

  defp optional_integer(value, _path) when value in [nil, ""], do: {:ok, nil}

  defp optional_integer(value, path) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, %{path: path, message: "must be a positive integer"}}
    end
  end

  defp optional_integer(_value, path), do: {:error, %{path: path, message: "must be a positive integer"}}

  defp result_pair({:ok, value}), do: {value, []}
  defp result_pair({:error, error}), do: {nil, [error]}

  defp field_errors(errors, path), do: ConfigurationFields.field_errors(errors, path)
  defp value_string(nil), do: ""
  defp value_string(value), do: to_string(value)
  defp default_workspace_base, do: %SymphonyElixir.Config.Schema.Workspace{}.root
  defp cancel_path(%Profile{id: nil}), do: "/execution-profiles"
  defp cancel_path(%Profile{id: id}), do: "/execution-profiles/#{id}"

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
