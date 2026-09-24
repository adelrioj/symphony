defmodule SymphonyElixir.CodexCredentials.GoogleClient do
  @moduledoc "Explicit Storage and numeric Secret Manager metadata transport using the controller's own Google identity."

  alias SymphonyElixir.GoogleCredentials

  @identity %{"credential_configuration" => "symphony-codex"}
  @fields ~w(credential_id secret control_bucket control_object)
  @type response :: {:ok, integer(), term(), term()} | {:error, :credential_outcome_unknown}

  @doc "Validates the four configured resource references, never an endpoint or an authentication override."
  @spec configuration(map()) :: {:ok, map()} | {:error, :credential_outcome_unknown}
  def configuration(config) when is_map(config) do
    refs = Map.get(config, :codex_credentials)

    if is_map(refs) and map_size(refs) == length(@fields) and Enum.all?(@fields, &nonblank?(refs[&1])) and
         valid_secret?(refs["secret"]) and refs["control_bucket"] not in [".", ".."] and
         refs["control_object"] not in [".", ".."] do
      {:ok, refs}
    else
      unknown()
    end
  end

  def configuration(_config), do: unknown()

  @spec request(map(), atom(), String.t(), [{String.t(), String.t()}], binary() | nil, keyword()) :: response()
  def request(config, method, url, headers, body, opts) do
    opts = GoogleCredentials.options(opts)

    with {:ok, refs} <- configuration(config),
         true <- GoogleCredentials.remaining(opts) > 0 and permitted?(refs, method, URI.parse(url)) do
      dispatch(Keyword.get(opts, :request), method, url, headers, body, opts)
    else
      _ -> unknown()
    end
  rescue
    _ -> unknown()
  end

  @doc "Reads enabled metadata for one exact numeric version; payload access is not implemented."
  @spec version_metadata(map(), String.t(), keyword()) :: {:ok, map()} | {:error, :credential_outcome_unknown}
  def version_metadata(config, version, opts \\ []) do
    with {:ok, refs} <- configuration(config),
         true <- numeric_version?(version, refs["secret"]),
         {:ok, 200, _headers, body} <-
           request(config, :get, "https://secretmanager.googleapis.com/v1/" <> version, [], nil, opts),
         {:ok, %{"name" => ^version, "state" => "ENABLED"}} <- json(body) do
      {:ok, %{"name" => version, "state" => "ENABLED"}}
    else
      _ -> unknown()
    end
  end

  defp dispatch(request, method, url, headers, body, _opts) when is_function(request, 4) do
    normalize(request.(method, url, headers, body))
  end

  defp dispatch(nil, method, url, headers, body, opts) do
    case GoogleCredentials.token(@identity, opts) do
      {:ok, token} -> authenticated(method, url, headers, body, opts, token)
      _ -> unknown()
    end
  end

  defp authenticated(method, url, headers, body, opts, token) do
    case perform(method, url, headers, body, opts, token) do
      {:ok, 401, _headers, _body} = denied ->
        case GoogleCredentials.refresh(@identity, opts) do
          {:ok, renewed} -> authenticated(method, url, headers, body, opts, renewed)
          {:error, :google_refresh_exhausted} -> denied
          _ -> unknown()
        end

      result ->
        result
    end
  end

  defp perform(method, url, headers, body, opts, token) do
    remaining = GoogleCredentials.remaining(opts)

    if remaining > 0 do
      request_opts = [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer " <> token} | headers],
        retry: false,
        redirect: false,
        receive_timeout: remaining,
        connect_options: [timeout: min(remaining, 30_000)]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :body, body)
      request = Keyword.get(opts, :request_fun, &Req.request/1)

      case request.(request_opts) do
        {:ok, %{status: status, body: response} = result} ->
          normalize({:ok, status, Map.get(result, :headers, []), response})

        _ ->
          unknown()
      end
    else
      unknown()
    end
  end

  defp normalize({:ok, status, headers, body}) when status in 200..299, do: {:ok, status, headers, body}
  defp normalize({:ok, status, _headers, _body}) when is_integer(status), do: {:ok, status, [], %{}}
  defp normalize(_response), do: unknown()

  defp permitted?(refs, method, %URI{scheme: "https", port: 443, userinfo: nil, fragment: nil} = uri) do
    query = URI.decode_query(uri.query || "")
    permitted_operation?(refs, method, uri, query)
  end

  defp permitted?(_refs, _method, _uri), do: false

  defp permitted_operation?(refs, :get, %URI{host: "storage.googleapis.com", path: path}, query) do
    bucket = URI.encode(refs["control_bucket"], &URI.char_unreserved?/1)
    object = URI.encode(refs["control_object"], &URI.char_unreserved?/1)

    path == "/storage/v1/b/" <> bucket <> "/o/" <> object and
      (query == %{} or (map_size(query) == 2 and query["alt"] == "media" and decimal?(query["generation"])))
  end

  defp permitted_operation?(refs, :post, %URI{host: "storage.googleapis.com", path: path}, query) do
    bucket = URI.encode(refs["control_bucket"], &URI.char_unreserved?/1)

    path == "/upload/storage/v1/b/" <> bucket <> "/o" and map_size(query) == 3 and
      query["uploadType"] == "media" and query["name"] == refs["control_object"] and
      decimal?(query["ifGenerationMatch"])
  end

  defp permitted_operation?(refs, :get, %URI{host: "secretmanager.googleapis.com", path: path}, query) do
    query == %{} and is_binary(path) and String.starts_with?(path, "/v1/") and
      numeric_version?(String.replace_prefix(path, "/v1/", ""), refs["secret"])
  end

  defp permitted_operation?(_refs, _method, _uri, _query), do: false

  defp numeric_version?(version, secret) when is_binary(version) do
    prefix = secret <> "/versions/"
    String.starts_with?(version, prefix) and decimal?(String.replace_prefix(version, prefix, ""))
  end

  defp numeric_version?(_version, _secret), do: false

  defp valid_secret?(secret) do
    case String.split(secret, "/") do
      ["projects", project, "secrets", name] ->
        Enum.all?([project, name], &(&1 not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, &1)))

      _ ->
        false
    end
  end

  defp decimal?(value), do: is_binary(value) and Regex.match?(~r/\A[1-9][0-9]*\z/, value)
  defp nonblank?(value), do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
  defp json(body) when is_map(body), do: {:ok, body}
  defp json(body) when is_binary(body), do: Jason.decode(body)
  defp json(_body), do: unknown()
  defp unknown, do: {:error, :credential_outcome_unknown}
end
