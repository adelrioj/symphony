defmodule SymphonyElixir.ExecutionEnvironment.Workstations.Client do
  @moduledoc "Bounded Workstations REST and read-only Compute inventory boundary. Credentials live only in the provider job."

  alias SymphonyElixir.ExecutionEnvironment.Command

  @spec options(map(), keyword()) :: keyword()
  def options(config, opts) do
    Keyword.put_new_lazy(opts, :deadline, fn -> System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, Map.get(config, :startup_timeout_ms, 30_000)) end)
  end

  @spec remaining(keyword()) :: non_neg_integer()
  def remaining(opts), do: max(Keyword.fetch!(opts, :deadline) - System.monotonic_time(:millisecond), 0)

  @spec request(map(), atom(), String.t(), keyword(), term(), keyword()) :: {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(config, method, path, query, body, opts) do
    opts = options(config, opts)

    with true <- remaining(opts) > 0,
         {:ok, token} <- token(config, opts) do
      perform(config, method, path, query, body, opts, token)
    else
      false -> {:error, {:unknown, :workstations_deadline}}
      error -> error
    end
  end

  @spec token(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def token(config, opts) do
    key = cache_key(config)

    case Process.get(key) do
      nil ->
        result = Keyword.get(opts, :token_fun, &fetch_token/2).(config, opts)

        case result do
          {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
            Process.put(key, value)
            {:ok, value}

          _ -> {:error, {:denied, :workstations_credentials}}
        end

      value -> {:ok, value}
    end
  end

  @spec auth_args(map()) :: [String.t()]
  def auth_args(config) do
    provider = config.provider
    ["--configuration=" <> provider["credential_configuration"], "--impersonate-service-account=" <> provider["impersonate_service_account"], "--quiet"]
  end

  defp perform(config, method, path, query, body, opts, token) do
    if remaining(opts) <= 0 do
      {:error, {:unknown, :workstations_deadline}}
    else
      perform_request(config, method, path, query, body, opts, token)
    end
  end

  defp perform_request(config, method, path, query, body, opts, token) do
    request_opts = [method: method, url: endpoint(path), params: query,
      headers: [{"authorization", "Bearer " <> token}], retry: false,
      receive_timeout: remaining(opts), connect_options: [timeout: min(remaining(opts), 30_000)]]
    request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    case request_fun.(request_opts) do
      {:ok, %{status: 401}} ->
        refresh_key = {__MODULE__, :refreshed, cache_key(config)}

        if Process.get(refresh_key, false) do
          {:ok, %{status: 401, body: %{}}}
        else
          Process.put(refresh_key, true)
          Process.delete(cache_key(config))
          with {:ok, refreshed} <- token(config, opts), do: perform(config, method, path, query, body, opts, refreshed)
        end

      {:ok, %{status: status, body: response}} when is_integer(status) -> {:ok, %{status: status, body: response}}
      _ -> {:error, {:unknown, :workstations_transport}}
    end
  rescue
    _ -> {:error, {:unknown, :workstations_transport}}
  end

  defp endpoint("/compute/v1/" <> _ = path), do: "https://compute.googleapis.com" <> path
  defp endpoint("/v1/" <> _ = path), do: "https://workstations.googleapis.com" <> path

  defp cache_key(config), do: {__MODULE__, :token, Map.take(config.provider, ["project", "credential_configuration", "impersonate_service_account"])}

  defp fetch_token(config, opts) do
    with executable when is_binary(executable) <- Keyword.get_lazy(opts, :gcloud_executable, fn -> System.find_executable("gcloud") end),
         {:ok, %{output: output, status: 0}} <- Command.run(executable, ["auth", "print-access-token", "--verbosity=error"] ++ auth_args(config), timeout_ms: remaining(opts), max_output_bytes: 16_384, env: [{"CLOUDSDK_CORE_DISABLE_PROMPTS", "1"}]),
         token <- String.trim(output),
         true <- token != "" and not String.contains?(token, ["\n", "\r", " "]) do
      {:ok, token}
    else
      _ -> {:error, {:denied, :workstations_credentials}}
    end
  end
end
