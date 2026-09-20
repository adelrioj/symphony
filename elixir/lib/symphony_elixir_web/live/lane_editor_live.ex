defmodule SymphonyElixirWeb.LaneEditorLive do
  @moduledoc "Create or edit a lane. Validates on every change through Config.Schema; a save is a new version."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{ExecutionProfiles, Lanes, Workflow}
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.Lanes.Lane
  alias SymphonyElixirWeb.ObservabilityPubSub

  @fields ~w(slug name enabled execution_profile_id workspace_subdir config prompt note)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe_lane(slug)

    case Lanes.get_by_slug(slug) do
      nil ->
        {:ok, socket |> put_flash(:error, "No lane with slug #{slug}") |> push_navigate(to: "/")}

      lane ->
        version = Lanes.current_version(lane)

        params = lane_params(lane, version)

        {:ok, assign(socket, lane: lane, params: params, errors: [], warnings: config_warnings(params["config"]))}
    end
  end

  def mount(_params, _session, socket) do
    profile_id = List.first(ExecutionProfiles.list())
    params = %{"slug" => "", "name" => "", "enabled" => false, "execution_profile_id" => profile_id && profile_id.id, "workspace_subdir" => ".", "config" => "{}", "prompt" => "", "note" => ""}
    {:ok, assign(socket, lane: nil, params: params, errors: [], warnings: [])}
  end

  @impl true
  def handle_event(event, payload, socket) when event in ["validate", "save"] do
    incoming = if is_map(payload), do: Map.get(payload, "lane")
    {params, input_errors} = merge_params(socket.assigns.params, incoming)
    {errors, warnings} = validate(socket.assigns.lane, params)
    errors = input_errors ++ errors
    result = if event == "save" and errors == [], do: save_lane(socket.assigns.lane, params), else: {:error, errors}

    case result do
      {:ok, lane} ->
        {:noreply, push_navigate(socket, to: "/lanes/#{lane.slug}")}

      {:error, errors} ->
        {:noreply, assign(socket, params: params, errors: errors, warnings: warnings)}
    end
  end

  @impl true
  def handle_info({:lane_updated, slug}, socket) do
    if is_nil(Lanes.get_by_slug(slug)) do
      {:noreply, socket |> put_flash(:error, "Lane no longer exists") |> push_navigate(to: "/")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <p class="eyebrow">{if @lane, do: "Edit lane", else: "New lane"}</p>
        <h1 class="hero-title">{if @lane, do: @lane.name, else: "New lane"}</h1>
      </header>

      <form id="lane-form" phx-change="validate" phx-submit="save" class="section-card lane-form">
        <ul :if={@errors != []} id="lane-errors" class="error-copy" role="alert">
          <li :for={error <- @errors}>{error.path}: {error.message}</li>
        </ul>
        <ul :if={@warnings != []} id="lane-warnings" class="muted" role="status">
          <li :for={warning <- @warnings}>{warning}</li>
        </ul>

        <label>Slug <input type="text" name="lane[slug]" value={@params["slug"]} readonly={not is_nil(@lane)} /></label>
        <label>Name <input type="text" name="lane[name]" value={@params["name"]} /></label>
        <label>
          <input type="hidden" name="lane[enabled]" value="false" />
          <input type="checkbox" name="lane[enabled]" value="true" checked={truthy?(@params["enabled"])} /> Enabled
        </label>
        <label>
          Execution profile ID
          <input type="number" name="lane[execution_profile_id]" value={@params["execution_profile_id"]} />
        </label>
        <label>
          Workspace subdirectory
          <input type="text" name="lane[workspace_subdir]" value={@params["workspace_subdir"]} />
        </label>
        <label>
          Configuration (JSON)
          <textarea name="lane[config]" rows="24" class="mono" phx-debounce="300">{Phoenix.HTML.Form.normalize_value("textarea", @params["config"])}</textarea>
        </label>
        <label>
          Prompt (Markdown)
          <textarea name="lane[prompt]" rows="24" class="mono" phx-debounce="300">{Phoenix.HTML.Form.normalize_value("textarea", @params["prompt"])}</textarea>
        </label>
        <label>Change note <input type="text" name="lane[note]" value={@params["note"]} phx-debounce="300" /></label>

        <button type="submit" class="subtle-button">Save</button>
        <a :if={@lane} class="issue-link" href={"/lanes/#{@lane.slug}"}>Cancel</a>
        <a :if={is_nil(@lane)} class="issue-link" href="/">Cancel</a>
      </form>
    </section>
    """
  end

  defp save_lane(nil, params), do: with({:ok, attrs} <- canonical_params(params), do: Lanes.create(attrs))

  defp save_lane(%Lane{slug: slug}, params) do
    case Lanes.get_by_slug(slug) do
      nil -> {:error, [%{path: "lane", message: "Lane no longer exists"}]}
      lane -> with {:ok, attrs} <- canonical_params(params), do: Lanes.update(lane, attrs)
    end
  end

  defp merge_params(params, incoming) when is_map(incoming) do
    incoming = Map.take(incoming, @fields)

    incoming =
      Map.update(incoming, "enabled", params["enabled"], fn
        value when value in [true, "true", "on"] -> true
        value when value in [false, "false"] -> false
        value -> value
      end)

    Enum.reduce(incoming, {params, []}, &merge_field/2)
  end

  defp merge_params(params, _incoming), do: {params, [%{path: "lane", message: "must be an object"}]}

  defp merge_field({field, value}, {params, errors}) do
    valid? = if field == "enabled", do: is_boolean(value), else: is_binary(value) or (field == "execution_profile_id" and is_integer(value))

    if valid? do
      {Map.put(params, field, value), errors}
    else
      message = if field == "enabled", do: "must be a boolean", else: "must be a string"
      {params, [%{path: field, message: message} | errors]}
    end
  end

  defp validate(lane, params) do
    config_result = decode_config(params["config"])

    lane_errors =
      (lane || %Lane{})
      |> Lane.changeset(Map.take(params, ~w(slug name enabled execution_profile_id workspace_subdir)))
      |> Ecto.Changeset.traverse_errors(fn {message, opts} -> Enum.reduce(opts, message, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end) end)
      |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &%{path: to_string(field), message: &1}) end)

    case config_result do
      {:ok, config} -> {lane_errors, config_warnings(config)}
      {:error, errors} -> {lane_errors ++ errors, []}
    end
  end

  defp lane_params(lane, version) do
    config =
      case version && Workflow.parse_parts(version.front_matter, "") do
        {:ok, %{config: raw}} ->
          {_profile, config} = Configuration.split(raw)
          config

        _ ->
          %{}
      end

    %{
      "slug" => lane.slug,
      "name" => lane.name,
      "enabled" => lane.enabled,
      "execution_profile_id" => lane.execution_profile_id,
      "workspace_subdir" => lane.workspace_subdir,
      "config" => Jason.encode!(config, pretty: true),
      "prompt" => (version && version.prompt) || "",
      "note" => ""
    }
  end

  defp canonical_params(params) do
    with {:ok, config} <- decode_config(params["config"]),
         {:ok, profile_id} <- integer_param(params["execution_profile_id"]) do
      {:ok, Map.merge(params, %{"config" => config, "execution_profile_id" => profile_id})}
    end
  end

  defp decode_config(config) when is_map(config), do: {:ok, config}

  defp decode_config(config) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _} -> {:error, [%{path: "config", message: "must be an object"}]}
      {:error, reason} -> {:error, [%{path: "config", message: "invalid JSON: #{Exception.message(reason)}"}]}
    end
  end

  defp decode_config(_config), do: {:error, [%{path: "config", message: "must be an object"}]}

  defp integer_param(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp integer_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, [%{path: "execution_profile_id", message: "must be an integer"}]}
    end
  end

  defp integer_param(_value), do: {:error, [%{path: "execution_profile_id", message: "must be an integer"}]}

  defp config_warnings(config) when is_map(config) do
    if Map.has_key?(config, "server"), do: ["server is configured per installation now (symphony serve --port/--host); the section is ignored"], else: []
  end

  defp config_warnings(_config), do: []

  defp truthy?(value), do: value in [true, "true", "on"]
end
