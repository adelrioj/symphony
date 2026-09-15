Code.require_file("../support/kubernetes_candidate_runner.exs", __DIR__)

defmodule SymphonyElixir.KubernetesCandidateTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Candidate

  setup do
    root = Path.join(System.tmp_dir!(), "candidate-boundary-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    helper = Path.join(root, "symphony-kubernetes-create")
    File.write!(helper, "#!/bin/sh\nexit 99\n")
    File.chmod!(helper, 0o700)
    path = System.get_env("PATH")
    System.put_env("PATH", root <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(root)
    end)

    {config, pins, objects} = fixture(helper)
    %{config: config, pins: pins, objects: objects, root: root}
  end

  test "runner imports a disabled DB lane before rejecting invalid candidate pins", ctx do
    alias SymphonyElixir.{KubernetesCandidateRunner, Lanes, LaneStore, LaneSupervisor, TestSupport}
    TestSupport.reset_lanes!()
    enabled = System.get_env("SYMPHONY_RUN_KUBERNETES_CANDIDATE")
    System.put_env("SYMPHONY_RUN_KUBERNETES_CANDIDATE", "1")

    on_exit(fn ->
      TestSupport.restore_env("SYMPHONY_RUN_KUBERNETES_CANDIDATE", enabled)
      TestSupport.reset_lanes!()
    end)

    File.chmod!(ctx.root, 0o700)
    workflow = Path.join(ctx.root, "WORKFLOW")
    output = Path.join(ctx.root, "evidence.json")
    environment = %{kind: "kubernetes", deployment_id: "ignored", provider: ctx.config.provider, startup_timeout_ms: 1_000, shutdown_timeout_ms: 1_000}
    File.write!(workflow, SymphonyElixir.Workflow.render(Jason.encode!(%{worker: %{environment: environment}, hooks: %{before_run: "must-not-run"}}), "Must not reach an agent."))
    input = %{
      "authorization" => "disposable-namespace-non-model",
      "mode" => "run",
      "workflow_path" => workflow,
      "output_path" => output,
      "pins" => %{"deployment_id" => "candidate-db-probe"},
      "timeout_ms" => 1_000,
      "cleanup_timeout_ms" => 1_000,
      "runner_sha256" => Candidate.sha256(File.read!(Path.expand("../support/kubernetes_candidate_runner.exs", __DIR__))),
      "negative_control_paths" => ["/api/v1/namespaces/unrelated"],
      "worker_count" => 1,
      "backend" => nil
    }
    input_path = Path.join(ctx.root, "input.json")
    File.write!(input_path, Jason.encode!(input))

    assert {:error, :candidate_setup_failed} = KubernetesCandidateRunner.run_file(input_path)
    [lane] = Lanes.list()
    refute lane.enabled
    refute LaneSupervisor.running?(lane.id)
    settings = LaneStore.settings!(lane.id)
    assert settings.tracker.kind == "memory"
    assert settings.agent.max_concurrent_agents == 1
    assert settings.hooks.before_run == nil
    assert settings.worker.environment.deployment_id == "candidate-db-probe"
    assert Jason.decode!(File.read!(output))["backend_sessions"] == 0
  end

  test "incomplete candidate identity is rejected without contacting the provider", %{config: config} do
    command = fn _, _, _ -> flunk("candidate identity must fail before provider I/O") end
    assert {:error, {:invalid, :kubernetes_candidate_identity}} = Kubernetes.candidate_preflight(config, %{}, command_fun: command)
  end

  test "ordinary preflight cannot select even a matching candidate baseline", ctx do
    command = fn _, _, _ -> flunk("ordinary preflight must reject candidate capability before I/O") end

    assert {:error, {:invalid, :kubernetes_candidate_options_forbidden}} =
             Kubernetes.preflight(ctx.config, candidate_baseline: ctx.pins, command_fun: command)
  end

  test "every candidate lifecycle mutation rejects wrong pins before provider I/O", ctx do
    record = %SymphonyElixir.ExecutionEnvironment.Record{
      key: "candidate",
      deployment_id: "candidate-run",
      tracker_kind: "memory",
      issue_id: "probe",
      kind: "kubernetes",
      scope: %{"namespace" => "candidate"},
      workspace_path: "/workspace/probe",
      template_identity: "candidate"
    }

    opts = [candidate_baseline: %{}, command_fun: fn _, _, _ -> flunk("invalid candidate must not mutate or query") end]

    for operation <- [:ensure, :inspect, :start, :stop, :destroy] do
      assert {:error, {:invalid, :kubernetes_candidate_identity}, _} = apply(Kubernetes, operation, [ctx.config, record, opts])
    end

    assert {:error, {:invalid, :kubernetes_candidate_identity}, _} = Kubernetes.put_intent(ctx.config, record, %{desired: :absent}, opts)
    assert {:error, {:invalid, :kubernetes_candidate_identity}} = Kubernetes.discover(ctx.config, opts)
  end

  test "candidate preflight requires the live inventory after exact safety validation", ctx do
    assert :ok = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: command(ctx.objects))
    denied = command(ctx.objects, "pods")
    assert {:error, _} = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: denied)
  end

  test "operator artifact, helper, scope and qualification claims cannot be substituted", ctx do
    wrong = [
      put_in(ctx.pins, ["namespace"], "elsewhere"),
      put_in(ctx.pins, ["contract", "controller_namespace"], ctx.pins["namespace"]),
      put_in(ctx.pins, ["deployment_id"], "elsewhere"),
      put_in(ctx.pins, ["consumer_artifact_sha256"], String.duplicate("0", 64)),
      put_in(ctx.pins, ["helper_sha256"], String.duplicate("0", 64)),
      put_in(ctx.pins, ["contract", "qualified"], true),
      put_in(ctx.pins, ["contract", "termination_contract"], "qualified-kubelet-all-containers-v1"),
      Map.put(ctx.pins, "skip_preflight", true)
    ]

    for pins <- wrong do
      no_io = fn _, _, _ -> flunk("wrong capability must fail before I/O") end
      assert {:error, {:invalid, :kubernetes_candidate_identity}} = Kubernetes.candidate_preflight(ctx.config, pins, command_fun: no_io)
    end
  end

  test "changed live namespace, controller, worker, schema, policy and report fail before mutation", ctx do
    changed = [
      put_in(ctx.objects, ["namespace", "metadata", "uid"], "replacement"),
      put_in(ctx.objects, ["deployments", Access.at(0), "spec", "replicas"], 2),
      put_in(ctx.objects, ["sandboxtemplates", Access.at(0), "spec", "podTemplate", "spec", "containers", Access.at(0), "image"], image("c")),
      put_in(ctx.objects, ["customresourcedefinitions", Access.at(0), "spec", "scope"], "Cluster"),
      put_in(ctx.objects, ["networkpolicies", Access.at(0), "spec", "policyTypes"], ["Ingress"]),
      put_in(ctx.objects, ["configmaps", Access.at(0), "data", "contract.json"], Jason.encode!(Map.put(ctx.pins["contract"], "qualification_report", "another-report")))
    ]

    for objects <- changed do
      assert {:error, _} = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: command(objects))
    end
  end

  test "even an exactly pinned controller must watch only the authorized namespace", ctx do
    for args <- [
          [],
          ["--watch-namespace=elsewhere"],
          ["--watch-namespace=candidate", "--watch-namespace=elsewhere"],
          ["--", "--watch-namespace=candidate"],
          ["ignored", "--watch-namespace=candidate"],
          ["--watch-namespace=candidate", "-watch-namespace=elsewhere"]
        ] do
      args = args ++ ["--leader-election-namespace=management"]
      objects = put_in(ctx.objects, ["deployments", Access.at(0), "spec", "template", "spec", "containers", Access.at(0), "args"], args)
      pins = Map.put(ctx.pins, "controller_spec_digest", Candidate.digest(hd(objects["deployments"])["spec"]))
      assert {:error, {:invalid, :kubernetes_candidate_contract_mismatch}} = Kubernetes.candidate_preflight(ctx.config, pins, command_fun: command(objects))
    end
  end

  test "a pinned command override cannot disguise a different controller entrypoint", ctx do
    objects = put_in(ctx.objects, ["deployments", Access.at(0), "spec", "template", "spec", "containers", Access.at(0), "command"], ["sh", "-c", "exec controller"])
    pins = Map.put(ctx.pins, "controller_spec_digest", Candidate.digest(hd(objects["deployments"])["spec"]))
    assert {:error, {:invalid, :kubernetes_candidate_contract_mismatch}} = Kubernetes.candidate_preflight(ctx.config, pins, command_fun: command(objects))
  end

  test "a new cluster-admin grant through any controller subject invalidates otherwise exact pins", ctx do
    subjects = [
      %{"kind" => "ServiceAccount", "name" => "controller", "namespace" => "management"},
      %{"kind" => "User", "name" => "system:serviceaccount:management:controller"},
      %{"kind" => "Group", "name" => "system:serviceaccounts:management"},
      %{"kind" => "Group", "name" => "system:serviceaccounts"},
      %{"kind" => "Group", "name" => "system:authenticated"}
    ]

    for subject <- subjects do
      binding = %{"metadata" => meta("widened", "widened-uid"), "subjects" => [subject], "roleRef" => %{"apiGroup" => "rbac.authorization.k8s.io", "kind" => "ClusterRole", "name" => "cluster-admin"}}
      objects = Map.put(ctx.objects, "clusterrolebindings", [binding])
      assert {:error, {:invalid, :kubernetes_candidate_authorization}} = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: command(objects))
    end
  end

  test "same service account name in another namespace is not the controller principal", ctx do
    binding = %{
      "metadata" => meta("unrelated", "unrelated-uid"),
      "subjects" => [%{"kind" => "ServiceAccount", "name" => "controller", "namespace" => "other"}],
      "roleRef" => %{"apiGroup" => "rbac.authorization.k8s.io", "kind" => "ClusterRole", "name" => "cluster-admin"}
    }

    assert :ok = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: command(Map.put(ctx.objects, "clusterrolebindings", [binding])))
  end

  test "RoleBinding service account namespace defaults to the binding namespace", ctx do
    for namespace <- ["management", "other"] do
      binding = %{
        "metadata" => Map.put(meta("extra", "extra-uid"), "namespace", namespace),
        "subjects" => [%{"kind" => "ServiceAccount", "name" => "controller"}],
        "roleRef" => %{"apiGroup" => "rbac.authorization.k8s.io", "kind" => "ClusterRole", "name" => "cluster-admin"}
      }

      objects = Map.update!(ctx.objects, "rolebindings", &(&1 ++ [binding]))
      result = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: command(objects))
      if namespace == "management", do: assert(result == {:error, {:invalid, :kubernetes_candidate_authorization}}), else: assert(result == :ok)
    end
  end

  test "standard discovery and self-review grants do not count as workload mutation", ctx do
    role = %{
      "metadata" => meta("basic-user", "basic-uid"),
      "rules" => [
        %{"nonResourceURLs" => ["/api", "/apis", "/version"], "verbs" => ["get"]},
        %{"apiGroups" => ["authorization.k8s.io"], "resources" => ["selfsubjectaccessreviews", "selfsubjectrulesreviews"], "verbs" => ["create"]}
      ]
    }

    binding = %{
      "metadata" => meta("basic-user", "basic-binding-uid"),
      "subjects" => [%{"kind" => "Group", "name" => "system:authenticated"}],
      "roleRef" => %{"apiGroup" => "rbac.authorization.k8s.io", "kind" => "ClusterRole", "name" => "basic-user"}
    }

    objects = ctx.objects |> Map.update!("clusterroles", &(&1 ++ [role])) |> Map.put("clusterrolebindings", [binding])
    assert :ok = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: command(objects))
  end

  test "all-namespace ConfigMap and Pod reads are not standard discovery grants", ctx do
    role = %{"metadata" => meta("read-workloads", "read-workloads-uid"), "rules" => [%{"apiGroups" => [""], "resources" => ["configmaps", "pods"], "verbs" => ["get", "list", "watch"]}]}

    binding = %{
      "metadata" => meta("read-workloads", "read-workloads-binding-uid"),
      "subjects" => [%{"kind" => "ServiceAccount", "name" => "controller", "namespace" => "management"}],
      "roleRef" => %{"apiGroup" => "rbac.authorization.k8s.io", "kind" => "ClusterRole", "name" => "read-workloads"}
    }

    objects = ctx.objects |> Map.update!("clusterroles", &(&1 ++ [role])) |> Map.put("clusterrolebindings", [binding])
    assert {:error, {:invalid, :kubernetes_candidate_authorization}} = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: command(objects))
  end

  test "GET on an interactive pod subresource is not a harmless read grant", ctx do
    role = %{"metadata" => meta("exec", "exec-uid"), "rules" => [%{"apiGroups" => [""], "resources" => ["pods/exec"], "verbs" => ["get"]}]}

    binding = %{
      "metadata" => meta("exec", "exec-binding-uid"),
      "subjects" => [%{"kind" => "Group", "name" => "system:authenticated"}],
      "roleRef" => %{"apiGroup" => "rbac.authorization.k8s.io", "kind" => "ClusterRole", "name" => "exec"}
    }

    objects = ctx.objects |> Map.update!("clusterroles", &(&1 ++ [role])) |> Map.put("clusterrolebindings", [binding])
    assert {:error, {:invalid, :kubernetes_candidate_authorization}} = Kubernetes.candidate_preflight(ctx.config, ctx.pins, command_fun: command(objects))
  end

  test "candidate contracts still enforce the ordinary unsafe template rejection", ctx do
    objects = put_in(ctx.objects, ["sandboxtemplates", Access.at(0), "spec", "podTemplate", "spec", "hostNetwork"], true)
    pins = put_in(ctx.pins, ["contract", "template_digest"], Candidate.digest(hd(objects["sandboxtemplates"])["spec"]))
    objects = put_in(objects, ["configmaps", Access.at(0), "data", "contract.json"], Jason.encode!(pins["contract"]))
    assert {:error, {:invalid, :unsafe_kubernetes_template}} = Kubernetes.candidate_preflight(ctx.config, pins, command_fun: command(objects))
  end

  defp command(objects, denied \\ nil) do
    fn _executable, args, _opts ->
      assert "get" in args, "candidate preflight must not mutate"
      raw = Enum.at(args, Enum.find_index(args, &(&1 == "--raw")) + 1)
      path = URI.parse(raw).path
      resource = Path.basename(path)

      body =
        cond do
          resource == denied -> %{"kind" => "Status", "code" => 403}
          path == "/version" -> %{"major" => "1", "minor" => "33"}
          path == "/api/v1/namespaces/candidate" -> objects["namespace"]
          true -> %{"metadata" => %{}, "items" => Map.fetch!(objects, resource)}
        end

      {:ok, %{status: if(resource == denied, do: 1, else: 0), output: Jason.encode!(body)}}
    end
  end

  defp fixture(helper) do
    config = %{
      provider: %{"namespace" => "candidate", "kubeconfig" => __ENV__.file, "context" => "unit", "template" => "worker", "ssh_user" => "worker", "ssh_auth_volume" => "auth", "ssh_port" => 2222},
      deployment_id: "candidate-run"
    }

    template = %{
      "metadata" => Map.put(meta("worker", "template-uid"), "annotations", %{"symphony.dev/qualification" => "candidate-contract"}),
      "spec" => %{
        "networkPolicyManagement" => "Unmanaged",
        "podTemplate" => %{
          "metadata" => %{"labels" => %{"profile" => "private"}},
          "spec" => %{
            "runtimeClassName" => "isolated",
            "containers" => [%{"image" => image("a"), "volumeMounts" => [%{"name" => "auth", "readOnly" => true}]}],
            "volumes" => [%{"name" => "auth", "emptyDir" => %{}}]
          }
        },
        "volumeClaimTemplates" => [%{"spec" => %{"storageClassName" => "private"}}]
      }
    }

    controller = %{
      "metadata" => meta("controller", "controller-uid"),
      "spec" => %{
        "replicas" => 1,
        "template" => %{
          "spec" => %{"serviceAccountName" => "controller", "containers" => [%{"image" => image("b"), "args" => ["--watch-namespace=candidate", "--leader-election-namespace=management"]}]}
        }
      },
      "status" => %{"availableReplicas" => 1, "observedGeneration" => 1}
    }

    runtime = %{"metadata" => meta("isolated", "runtime-uid"), "handler" => "kata"}
    storage = %{"metadata" => meta("private", "storage-uid"), "reclaimPolicy" => "Delete", "provisioner" => "candidate.csi"}
    policy = %{"metadata" => meta("private", "policy-uid"), "spec" => %{"podSelector" => %{"matchLabels" => %{"profile" => "private"}}, "policyTypes" => ["Ingress", "Egress"]}}

    schemas =
      Enum.map(~w(sandboxes.agents.x-k8s.io sandboxtemplates.extensions.agents.x-k8s.io), fn name ->
        %{
          "metadata" => meta(name, name),
          "spec" => %{"scope" => "Namespaced", "versions" => [%{"name" => "v1beta1", "served" => true, "storage" => true, "schema" => %{"openAPIV3Schema" => %{"type" => "object"}}}]}
        }
      end)

    q = %{
      "release" => "unit-candidate",
      "stage" => "candidate-unqualified",
      "qualified" => false,
      "termination_contract" => "candidate-unqualified-kubelet-all-containers-v1",
      "qualification_report" => "unit-report-not-live",
      "template_uid" => "template-uid",
      "template_digest" => Candidate.digest(template["spec"]),
      "controller_namespace" => "management",
      "controller_name" => "controller",
      "controller_uid" => "controller-uid",
      "controller_source_commit" => String.duplicate("a", 40),
      "controller_image" => image("b"),
      "runtime_class_uid" => "runtime-uid",
      "runtime_handler" => "kata",
      "storage_class_uids" => ["storage-uid"],
      "csi_driver" => "candidate.csi",
      "network_policy_uid" => "policy-uid",
      "network_profile_label" => "profile",
      "worker_image" => image("a")
    }

    sa = %{"metadata" => Map.put(meta("controller", "sa-uid"), "namespace", "management")}

    workload =
      role("workload", "candidate", [%{"apiGroups" => [""], "resources" => ["pods", "persistentvolumeclaims", "services"], "verbs" => ["get", "list", "watch", "create", "patch", "update", "delete"]}])

    management = role("management", "management", [%{"apiGroups" => ["coordination.k8s.io"], "resources" => ["leases"], "verbs" => ["get", "list", "watch", "create", "patch", "update"]}])
    workload_binding = role_binding(workload)
    management_binding = role_binding(management)

    authorization = %{
      "service_account" => authorization_pin(sa),
      "workload_role" => authorization_pin(workload),
      "management_role" => authorization_pin(management),
      "workload_binding" => authorization_pin(workload_binding),
      "management_binding" => authorization_pin(management_binding)
    }

    pins = %{
      "namespace" => "candidate",
      "namespace_uid" => "namespace-uid",
      "deployment_id" => "candidate-run",
      "consumer_source_commit" => String.duplicate("b", 40),
      "consumer_artifact_sha256" => Candidate.artifact_identity().sha256,
      "helper_sha256" => Candidate.sha256(File.read!(helper)),
      "contract" => q,
      "controller_authorization" => authorization,
      "schema_digests" => Map.new(schemas, &{&1["metadata"]["name"], Candidate.digest(%{"type" => "object"})}),
      "controller_spec_digest" => Candidate.digest(controller["spec"]),
      "runtime_class_spec_digest" => Candidate.digest(%{"handler" => "kata"}),
      "storage_class_digests" => %{"storage-uid" => Candidate.digest(Map.drop(storage, ["metadata"]))},
      "network_policy_spec_digest" => Candidate.digest(policy["spec"])
    }

    objects =
      Map.new(~w(sandboxes pods persistentvolumeclaims persistentvolumes secrets services), &{&1, []})
      |> Map.merge(%{
        "namespace" => %{"metadata" => meta("candidate", "namespace-uid")},
        "sandboxtemplates" => [template],
        "configmaps" => [%{"metadata" => meta("candidate-contract", "contract-uid"), "immutable" => true, "data" => %{"contract.json" => Jason.encode!(q)}}],
        "customresourcedefinitions" => schemas,
        "serviceaccounts" => [sa],
        "roles" => [workload, management],
        "rolebindings" => [workload_binding, management_binding],
        "clusterroles" => [%{"metadata" => meta("cluster-admin", "admin-uid"), "rules" => [%{"apiGroups" => ["*"], "resources" => ["*"], "verbs" => ["*"]}]}],
        "clusterrolebindings" => [],
        "deployments" => [controller],
        "runtimeclasses" => [runtime],
        "storageclasses" => [storage],
        "networkpolicies" => [policy]
      })

    {config, pins, objects}
  end

  defp role(name, namespace, rules), do: %{"metadata" => Map.put(meta(name, name <> "-uid"), "namespace", namespace), "rules" => rules}

  defp role_binding(role),
    do: %{
      "metadata" => Map.update!(role["metadata"], "uid", &(&1 <> "-binding")),
      "subjects" => [%{"kind" => "ServiceAccount", "name" => "controller", "namespace" => "management"}],
      "roleRef" => %{"apiGroup" => "rbac.authorization.k8s.io", "kind" => "Role", "name" => role["metadata"]["name"]}
    }

  defp authorization_pin(object), do: Map.take(object["metadata"], ~w(name namespace uid)) |> Map.put("digest", Candidate.digest(Map.drop(object, ~w(metadata apiVersion kind))))

  defp meta(name, uid), do: %{"name" => name, "uid" => uid, "generation" => 1, "resourceVersion" => "1"}
  defp image(char), do: "unit.invalid/candidate@sha256:" <> String.duplicate(char, 64)
end
