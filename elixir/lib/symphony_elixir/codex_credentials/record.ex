defmodule SymphonyElixir.CodexCredentials.Record do
  @moduledoc """
  Pure, fail-closed transitions for the JSON Codex credential authority.

  This module validates identity and evidence shape, not provider observations or
  credential bytes. Callers must obtain correlated Workstations stop evidence and
  persist each transition with the authority object's generation precondition.
  Recovery and reseeding are explicit operator operations, not ordinary events.
  """

  @record_fields ~w(schema credential_id epoch state head_version claim_id owner candidate stop_proof last_handoff reason transition_id)
  @owner_fields ~w(deployment_id lane workstation_name workstation_uid attempt_id)
  @receipt_fields ~w(schema credential_id epoch claim_id owner secret_version sha256 admission)
  @proof_fields ~w(uid operation attempt_id)
  @handoff_fields ~w(claim_id secret_version owner stop_proof resource_acknowledged)

  @type t :: %{required(String.t()) => term()}
  @type event ::
          {:claim, String.t(), map()}
          | {:bind_uid, String.t(), String.t()}
          | {:checkpoint, map()}
          | {:stopped, String.t(), map()}
          | {:release, String.t()}
          | {:acknowledge_handoff, String.t()}
          | {:quarantine, String.t(), String.t()}
  @type error :: :credential_busy | :credential_outcome_unknown | {:credential_recovery_required, atom() | String.t()}

  @doc "Creates an operator seed; invalid seed arguments raise without producing authority."
  @spec initial(String.t(), pos_integer(), String.t()) :: t()
  def initial(credential_id, epoch, head_version) do
    record = %{
      "schema" => 1,
      "credential_id" => credential_id,
      "epoch" => epoch,
      "state" => "AVAILABLE",
      "head_version" => head_version,
      "claim_id" => nil,
      "owner" => nil,
      "candidate" => nil,
      "stop_proof" => nil,
      "last_handoff" => nil,
      "reason" => nil,
      "transition_id" => nil
    }

    case validate(record) do
      :ok -> record
      {:error, _} -> raise ArgumentError, "invalid Codex credential seed"
    end
  end

  @doc "Rejects malformed authority, including inconsistent nested evidence."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(record) do
    if valid_record?(record), do: :ok, else: {:error, :credential_outcome_unknown}
  end

  @doc "Applies one ordinary event without I/O, expiry, or implicit recovery."
  @spec transition(term(), event(), String.t()) :: {:ok, t()} | {:error, error()}
  def transition(record, event, transition_id) do
    with :ok <- validate(record) do
      if nonblank?(transition_id) do
        case apply_event(record, event) do
          {:ok, updated} -> {:ok, %{updated | "transition_id" => transition_id}}
          {:error, _} = error -> error
        end
      else
        recovery(:invalid_transition_id)
      end
    end
  end

  @doc "Returns the bound original assignment, including for admission-disabled recovery."
  @spec assignment(term()) :: {:ok, map()} | {:error, error()}
  def assignment(record) do
    with :ok <- validate(record) do
      cond do
        record["state"] == "AVAILABLE" -> recovery(:not_owned)
        is_nil(record["owner"]["workstation_uid"]) -> recovery(:uid_missing)
        true -> {:ok, assignment_data(record)}
      end
    end
  end

  defp apply_event(%{"state" => "RECOVERY_REQUIRED", "reason" => reason}, _event), do: recovery(reason)

  defp apply_event(%{"state" => "AVAILABLE"} = record, {:claim, claim_id, owner}) do
    cond do
      unacknowledged?(record["last_handoff"]) -> {:error, :credential_busy}
      not nonblank?(claim_id) -> recovery(:invalid_claim)
      not valid_owner?(owner, false) -> recovery(:invalid_owner)
      not is_nil(owner["workstation_uid"]) -> recovery(:uid_already_bound)
      record["last_handoff"] && record["last_handoff"]["claim_id"] == claim_id -> recovery(:claim_reused)
      true -> {:ok, %{record | "state" => "OWNED", "claim_id" => claim_id, "owner" => owner}}
    end
  end

  defp apply_event(%{"state" => state}, {:claim, _claim_id, _owner}) when state in ["OWNED", "CHECKPOINTED"],
    do: {:error, :credential_busy}

  defp apply_event(%{"state" => "OWNED"} = record, {:bind_uid, claim_id, uid}) do
    cond do
      claim_id != record["claim_id"] -> recovery(:claim_mismatch)
      not nonblank?(uid) -> recovery(:invalid_uid)
      record["owner"]["workstation_uid"] not in [nil, uid] -> recovery(:uid_mismatch)
      true -> {:ok, put_in(record, ["owner", "workstation_uid"], uid)}
    end
  end

  defp apply_event(%{"state" => "OWNED"} = record, {:checkpoint, receipt}) do
    if valid_receipt?(receipt, record) do
      {:ok, %{record | "state" => "CHECKPOINTED", "candidate" => receipt}}
    else
      recovery(:checkpoint_mismatch)
    end
  end

  defp apply_event(%{"state" => "CHECKPOINTED"} = record, {:stopped, claim_id, proof}) do
    cond do
      claim_id != record["claim_id"] -> recovery(:claim_mismatch)
      not valid_proof?(proof, record["owner"]) -> recovery(:stop_mismatch)
      record["stop_proof"] not in [nil, proof] -> recovery(:stop_mismatch)
      true -> {:ok, %{record | "stop_proof" => proof}}
    end
  end

  defp apply_event(%{"state" => state} = record, {:release, claim_id}) when state in ["OWNED", "CHECKPOINTED"] do
    cond do
      claim_id != record["claim_id"] -> recovery(:claim_mismatch)
      is_nil(record["candidate"]) -> recovery(:checkpoint_missing)
      is_nil(record["stop_proof"]) -> recovery(:stop_missing)
      true -> {:ok, release(record)}
    end
  end

  defp apply_event(%{"state" => "AVAILABLE", "last_handoff" => handoff} = record, {:acknowledge_handoff, claim_id})
       when is_map(handoff) do
    if claim_id == handoff["claim_id"] do
      {:ok, put_in(record, ["last_handoff", "resource_acknowledged"], true)}
    else
      recovery(:claim_mismatch)
    end
  end

  defp apply_event(%{"state" => state} = record, {:quarantine, claim_id, reason}) when state in ["OWNED", "CHECKPOINTED"] do
    cond do
      claim_id != record["claim_id"] -> recovery(:claim_mismatch)
      not valid_reason?(reason) -> recovery(:invalid_reason)
      true -> {:ok, %{record | "state" => "RECOVERY_REQUIRED", "reason" => reason}}
    end
  end

  defp apply_event(_record, _event), do: recovery(:invalid_transition)

  defp release(record) do
    version = record["candidate"]["secret_version"]

    handoff = %{
      "claim_id" => record["claim_id"],
      "secret_version" => version,
      "owner" => record["owner"],
      "stop_proof" => record["stop_proof"],
      "resource_acknowledged" => false
    }

    %{record | "state" => "AVAILABLE", "head_version" => version, "claim_id" => nil, "owner" => nil, "candidate" => nil, "stop_proof" => nil, "last_handoff" => handoff}
  end

  defp assignment_data(record) do
    %{
      "schema" => 1,
      "credential_id" => record["credential_id"],
      "epoch" => record["epoch"],
      "claim_id" => record["claim_id"],
      "secret_version" => record["head_version"],
      "owner" => record["owner"]
    }
  end

  defp valid_record?(record) do
    exact_fields?(record, @record_fields) and record["schema"] === 1 and
      nonblank?(record["credential_id"]) and is_integer(record["epoch"]) and record["epoch"] > 0 and
      not is_nil(secret_resource(record["head_version"])) and valid_transition_id?(record) and
      valid_handoff?(record["last_handoff"], record["head_version"]) and valid_state?(record)
  end

  defp valid_transition_id?(%{"state" => "AVAILABLE", "last_handoff" => nil, "transition_id" => nil}), do: true
  defp valid_transition_id?(record), do: nonblank?(record["transition_id"])

  defp valid_state?(%{"state" => "AVAILABLE"} = record) do
    Enum.all?(~w(claim_id owner candidate stop_proof reason), &is_nil(record[&1]))
  end

  defp valid_state?(%{"state" => "OWNED"} = record) do
    valid_ownership?(record, false) and Enum.all?(~w(candidate stop_proof reason), &is_nil(record[&1]))
  end

  defp valid_state?(%{"state" => "CHECKPOINTED"} = record) do
    valid_ownership?(record, true) and is_nil(record["reason"]) and
      valid_receipt?(record["candidate"], record) and optional_proof?(record)
  end

  defp valid_state?(%{"state" => "RECOVERY_REQUIRED"} = record) do
    valid_ownership?(record, false) and valid_reason?(record["reason"]) and
      (is_nil(record["candidate"]) or valid_receipt?(record["candidate"], record)) and optional_proof?(record)
  end

  defp valid_state?(_record), do: false

  defp valid_ownership?(record, bound?) do
    nonblank?(record["claim_id"]) and valid_owner?(record["owner"], bound?) and
      not unacknowledged?(record["last_handoff"]) and
      (is_nil(record["last_handoff"]) or record["claim_id"] != record["last_handoff"]["claim_id"])
  end

  defp valid_owner?(owner, bound?) do
    exact_fields?(owner, @owner_fields) and Enum.all?(~w(deployment_id lane attempt_id), &nonblank?(owner[&1])) and
      valid_workstation?(owner["workstation_name"]) and
      (nonblank?(owner["workstation_uid"]) or (not bound? and is_nil(owner["workstation_uid"])))
  end

  defp valid_receipt?(receipt, record) do
    exact_fields?(receipt, @receipt_fields) and receipt["schema"] === 1 and receipt["admission"] == "sealed" and
      valid_owner?(receipt["owner"], true) and receipt["owner"] == record["owner"] and
      receipt["credential_id"] == record["credential_id"] and receipt["epoch"] === record["epoch"] and
      receipt["claim_id"] == record["claim_id"] and same_secret?(receipt["secret_version"], record["head_version"]) and
      is_binary(receipt["sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, receipt["sha256"])
  end

  defp optional_proof?(%{"stop_proof" => nil}), do: true

  defp optional_proof?(record) do
    not is_nil(record["candidate"]) and valid_proof?(record["stop_proof"], record["owner"])
  end

  defp valid_proof?(proof, owner) do
    exact_fields?(proof, @proof_fields) and nonblank?(owner["workstation_uid"]) and
      proof["uid"] == owner["workstation_uid"] and proof["attempt_id"] == owner["attempt_id"] and
      correlated_operation?(proof["operation"], owner["workstation_name"])
  end

  defp valid_handoff?(nil, _head), do: true

  defp valid_handoff?(handoff, head) do
    exact_fields?(handoff, @handoff_fields) and nonblank?(handoff["claim_id"]) and
      handoff["secret_version"] == head and valid_owner?(handoff["owner"], true) and
      valid_proof?(handoff["stop_proof"], handoff["owner"]) and is_boolean(handoff["resource_acknowledged"])
  end

  defp unacknowledged?(nil), do: false
  defp unacknowledged?(handoff), do: not handoff["resource_acknowledged"]

  defp valid_workstation?(name) when is_binary(name) do
    case String.split(name, "/") do
      ["projects", project, "locations", location, "workstationClusters", cluster, "workstationConfigs", config, "workstations", workstation] ->
        Enum.all?([project, location, cluster, config, workstation], &resource_segment?/1)

      _ ->
        false
    end
  end

  defp valid_workstation?(_name), do: false

  defp correlated_operation?(operation, workstation) when is_binary(operation) do
    case {String.split(operation, "/"), String.split(workstation, "/")} do
      {["projects", project, "locations", location, "operations", id], ["projects", project, "locations", location | _]} -> resource_segment?(id)
      _ -> false
    end
  end

  defp correlated_operation?(_operation, _workstation), do: false

  defp same_secret?(version, head) do
    secret = secret_resource(version)
    not is_nil(secret) and secret == secret_resource(head)
  end

  defp secret_resource(version) when is_binary(version) do
    case String.split(version, "/") do
      ["projects", project, "secrets", secret, "versions", number] ->
        if resource_segment?(project) and resource_segment?(secret) and Regex.match?(~r/\A[1-9][0-9]*\z/, number), do: {project, secret}, else: nil

      _ ->
        nil
    end
  end

  defp secret_resource(_version), do: nil

  defp resource_segment?(value), do: value not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, value)
  defp valid_reason?(reason), do: is_binary(reason) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, reason)
  defp nonblank?(value), do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
  defp exact_fields?(value, fields), do: is_map(value) and map_size(value) == length(fields) and Enum.all?(fields, &Map.has_key?(value, &1))
  defp recovery(reason), do: {:error, {:credential_recovery_required, reason}}
end
