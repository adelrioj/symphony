defmodule SymphonyElixir.ExecutionEnvironment.Workstations.Client do
  @moduledoc "Bounded Workstations REST and read-only Compute inventory boundary. Credentials live only in the provider job."

  alias SymphonyElixir.GoogleCredentials

  @spec options(map(), keyword()) :: keyword()
  def options(config, opts) do
    Keyword.put_new_lazy(opts, :deadline, fn ->
      System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, Map.get(config, :startup_timeout_ms, 30_000))
    end)
  end

  @spec remaining(keyword()) :: non_neg_integer()
  def remaining(opts), do: max(Keyword.fetch!(opts, :deadline) - System.monotonic_time(:millisecond), 0)

  @type response :: {:ok, %{status: integer(), body: term()}} | {:error, term()}
  @spec request(map(), atom(), String.t(), keyword(), term(), keyword()) :: response()
  def request(config, method, path, query, body, opts) do
    opts = options(config, opts)

    with true <- remaining(opts) > 0,
         :ok <- require_impersonation(config.provider),
         {:ok, token} <- GoogleCredentials.token(config.provider, opts) do
      perform(config, method, path, query, body, opts, token)
    else
      false -> {:error, {:unknown, :workstations_deadline}}
      {:error, {:unknown, :google_deadline}} -> {:error, {:unknown, :workstations_deadline}}
      _ -> {:error, {:denied, :workstations_credentials}}
    end
  end

  defp perform(config, method, path, query, body, opts, token) do
    if remaining(opts) <= 0 do
      {:error, {:unknown, :workstations_deadline}}
    else
      perform_request(config, method, path, query, body, opts, token)
    end
  end

  defp perform_request(config, method, path, query, body, opts, token) do
    request_opts = [
      method: method,
      url: endpoint(path),
      params: query,
      headers: [{"authorization", "Bearer " <> token}],
      retry: false,
      receive_timeout: remaining(opts),
      connect_options: [timeout: min(remaining(opts), 30_000)]
    ]

    request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    case request_fun.(request_opts) do
      {:ok, %{status: 401}} ->
        refresh(config, method, path, query, body, opts)

      {:ok, %{status: status, body: response}} when is_integer(status) ->
        {:ok, %{status: status, body: response}}

      _ ->
        {:error, {:unknown, :workstations_transport}}
    end
  rescue
    _ -> {:error, {:unknown, :workstations_transport}}
  end

  defp refresh(config, method, path, query, body, opts) do
    case GoogleCredentials.refresh(config.provider, opts) do
      {:ok, refreshed} -> perform(config, method, path, query, body, opts, refreshed)
      {:error, :google_refresh_exhausted} -> {:ok, %{status: 401, body: %{}}}
      {:error, {:unknown, :google_deadline}} -> {:error, {:unknown, :workstations_deadline}}
      _ -> {:error, {:denied, :workstations_credentials}}
    end
  end

  defp require_impersonation(%{"impersonate_service_account" => account}) when is_binary(account) do
    if String.valid?(account) and String.trim(account) != "", do: :ok, else: :error
  end

  defp require_impersonation(_provider), do: :error

  defp endpoint("/compute/v1/" <> _ = path), do: "https://compute.googleapis.com" <> path
  defp endpoint("/v1/" <> _ = path), do: "https://workstations.googleapis.com" <> path
end
