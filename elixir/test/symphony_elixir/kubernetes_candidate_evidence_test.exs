Code.require_file("../support/kubernetes_candidate_evidence.exs", __DIR__)

defmodule SymphonyElixir.KubernetesCandidateEvidenceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.{Config, Record}
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Guard
  alias SymphonyElixir.KubernetesCandidateEvidence, as: Evidence

  test "a non-guard ConfigMap cannot inject a matching deployment receipt" do
    {config, _record, object} = fixture()
    forged = put_in(object, ["metadata", "name"], "unrelated-config")
    forged = put_in(forged, ["metadata", "labels"], %{})
    assert Evidence.guard(forged, config) == nil
    assert Evidence.guard(put_in(object, ["metadata", "uid"], ""), config) == nil
  end

  test "validated guards retain protocol identities but never nested credential payloads" do
    {config, _record, object} = fixture()
    data = Jason.decode!(object["data"]["guard.json"])

    data =
      Map.put(data, "evidence", %{
        "parentUID" => "parent-uid",
        "password" => "GUARD_SECRET_CANARY",
        "controllerJournal" => %{"phase" => "Closed", "operations" => [%{"id" => "operation", "resource" => "pods", "objectUID" => "pod-uid", "credentials" => %{"token" => "JOURNAL_SECRET_CANARY"}}]},
        "volumes" => %{
          "volume-uid" => %{"pv_uid" => "pv-uid", "claim_ref" => %{"uid" => "claim-uid", "password" => "CLAIM_SECRET_CANARY"}, "credentials" => %{"private_key" => "VOLUME_SECRET_CANARY"}}
        }
      })

    object = put_in(object, ["data", "guard.json"], Jason.encode!(data))
    receipt = Evidence.guard(object, config)
    assert receipt["resource"]["uid"] == "guard-uid"
    assert receipt["observed_receipt"]["evidence"]["controllerJournal"]["operations"] == [%{"id" => "operation", "resource" => "pods", "objectUID" => "pod-uid"}]
    assert receipt["observed_receipt"]["evidence"]["volumes"]["volume-uid"]["claim_ref"] == %{"uid" => "claim-uid"}
    refute Jason.encode!(receipt) =~ "SECRET_CANARY"
  end

  test "record obligations and quiescent proof reject nested objects in scalar fields" do
    {config, record, _object} = fixture()

    record = %{
      record
      | metadata: %{
          "volumes" => %{"pvc" => %{"pv_uid" => "pv-uid", "pvc_name" => %{"password" => "NESTED_SECRET_CANARY"}, "claim_ref" => %{"uid" => "pvc-uid", "token" => "CLAIM_SECRET_CANARY"}}},
          "termination_evidence" => %{"pod" => %{"uid" => "pod", "kind" => "kubelet_terminated", "password" => "TERMINATION_SECRET_CANARY"}}
        },
        proof: {:quiescent, %{guard_uid: "guard-uid", credentials: %{token: "PROOF_SECRET_CANARY"}}}
    }

    facts = Evidence.record(record, config)
    assert facts["obligations"]["volumes"]["pvc"]["pv_uid"] == "pv-uid"
    assert facts["proof"] == %{"quiescent" => %{"guard_uid" => "guard-uid"}}
    refute Jason.encode!(facts) =~ "SECRET_CANARY"
  end

  defp fixture do
    config = %{deployment_id: "candidate-run", kind: "kubernetes", tracker_kind: "memory", provider: %{"namespace" => "candidate", "context" => "unit", "kubeconfig" => "/private/config"}}

    record = %Record{
      key: ExecutionEnvironment.resource_key(config.deployment_id, "memory", "probe"),
      deployment_id: config.deployment_id,
      tracker_kind: "memory",
      issue_id: "probe",
      kind: "kubernetes",
      scope: Config.scope(config),
      workspace_path: "/workspace/probe",
      template_identity: "template-uid"
    }

    saved =
      Map.from_struct(record)
      |> Map.take([:key, :deployment_id, :tracker_kind, :issue_id, :kind, :scope, :workspace_path, :template_identity])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("desired", "stopped")

    data = %{
      "protocol" => "symphony-create-drain-v1",
      "identity" => %{"deploymentID" => config.deployment_id, "environmentKey" => record.key, "scope" => record.scope},
      "phase" => "Open",
      "operations" => [],
      "parentUID" => nil,
      "closeRequestId" => nil,
      "record" => saved,
      "evidence" => %{}
    }

    object = %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{
        "name" => Guard.name(record),
        "uid" => "guard-uid",
        "resourceVersion" => "1",
        "namespace" => "candidate",
        "labels" => %{"symphony.dev/create-guard" => "true", "symphony.dev/environment" => record.key}
      },
      "data" => %{"guard.json" => Jason.encode!(data)}
    }

    {config, record, object}
  end
end
