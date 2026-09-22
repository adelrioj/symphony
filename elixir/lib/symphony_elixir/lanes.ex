defmodule SymphonyElixir.Lanes do
  @moduledoc "Database-backed lane configuration and immutable workflow versions."

  import Ecto.Query, only: [from: 2]
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.{ExecutionProfiles, LaneStore, LaneSupervisor, Repo, Workflow, Workspace}
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.ExecutionProfiles.Profile
  alias SymphonyElixir.Lanes.{Lane, LaneVersion}

  @type error :: %{path: String.t(), message: String.t()}
  @type validated :: %{settings: Schema.t(), workflow: Workflow.loaded_workflow(), warnings: [String.t()]}
  @lane_fields ~w(name enabled execution_profile_id workspace_subdir)
  @string_fields ~w(slug name workspace_subdir prompt front_matter)
  @path_pattern ~r/^([a-z_]+(?:\.[a-z_]+)+) (.+)$/s
  @max_sqlite_id 9_223_372_036_854_775_807

  @spec list() :: [Lane.t()]
  def list, do: Repo.all(from(l in Lane, where: is_nil(l.deleted_at), order_by: l.id))

  @spec get(term()) :: Lane.t() | nil
  def get(id) when is_integer(id) and id > 0 and id <= @max_sqlite_id, do: Repo.one(from(l in Lane, where: l.id == ^id and is_nil(l.deleted_at)))
  def get(_id), do: nil

  @spec get_any(term()) :: Lane.t() | nil
  def get_any(id) when is_integer(id) and id > 0 and id <= @max_sqlite_id, do: Repo.get(Lane, id)
  def get_any(_id), do: nil

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

  @doc false
  @spec resolve_lane(Lane.t()) :: {:ok, validated()} | {:error, [error()]}
  def resolve_lane(%Lane{} = lane), do: resolve_lane(lane, nil)

  @doc false
  @spec resolve_lane(Lane.t(), String.t() | nil) :: {:ok, validated()} | {:error, [error()]}
  def resolve_lane(%Lane{} = lane, cached_root) do
    with {:ok, profile} <- fetch_profile(lane.execution_profile_id),
         :ok <- profile_repair(profile),
         {:ok, version} <- fetch_current_version(lane),
         {:ok, config} <- lane_config(version.front_matter),
         {:ok, value} <- Configuration.resolve(profile_attrs(profile), config, lane.workspace_subdir, version.prompt, cached_root) do
      {:ok, value}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, reason} -> {:error, errors_for(reason)}
    end
  end

  @doc false
  @spec ownership_settings(Lane.t()) :: {:ok, Schema.t()} | {:error, term()}
  def ownership_settings(%Lane{} = lane) do
    with {:ok, profile} <- fetch_profile(lane.execution_profile_id),
         :ok <- ownership_provenance(profile, lane),
         {:ok, worker} <- ownership_worker(profile.worker),
         attrs = Map.put(profile_attrs(profile), "worker", worker),
         {:ok, %{settings: settings}} <-
           Configuration.resolve(attrs, %{"tracker" => %{"kind" => "memory"}}, lane.workspace_subdir, "") do
      ownership_tracker(settings, lane)
    end
  end

  defp ownership_provenance(%Profile{repair_error: nil}, _lane), do: :ok

  defp ownership_provenance(_profile, lane) do
    # Migration sanitizes unrepresentable infrastructure before persisting a
    # repair row. The preserved source must still prove that it was not unknown.
    with {:ok, version} <- fetch_current_version(lane),
         {:ok, %{config: config}} <- Workflow.parse_parts(version.front_matter, ""),
         true <- is_map(Map.get(config, "worker", %{})),
         true <- is_map(Map.get(config, "workspace", %{})) do
      :ok
    else
      _ -> {:error, :environment_identity_in_use}
    end
  end

  defp ownership_worker(worker) when is_map(worker) do
    worker = Map.delete(worker, "max_concurrent_agents_per_host")

    case Map.get(worker, "environment") do
      environment when is_map(environment) ->
        # Lifecycle limits do not identify a resource or its workspace.
        environment = Map.merge(environment, %{"startup_timeout_ms" => 1, "shutdown_timeout_ms" => 1, "terminal_retention_ms" => 0})
        {:ok, Map.put(worker, "environment", environment)}

      nil ->
        {:ok, worker}

      _ ->
        {:error, :environment_identity_in_use}
    end
  end

  defp ownership_tracker(%Schema{worker: %{environment: nil}} = settings, _lane), do: {:ok, settings}

  defp ownership_tracker(settings, lane) do
    with {:ok, version} <- fetch_current_version(lane),
         {:ok, %{"tracker" => %{"kind" => kind}}} <- lane_config(version.front_matter),
         true <- is_binary(kind) and String.trim(kind) != "" do
      {:ok, put_in(settings.tracker.kind, kind)}
    else
      _ -> {:error, :environment_identity_in_use}
    end
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

  @spec delete(Lane.t()) :: :ok | {:error, term()}
  def delete(%Lane{id: id}) do
    case mutate(id, fn check -> delete_lane(id, check) end) do
      {:ok, _lane} -> :ok
      {:error, reason} -> {:error, reason}
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
      nil ->
        {:error, :no_version}

      _version ->
        export_current_lane(lane)
    end
  end

  defp export_current_lane(lane) do
    case effective_lane_workflow(lane) do
      {:ok, %{workflow: %{config: config, prompt: prompt}}} ->
        {:ok, Workflow.render(Workflow.encode_config(Configuration.redact_secrets(config)), prompt)}

      _ ->
        {:error, :no_version}
    end
  end

  defp effective_lane_workflow(lane) do
    case LaneStore.lookup(lane.id) do
      {:ok, %{workflow: %{}}} = result -> result
      _ -> resolve_lane(lane)
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

  def errors_for({:lane_invalid, lane_id, errors}) when is_list(errors) do
    Enum.map(errors, &%{path: "lanes.#{lane_id}.#{&1.path}", message: &1.message})
  end

  def errors_for({:profile_repair, message}), do: [%{path: "profile", message: message}]

  def errors_for({:workspace_identity_in_use, left, right}) do
    [
      %{path: "lanes.#{left}.workspace", message: "location conflicts with lane #{right}"},
      %{path: "lanes.#{right}.workspace", message: "location conflicts with lane #{left}"}
    ]
  end

  def errors_for(:environment_identity_in_use), do: [%{path: "worker.environment", message: "cannot change a guarded field while the lane owns environments or has unresolved operations"}]
  def errors_for(:lane_resources_retained), do: [%{path: "lane", message: "cannot delete while workspaces, managed resources, or unresolved operations may remain"}]
  def errors_for(:missing_tracker_kind), do: [%{path: "tracker.kind", message: "can't be blank"}]
  def errors_for({:unsupported_tracker_kind, kind}), do: [%{path: "tracker.kind", message: "unsupported tracker kind: #{inspect(kind)}"}]
  def errors_for(:workflow_front_matter_not_a_map), do: [%{path: "front_matter", message: "YAML must decode to a map"}]
  def errors_for({:workflow_parse_error, reason}), do: [%{path: "front_matter", message: "YAML parse error: #{inspect(reason)}"}]
  def errors_for(reason) when is_atom(reason), do: [%{path: "tracker", message: reason |> Atom.to_string() |> String.replace("_", " ")}]
  def errors_for(reason), do: [%{path: "front_matter", message: inspect(reason)}]

  @spec format_errors([error()]) :: String.t()
  def format_errors(errors), do: Enum.map_join(errors, "; ", &"#{&1.path}: #{&1.message}")

  defp create_lane(attrs, check) do
    config = Map.get(attrs, "config", %{})
    prompt = Map.get(attrs, "prompt", "")
    slug = attrs["slug"]
    subdir = Map.get(attrs, "workspace_subdir", slug)
    attrs = Map.put(attrs, "enabled", false)

    with :ok <- reject_legacy_fields(attrs),
         {:ok, profile} <- fetch_profile(attrs["execution_profile_id"]),
         {:ok, validated} <- validate_candidate(profile, config, subdir, prompt, nil, check),
         {:ok, lane} <- Repo.insert(Lane.changeset(%Lane{}, Map.merge(Map.take(attrs, @lane_fields), %{"slug" => slug, "workspace_subdir" => subdir, "executor" => "local"}))),
         {:ok, lane} <- add_version(lane, Workflow.encode_config(config), prompt, attrs["note"]) do
      _ = validated
      {:ok, lane}
    end
  end

  defp update_lane(id, attrs, check) do
    with {:ok, lane} <- fetch_lane(id),
         :ok <- immutable_slug(attrs),
         :ok <- reject_legacy_fields(attrs) do
      update_current_lane(lane, attrs, check)
    end
  end

  defp update_current_lane(lane, attrs, check) do
    current = current_version(lane)

    config = Map.get(attrs, "config", previous_config(current))
    prompt = Map.get(attrs, "prompt", (current && current.prompt) || "")
    profile_id = Map.get(attrs, "execution_profile_id", lane.execution_profile_id)
    subdir = Map.get(attrs, "workspace_subdir", lane.workspace_subdir)
    new_version? = Map.has_key?(attrs, "config") or Map.has_key?(attrs, "prompt")
    validation = update_validation(current, new_version?, attrs, lane.enabled)

    with {:ok, profile} <- fetch_profile(profile_id),
         :ok <- validate_update(validation, profile, config, subdir, prompt, lane.id, check),
         {:ok, updated} <- Repo.update(Lane.changeset(lane, Map.take(Map.put(attrs, "execution_profile_id", profile_id), @lane_fields))),
         {:ok, updated} <- maybe_add_version(updated, config, prompt, attrs["note"], new_version?) do
      repair_profile(updated, profile)
    end
  end

  defp previous_config(nil), do: %{}

  defp previous_config(version) do
    case current_config(version.front_matter) do
      {:ok, config} -> config
      {:error, _} -> %{}
    end
  end

  defp update_validation(current, new_version?, attrs, enabled) do
    required? = new_version? or Map.has_key?(attrs, "execution_profile_id") or Map.has_key?(attrs, "workspace_subdir") or Map.get(attrs, "enabled", enabled)

    cond do
      not required? -> :skip
      is_nil(current) and not new_version? -> :missing_version
      true -> :validate
    end
  end

  defp maybe_add_version(lane, config, prompt, note, true), do: add_version(lane, Workflow.encode_config(config), prompt, note)
  defp maybe_add_version(lane, _config, _prompt, _note, false), do: {:ok, lane}

  defp repair_profile(lane, %Profile{repair_error: nil}), do: {:ok, lane}

  defp repair_profile(lane, %Profile{} = profile) do
    with {:ok, _profile} <- profile |> Ecto.Changeset.change(repair_error: nil) |> Repo.update() do
      ids = profile |> ExecutionProfiles.linked_lanes() |> Enum.map(& &1.id)
      {:ok, {:batch, lane, ids}}
    end
  end

  defp activate_lane_version(id, version_id, check) do
    with {:ok, lane} <- fetch_lane(id),
         {:ok, version} <- fetch_version(id, version_id),
         {:ok, config} <- current_config(version.front_matter),
         {:ok, profile} <- fetch_profile(lane.execution_profile_id),
         {:ok, _} <- validate_candidate(profile, config, lane.workspace_subdir, version.prompt, lane.id, check) do
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

  defp delete_lane(id, check) do
    case get(id) do
      nil -> {:ok, nil}
      lane -> delete_inactive_lane(lane, check)
    end
  end

  defp delete_inactive_lane(lane, check) do
    if lane.enabled or LaneSupervisor.running?(lane.id) do
      {:error, :lane_active}
    else
      settings =
        case resolve_lane(lane) do
          {:ok, %{settings: settings}} -> settings
          _ -> ownership_settings_for_deletion(lane)
        end

      with :ok <- check.({:delete, settings}) do
        lane |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)) |> Repo.update()
      end
    end
  end

  defp ownership_settings_for_deletion(lane) do
    case ownership_settings(lane) do
      {:ok, settings} -> settings
      {:error, _} -> nil
    end
  end

  defp import_content(content, _path, opts) do
    %{front_matter: front_matter, prompt: prompt} = Workflow.split(content)
    slug = Keyword.get(opts, :slug)

    with {:ok, workflow} <- Workflow.parse_parts(front_matter, prompt),
         {profile_attrs, config} = Configuration.split(workflow.config),
         {:ok, %{lane: lane, profile_name: profile_name}} <-
           import_mutation(slug, profile_attrs, config, prompt, opts) do
      {:ok, lane, ["created execution profile #{profile_name}" | warnings(front_matter)]}
    else
      {:error, errors} when is_list(errors) -> {:error, errors_for(errors)}
      {:error, reason} -> {:error, errors_for(reason)}
    end
  end

  defp import_mutation(slug, profile_attrs, config, prompt, opts) do
    profile_name = imported_profile_name(slug)

    mutation = fn check ->
      with {:ok, profile} <-
             Repo.insert(
               Profile.changeset(%Profile{}, %{
                 "name" => profile_name,
                 "workspace_base" => profile_attrs["workspace_base"] || %Schema.Workspace{}.root,
                 "worker" => profile_attrs["worker"] || %{}
               })
             ),
           {:ok, lane} <- import_lane(slug, config, prompt, profile.id, opts, check) do
        {:ok, {:batch, lane, [lane.id]}}
      else
        {:error, %Ecto.Changeset{} = changeset} -> {:error, errors_for(changeset)}
        {:error, errors} -> {:error, errors}
      end
    end

    result = execute_import_mutation(mutation, slug)

    result
    |> case do
      {:ok, {:batch, lane, _ids}} -> {:ok, %{lane: lane, profile_name: profile_name}}
      {:ok, lane} -> {:ok, %{lane: lane, profile_name: profile_name}}
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, reason} -> {:error, errors_for(reason)}
    end
  end

  defp execute_import_mutation(mutation, slug) do
    if Process.whereis(LaneStore) do
      LaneStore.mutate(nil, mutation, nil)
    else
      Repo.transaction(fn -> offline_import_mutation(mutation, slug) end)
    end
  end

  defp offline_import_mutation(mutation, slug) do
    with {:ok, {:batch, lane, _ids} = value} <- mutation.(&offline_identity_check(slug, &1)),
         :ok <- validate_offline_locations(lane.id) do
      value
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp import_lane(slug, config, prompt, profile_id, opts, check) do
    case get_by_slug(slug) do
      nil ->
        create_lane(
          %{
            "slug" => slug,
            "name" => Keyword.get(opts, :name, slug),
            "enabled" => false,
            "execution_profile_id" => profile_id,
            "workspace_subdir" => ".",
            "config" => config,
            "prompt" => prompt,
            "note" => Keyword.get(opts, :note, "import")
          },
          check
        )

      lane ->
        attrs = %{
          "execution_profile_id" => profile_id,
          "workspace_subdir" => ".",
          "config" => config,
          "prompt" => prompt,
          "note" => Keyword.get(opts, :note, "import")
        }

        attrs = if Keyword.has_key?(opts, :name), do: Map.put(attrs, "name", opts[:name]), else: attrs
        update_lane(lane.id, attrs, check)
    end
  end

  defp imported_profile_name(slug) do
    candidate = "Imported #{slug} #{System.unique_integer([:positive])}"

    if Enum.any?(ExecutionProfiles.list(), &(&1.name == candidate)), do: imported_profile_name(slug), else: candidate
  end

  defp offline_identity_check(slug, new_settings) do
    case get_by_slug(slug) do
      nil ->
        :ok

      lane ->
        with {:ok, old_settings} <- ownership_settings(lane) do
          check_offline_ownership(old_settings, new_settings)
        end
    end
  end

  defp check_offline_ownership(old_settings, new_settings) do
    cond do
      effective_identity(old_settings) == effective_identity(new_settings) -> :ok
      not is_nil(EnvironmentConfig.identity(old_settings)) -> {:error, :environment_identity_in_use}
      Workspace.location_inventory(old_settings) == :empty -> :ok
      true -> {:error, :environment_identity_in_use}
    end
  end

  defp validate_offline_locations(lane_id) do
    with {:ok, lanes} <- resolve_offline_lanes(list(), lane_id) do
      case offline_location_conflict(List.keyfind(lanes, lane_id, 0), lanes) do
        nil -> :ok
        error -> {:error, error}
      end
    end
  end

  defp offline_location_conflict({left_id, left}, lanes) do
    Enum.find_value(lanes, fn {right_id, right} ->
      if left_id != right_id and LaneStore.locations_overlap?(left, right),
        do: {:workspace_identity_in_use, left_id, right_id}
    end)
  end

  defp resolve_offline_lanes(lanes, target_id) do
    Enum.reduce_while(lanes, {:ok, []}, fn lane, {:ok, resolved} ->
      case offline_owner_settings(lane, target_id) do
        {:ok, settings} -> {:cont, {:ok, [{lane.id, settings} | resolved]}}
        {:error, error} -> {:halt, {:error, {:lane_invalid, lane.id, error}}}
      end
    end)
  end

  defp offline_owner_settings(%Lane{id: id} = lane, target_id) when id == target_id do
    with {:ok, %{settings: settings}} <- resolve_lane(lane), do: {:ok, settings}
  end

  defp offline_owner_settings(lane, _target_id), do: ownership_settings(lane)

  defp effective_identity(settings), do: EnvironmentConfig.identity(settings) || EnvironmentConfig.location_identity(settings)

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
        {:ok, value} -> value
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

  defp validate_update(:skip, _profile, _config, _subdir, _prompt, _lane_id, _check), do: :ok

  defp validate_update(:missing_version, _profile, _config, _subdir, _prompt, _lane_id, _check),
    do: {:error, [%{path: "version", message: "lane has no version"}]}

  defp validate_update(:validate, profile, config, subdir, prompt, lane_id, check) do
    with {:ok, _} <- validate_candidate(profile, config, subdir, prompt, lane_id, check), do: :ok
  end

  defp validate_candidate(profile, config, subdir, prompt, lane_id, check) do
    attrs = profile_attrs(profile)
    cached_root = cached_root(lane_id, attrs, subdir)

    with {:ok, validated} <- Configuration.resolve(attrs, config, subdir, prompt, cached_root),
         :ok <- check.(validated.settings) do
      {:ok, validated}
    end
  end

  @doc false
  @spec cached_root(term(), map(), String.t()) :: String.t() | nil
  def cached_root(lane_id, profile, subdir) do
    source = Configuration.location_source(profile, subdir)

    case LaneStore.lookup(lane_id) do
      {:ok, %{location_source: ^source, settings: %Schema{workspace: %{root: root}}}} when not is_nil(source) -> root
      _ -> nil
    end
  end

  defp fetch_profile(id) when is_integer(id) and id > 0 and id <= @max_sqlite_id do
    case ExecutionProfiles.get(id) do
      nil -> {:error, [%{path: "execution_profile_id", message: "not found"}]}
      profile -> {:ok, profile}
    end
  end

  defp fetch_profile(_id), do: {:error, [%{path: "execution_profile_id", message: "must be an integer"}]}

  defp profile_attrs(profile) do
    %{
      "name" => profile.name,
      "description" => profile.description,
      "workspace_base" => profile.workspace_base,
      "worker" => profile.worker
    }
  end

  defp profile_repair(%{repair_error: nil}), do: :ok
  defp profile_repair(%{repair_error: error}), do: {:error, {:profile_repair, error}}

  defp fetch_current_version(%Lane{} = lane) do
    case current_version(lane) do
      nil -> {:error, [%{path: "version", message: "lane has no version"}]}
      version -> {:ok, version}
    end
  end

  defp lane_config(front_matter) do
    case Workflow.parse_parts(front_matter, "") do
      {:ok, workflow} ->
        {_profile, config} = Configuration.split(workflow.config)
        {:ok, config}

      {:error, reason} ->
        {:error, errors_for(reason)}
    end
  end

  defp current_config(front_matter), do: lane_config(front_matter)

  defp immutable_slug(attrs) do
    if Map.has_key?(attrs, "slug"), do: {:error, [%{path: "slug", message: "is immutable"}]}, else: :ok
  end

  defp reject_legacy_fields(attrs) do
    errors =
      [
        Map.has_key?(attrs, "front_matter") && %{path: "front_matter", message: "is no longer accepted; use config"},
        Map.has_key?(attrs, "executor") && %{path: "executor", message: "is no longer accepted; use execution_profile_id"},
        Map.has_key?(attrs, "worker") && %{path: "worker", message: "is owned by the execution profile"},
        Map.has_key?(attrs, "workspace") && %{path: "workspace", message: "is owned by the execution profile"},
        Map.has_key?(attrs, "workspace_base") && %{path: "workspace_base", message: "is owned by the execution profile"}
      ]
      |> Enum.reject(&is_boolean/1)

    if errors == [], do: :ok, else: {:error, errors}
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

  defp type_errors(attrs), do: Enum.flat_map(attrs, &field_type_errors/1)

  defp field_type_errors({key, value}) when key in @string_fields and not is_binary(value),
    do: [%{path: key, message: "must be a string"}]

  defp field_type_errors({"enabled", value}) when not is_boolean(value),
    do: [%{path: "enabled", message: "must be a boolean"}]

  defp field_type_errors({"config", value}) when not is_map(value),
    do: [%{path: "config", message: "must be an object"}]

  defp field_type_errors({"execution_profile_id", value}) when not is_integer(value),
    do: [%{path: "execution_profile_id", message: "must be an integer"}]

  defp field_type_errors({"note", value}) when not (is_binary(value) or is_nil(value)),
    do: [%{path: "note", message: "must be a string or null"}]

  defp field_type_errors(_field), do: []

  defp invalid_object, do: {:error, [%{path: "lane", message: "must be an object"}]}

  defp config_warnings(config) do
    if Map.has_key?(config, "server"), do: ["server is configured per installation now (symphony serve --port/--host); the section is ignored"], else: []
  end
end
