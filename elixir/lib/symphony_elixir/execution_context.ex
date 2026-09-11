defmodule SymphonyElixir.ExecutionContext do
  @moduledoc """
  Captured workspace and transport selection for one execution attempt.

  Managed contexts can only be constructed from a matching running environment and
  a live runtime connection. Invalid managed input raises a redacted error and never
  falls back to local execution. A connection is not proof of remote quiescence.
  """

  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.{Config, Connection, Record}
  alias SymphonyElixir.SSH.Target

  @enforce_keys [:mode, :workspace_root]
  @derive {Inspect, only: [:mode, :worker_host]}
  defstruct [:mode, :workspace_root, :workspace_path, :target, :connection, :worker_host, :environment]

  @type t :: %__MODULE__{
          mode: :local | :ssh | :managed,
          workspace_root: String.t(),
          workspace_path: String.t() | nil,
          target: Target.t() | String.t() | nil,
          connection: Connection.t() | nil,
          worker_host: String.t() | nil,
          environment: %{config: map(), record: Record.t()} | nil
        }

  @spec local(String.t()) :: t()
  def local(root), do: %__MODULE__{mode: :local, workspace_root: root}

  @spec ssh(String.t(), Target.t() | String.t()) :: t()
  def ssh(root, %Target{label: label} = target) do
    %__MODULE__{mode: :ssh, workspace_root: root, target: target, worker_host: label}
  end

  def ssh(root, target) when is_binary(target) do
    %__MODULE__{mode: :ssh, workspace_root: root, target: target, worker_host: target}
  end

  @spec managed(map(), Record.t(), Connection.t()) :: t()
  def managed(config, record, connection) do
    unless matching_record?(config, record) and ready_connection?(connection) do
      raise ArgumentError, "invalid managed execution context"
    end

    %__MODULE__{
      mode: :managed,
      workspace_root: config.workspace_root,
      workspace_path: record.workspace_path,
      target: connection.target,
      connection: connection,
      worker_host: connection.target.label,
      environment: %{config: config, record: record}
    }
  end

  @spec remote?(t()) :: boolean()
  def remote?(%__MODULE__{mode: mode}), do: mode in [:ssh, :managed]

  defp matching_record?(
         %{kind: kind, deployment_id: deployment_id, tracker_kind: tracker_kind, workspace_root: root, provider: provider} = config,
         %Record{phase: :running, absent?: false} = record
       )
       when kind in ["google_workstations", "kubernetes"] and is_map(provider) do
    with {:ok, _parsed} <- Config.parse(config),
         true <- Enum.all?([deployment_id, tracker_kind, record.issue_id], &nonblank?/1),
         scope <- Config.scope(config),
         true <- map_size(scope) == 3 and Enum.all?(Map.values(scope), &nonblank?/1) do
      record.deployment_id == deployment_id and record.tracker_kind == tracker_kind and
        record.kind == kind and record.scope == scope and
        record.key == ExecutionEnvironment.resource_key(deployment_id, tracker_kind, record.issue_id) and
        template_identity?(record.template_identity) and workspace_path?(root, record.workspace_path)
    else
      _ -> false
    end
  end

  defp matching_record?(_config, _record), do: false

  defp ready_connection?(%Connection{owner: owner, id: id, target: %Target{} = target})
       when is_pid(owner) and is_reference(id) and node(owner) == node() do
    Process.alive?(owner) and nonblank?(target.executable) and nonblank?(target.label) and
      is_list(target.prefix) and Enum.all?(target.prefix, &transport_string?/1) and
      is_list(target.env) and Enum.all?(target.env, &environment_entry?/1)
  end

  defp ready_connection?(_connection), do: false

  defp workspace_path?(root, path) when is_binary(root) and is_binary(path) do
    nonblank?(root) and nonblank?(path) and Path.type(root) == :absolute and Path.type(path) == :absolute and
      path == Path.expand(path) and String.starts_with?(path, String.trim_trailing(Path.expand(root), "/") <> "/") and
      path != Path.expand(root)
  end

  defp workspace_path?(_root, _path), do: false

  defp template_identity?(value) when is_binary(value), do: nonblank?(value)
  defp template_identity?(value) when is_map(value), do: map_size(value) > 0
  defp template_identity?(_value), do: false

  defp environment_entry?({key, value}), do: nonblank?(key) and (is_nil(value) or transport_string?(value)) and not String.contains?(key, "=")
  defp environment_entry?(_entry), do: false

  defp nonblank?(value), do: transport_string?(value) and String.trim(value) != ""
  defp transport_string?(value), do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)
end
