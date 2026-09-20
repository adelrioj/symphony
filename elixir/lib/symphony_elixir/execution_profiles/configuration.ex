defmodule SymphonyElixir.ExecutionProfiles.Configuration do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PathSafety

  @redacted "$REDACTED"
  @missing :__symphony_missing__

  @spec split(map()) :: {map(), map()}
  def split(config) when is_map(config) do
    {profile, lane_config} = pop_if_present(config, "worker")

    case Map.fetch(lane_config, "workspace") do
      {:ok, workspace} when is_map(workspace) ->
        case Map.fetch(workspace, "root") do
          {:ok, root} ->
            {Map.put(profile, "workspace_base", root), put_workspace(lane_config, Map.delete(workspace, "root"))}

          :error ->
            {profile, lane_config}
        end

      _ ->
        {profile, lane_config}
    end
  end

  @spec redact_secrets(term()) :: term()
  def redact_secrets(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value =
        if secret_key?(key) and is_binary(value) and not String.starts_with?(value, "$"),
          do: @redacted,
          else: redact_secrets(value)

      {key, value}
    end)
  end

  def redact_secrets(list) when is_list(list), do: Enum.map(list, &redact_secrets/1)
  def redact_secrets(value), do: value

  @spec restore_redacted(term(), term(), String.t()) :: {:ok, term()} | {:error, [map()]}
  def restore_redacted(value, original, path) when is_binary(path), do: restore_redacted_value(value, original, path)

  @spec resolve(map(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, [map()]}
  def resolve(profile, lane_config, workspace_subdir, prompt)
      when is_map(profile) and is_map(lane_config) and is_binary(workspace_subdir) and is_binary(prompt) do
    resolve(profile, lane_config, workspace_subdir, prompt, nil)
  end

  def resolve(_profile, _lane_config, _workspace_subdir, _prompt), do: {:error, [error("config", "must be an object")]}

  @doc false
  @spec resolve(map(), map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, [map()]}
  def resolve(profile, lane_config, workspace_subdir, prompt, cached_root)
      when is_map(profile) and is_map(lane_config) and is_binary(workspace_subdir) and is_binary(prompt) and
             (is_binary(cached_root) or is_nil(cached_root)) do
    with {:ok, worker} <- profile_worker(profile),
         :ok <- validate_lane_ownership(lane_config),
         {:ok, base_root} <- profile_workspace_base(profile),
         {:ok, effective_root} <- effective_root(worker, base_root, workspace_subdir, cached_root),
         effective_config <- compose(profile, worker, lane_config, effective_root),
         normalized_prompt <- prompt |> String.replace(~r/\R/u, "\n") |> String.trim(),
         workflow <- %{config: effective_config, prompt: normalized_prompt, prompt_template: normalized_prompt},
         {:ok, settings} <- Schema.parse(Map.delete(workflow.config, "server"), errors: :list),
         :ok <- Config.validate_settings(settings) do
      {:ok, %{settings: settings, workflow: workflow, warnings: warnings(workflow.config)}}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, reason} -> {:error, errors_for(reason)}
    end
  end

  def resolve(_profile, _lane_config, _workspace_subdir, _prompt, _cached_root), do: {:error, [error("config", "must be an object")]}

  @spec validate_profile(map()) :: :ok | {:error, [map()]}
  def validate_profile(profile) when is_map(profile) do
    case profile_worker(profile) do
      {:ok, _worker} -> :ok
      {:error, errors} when is_list(errors) -> {:error, normalize_profile_errors(errors)}
    end
  end

  def validate_profile(_profile), do: {:error, [error("profile", "must be an object")]}

  @doc false
  @spec location_source(map(), String.t()) :: {:ssh, term(), String.t(), [term()]} | nil
  def location_source(profile, workspace_subdir) when is_map(profile) and is_binary(workspace_subdir) do
    worker = Map.get(profile, "worker", Map.get(profile, :worker, %{}))
    hosts = if is_map(worker), do: worker_hosts(worker), else: []

    if is_list(hosts) and hosts != [] do
      base = profile |> Map.get("workspace_base", Map.get(profile, :workspace_base)) |> resolve_workspace_base()
      {:ssh, base, workspace_subdir, hosts |> Enum.uniq() |> Enum.sort()}
    end
  end

  def location_source(_profile, _workspace_subdir), do: nil

  @doc false
  @spec workspace_base(map()) :: String.t() | nil
  def workspace_base(profile) when is_map(profile) do
    profile
    |> Map.get("workspace_base", Map.get(profile, :workspace_base))
    |> case do
      value when is_binary(value) and value != "" -> resolve_workspace_base(value)
      _ -> nil
    end
  end

  defp pop_if_present(map, key) do
    case Map.fetch(map, key) do
      :error -> {%{}, map}
      {:ok, value} -> {%{key => value}, Map.delete(map, key)}
    end
  end

  defp put_workspace(config, workspace) when workspace == %{}, do: Map.delete(config, "workspace")
  defp put_workspace(config, workspace), do: Map.put(config, "workspace", workspace)

  defp profile_worker(profile) do
    case Map.fetch(profile, "worker") do
      :error ->
        {:ok, %{}}

      {:ok, worker} when is_map(worker) ->
        case Schema.parse(%{"worker" => worker}, errors: :list) do
          {:ok, _settings} ->
            {:ok, worker}

          {:error, {:invalid_workflow_config, errors}} ->
            {:error, Enum.map(errors, fn {path, message} -> error("profile." <> path, message) end)}
        end

      {:ok, _worker} ->
        {:error, [error("profile.worker", "must be an object")]}
    end
  end

  defp profile_workspace_base(profile) do
    case Map.fetch(profile, "workspace_base") do
      :error -> {:ok, %Schema.Workspace{}.root}
      {:ok, root} when is_binary(root) and byte_size(root) > 0 -> {:ok, root}
      {:ok, _root} -> {:error, [error("profile.workspace_base", "must be a nonempty string")]}
    end
  end

  defp validate_lane_ownership(config) do
    errors =
      [
        if(Map.has_key?(config, "worker"), do: error("config.worker", "is owned by the execution profile")),
        if(Map.has_key?(config, "workspace_base"), do: error("config.workspace_base", "is owned by the execution profile")),
        workspace_root_error(config)
      ]
      |> Enum.reject(&is_nil/1)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp workspace_root_error(%{"workspace" => workspace}) when is_map(workspace) do
    if Map.has_key?(workspace, "root"), do: error("config.workspace.root", "is owned by the execution profile")
  end

  defp workspace_root_error(%{"workspace" => _workspace}), do: error("config.workspace", "must be an object")
  defp workspace_root_error(_config), do: nil

  defp effective_root(_worker, _base_root, _workspace_subdir, cached_root) when is_binary(cached_root) and cached_root != "", do: {:ok, cached_root}

  defp effective_root(worker, base_root, workspace_subdir, nil) do
    base_root = resolve_workspace_base(base_root)

    cond do
      absolute_path?(workspace_subdir) ->
        {:error, [error("workspace_subdir", "must be relative")]}

      workspace_subdir == "" ->
        {:error, [error("workspace_subdir", "must not be blank")]}

      Enum.any?(Path.split(workspace_subdir), &(&1 == "..")) ->
        {:error, [error("workspace_subdir", "must not contain .. segments")]}

      static_ssh_worker?(worker) ->
        SymphonyElixir.Workspace.remote_effective_root(worker_hosts(worker), base_root, workspace_subdir)

      managed_worker?(worker) ->
        {:ok, if(workspace_subdir == ".", do: base_root, else: Path.join(base_root, workspace_subdir))}

      true ->
        with expanded_base <- Path.expand(base_root, Config.data_root()),
             {:ok, canonical_base} <- PathSafety.canonicalize(expanded_base),
             effective_path <- Path.join(canonical_base, workspace_subdir),
             {:ok, canonical_effective} <- PathSafety.canonicalize(effective_path),
             {:ok, true} <- PathSafety.contained?(canonical_effective, canonical_base) do
          {:ok, canonical_effective}
        else
          {:ok, false} -> {:error, [error("workspace_subdir", "resolves outside workspace_base")]}
          {:error, _reason} -> {:error, [error("workspace_subdir", "cannot be safely resolved")]}
        end
    end
  end

  defp resolve_workspace_base("$" <> env_name = value) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      case System.get_env(env_name) do
        nil -> %Schema.Workspace{}.root
        "" -> %Schema.Workspace{}.root
        path -> path
      end
    else
      value
    end
  end

  defp resolve_workspace_base(value), do: value

  defp worker_hosts(worker), do: Map.get(worker, "ssh_hosts", Map.get(worker, :ssh_hosts, []))
  defp static_ssh_worker?(worker), do: worker_hosts(worker) != []
  defp managed_worker?(worker), do: is_map(Map.get(worker, "environment", Map.get(worker, :environment)))

  defp absolute_path?(path), do: :filename.pathtype(String.to_charlist(path)) == :absolute

  defp compose(profile, worker, lane_config, effective_root) do
    workspace = Map.get(lane_config, "workspace", %{})

    lane_config
    |> Map.put("worker", Map.get(profile, "worker", worker))
    |> Map.put("workspace", Map.put(workspace, "root", effective_root))
  end

  defp warnings(config) do
    if Map.has_key?(config, "server"), do: ["server is configured per installation now (symphony serve --port/--host); the section is ignored"], else: []
  end

  defp errors_for({:invalid_workflow_config, errors}) when is_list(errors),
    do: Enum.map(errors, fn {path, message} -> error(path, message) end)

  defp errors_for({:invalid_workflow_config, message}) when is_binary(message) do
    case Regex.run(~r/^([a-z_]+(?:\.[a-z_]+)+) (.+)$/s, message, capture: :all_but_first) do
      [path, rest] -> [error(path, rest)]
      nil -> [error("config", message)]
    end
  end

  defp errors_for(:missing_tracker_kind), do: [error("tracker.kind", "can't be blank")]
  defp errors_for({:unsupported_tracker_kind, kind}), do: [error("tracker.kind", "unsupported tracker kind: #{inspect(kind)}")]
  defp errors_for(reason), do: [error("config", inspect(reason))]

  defp error(path, message), do: %{path: path, message: message}

  defp normalize_profile_errors(errors) do
    Enum.map(errors, fn
      %{path: "profile." <> path} = error -> %{error | path: path}
      error -> error
    end)
  end

  defp restore_redacted_value(@redacted, original, _path) when original not in [@missing, @redacted], do: {:ok, original}
  defp restore_redacted_value(@redacted, _original, path), do: {:error, [error(path, "cannot redact a value that does not already exist")]}

  defp restore_redacted_value(value, original, path) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, child}, {:ok, restored} ->
      child_original = if is_map(original), do: Map.get(original, key, @missing), else: @missing

      case restore_redacted_value(child, child_original, child_path(path, key)) do
        {:ok, result} -> {:cont, {:ok, Map.put(restored, key, result)}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
  end

  defp restore_redacted_value(value, original, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {child, index}, {:ok, restored} ->
      child_original = if is_list(original), do: Enum.at(original, index, @missing), else: @missing

      case restore_redacted_value(child, child_original, "#{path}[#{index}]") do
        {:ok, result} -> {:cont, {:ok, [result | restored]}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      error -> error
    end
  end

  defp restore_redacted_value(value, _original, _path), do: {:ok, value}
  defp child_path("", key), do: to_string(key)
  defp child_path(path, key), do: path <> "." <> to_string(key)
  defp secret_key?(key), do: Regex.match?(~r/(api.?key|token|secret|password|credential)/i, to_string(key))
end
