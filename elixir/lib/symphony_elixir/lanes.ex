defmodule SymphonyElixir.Lanes do
  @moduledoc "Database-backed lane configuration and immutable workflow versions."

  import Ecto.Query, only: [from: 2]
  alias SymphonyElixir.{Config, LaneStore, LaneSupervisor, Repo, Workflow}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Lanes.{Lane, LaneVersion}

  @type error :: %{path: String.t(), message: String.t()}
  @type validated :: %{settings: Schema.t(), workflow: Workflow.loaded_workflow(), warnings: [String.t()]}
  @lane_fields ~w(slug name enabled executor)
  @string_fields ~w(slug name executor front_matter prompt)
  @path_pattern ~r/^([a-z_]+(?:\.[a-z_]+)+) (.+)$/s
  @max_sqlite_id 9_223_372_036_854_775_807

  @spec list() :: [Lane.t()]
  def list, do: Repo.all(from(l in Lane, where: is_nil(l.deleted_at), order_by: l.id))

  @spec get(term()) :: Lane.t() | nil
  def get(id) when is_integer(id) and id > 0 and id <= @max_sqlite_id, do: Repo.one(from(l in Lane, where: l.id == ^id and is_nil(l.deleted_at)))
  def get(_id), do: nil

  @spec get!(integer()) :: Lane.t()
  def get!(id), do: get(id) || raise(Ecto.NoResultsError, queryable: Lane)

  @spec get_by_slug(term()) :: Lane.t() | nil
  def get_by_slug(slug) when is_binary(slug), do: Repo.one(from(l in Lane, where: l.slug == ^slug and is_nil(l.deleted_at)))
  def get_by_slug(_slug), do: nil

  @spec versions(Lane.t()) :: [LaneVersion.t()]
  def versions(%Lane{id: id}), do: Repo.all(from(v in LaneVersion, where: v.lane_id == ^id, order_by: [desc: v.id]))

  @spec current_version(Lane.t()) :: LaneVersion.t() | nil
  def current_version(%Lane{current_version_id: nil}), do: nil
  def current_version(%Lane{id: lane_id, current_version_id: id}), do: Repo.one(from(v in LaneVersion, where: v.id == ^id and v.lane_id == ^lane_id))

  @spec validate_version(integer() | nil, term(), term()) :: {:ok, validated()} | {:error, [error()]}
  def validate_version(lane_id, front_matter, prompt) when is_binary(front_matter) and is_binary(prompt) do
    with {:ok, workflow} <- Workflow.parse_parts(front_matter, prompt),
         {:ok, settings} <- Schema.parse(Map.delete(workflow.config, "server"), errors: :list),
         :ok <- Config.validate_settings(settings),
         :ok <- LaneStore.check_identity(lane_id, settings) do
      {:ok, %{settings: settings, workflow: workflow, warnings: config_warnings(workflow.config)}}
    else
      {:error, reason} -> {:error, errors_for(reason)}
    end
  end

  def validate_version(_lane_id, front_matter, prompt) do
    {:error, type_errors(%{"front_matter" => front_matter, "prompt" => prompt})}
  end

  @spec warnings(String.t()) :: [String.t()]
  def warnings(front_matter) when is_binary(front_matter) do
    case Workflow.parse_parts(front_matter, "") do
      {:ok, %{config: config}} -> config_warnings(config)
      {:error, _reason} -> []
    end
  end

  @spec create(term()) :: {:ok, Lane.t()} | {:error, [error()]}
  def create(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize(attrs) do
      attrs = Map.put_new(attrs, "name", attrs["slug"])
      mutate(nil, &create_lane(attrs, &1))
    end
  end

  def create(_attrs), do: invalid_object()

  @spec update(Lane.t(), term()) :: {:ok, Lane.t()} | {:error, [error()]}
  def update(%Lane{id: id}, attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize(attrs) do
      mutate(id, &update_lane(id, attrs, &1))
    end
  end

  def update(%Lane{}, _attrs), do: invalid_object()

  @spec activate_version(Lane.t(), term()) :: {:ok, Lane.t()} | {:error, [error()]}
  def activate_version(%Lane{id: id}, version_id) when is_integer(version_id) and version_id > 0 and version_id <= @max_sqlite_id do
    mutate(id, &activate_lane_version(id, version_id, &1))
  end

  def activate_version(%Lane{}, _version_id), do: {:error, [%{path: "version", message: "must be an integer between 1 and 9223372036854775807"}]}

  @spec set_enabled(Lane.t(), term()) :: {:ok, Lane.t()} | {:error, [error()]}
  def set_enabled(%Lane{} = lane, enabled), do: update(lane, %{enabled: enabled})

  @spec disable(integer(), String.t()) :: :ok
  def disable(lane_id, reason) when is_integer(lane_id) and lane_id > 0 and lane_id <= @max_sqlite_id and is_binary(reason) do
    {:ok, _lane} = mutate(lane_id, fn _check -> disable_lane(lane_id) end, reason)
    :ok
  end

  def disable(_lane_id, reason) when is_binary(reason), do: :ok

  @spec delete(Lane.t()) :: :ok | {:error, :lane_active}
  def delete(%Lane{id: id}) do
    case mutate(id, fn _check -> delete_lane(id) end) do
      {:ok, _lane} -> :ok
      {:error, :lane_active} = error -> error
    end
  end

  @spec import_file(Path.t(), keyword()) :: {:ok, Lane.t(), [String.t()]} | {:error, [error()]}
  def import_file(path, opts) do
    case File.read(path) do
      {:error, reason} ->
        {:error, [%{path: "file", message: "cannot read #{path}: #{inspect(reason)}"}]}

      {:ok, content} ->
        import_content(content, path, opts)
    end
  end

  @spec export(Lane.t()) :: {:ok, String.t()} | {:error, :no_version}
  def export(%Lane{} = lane) do
    case current_version(lane) do
      nil -> {:error, :no_version}
      version -> {:ok, Workflow.render(version.front_matter, version.prompt)}
    end
  end

  @spec errors_for(term()) :: [error()]
  def errors_for(errors) when is_list(errors), do: errors

  def errors_for(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &%{path: to_string(field), message: &1}) end)
  end

  def errors_for({:invalid_workflow_config, errors}) when is_list(errors), do: Enum.map(errors, fn {path, message} -> %{path: path, message: message} end)

  def errors_for({:invalid_workflow_config, message}) when is_binary(message) do
    case Regex.run(@path_pattern, message, capture: :all_but_first) do
      [path, rest] -> [%{path: path, message: rest}]
      nil -> [%{path: "worker", message: message}]
    end
  end

  def errors_for(:environment_identity_in_use), do: [%{path: "worker.environment", message: "cannot change a guarded field while the lane owns environments or has unresolved operations"}]
  def errors_for(:missing_tracker_kind), do: [%{path: "tracker.kind", message: "can't be blank"}]
  def errors_for({:unsupported_tracker_kind, kind}), do: [%{path: "tracker.kind", message: "unsupported tracker kind: #{inspect(kind)}"}]
  def errors_for(:workflow_front_matter_not_a_map), do: [%{path: "front_matter", message: "YAML must decode to a map"}]
  def errors_for({:workflow_parse_error, reason}), do: [%{path: "front_matter", message: "YAML parse error: #{inspect(reason)}"}]
  def errors_for(reason) when is_atom(reason), do: [%{path: "tracker", message: reason |> Atom.to_string() |> String.replace("_", " ")}]
  def errors_for(reason), do: [%{path: "front_matter", message: inspect(reason)}]

  @spec format_errors([error()]) :: String.t()
  def format_errors(errors), do: Enum.map_join(errors, "; ", &"#{&1.path}: #{&1.message}")

  defp create_lane(attrs, check) do
    front_matter = Map.get(attrs, "front_matter", "")
    prompt = Map.get(attrs, "prompt", "")

    with {:ok, _validated} <- validate_candidate(nil, front_matter, prompt, check),
         {:ok, lane} <- Repo.insert(Lane.changeset(%Lane{}, Map.take(attrs, @lane_fields))) do
      add_version(lane, front_matter, prompt, attrs["note"])
    end
  end

  defp update_lane(id, attrs, check) do
    with {:ok, lane} <- fetch_lane(id) do
      update_current_lane(lane, attrs, check)
    end
  end

  defp update_current_lane(lane, attrs, check) do
    current = current_version(lane)
    front_matter = Map.get(attrs, "front_matter", (current && current.front_matter) || "")
    prompt = Map.get(attrs, "prompt", (current && current.prompt) || "")
    new_version? = Map.has_key?(attrs, "front_matter") or Map.has_key?(attrs, "prompt")
    validate? = new_version? or Map.get(attrs, "enabled", lane.enabled)

    with :ok <- validate_update(validate?, current, new_version?, front_matter, prompt, check),
         {:ok, updated} <- Repo.update(Lane.changeset(lane, Map.take(attrs, @lane_fields))) do
      if new_version?, do: add_version(updated, front_matter, prompt, attrs["note"]), else: {:ok, updated}
    end
  end

  defp activate_lane_version(id, version_id, check) do
    with {:ok, lane} <- fetch_lane(id),
         {:ok, version} <- fetch_version(id, version_id),
         {:ok, _} <- validate_candidate(nil, version.front_matter, version.prompt, check) do
      lane |> Ecto.Changeset.change(current_version_id: version.id) |> Repo.update()
    end
  end

  defp fetch_version(lane_id, version_id) do
    case Repo.one(from(v in LaneVersion, where: v.id == ^version_id and v.lane_id == ^lane_id)) do
      nil -> {:error, [%{path: "version", message: "not found for this lane"}]}
      version -> {:ok, version}
    end
  end

  defp disable_lane(id) do
    case get(id) do
      nil -> {:ok, nil}
      lane -> lane |> Ecto.Changeset.change(enabled: false) |> Repo.update()
    end
  end

  defp delete_lane(id) do
    case get(id) do
      nil -> {:ok, nil}
      lane -> delete_inactive_lane(lane)
    end
  end

  defp delete_inactive_lane(lane) do
    if lane.enabled or LaneSupervisor.running?(lane.id) do
      {:error, :lane_active}
    else
      lane |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)) |> Repo.update()
    end
  end

  defp import_content(content, path, opts) do
    %{front_matter: front_matter, prompt: prompt} = Workflow.split(content)
    attrs = %{front_matter: front_matter, prompt: prompt, note: Keyword.get(opts, :note, "import #{Path.basename(path)}")}

    with {:ok, lane} <- import_lane(Keyword.get(opts, :slug), attrs, opts) do
      {:ok, lane, warnings(front_matter)}
    end
  end

  defp import_lane(slug, attrs, opts) do
    case get_by_slug(slug) do
      nil ->
        create(Map.merge(attrs, %{slug: slug, name: Keyword.get(opts, :name, slug), enabled: false, executor: "local"}))

      lane ->
        attrs = if Keyword.has_key?(opts, :name), do: Map.put(attrs, :name, opts[:name]), else: attrs
        update(lane, attrs)
    end
  end

  defp mutate(lane_id, fun, reason \\ nil) do
    LaneStore.mutate(lane_id, &transact_mutation(fun, &1), reason)
    |> case do
      {:ok, lane} -> {:ok, lane}
      {:error, :lane_active} = error -> error
      {:error, reason} -> {:error, errors_for(reason)}
    end
  end

  defp transact_mutation(fun, check) do
    Repo.transaction(fn ->
      case fun.(check) do
        {:ok, lane} -> lane
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp fetch_lane(id) do
    case get(id) do
      nil -> {:error, [%{path: "lane", message: "not found"}]}
      lane -> {:ok, lane}
    end
  end

  defp validate_update(false, _current, _new?, _front, _prompt, _check), do: :ok
  defp validate_update(true, nil, false, _front, _prompt, _check), do: {:error, [%{path: "version", message: "lane has no version"}]}

  defp validate_update(true, _current, _new?, front, prompt, check) do
    with {:ok, _} <- validate_candidate(nil, front, prompt, check), do: :ok
  end

  defp validate_candidate(lane_id, front, prompt, check) do
    with {:ok, validated} <- validate_version(lane_id, front, prompt),
         :ok <- check.(validated.settings) do
      {:ok, validated}
    end
  end

  defp add_version(lane, front_matter, prompt, note) do
    with {:ok, version} <- Repo.insert(LaneVersion.changeset(%LaneVersion{lane_id: lane.id}, %{front_matter: front_matter, prompt: prompt, note: note})) do
      lane |> Ecto.Changeset.change(current_version_id: version.id) |> Repo.update()
    end
  end

  defp normalize(attrs) do
    if Enum.all?(Map.keys(attrs), &(is_binary(&1) or is_atom(&1))) do
      attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

      case type_errors(attrs) do
        [] -> {:ok, attrs}
        errors -> {:error, errors}
      end
    else
      invalid_object()
    end
  end

  defp type_errors(attrs) do
    Enum.flat_map(attrs, fn {key, value} ->
      cond do
        key in @string_fields and not is_binary(value) -> [%{path: key, message: "must be a string"}]
        key == "enabled" and not is_boolean(value) -> [%{path: key, message: "must be a boolean"}]
        key == "note" and not (is_binary(value) or is_nil(value)) -> [%{path: key, message: "must be a string or null"}]
        true -> []
      end
    end)
  end

  defp invalid_object, do: {:error, [%{path: "lane", message: "must be an object"}]}

  defp config_warnings(config) do
    if Map.has_key?(config, "server"), do: ["server is configured per installation now (symphony serve --port/--host); the section is ignored"], else: []
  end
end
