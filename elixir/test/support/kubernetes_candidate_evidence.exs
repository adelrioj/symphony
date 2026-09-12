defmodule SymphonyElixir.KubernetesCandidateEvidence do
  @moduledoc false
  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.{Config, Record}
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Guard

  @operation_fields ~w(id issuerId namespace name guardUID parentUID group resource state objectUID templateDigest payloadDigest)
  @resource_fields ~w(kind name uid namespace resourceVersion apiVersion)
  @physical_fields ~w(kind uid resourceVersion qualification_uid node_uid node_name)
  @volume_fields ~w(pvc_uid pvc_name pvc_version pv_uid pv_name pv_version volume_handle csi_finalizer_observed deleted unbound)

  @spec guard(map(), map()) :: map() | nil
  def guard(object, config) do
    with {:ok, data} when is_map(data) <- Jason.decode(get_in(object, ["data", "guard.json"]) || ""),
         saved when is_map(saved) <- data["record"],
         true <- saved["deployment_id"] == config.deployment_id and saved["kind"] == "kubernetes" and saved["tracker_kind"] == config.tracker_kind,
         true <- saved["scope"] == Config.scope(config),
         true <- Enum.all?(~w(key issue_id workspace_path), &is_binary(saved[&1])),
         record = %Record{
           key: saved["key"],
           deployment_id: config.deployment_id,
           tracker_kind: config.tracker_kind,
           issue_id: saved["issue_id"],
           kind: "kubernetes",
           scope: Config.scope(config),
           workspace_path: saved["workspace_path"],
           template_identity: saved["template_identity"]
         },
         true <- owned_record?(record, config),
         {:ok, guard} <- Guard.decode(object, record) do
      %{
        "resource" => scalar_fields(guard.object["metadata"], @resource_fields),
        "guard_payload_sha256" => :crypto.hash(:sha256, object["data"]["guard.json"]) |> Base.encode16(case: :lower),
        "observed_receipt" =>
          scalar_fields(guard.data, ~w(protocol phase parentUID closeRequestId))
          |> Map.merge(%{
            "identity" => scalar_fields(guard.data["identity"], ~w(deploymentID environmentKey)) |> Map.put("namespace", config.provider["namespace"]),
            "operations" => operations(guard.data["operations"]),
            "evidence" => receipt_evidence(guard.data["evidence"])
          })
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec record(Record.t(), map()) :: map() | nil
  def record(%Record{} = record, config) do
    if owned_record?(record, config) do
      scalar_fields(%{"environment_id" => record.key, "parent_uid" => record.provider_ref, "phase" => record.phase, "absent" => record.absent?}, ~w(environment_id parent_uid phase absent))
      |> Map.put("obligations", obligations(record.metadata))
      |> Map.put(
        "proof",
        case record.proof do
          {:quiescent, proof} -> %{"quiescent" => scalar_fields(proof, ~w(parent_uid guard_uid sandbox_uid protocol generation))}
          _ -> "unknown"
        end
      )
    end
  end

  def record(_, _), do: nil

  defp owned_record?(record, config) do
    record.deployment_id == config.deployment_id and record.scope == Config.scope(config) and record.kind == "kubernetes" and
      record.tracker_kind == config.tracker_kind and is_binary(record.issue_id) and
      record.key == ExecutionEnvironment.resource_key(config.deployment_id, config.tracker_kind, record.issue_id)
  end

  defp obligations(metadata) when is_map(metadata) do
    %{
      "guard" => scalar_fields(metadata["guard"], @resource_fields ++ ["phase"]),
      "volumes" => volumes(metadata["volumes"]),
      "authorized_pod_uids" => scalar_list(metadata["authorized_pod_uids"]),
      "pod_safety" => keyed_facts(metadata["pod_safety"], &scalar_fields(&1, @physical_fields)),
      "termination_evidence" => keyed_facts(metadata["termination_evidence"], &scalar_fields(&1, @physical_fields)),
      "controller_pod_operations" => keyed_facts(metadata["controller_pod_operations"], &scalar_fields(&1, @operation_fields)),
      "creation_journal" => journal(metadata["creation_journal"])
    }
  end

  defp obligations(_), do: %{}

  defp receipt_evidence(evidence) when is_map(evidence) do
    scalar_fields(evidence, ~w(childrenAbsent parentUID closeRequestId))
    |> Map.merge(%{
      "controllerJournal" => journal(evidence["controllerJournal"]),
      "physical" => keyed_facts(evidence["physical"], &scalar_fields(&1, @physical_fields)),
      "termination" => keyed_facts(evidence["termination"], &scalar_fields(&1, @physical_fields)),
      "volumes" => volumes(evidence["volumes"])
    })
  end

  defp receipt_evidence(_), do: %{}

  defp journal(value) when is_map(value),
    do:
      scalar_fields(value, ~w(protocol parentUID closeRequestId revision phase))
      |> Map.put("operations", operations(value["operations"]))
      |> Map.put("acknowledgement", scalar_fields(value["acknowledgement"], ~w(protocol parentUID closeRequestId revision operationCount)))

  defp journal(_), do: %{}
  defp operations(values) when is_list(values), do: Enum.map(values, &scalar_fields(&1, @operation_fields)) |> Enum.reject(&(&1 == %{}))
  defp operations(_), do: []

  defp volumes(values),
    do:
      keyed_facts(values, fn value ->
        facts = scalar_fields(value, @volume_fields) |> Map.put("claim_ref", scalar_fields(value["claim_ref"], @resource_fields))

        if is_binary(value["volume_handle"]) and not Map.has_key?(facts, "volume_handle"),
          do: Map.put(facts, "volume_handle_sha256", :crypto.hash(:sha256, value["volume_handle"]) |> Base.encode16(case: :lower)),
          else: facts
      end)

  defp keyed_facts(values, fun) when is_map(values) do
    Map.new(
      Enum.flat_map(values, fn {key, value} ->
        if is_binary(key) and safe_scalar?(key) and is_map(value), do: [{key, fun.(value)}], else: []
      end)
    )
  end

  defp keyed_facts(_, _), do: %{}
  defp scalar_list(values) when is_list(values), do: Enum.filter(values, &(is_binary(&1) and safe_scalar?(&1)))
  defp scalar_list(_), do: []

  defp scalar_fields(values, fields) when is_map(values) do
    values
    |> Enum.flat_map(fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      value = if is_atom(value) and value not in [true, false, nil], do: Atom.to_string(value), else: value
      if key in fields and safe_field?(key, value), do: [{key, value}], else: []
    end)
    |> Map.new()
  end

  defp scalar_fields(_, _), do: %{}
  defp safe_field?("group", ""), do: true
  defp safe_field?("protocol", value), do: value == "symphony-create-drain-v1"
  defp safe_field?("state", value), do: value in ~w(Issued Committed)
  defp safe_field?("phase", value), do: value in ~w(Open Closing Closed Drained ReadyToFinalize Complete unknown pending preparing starting running stopping stopped deleting)
  defp safe_field?("resource", value), do: value in ~w(sandboxes pods persistentvolumeclaims persistentvolumes services secrets configmaps)
  defp safe_field?("kind", value), do: value in ~w(kubelet_terminated never_released never_executable terminated ConfigMap Pod PersistentVolumeClaim PersistentVolume Sandbox Secret Service)
  defp safe_field?(_, value), do: safe_scalar?(value)
  defp safe_scalar?(value) when is_binary(value), do: byte_size(value) in 1..2048 and Regex.match?(~r/\A[A-Za-z0-9_-][A-Za-z0-9._:\/@+-]*\z/, value)
  defp safe_scalar?(value), do: is_boolean(value) or (is_integer(value) and value >= 0)
end
