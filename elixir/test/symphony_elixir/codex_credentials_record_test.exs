defmodule SymphonyElixir.CodexCredentials.RecordTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CodexCredentials.Record

  @head "projects/fixture-workers/secrets/features-codex/versions/1"
  @next "projects/fixture-workers/secrets/features-codex/versions/2"
  @workstation "projects/fixture-workers/locations/europe-west1/workstationClusters/fixture/workstationConfigs/features/workstations/ticket-1"

  test "operator initialization rejects aliases, invalid epochs and incomplete identifiers" do
    for {credential_id, epoch, version} <- [
          {"", 1, @head},
          {"features", 0, @head},
          {"features", 1.0, @head},
          {"features", 1, "projects/fixture-workers/secrets/features-codex/versions/latest"},
          {"features", 1, "projects/fixture-workers/secrets/features-codex/versions/0"},
          {"features", 1, "1"}
        ] do
      assert_raise ArgumentError, fn -> Record.initial(credential_id, epoch, version) end
    end
  end

  test "claim excludes competing and repeated acquisitions and cannot release without a checkpoint" do
    owned = owned()

    for claim <- ["claim-a", "claim-b"] do
      assert {:error, :credential_busy} = Record.transition(owned, {:claim, claim, owner()}, "competing")
    end

    assert {:error, {:credential_recovery_required, :checkpoint_missing}} = Record.transition(owned, {:release, "claim-a"}, "release")
    assert {:error, _} = Record.transition(owned, {:stopped, "claim-a", proof()}, "premature-stop")
    assert {:error, _} = Record.assignment(initial())
  end

  test "assignment requires provider UID binding and a bound UID is immutable" do
    owned = owned()
    assert {:error, {:credential_recovery_required, :uid_missing}} = Record.assignment(owned)
    assert {:error, _} = Record.transition(owned, {:bind_uid, "claim-b", "uid-a"}, "wrong-claim")
    assert {:error, _} = Record.transition(owned, {:bind_uid, "claim-a", ""}, "empty-uid")
    assert {:ok, bound} = Record.transition(owned, {:bind_uid, "claim-a", "uid-a"}, "bind")
    assert {:ok, _} = Record.transition(bound, {:bind_uid, "claim-a", "uid-a"}, "same-uid")
    assert {:error, _} = Record.transition(bound, {:bind_uid, "claim-a", "uid-b"}, "replace-uid")

    assert {:ok, assignment} = Record.assignment(bound)
    assert assignment == %{
             "schema" => 1,
             "credential_id" => "features",
             "epoch" => 1,
             "claim_id" => "claim-a",
             "secret_version" => @head,
             "owner" => owner("uid-a")
           }
  end

  test "claims cannot bypass UID readback or introduce malformed owner identity" do
    for invalid_owner <- [owner("uid-a"), Map.delete(owner(), "attempt_id"), Map.put(owner(), "attempt_id", ""),
                          Map.put(owner(), "workstation_name", "ticket-1"), Map.put(owner(), "token", "synthetic-extra")] do
      assert {:error, _} = Record.transition(initial(), {:claim, "claim-a", invalid_owner}, "claim")
    end

    assert {:error, _} = Record.transition(initial(), {:claim, "", owner()}, "claim")
    assert {:error, _} = Record.transition(initial(), {:claim, "claim-a", owner()}, nil)
  end

  test "checkpoint requires a bound owner and exact original assignment identity" do
    assert {:error, _} = Record.transition(owned(), {:checkpoint, receipt()}, "unbound")

    for bad_receipt <- [
          Map.put(receipt(), "credential_id", "other"),
          Map.put(receipt(), "epoch", 2),
          Map.put(receipt(), "claim_id", "claim-b"),
          put_in(receipt(), ["owner", "workstation_uid"], "uid-b"),
          put_in(receipt(), ["owner", "attempt_id"], "recovery-attempt"),
          put_in(receipt(), ["owner", "deployment_id"], "other-deployment"),
          put_in(receipt(), ["owner", "lane"], "other-lane"),
          put_in(receipt(), ["owner", "workstation_name"], @workstation <> "-other")
        ] do
      assert {:error, _} = Record.transition(bound(), {:checkpoint, bad_receipt}, "mismatch")
    end
  end

  test "checkpoint requires a sealed complete receipt for a numeric version of the same secret" do
    for bad_receipt <- [
          Map.put(receipt(), "schema", 2),
          Map.put(receipt(), "admission", "open"),
          Map.put(receipt(), "sha256", "not-a-digest"),
          Map.delete(receipt(), "sha256"),
          Map.put(receipt(), "secret_version", "projects/fixture-workers/secrets/other/versions/2"),
          Map.put(receipt(), "secret_version", "projects/fixture-workers/secrets/features-codex/versions/latest"),
          Map.put(receipt(), "token", "synthetic-extra")
        ] do
      assert {:error, _} = Record.transition(bound(), {:checkpoint, bad_receipt}, "invalid-receipt")
    end

    assert {:ok, unchanged} = Record.transition(bound(), {:checkpoint, receipt(@head)}, "unchanged-bytes")
    assert {:ok, stopped} = Record.transition(unchanged, {:stopped, "claim-a", proof()}, "stop-unchanged")
    assert {:ok, released} = Record.transition(stopped, {:release, "claim-a"}, "release-unchanged")
    assert released["head_version"] == @head
  end

  test "checkpoint cannot release until matching correlated physical stop proof is recorded" do
    checkpointed = checkpointed()
    assert {:error, {:credential_recovery_required, :stop_missing}} = Record.transition(checkpointed, {:release, "claim-a"}, "release")

    for bad_proof <- [
          %{"process_exit" => 0},
          Map.put(proof(), "uid", "uid-b"),
          Map.put(proof(), "attempt_id", "recovery-attempt"),
          Map.put(proof(), "operation", nil),
          Map.put(proof(), "operation", "projects/other/locations/europe-west1/operations/stop-1"),
          Map.put(proof(), "operation", "projects/fixture-workers/locations/other/operations/stop-1"),
          Map.put(proof(), "operation", "stop-1"),
          Map.put(proof(), "token", "synthetic-extra")
        ] do
      assert {:error, _} = Record.transition(checkpointed, {:stopped, "claim-a", bad_proof}, "bad-stop")
    end

    assert {:error, _} = Record.transition(checkpointed, {:stopped, "claim-b", proof()}, "wrong-stop-claim")
    assert {:error, _} = Record.transition(checkpointed, {:release, "claim-b"}, "wrong-release-claim")
  end

  test "handoff selects the candidate but blocks a new owner until resource disposition is acknowledged" do
    released = released()
    assert :ok = Record.validate(released)
    assert released["head_version"] == @next
    assert released["state"] == "AVAILABLE"
    assert released["last_handoff"] == %{
             "claim_id" => "claim-a",
             "secret_version" => @next,
             "owner" => owner("uid-a"),
             "stop_proof" => proof(),
             "resource_acknowledged" => false
           }

    assert {:error, :credential_busy} = Record.transition(released, {:claim, "claim-b", owner()}, "blocked")
    assert {:error, _} = Record.transition(released, {:acknowledge_handoff, "claim-b"}, "wrong-ack")
    assert {:ok, acknowledged} = Record.transition(released, {:acknowledge_handoff, "claim-a"}, "ack")
    assert {:error, _} = Record.transition(acknowledged, {:claim, "claim-a", owner()}, "reused-claim")
    assert {:ok, next_owner} = Record.transition(acknowledged, {:claim, "claim-b", Map.put(owner(), "attempt_id", "attempt-b")}, "next-claim")
    assert {:ok, next_bound} = Record.transition(next_owner, {:bind_uid, "claim-b", "uid-b"}, "next-bind")
    assert {:ok, assignment} = Record.assignment(next_bound)
    assert assignment["secret_version"] == @next
    assert assignment["owner"]["attempt_id"] == "attempt-b"
    assert next_bound["last_handoff"]["resource_acknowledged"] == true
  end

  test "quarantine retains the original identity and evidence and cannot be escaped by ordinary events" do
    for record <- [owned(), bound(), checkpointed(), stopped()] do
      assert {:error, _} = Record.transition(record, {:quarantine, "claim-b", "outcome_unknown"}, "wrong-quarantine")
      assert {:error, _} = Record.transition(record, {:quarantine, "claim-a", "unbounded reason with payload"}, "unsafe-reason")
      assert {:ok, quarantined} = Record.transition(record, {:quarantine, "claim-a", "outcome_unknown"}, "quarantine")
      assert :ok = Record.validate(quarantined)
      assert quarantined["owner"] == record["owner"]
      assert quarantined["candidate"] == record["candidate"]
      assert quarantined["stop_proof"] == record["stop_proof"]
      assert quarantined["state"] == "RECOVERY_REQUIRED"

      for event <- [{:claim, "recovery-claim", Map.put(owner(), "attempt_id", "recovery-attempt")},
                    {:bind_uid, "claim-a", "uid-b"}, {:checkpoint, receipt()}, {:stopped, "claim-a", proof()},
                    {:release, "claim-a"}, {:acknowledge_handoff, "claim-a"}] do
        assert {:error, {:credential_recovery_required, _}} = Record.transition(quarantined, event, "recovery")
      end

      if record["owner"]["workstation_uid"] do
        assert {:ok, assignment} = Record.assignment(quarantined)
        assert assignment["claim_id"] == "claim-a"
        assert assignment["owner"]["attempt_id"] == "attempt-a"
      else
        assert {:error, _} = Record.assignment(quarantined)
      end
    end
  end

  test "unknown and malformed authority fails closed instead of being repaired by transitions" do
    for invalid <- [nil, [], %{}, Map.delete(initial(), "reason"), Map.put(initial(), "schema", 2),
                    Map.put(initial(), "state", "EXPIRED"), Map.put(initial(), "epoch", 0),
                    Map.put(initial(), "head_version", "latest"), Map.put(initial(), "generation", "3"),
                    Map.put(initial(), "transition_id", ""), Map.put(initial(), "owner", owner()),
                    Map.put(owned(), "owner", nil), Map.put(owned(), "candidate", receipt()),
                    Map.put(owned(), "stop_proof", proof()), Map.put(bound(), "reason", "unexpected"),
                    Map.put(checkpointed(), "candidate", nil),
                    put_in(checkpointed(), ["candidate", "secret_version"], "projects/fixture-workers/secrets/other/versions/2"),
                    put_in(checkpointed(), ["candidate", "owner", "attempt_id"], "recovery-attempt"),
                    put_in(stopped(), ["stop_proof", "uid"], "uid-b"),
                    Map.put(bound(), "state", "RECOVERY_REQUIRED")] do
      assert {:error, :credential_outcome_unknown} = Record.validate(invalid)
      assert {:error, :credential_outcome_unknown} = Record.assignment(invalid)
      assert {:error, :credential_outcome_unknown} = Record.transition(invalid, {:claim, "claim-b", owner()}, "no-repair")
    end
  end

  test "malformed handoff evidence cannot authorize another claim" do
    for invalid <- [
          put_in(released(), ["last_handoff", "secret_version"], @head),
          put_in(released(), ["last_handoff", "owner", "workstation_uid"], "uid-b"),
          put_in(released(), ["last_handoff", "stop_proof", "attempt_id"], "recovery-attempt"),
          put_in(released(), ["last_handoff", "resource_acknowledged"], "true"),
          put_in(released(), ["last_handoff", "claim_id"], nil),
          Map.put(released(), "last_handoff", %{})
        ] do
      assert {:error, :credential_outcome_unknown} = Record.validate(invalid)
      assert {:error, :credential_outcome_unknown} = Record.transition(invalid, {:acknowledge_handoff, "claim-a"}, "no-repair")
    end
  end

  test "unsupported event order never advances ownership" do
    for {record, event} <- [
          {initial(), {:release, "claim-a"}},
          {initial(), {:acknowledge_handoff, "claim-a"}},
          {initial(), {:checkpoint, receipt()}},
          {bound(), {:acknowledge_handoff, "claim-a"}},
          {checkpointed(), {:checkpoint, receipt(@head)}},
          {checkpointed(), {:bind_uid, "claim-a", "uid-a"}},
          {released(), {:quarantine, "claim-a", "unknown"}},
          {bound(), {:expires, 999_999_999}},
          {bound(), :unknown}
        ] do
      assert {:error, _} = Record.transition(record, event, "invalid-order")
      assert :ok = Record.validate(record)
    end
  end

  defp initial, do: Record.initial("features", 1, @head)

  defp owner(uid \\ nil) do
    %{"deployment_id" => "deployment-a", "lane" => "features", "workstation_name" => @workstation,
      "workstation_uid" => uid, "attempt_id" => "attempt-a"}
  end

  defp receipt(version \\ @next) do
    %{"schema" => 1, "credential_id" => "features", "epoch" => 1, "claim_id" => "claim-a",
      "owner" => owner("uid-a"), "secret_version" => version, "sha256" => String.duplicate("a", 64), "admission" => "sealed"}
  end

  defp proof do
    %{"uid" => "uid-a", "attempt_id" => "attempt-a",
      "operation" => "projects/fixture-workers/locations/europe-west1/operations/stop-1"}
  end

  defp owned do
    {:ok, record} = Record.transition(initial(), {:claim, "claim-a", owner()}, "claim")
    record
  end

  defp bound do
    {:ok, record} = Record.transition(owned(), {:bind_uid, "claim-a", "uid-a"}, "bind")
    record
  end

  defp checkpointed do
    {:ok, record} = Record.transition(bound(), {:checkpoint, receipt()}, "checkpoint")
    record
  end

  defp stopped do
    {:ok, record} = Record.transition(checkpointed(), {:stopped, "claim-a", proof()}, "stop")
    record
  end

  defp released do
    {:ok, record} = Record.transition(stopped(), {:release, "claim-a"}, "release")
    record
  end
end
