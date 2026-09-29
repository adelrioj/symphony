defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes.HostRecovery do
  @moduledoc false

  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.{Client, Guard}

  @receipt_namespace "symphony"
  @receipt_prefix "symphony-host-recovery-"
  @receipt_schema "devbox-host-shutdown/v1"
  @max_age_seconds 600

  # Only an operator-controlled, immutable receipt in the management namespace can authorize
  # this path. A host-root inspection attests that neither the Pod nor a user of its bound block
  # device remains. Kubernetes admission-gate history alone cannot prove this: pods/binding may
  # bind a gated Pod without recording a provider start authorization.
  @spec proof(map(), map(), map(), map(), keyword()) :: {:ok, map() | nil}
  def proof(config, record, sandbox, operation, opts) do
    pod_uid = operation["objectUID"]
    name = @receipt_prefix <> pod_uid

    with {:ok, receipt} <- fetch_receipt(config, name, opts),
         {:ok, assertion} <- decode_receipt(receipt, record, sandbox, operation),
         {:ok, guard} <- Guard.fetch(config, record, opts),
         {:ok, node} <- Client.lookup(config, "/api/v1/nodes", assertion["hostname"], opts),
         {:ok, pv} <- Client.lookup(config, "/api/v1/persistentvolumes", assertion["pvName"], opts),
         true <- host_matches?(guard, node, sandbox, assertion),
         true <- volume_matches?(record, pv, assertion),
         true <- fresh?(assertion, receipt, sandbox) do
      {:ok,
       %{
         "kind" => "host_shutdown",
         "uid" => pod_uid,
         "operation_id" => operation["id"],
         "parent_uid" => record.provider_ref,
         "qualification_uid" => record.metadata["qualification_uid"],
         "node_uid" => assertion["nodeUID"],
         "boot_id" => assertion["boot_id"],
         "pv_uid" => assertion["pvUID"],
         "volume_handle" => assertion["volume_handle"],
         "receipt_uid" => get_in(receipt, ["metadata", "uid"]),
         "captured_at" => assertion["captured_at"]
       }}
    else
      _ -> {:ok, nil}
    end
  end

  # Client.lookup lists the whole collection; the provider has only get on
  # management-namespace ConfigMaps. Read this exact operator-issued name.
  defp fetch_receipt(config, name, opts) do
    path = "/api/v1/namespaces/#{@receipt_namespace}/configmaps/#{name}"

    case Client.request(config, :get, path, nil, opts) do
      {:ok, %{status: 200, body: %{} = receipt}} -> {:ok, receipt}
      _ -> {:ok, nil}
    end
  end

  defp decode_receipt(
         %{"immutable" => true, "metadata" => metadata, "data" => %{"recovery.json" => json}},
         record,
         sandbox,
         operation
       )
       when is_binary(json) do
    with {:ok, assertion} when is_map(assertion) <- Jason.decode(json),
         true <- metadata["namespace"] == @receipt_namespace and nonempty?(metadata["uid"]),
         true <- assertion["schema"] == @receipt_schema,
         true <-
           assertion["parentUID"] == record.provider_ref and record.provider_ref == get_in(sandbox, ["metadata", "uid"]),
         true <- assertion["pod_uid"] == operation["objectUID"] and assertion["operationID"] == operation["id"],
         true <- Enum.all?(~w(pod_processes volume_mounts volume_users), &(assertion[&1] == [])),
         true <- assertion["fence"] == %{"lvm_permissions" => "read-only", "block_device_read_only" => true},
         true <- valid_command?(assertion),
         true <-
           nonempty?(record.metadata["qualification_uid"]) and nonempty?(assertion["pvUID"]) and
             nonempty?(assertion["nodeUID"]) do
      {:ok, assertion}
    else
      _ -> :invalid
    end
  end

  defp decode_receipt(_, _, _, _), do: :invalid

  defp valid_command?(assertion) do
    assertion["command"] == [
      "devbox-host-shutdown-receipt",
      "--host",
      assertion["hostname"],
      "--pod-uid",
      assertion["pod_uid"],
      "--volume-handle",
      assertion["volume_handle"],
      "--fence-read-only"
    ]
  end

  defp host_matches?(guard, node, sandbox, assertion) when is_map(node) do
    binding = guard.data["hostBinding"] || %{}
    host = assertion["hostname"]

    guard.data["parentUID"] == get_in(sandbox, ["metadata", "uid"]) and
      binding["node_name"] == host and binding["node_uid"] == assertion["nodeUID"] and
      binding["boot_id"] == assertion["boot_id"] and
      get_in(node, ["metadata", "name"]) == host and get_in(node, ["metadata", "uid"]) == assertion["nodeUID"] and
      get_in(node, ["status", "nodeInfo", "bootID"]) == assertion["boot_id"] and
      get_in(sandbox, ["spec", "podTemplate", "spec", "nodeSelector", "kubernetes.io/hostname"]) == host
  end

  defp host_matches?(_, _, _, _), do: false

  defp volume_matches?(record, pv, assertion) when is_map(pv) do
    volume =
      Enum.find(record.metadata["volumes"] || %{}, fn {_, value} ->
        value["pv_name"] == assertion["pvName"] and value["volume_handle"] == assertion["volume_handle"]
      end)

    volume = if volume, do: elem(volume, 1), else: %{}

    volume["pv_uid"] == assertion["pvUID"] and nonempty?(volume["pvc_uid"]) and
      get_in(pv, ["metadata", "uid"]) == assertion["pvUID"] and
      get_in(pv, ["spec", "claimRef", "uid"]) == volume["pvc_uid"] and
      get_in(pv, ["spec", "csi", "volumeHandle"]) == assertion["volume_handle"] and
      pv_pinned_to_host?(pv, assertion["hostname"])
  end

  defp volume_matches?(_, _, _), do: false

  defp pv_pinned_to_host?(pv, host) do
    Enum.any?(get_in(pv, ["spec", "nodeAffinity", "required", "nodeSelectorTerms"]) || [], fn term ->
      Enum.any?(term["matchExpressions"] || [], fn expression ->
        expression["key"] == "topology.topolvm.io/node" and expression["operator"] == "In" and
          expression["values"] == [host]
      end)
    end)
  end

  defp fresh?(assertion, receipt, sandbox) do
    with {:ok, captured, _} <- DateTime.from_iso8601(assertion["captured_at"] || ""),
         {:ok, created, _} <- DateTime.from_iso8601(get_in(sandbox, ["metadata", "creationTimestamp"]) || ""),
         {:ok, issued, _} <- DateTime.from_iso8601(get_in(receipt, ["metadata", "creationTimestamp"]) || "") do
      age = DateTime.diff(DateTime.utc_now(), captured, :second)

      age in 0..@max_age_seconds and DateTime.compare(captured, created) == :gt and
        DateTime.compare(issued, captured) in [:gt, :eq]
    else
      _ -> false
    end
  end

  defp nonempty?(value), do: is_binary(value) and value != ""
end
