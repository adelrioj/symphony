defmodule SymphonyElixirWeb.ConfigurationFields do
  @moduledoc "Reusable structured execution-profile fields and lossless scalar conversion."

  use Phoenix.Component

  @spec profile_attributes(map(), map()) :: {map(), [map()]}
  def profile_attributes(params, original \\ %{}) when is_map(params) and is_map(original) do
    with {:ok, worker} <- worker_attributes(params, original),
         {:ok, workspace_base} <- required_text(params["workspace_base"], "workspace_base") do
      {name, name_errors} = required_text(params["name"], "name") |> result_pair()
      description = if String.trim(params["description"] || "") == "", do: nil, else: params["description"]

      {%{"name" => name, "description" => description, "workspace_base" => workspace_base, "worker" => worker}, name_errors}
    else
      {:error, errors} ->
        {%{"name" => params["name"], "description" => params["description"], "workspace_base" => params["workspace_base"], "worker" => original}, List.wrap(errors)}
    end
  end

  @spec profile_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def profile_fields(assigns) do
    ~H"""
    <fieldset class="form-section">
      <legend>Execution environment</legend>
      <p class="section-copy">Profiles select existing workers; saving a profile never provisions infrastructure.</p>

      <label for="profile-worker-mode">Worker type</label>
      <select id="profile-worker-mode" name="profile[worker_mode]">
        <option value="local" selected={@params["worker_mode"] == "local"}>Local</option>
        <option value="ssh" selected={@params["worker_mode"] == "ssh"}>Static SSH</option>
        <option value="managed" selected={@params["worker_mode"] == "managed"}>Existing managed environment</option>
      </select>
      <p :for={error <- field_errors(@errors, "worker_mode")} class="field-error" role="alert">{error.message}</p>

      <div :if={@params["worker_mode"] == "local"} class="field-help">
        <p>Runs use the local worker on this machine.</p>
      </div>

      <div :if={@params["worker_mode"] == "ssh"} class="config-subsection">
        <label for="profile-ssh-hosts">SSH hosts</label>
        <textarea id="profile-ssh-hosts" name="profile[ssh_hosts]" rows="3" placeholder="one host per line">{@params["ssh_hosts"]}</textarea>
        <p class="field-help">Host names are references to existing static SSH workers.</p>
        <p :for={error <- field_errors(@errors, "worker.ssh_hosts")} class="field-error" role="alert">{error.message}</p>

        <label for="profile-host-limit">Maximum agents per SSH host</label>
        <input id="profile-host-limit" type="number" min="1" name="profile[max_concurrent_agents_per_host]" value={@params["max_concurrent_agents_per_host"]} />
        <p :for={error <- field_errors(@errors, "worker.max_concurrent_agents_per_host")} class="field-error" role="alert">{error.message}</p>
      </div>

      <div :if={@params["worker_mode"] == "managed"} class="config-subsection">
        <p class="field-help">Managed provider settings identify an existing qualified environment. They do not enable an unavailable provider.</p>

        <label for="profile-environment-kind">Managed provider</label>
        <select id="profile-environment-kind" name="profile[environment_kind]">
          <option value="" selected={@params["environment_kind"] == ""}>Choose a provider</option>
          <option value="google_workstations" selected={@params["environment_kind"] == "google_workstations"}>Google Cloud Workstations</option>
          <option value="kubernetes" selected={@params["environment_kind"] == "kubernetes"}>Customer-managed Kubernetes</option>
        </select>
        <p :for={error <- field_errors(@errors, "worker.environment.kind")} class="field-error" role="alert">{error.message}</p>

        <label for="profile-deployment-id">Deployment identifier</label>
        <input id="profile-deployment-id" type="text" name="profile[deployment_id]" value={@params["deployment_id"]} />
        <p :for={error <- field_errors(@errors, "worker.environment.deployment_id")} class="field-error" role="alert">{error.message}</p>

        <label for="profile-startup-timeout">Startup timeout (seconds)</label>
        <input id="profile-startup-timeout" type="text" inputmode="decimal" name="profile[startup_timeout]" value={@params["startup_timeout"]} />
        <p :for={error <- field_errors(@errors, "worker.environment.startup_timeout_ms")} class="field-error" role="alert">{error.message}</p>

        <label for="profile-shutdown-timeout">Shutdown timeout (seconds)</label>
        <input id="profile-shutdown-timeout" type="text" inputmode="decimal" name="profile[shutdown_timeout]" value={@params["shutdown_timeout"]} />
        <p :for={error <- field_errors(@errors, "worker.environment.shutdown_timeout_ms")} class="field-error" role="alert">{error.message}</p>

        <label for="profile-terminal-retention">Terminal retention (seconds)</label>
        <input id="profile-terminal-retention" type="text" inputmode="decimal" name="profile[terminal_retention]" value={@params["terminal_retention"]} />
        <p :for={error <- field_errors(@errors, "worker.environment.terminal_retention_ms")} class="field-error" role="alert">{error.message}</p>

        <label for="profile-provider">Provider details (JSON)</label>
        <textarea id="profile-provider" name="profile[provider_json]" rows="8" class="mono">{@params["provider_json"]}</textarea>
        <p class="field-help">Credential references are retained as references; resolved credential values are never shown.</p>
        <p :for={error <- field_errors(@errors, "worker.environment.provider")} class="field-error" role="alert">{error.message}</p>
      </div>
    </fieldset>
    """
  end

  @spec worker_mode(map()) :: String.t()
  def worker_mode(worker) when is_map(worker) do
    cond do
      is_map(worker_value(worker, "environment")) -> "managed"
      worker_value(worker, "ssh_hosts") in [nil, []] -> "local"
      true -> "ssh"
    end
  end

  @spec duration_input(integer() | nil) :: String.t()
  def duration_input(nil), do: ""

  def duration_input(milliseconds) when is_integer(milliseconds) do
    whole = div(milliseconds, 1_000)
    remainder = rem(milliseconds, 1_000)

    if remainder == 0 do
      Integer.to_string(whole)
    else
      fraction =
        milliseconds
        |> rem(1_000)
        |> abs()
        |> Integer.to_string()
        |> String.pad_leading(3, "0")
        |> String.trim_trailing("0")

      "#{whole}.#{fraction}"
    end
  end

  @spec parse_duration(term(), String.t()) :: {:ok, non_neg_integer()} | {:error, map()}
  def parse_duration(value, path) when is_binary(value) do
    value = String.trim(value)

    case Regex.run(~r/^([0-9]+)(?:\.([0-9]+))?$/, value, capture: :all_but_first) do
      [whole, fraction] -> duration_number(whole, fraction, path)
      [whole] -> duration_number(whole, "", path)
      _ -> {:error, %{path: path, message: "must be a nonnegative decimal number of seconds"}}
    end
  end

  def parse_duration(_value, path), do: {:error, %{path: path, message: "must be a nonnegative decimal number of seconds"}}

  @spec safe_json(term()) :: String.t()
  def safe_json(value), do: value |> safe_value() |> Jason.encode!(pretty: true)

  @spec safe_value(term()) :: term()
  def safe_value(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value =
        if secret_key?(key) and is_binary(value) and not String.starts_with?(value, "$"),
          do: "$REDACTED",
          else: safe_value(value)

      {key, value}
    end)
  end

  def safe_value(list) when is_list(list), do: Enum.map(list, &safe_value/1)
  def safe_value(value), do: value

  @spec field_errors([map()], String.t()) :: [map()]
  def field_errors(errors, path), do: Enum.filter(errors, &(&1.path == path))

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
      with {:ok, startup} <- parse_duration(params["startup_timeout"], "worker.environment.startup_timeout_ms"),
           {:ok, shutdown} <- parse_duration(params["shutdown_timeout"], "worker.environment.shutdown_timeout_ms"),
           {:ok, retention} <- parse_duration(params["terminal_retention"], "worker.environment.terminal_retention_ms"),
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
    original_provider = get_in(original, ["environment", "provider"]) || %{}

    case Jason.decode(value || "") do
      {:ok, provider} when is_map(provider) -> {:ok, restore_redacted(provider, original_provider)}
      {:ok, _} -> {:error, [%{path: "worker.environment.provider", message: "must be a JSON object"}]}
      {:error, reason} -> {:error, [%{path: "worker.environment.provider", message: "invalid JSON: #{Exception.message(reason)}"}]}
    end
  end

  defp restore_redacted(value, original) when value == "$REDACTED", do: original
  defp restore_redacted(map, original) when is_map(map), do: Map.new(map, fn {key, child} -> {key, restore_redacted(child, Map.get(original || %{}, key))} end)
  defp restore_redacted(value, _original), do: value

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

  defp duration_number(whole, fraction, path) do
    numerator = String.to_integer(whole <> fraction)
    denominator = Integer.pow(10, String.length(fraction))
    milliseconds = numerator * 1_000

    if rem(milliseconds, denominator) == 0 do
      {:ok, div(milliseconds, denominator)}
    else
      {:error, %{path: path, message: "must represent a whole millisecond"}}
    end
  end

  defp worker_value(worker, key), do: Map.get(worker, key, Map.get(worker, String.to_atom(key)))

  defp secret_key?(key), do: Regex.match?(~r/(api.?key|token|secret|password|credential)/i, to_string(key))
end
