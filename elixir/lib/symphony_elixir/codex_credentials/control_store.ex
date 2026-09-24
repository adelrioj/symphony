defmodule SymphonyElixir.CodexCredentials.ControlStore do
  @moduledoc "Generation-pinned authority reads and conditional replacements, with readback instead of ambiguous-write retries."

  alias SymphonyElixir.CodexCredentials.{GoogleClient, Record}
  alias SymphonyElixir.GoogleCredentials

  @type snapshot :: %{generation: String.t(), record: Record.t()}
  @type result :: {:ok, snapshot()} | {:error, Record.error()}

  @spec read(map(), keyword()) :: result()
  def read(config, opts \\ []) do
    opts = GoogleCredentials.options(opts)

    with {:ok, refs} <- GoogleClient.configuration(config) do
      read_current(config, refs, opts, true)
    end
  end

  @spec replace(map(), snapshot(), Record.t(), keyword()) :: result()
  def replace(config, snapshot, next_record, opts \\ []) do
    opts = GoogleCredentials.options(opts)

    with {:ok, refs} <- GoogleClient.configuration(config),
         %{generation: generation, record: record} <- snapshot,
         true <- decimal?(generation),
         :ok <- validate_record(record, refs),
         :ok <- validate_record(next_record, refs),
         true <-
           record["epoch"] == next_record["epoch"] and is_binary(next_record["transition_id"]) and
             next_record["transition_id"] != record["transition_id"],
         {:ok, body} <- Jason.encode(next_record) do
      url = upload_url(refs, generation)

      result = GoogleClient.request(config, :post, url, [{"content-type", "application/json"}], body, opts)
      resolve_replacement(result, config, snapshot, next_record, opts)
    else
      _ -> unknown()
    end
  end

  defp resolve_replacement({:ok, status, _headers, response}, config, snapshot, next_record, opts)
       when status in 200..299 do
    case generation(response) do
      {:ok, next_generation} when next_generation != snapshot.generation ->
        {:ok, %{generation: next_generation, record: next_record}}

      _ ->
        reconcile(config, snapshot, next_record, opts)
    end
  end

  defp resolve_replacement({:ok, 412, _headers, _body}, _config, _snapshot, _next_record, _opts),
    do: {:error, :credential_busy}

  defp resolve_replacement({:ok, status, _headers, _body}, _config, _snapshot, _next_record, _opts)
       when status in 400..499 and status != 408, do: unknown()

  defp resolve_replacement(_result, config, snapshot, next_record, opts),
    do: reconcile(config, snapshot, next_record, opts)

  defp read_current(config, refs, opts, retry_raced_read?) do
    url = object_url(refs)

    with {:ok, 200, _headers, metadata} <- GoogleClient.request(config, :get, url, [], nil, opts),
         {:ok, generation} <- generation(metadata) do
      pinned = url <> "?" <> URI.encode_query([{"alt", "media"}, {"generation", generation}])

      case GoogleClient.request(config, :get, pinned, [], nil, opts) do
        {:ok, 200, _headers, body} ->
          decode_snapshot(body, refs, generation)

        {:ok, 404, _headers, _body} when retry_raced_read? ->
          read_current(config, refs, opts, false)

        _ ->
          unknown()
      end
    else
      _ -> unknown()
    end
  end

  defp decode_snapshot(body, refs, generation) do
    with {:ok, record} <- json(body),
         :ok <- validate_record(record, refs) do
      {:ok, %{generation: generation, record: record}}
    else
      _ -> unknown()
    end
  end

  defp reconcile(config, previous, expected, opts) do
    case read(config, opts) do
      {:ok, %{record: ^expected, generation: generation} = current} when generation != previous.generation ->
        {:ok, current}

      _ ->
        unknown()
    end
  end

  defp validate_record(record, refs) do
    with :ok <- Record.validate(record),
         true <-
           record["credential_id"] == refs["credential_id"] and
             String.starts_with?(record["head_version"], refs["secret"] <> "/versions/") do
      :ok
    else
      _ -> unknown()
    end
  end

  defp object_url(refs),
    do:
      "https://storage.googleapis.com/storage/v1/b/" <>
        encode(refs["control_bucket"]) <> "/o/" <> encode(refs["control_object"])

  defp upload_url(refs, generation) do
    query =
      URI.encode_query([{"uploadType", "media"}, {"name", refs["control_object"]}, {"ifGenerationMatch", generation}])

    "https://storage.googleapis.com/upload/storage/v1/b/" <> encode(refs["control_bucket"]) <> "/o?" <> query
  end

  defp generation(body) do
    with {:ok, %{"generation" => generation}} <- json(body),
         true <- decimal?(generation) do
      {:ok, generation}
    else
      _ -> unknown()
    end
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp decimal?(value), do: is_binary(value) and Regex.match?(~r/\A[1-9][0-9]*\z/, value)
  defp json(body) when is_map(body), do: {:ok, body}
  defp json(body) when is_binary(body), do: Jason.decode(body)
  defp json(_body), do: unknown()
  defp unknown, do: {:error, :credential_outcome_unknown}
end
