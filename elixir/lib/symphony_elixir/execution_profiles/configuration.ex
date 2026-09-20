defmodule SymphonyElixir.ExecutionProfiles.Configuration do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PathSafety

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

  @spec resolve(map(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, [map()]}
  def resolve(profile, lane_config, workspace_subdir, prompt)
      when is_map(profile) and is_map(lane_config) and is_binary(workspace_subdir) and is_binary(prompt) do
    with {:ok, worker} <- profile_worker(profile),
         :ok <- validate_lane_ownership(lane_config),
         {:ok, base_root} <- profile_workspace_base(profile),
         {:ok, effective_root} <- effective_root(worker, base_root, workspace_subdir),
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

  def resolve(_profile, _lane_config, _workspace_subdir, _prompt), do: {:error, [error("config", "must be an object")]}

  @spec validate_profile(map()) :: :ok | {:error, [map()]}
  def validate_profile(profile) when is_map(profile) do
    case profile_worker(profile) do
      {:ok, _worker} -> :ok
      {:error, errors} when is_list(errors) -> {:error, normalize_profile_errors(errors)}
    end
  end

  def validate_profile(_profile), do: {:error, [error("profile", "must be an object")]}

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

  defp effective_root(worker, base_root, workspace_subdir) do
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
end
