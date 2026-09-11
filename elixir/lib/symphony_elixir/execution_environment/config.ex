defmodule SymphonyElixir.ExecutionEnvironment.Config do
  @moduledoc """
  Private managed-environment configuration, runtime capture, and reload identity.

  This schema is deliberately not embedded in the public worker configuration yet.
  Provider-specific validation belongs to adapters, not this parser. Identity hashes
  operator references, never resolved credentials or mutable scheduling settings.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @fields [:kind, :deployment_id, :provider, :startup_timeout_ms, :shutdown_timeout_ms, :terminal_retention_ms]
  @workstations_scope ["project", "location", "cluster"]
  @kubernetes_scope ["kubeconfig", "context", "namespace"]
  @workstations_identity @workstations_scope ++ ["config", "credential_configuration", "impersonate_service_account", "ssh_user"]
  @kubernetes_identity @kubernetes_scope ++ ["template", "ssh_user", "ssh_auth_volume", "ssh_port"]

  embedded_schema do
    field(:kind, :string)
    field(:deployment_id, :string)
    field(:provider, :map, redact: true)
    field(:startup_timeout_ms, :integer)
    field(:shutdown_timeout_ms, :integer)
    field(:terminal_retention_ms, :integer, default: 0)
  end

  @type t :: %__MODULE__{
          kind: String.t(),
          deployment_id: String.t(),
          provider: map(),
          startup_timeout_ms: pos_integer(),
          shutdown_timeout_ms: pos_integer(),
          terminal_retention_ms: non_neg_integer()
        }

  @spec parse(term()) :: {:ok, t()} | {:error, {:invalid_environment_config, map()}}
  def parse(config) when is_map(config) do
    %__MODULE__{}
    |> cast(normalize_keys(config), @fields, empty_values: [])
    |> validate_required(@fields)
    |> validate_inclusion(:kind, ["google_workstations", "kubernetes"])
    |> validate_change(:deployment_id, fn :deployment_id, deployment_id ->
      if String.trim(deployment_id) == "", do: [deployment_id: "must not be blank"], else: []
    end)
    |> validate_number(:startup_timeout_ms, greater_than: 0)
    |> validate_number(:shutdown_timeout_ms, greater_than: 0)
    |> validate_number(:terminal_retention_ms, greater_than_or_equal_to: 0)
    |> validate_change(:provider, fn :provider, provider ->
      if string_keys?(provider), do: [], else: [provider: "must contain string keys"]
    end)
    |> apply_action(:validate)
    |> case do
      {:ok, parsed} -> {:ok, parsed}
      {:error, changeset} -> {:error, {:invalid_environment_config, traverse_errors(changeset, fn {message, _opts} -> message end)}}
    end
  end

  def parse(_config), do: {:error, {:invalid_environment_config, %{environment: ["must be a managed configuration map"]}}}

  @spec runtime(map()) :: map() | nil
  def runtime(settings) do
    case value(value(settings, :worker), :environment) do
      nil -> nil
      managed -> capture(settings, managed)
    end
  end

  @spec identity(map()) :: binary() | nil
  def identity(settings) do
    case runtime(settings) do
      nil ->
        nil

      config ->
        keys = if config.kind == "google_workstations", do: @workstations_identity, else: @kubernetes_identity

        {config.kind, config.deployment_id, config.workspace_root, canonical(Map.take(config.provider, keys))}
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
    end
  end

  @doc "Returns the provider ownership scope from captured runtime configuration."
  @spec scope(map()) :: map()
  def scope(%{kind: "google_workstations", provider: provider}), do: Map.take(provider, @workstations_scope)
  def scope(%{kind: "kubernetes", provider: provider}), do: Map.take(provider, @kubernetes_scope)

  defp capture(settings, managed) do
    with {:ok, config} <- parse(managed),
         root when is_binary(root) <- value(value(settings, :workspace), :root),
         tracker when is_binary(tracker) <- value(value(settings, :tracker), :kind),
         true <- String.trim(root) != "" and String.trim(tracker) != "" do
      config
      |> Map.from_struct()
      |> Map.take(@fields)
      |> Map.merge(%{workspace_root: root, tracker_kind: tracker})
    else
      _ -> raise ArgumentError, "invalid managed execution environment configuration"
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil

  defp normalize_keys(%__MODULE__{} = config), do: config |> Map.from_struct() |> normalize_keys()

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {if(is_atom(key), do: Atom.to_string(key), else: key), normalize_keys(value)}
    end)
  end

  defp normalize_keys(list) when is_list(list), do: Enum.map(list, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp string_keys?(map) when is_map(map), do: Enum.all?(map, fn {key, value} -> is_binary(key) and string_keys?(value) end)
  defp string_keys?(list) when is_list(list), do: Enum.all?(list, &string_keys?/1)
  defp string_keys?(_value), do: true

  defp canonical(map) when is_map(map) do
    {:map, map |> Enum.map(fn {key, value} -> {key, canonical(value)} end) |> Enum.sort()}
  end

  defp canonical(list) when is_list(list), do: {:list, Enum.map(list, &canonical/1)}
  defp canonical(value), do: {:value, value}
end
