defmodule SymphonyElixir.Lanes.InstructionMigration do
  @moduledoc "Backfills reviewed instruction bundles into legacy lane versions under offline maintenance."

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.{Lanes, Repo}
  alias SymphonyElixir.Lanes.{Lane, LaneVersion}

  @managed_slugs ~w(bonbons-delivery chorus-delivery)
  # Older inline prompts predate the image loader; its reserved path identifies image-backed history.
  @image_path "/opt/symphony/procedures/"
  @procedure_tool ~r/(?<![\w-])mcp__symphony__read_procedure(?![\w-])/
  @legacy_issue_interpolation ~r/\{\{-?\s*(?:issue\b|attempt\b)/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @doc "Validates an operator-reviewed manifest and updates only legacy instruction columns."
  @spec migrate(Path.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def migrate(path) do
    with {:ok, entries} <- read_manifest(path),
         :ok <- ensure_schema(entries) do
      Repo.transaction(
        fn ->
          versions = legacy_versions(:bundled_schema)

          case validate_coverage(versions, entries) do
            :ok -> update_versions(versions, entries)
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        log: false
      )
    end
  rescue
    # Database messages can contain instruction text; the offline command only reports a fixed code.
    _error in [DBConnection.ConnectionError, Ecto.ConstraintError, Exqlite.Error] -> {:error, :database_error}
  end

  defp ensure_schema(entries) do
    query = "SELECT 1 FROM pragma_table_info('lane_versions') WHERE name = 'procedures'"

    if Repo.query!(query, [], log: false).num_rows == 0 do
      # Before the additive DDL, every managed version is legacy. Reject an invalid manifest
      # without changing the old schema, then revalidate after migration inside the write transaction.
      with :ok <- validate_coverage(legacy_versions(:legacy_schema), entries), do: Repo.migrate()
    else
      :ok
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, json} -> parse_manifest(json)
      {:error, _reason} -> {:error, :unreadable_manifest}
    end
  end

  defp parse_manifest(json) do
    with {:ok, document} <- Jason.decode(json, objects: :ordered_objects),
         {:ok, %{"versions" => versions} = manifest} when is_list(versions) and map_size(manifest) == 1 <-
           json_object(document) do
      Enum.reduce_while(versions, {:ok, %{}}, fn version, {:ok, entries} ->
        case parse_version(version) do
          {:ok, key, entry} when not is_map_key(entries, key) -> {:cont, {:ok, Map.put(entries, key, entry)}}
          {:ok, _key, _entry} -> {:halt, {:error, :duplicate_version}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_manifest_key} = error -> error
      _ -> {:error, :invalid_manifest}
    end
  end

  defp parse_version(version) do
    with {:ok, entry} <- json_object(version) do
      case entry do
        %{
          "lane" => lane,
          "version_id" => id,
          "source_prompt_sha256" => hash,
          "source" => source,
          "prompt" => prompt,
          "procedures" => procedures
        }
        when map_size(entry) == 6 and lane in @managed_slugs and is_integer(id) and id > 0 ->
          with :ok <- validate_hash(hash),
               {:ok, kind} <- source_kind(source),
               :ok <- validate_prompt(prompt),
               {:ok, procedures} <- validate_procedures(lane, procedures) do
            {:ok, {lane, id}, %{hash: hash, kind: kind, prompt: prompt, procedures: procedures}}
          end

        _ ->
          {:error, :invalid_version}
      end
    end
  end

  defp json_object(%Jason.OrderedObject{values: pairs}) do
    map = Map.new(pairs)
    if map_size(map) == length(pairs), do: {:ok, map}, else: {:error, :duplicate_manifest_key}
  end

  defp json_object(_), do: {:error, :invalid_manifest}

  defp validate_hash(hash) do
    if sha256?(hash), do: :ok, else: {:error, :invalid_source_prompt_sha256}
  end

  defp sha256?(hash), do: is_binary(hash) and Regex.match?(@sha256, hash)

  defp source_kind(value) do
    with {:ok, source} <- json_object(value) do
      case source do
        %{"kind" => "image", "worker_digest" => "sha256:" <> hash} when map_size(source) == 2 ->
          if sha256?(hash), do: {:ok, :image}, else: {:error, :invalid_source}

        %{"kind" => "reviewed-inline", "reference" => reference} when map_size(source) == 2 ->
          if nonblank?(reference), do: {:ok, :reviewed_inline}, else: {:error, :invalid_source}

        _ ->
          {:error, :invalid_source}
      end
    end
  end

  defp validate_prompt(prompt) do
    if is_binary(prompt) and Regex.match?(@procedure_tool, prompt) and not String.contains?(prompt, @image_path) and
         match?({:ok, _}, Solid.parse(prompt)),
       do: :ok,
       else: {:error, :invalid_prompt}
  end

  defp validate_procedures(lane, value) do
    with {:ok, procedures} <- json_object(value),
         :ok <- Lanes.validate_procedures(lane, procedures),
         false <- Enum.any?(procedures, fn {_key, text} -> legacy_procedure?(text) end) do
      {:ok, procedures}
    else
      true -> {:error, :invalid_procedures}
      {:error, errors} when is_list(errors) -> {:error, :invalid_procedures}
      {:error, _reason} = error -> error
    end
  end

  defp legacy_procedure?(text),
    do: String.contains?(text, @image_path) or Regex.match?(@legacy_issue_interpolation, text)

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp legacy_versions(schema) do
    query =
      from(version in LaneVersion,
        join: lane in Lane,
        on: lane.id == version.lane_id,
        where: lane.slug in ^@managed_slugs,
        order_by: version.id,
        select: {lane.slug, version.id, version.prompt}
      )

    query =
      case schema do
        :legacy_schema -> query
        :bundled_schema -> from(version in query, where: version.procedures == ^%{})
      end

    Repo.all(query, log: false)
  end

  defp validate_coverage(versions, entries) do
    Enum.reduce_while(versions, {:ok, entries}, fn {lane, id, prompt}, {:ok, remaining} ->
      case Map.pop(remaining, {lane, id}) do
        {nil, _} ->
          {:halt, {:error, :missing_versions}}

        {entry, rest} ->
          case validate_source(prompt, entry) do
            :ok -> {:cont, {:ok, rest}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, remaining} when map_size(remaining) == 0 -> :ok
      {:ok, _remaining} -> {:error, :unexpected_version}
      {:error, _reason} = error -> error
    end
  end

  defp validate_source(prompt, entry) do
    source_hash = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    kind = if String.contains?(prompt, @image_path), do: :image, else: :reviewed_inline

    cond do
      source_hash != entry.hash -> {:error, :source_prompt_mismatch}
      kind != entry.kind -> {:error, :source_kind_mismatch}
      true -> :ok
    end
  end

  defp update_versions(versions, entries) do
    Enum.each(versions, fn {lane, id, _source_prompt} ->
      %{prompt: prompt, procedures: procedures} = Map.fetch!(entries, {lane, id})
      query = from(version in LaneVersion, where: version.id == ^id)

      case Repo.update_all(query, [set: [prompt: prompt, procedures: procedures]], log: false) do
        {1, _} -> :ok
        _ -> Repo.rollback(:database_error)
      end
    end)

    map_size(entries)
  end
end
