defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes.Declaration do
  @moduledoc false

  defstruct [:name, :spec]

  @type t :: %__MODULE__{name: String.t(), spec: map()}

  @version 1
  @max_keys 64
  @max_obligations 512
  @host_fields ~w(node_name node_uid machine_id system_uuid)
  # The prefix the admission policy binds its protections to. A receipt named anything else is
  # unprotected: nothing would stop the operator asserting the loss from also writing it.
  @receipt_name ~r/^symphony-destruction-receipt-[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/
  @required ~w(schemaVersion deploymentId host environmentKeys obligationUIDs guards receiptName operatorSubject chunkIndex chunkTotal)

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(spec) when is_map(spec) do
    with true <- Enum.all?(@required, &Map.has_key?(spec, &1)),
         true <- spec["schemaVersion"] == @version,
         true <- nonempty?(spec["deploymentId"]) and nonempty?(spec["operatorSubject"]),
         true <- is_binary(spec["receiptName"]) and Regex.match?(@receipt_name, spec["receiptName"]),
         true <- host?(spec["host"]),
         true <- keys?(spec["environmentKeys"]),
         true <- obligations?(spec["obligationUIDs"]),
         true <- guards?(spec["guards"], spec["environmentKeys"]),
         true <- chunk?(spec["chunkIndex"], spec["chunkTotal"]) do
      {:ok, %__MODULE__{name: name(spec), spec: spec}}
    else
      _ -> {:error, {:invalid, :kubernetes_declaration_invalid}}
    end
  end

  def decode(_), do: {:error, {:invalid, :kubernetes_declaration_invalid}}

  # The receipt is what the amendment to SPEC.md:2946-2950 admits in place of an exact-UID PV
  # DELETED event, which a lost host's dead CSI driver can never emit. It carries weight only
  # because it is positive evidence issued by the provider: immutable once written, and keyed to
  # the machine identity the declaration names. The operator asserting the loss does not write it,
  # and RBAC keeps those two subjects apart.
  @spec receipt(term(), t()) :: {:ok, map()} | {:error, term()}
  def receipt(object, %__MODULE__{spec: spec}) when is_map(object) do
    host = spec["host"]

    with true <- object["immutable"] == true,
         {:ok, body} when is_map(body) <- Jason.decode(get_in(object, ["data", "receipt.json"]) || ""),
         true <- nonempty?(body["provider"]) and nonempty?(body["destroyedAt"]),
         true <- body["machine_id"] == host["machine_id"] and body["system_uuid"] == host["system_uuid"],
         true <- is_list(body["destroyedVolumeHandles"]) and Enum.all?(body["destroyedVolumeHandles"], &nonempty?/1) do
      {:ok, body}
    else
      _ -> {:error, {:invalid, :kubernetes_destruction_receipt_invalid}}
    end
  end

  def receipt(_, _), do: {:error, {:invalid, :kubernetes_destruction_receipt_invalid}}

  # Narrow by construction: a handle the receipt does not name is not discharged by it.
  @spec destroyed?(map(), term()) :: boolean()
  def destroyed?(receipt, handle), do: nonempty?(handle) and handle in receipt["destroyedVolumeHandles"]

  defp host?(host), do: is_map(host) and Enum.all?(@host_fields, &nonempty?(host[&1]))

  # An empty declaration would discharge nothing while still claiming a machine.
  defp keys?(keys), do: is_list(keys) and keys != [] and length(keys) <= @max_keys and Enum.all?(keys, &nonempty?/1) and unique?(keys)

  # A duplicate would let one obligation stand in for another under the exact-cover check.
  defp obligations?(uids), do: is_list(uids) and uids != [] and length(uids) <= @max_obligations and Enum.all?(uids, &nonempty?/1) and unique?(uids)

  # Exact cover both ways: every declared environment carries its guard reference, and no
  # reference names an environment the declaration does not claim.
  defp guards?(guards, keys) do
    is_map(guards) and Enum.sort(Map.keys(guards)) == Enum.sort(keys) and
      Enum.all?(guards, fn {_, reference} -> is_map(reference) and nonempty?(reference["uid"]) and nonempty?(reference["resourceVersion"]) end)
  end

  defp chunk?(index, total), do: is_integer(index) and is_integer(total) and total >= 1 and index >= 0 and index < total

  defp unique?(list), do: length(Enum.uniq(list)) == length(list)
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  # Deterministic so a replay is the same object. The chunk index is part of the identity
  # because one environment's obligations can exceed a single declaration's bound.
  defp name(spec) do
    identity = [spec["deploymentId"], spec["host"]["node_uid"], Enum.sort(spec["environmentKeys"]), spec["chunkIndex"]]
    "symphony-loss-" <> (:crypto.hash(:sha256, Jason.encode!(identity)) |> Base.encode16(case: :lower) |> binary_part(0, 40))
  end
end
