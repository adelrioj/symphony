defmodule SymphonyElixir.GoogleCredentials do
  @moduledoc "Bounded Google OAuth acquisition, cached by explicit identity for the lifetime of the caller job."

  alias SymphonyElixir.ExecutionEnvironment.Command

  @type identity :: %{required(String.t()) => String.t()}
  @type result :: {:ok, String.t()} | {:error, {:denied | :unknown, atom()} | :google_refresh_exhausted}

  @spec options(keyword()) :: keyword()
  def options(opts) do
    Keyword.put_new_lazy(opts, :deadline, fn -> System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 30_000) end)
  end

  @spec remaining(keyword()) :: non_neg_integer()
  def remaining(opts), do: max(Keyword.fetch!(opts, :deadline) - System.monotonic_time(:millisecond), 0)

  @spec token(identity(), keyword()) :: result()
  def token(identity, opts) do
    opts = options(opts)

    cond do
      remaining(opts) <= 0 -> {:error, {:unknown, :google_deadline}}
      not valid_identity?(identity) -> {:error, {:denied, :google_credentials}}
      true -> cached_token(identity, opts)
    end
  rescue
    _ -> {:error, {:denied, :google_credentials}}
  end

  @doc "Allows one renewal per job and identity, only after the caller observes a definite 401 rejection."
  @spec refresh(identity(), keyword()) :: result()
  def refresh(identity, opts) do
    opts = options(opts)
    refresh_key = {__MODULE__, :refreshed, cache_key(identity)}

    cond do
      remaining(opts) <= 0 -> {:error, {:unknown, :google_deadline}}
      not valid_identity?(identity) -> {:error, {:denied, :google_credentials}}
      Process.get(refresh_key, false) -> {:error, :google_refresh_exhausted}
      true ->
        Process.put(refresh_key, true)
        Process.delete(cache_key(identity))
        token(identity, opts)
    end
  end

  @spec auth_args(identity()) :: [String.t()]
  def auth_args(identity) do
    configuration = ["--configuration=" <> identity["credential_configuration"]]
    impersonation = if identity["impersonate_service_account"], do: ["--impersonate-service-account=" <> identity["impersonate_service_account"]], else: []
    configuration ++ impersonation ++ ["--quiet"]
  end

  defp cached_token(identity, opts) do
    key = cache_key(identity)

    case Process.get(key) do
      nil ->
        case Keyword.get(opts, :token_fun, &fetch_token/2).(identity, opts) do
          {:ok, value} ->
            if valid_token?(value) do
              Process.put(key, value)
              {:ok, value}
            else
              {:error, {:denied, :google_credentials}}
            end

          _ -> {:error, {:denied, :google_credentials}}
        end

      value -> {:ok, value}
    end
  end

  defp fetch_token(identity, opts) do
    command_opts =
      opts
      |> Keyword.merge(timeout_ms: remaining(opts), max_output_bytes: 16_384)
      |> Keyword.update(:env, [{"CLOUDSDK_CORE_DISABLE_PROMPTS", "1"}], &List.keystore(&1, "CLOUDSDK_CORE_DISABLE_PROMPTS", 0, {"CLOUDSDK_CORE_DISABLE_PROMPTS", "1"}))

    executable = Keyword.get_lazy(opts, :gcloud_executable, fn -> System.find_executable("gcloud") end)
    args = ["auth", "print-access-token", "--verbosity=error"] ++ auth_args(identity)

    with executable when is_binary(executable) <- executable,
         {:ok, %{output: output, status: 0}} <- Command.run(executable, args, command_opts),
         token <- String.trim(output),
         true <- valid_token?(token) do
      {:ok, token}
    else
      _ -> {:error, {:denied, :google_credentials}}
    end
  end

  defp cache_key(identity), do: {__MODULE__, :token, Map.take(identity, ["project", "credential_configuration", "impersonate_service_account"])}

  defp valid_identity?(identity) when is_map(identity) do
    nonblank?(identity["credential_configuration"]) and
      Enum.all?(["project", "impersonate_service_account"], fn key -> not Map.has_key?(identity, key) or nonblank?(identity[key]) end)
  end

  defp valid_identity?(_identity), do: false
  defp nonblank?(value), do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
  defp valid_token?(value), do: is_binary(value) and byte_size(value) in 1..16_384 and String.valid?(value) and not Regex.match?(~r/\s/u, value)
end
