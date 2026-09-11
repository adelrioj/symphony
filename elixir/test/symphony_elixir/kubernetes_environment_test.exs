defmodule SymphonyElixir.KubernetesEnvironmentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionEnvironment.{Kubernetes, Record}
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Client

  test "a suspended sandbox with no visible pod is not physical stop evidence" do
    record = record(%{"authorized_pod_uids" => ["pod-before-partition"]})
    observed = Kubernetes.normalize(record, sandbox(), [], %{})
    assert observed.proof == :unknown
    refute observed.phase == :stopped
  end

  test "a late permanently gated Pod cannot turn a qualified suspension into running" do
    pod = %{"metadata" => %{"uid" => "late"}, "spec" => %{"schedulingGates" => [%{"name" => "symphony.dev/start-authorized"}]}}
    observed = Kubernetes.normalize(record(), sandbox(), [pod], %{})
    assert observed.phase == :stopped
    assert {:quiescent, _} = observed.proof
  end

  test "a terminal phase without authenticated kubelet termination evidence is unknown" do
    pod = %{"metadata" => %{"uid" => "old"}, "spec" => %{}, "status" => %{"phase" => "Failed"}}
    observed = Kubernetes.normalize(record(%{"authorized_pod_uids" => ["old"]}), sandbox(), [pod], %{})
    assert observed.proof == :unknown
  end

  test "saved exact UID termination evidence permits physical stop" do
    proof = %{"old" => %{"kind" => "kubelet_terminated", "uid" => "old", "resourceVersion" => "14", "qualification_uid" => "qualified"}}
    observed = Kubernetes.normalize(record(%{"authorized_pod_uids" => ["old"], "qualification_uid" => "qualified"}), sandbox(), [], proof)
    assert observed.phase == :stopped
    assert {:quiescent, _} = observed.proof
  end

  test "stale suspension conditions and stripped blueprint gates never prove stop" do
    stale = put_in(sandbox(), ["metadata", "generation"], 3)
    assert Kubernetes.normalize(record(), stale, [], %{}).proof == :unknown
    stripped = put_in(sandbox(), ["spec", "podTemplate", "spec", "schedulingGates"], [])
    assert Kubernetes.normalize(record(), stripped, [], %{}).proof == :unknown
  end

  test "inventory follows continuation after an empty page and rejects partial failure" do
    command = fn _exe, args, _opts ->
      path = Enum.at(args, Enum.find_index(args, &(&1 == "--raw")) + 1)

      case URI.decode_query(URI.parse(path).query || "") do
        %{"continue" => "second"} -> {:ok, %{status: 0, output: Jason.encode!(%{"metadata" => %{}, "items" => [%{"metadata" => %{"name" => "late"}}]})}}
        _ -> {:ok, %{status: 0, output: Jason.encode!(%{"metadata" => %{"continue" => "second"}, "items" => []})}}
      end
    end

    assert {:ok, [%{"metadata" => %{"name" => "late"}}]} = Client.list(config(), "/api/v1/namespaces/test/pods", command_fun: command, timeout_ms: 1_000)
    denied = fn _, _, _ -> {:ok, %{status: 1, output: "Error from server (Forbidden)"}} end
    assert {:error, {:unknown, _}} = Client.list(config(), "/api/v1/namespaces/test/pods", command_fun: denied, timeout_ms: 1_000)
  end

  test "stderr NotFound cannot certify absence" do
    command = fn _, _, _ -> {:ok, %{status: 1, output: "Error from server (NotFound): pods missing"}} end
    assert {:error, {:unknown, _}} = Client.lookup(config(), "/api/v1/namespaces/test/pods", "missing", command_fun: command, timeout_ms: 1_000)
  end

  test "JSON CAS conflict is retained and request bodies are private and removed" do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    command = fn _, args, _ ->
      file = Enum.at(args, Enum.find_index(args, &(&1 == "--patch-file")) + 1)
      send(parent, {:body_file, file, File.stat!(file).mode, Jason.decode!(File.read!(file))})
      {:ok, %{status: 1, output: Jason.encode!(%{"kind" => "Status", "code" => 409})}}
    end

    patch = [%{"op" => "test", "path" => "/metadata/uid", "value" => "original"}]

    assert {:ok, %{status: 409}} =
             Client.request(config(), :patch, "/api/v1/namespaces/test/pods/ticket", patch, command_fun: command, timeout_ms: 1_000, task_supervisor: supervisor, authority: self())

    assert_receive {:body_file, file, mode, ^patch}
    assert Bitwise.band(mode, 0o777) == 0o600
    refute File.exists?(file)
  end

  test "lost Sandbox create response is recovered without duplicating retained PVCs" do
    {config, record, opts} = api_fixture(lost_create: true)
    assert {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert created.provider_ref == "sandbox-uid"
    assert get_in(api_state(), ["persistentvolumeclaims", "workspace-se-ticket", "metadata", "uid"]) == "pvc-uid"
    assert {:ok, recovered} = Kubernetes.ensure(config, created, opts)
    assert recovered.provider_ref == created.provider_ref
    assert Process.get(:sandbox_creates) == 1
  end

  test "start persists the exact release UID, keeps blueprint gate, and stop defeats a delayed ungate" do
    {config, record, opts} = api_fixture(delay_release: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:error, {:unknown, :kubernetes_release_outcome}, attempted} = Kubernetes.start(config, intended, opts)
    state = api_state()
    saved = Jason.decode!(get_in(state, ["sandboxes", record.key, "metadata", "annotations", "symphony.dev/record"]))
    assert saved["metadata"]["authorized_pod_uids"] == ["pod-uid"]
    assert Enum.any?(get_in(state, ["sandboxes", record.key, "spec", "podTemplate", "spec", "schedulingGates"]), &(&1["name"] == "symphony.dev/start-authorized"))
    assert {:ok, stopped} = Kubernetes.stop(config, attempted, opts)
    assert {:quiescent, _} = stopped.proof
    {path, patch} = Process.get(:delayed_release)
    assert {:ok, %{status: 409}} = Client.request(config, :patch, path, patch, Keyword.put(opts, :command_fun, &api_command/3))
    refute Enum.any?(Map.values(api_state()["pods"]), &(&1["status"]["phase"] == "Running"))
  end

  test "qualified kubelet stream evidence stops compute while retaining PVC identity" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:ok, started} = Kubernetes.start(config, intended, opts)
    assert Process.get(:operator_gates_after_release) == [%{"name" => "operator.dev/approval"}]
    assert {:ok, running} = Kubernetes.inspect(config, started, opts)
    assert running.phase == :running
    assert {:ok, stopped} = Kubernetes.stop(config, running, opts)
    assert stopped.phase == :stopped
    assert get_in(stopped.metadata, ["termination_evidence", "pod-uid", "kind"]) == "kubelet_terminated"
    assert get_in(api_state(), ["persistentvolumeclaims", "workspace-se-ticket", "metadata", "uid"]) == "pvc-uid"
  end

  test "missing physical watch evidence retains capacity after Pod API disappearance" do
    {config, record, opts} = api_fixture(missing_termination: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    assert {:ok, stopped} = Kubernetes.stop(config, started, opts)
    assert api_state()["pods"] == %{}
    assert stopped.proof == :unknown
    refute stopped.phase == :stopped
  end

  test "CSI backing deletion evidence is persisted but parent finalizer survives absent ordering proof" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}, deleting} = Kubernetes.destroy(config, created, opts)
    assert get_in(deleting.metadata, ["volumes", "workspace-se-ticket", "deleted"]) == true
    refute deleting.absent?
    parent = api_state()["sandboxes"][record.key]
    assert parent["metadata"]["deletionTimestamp"] != nil
    assert "symphony.dev/environment-cleanup" in parent["metadata"]["finalizers"]
  end

  test "delayed PV deletion never becomes disk absence" do
    {config, record, opts} = api_fixture(delay_pv: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}, deleting} = Kubernetes.destroy(config, created, opts)
    refute get_in(deleting.metadata, ["volumes", "workspace-se-ticket", "deleted"]) == true
    refute deleting.absent?
    assert map_size(api_state()["persistentvolumes"]) == 1
  end

  test "replaced Sandbox or retained PVC cannot be adopted by matching name" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    Process.put(:kubernetes_api, put_in(api_state(), ["sandboxes", record.key, "metadata", "uid"], "replacement"))
    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = Kubernetes.ensure(config, created, opts)
    Process.put(:kubernetes_api, put_in(api_state(), ["sandboxes", record.key, "metadata", "uid"], created.provider_ref))
    {:ok, inspected} = Kubernetes.inspect(config, created, opts)
    Process.put(:kubernetes_api, put_in(api_state(), ["persistentvolumeclaims", "workspace-se-ticket", "metadata", "uid"], "replacement"))
    assert {:error, {:unknown, :retained_pvc_replaced}, _} = Kubernetes.inspect(config, inspected, opts)
  end

  test "wrong SSH host identity is rejected and private session files are removed" do
    {config, record, opts} = api_fixture(wrong_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    assert {:error, {:unknown, :kubernetes_ssh_authentication_failed}} = Kubernetes.connect(config, started, opts)
    args = Process.get(:ssh_args)
    assert "StrictHostKeyChecking=yes" in args
    hosts = Enum.find_value(args, fn arg -> if String.starts_with?(arg, "UserKnownHostsFile="), do: String.replace_prefix(arg, "UserKnownHostsFile=", "") end)
    refute File.exists?(hosts)
  end

  test "complete discovery recovers an orphaned labeled PVC instead of reporting zero capacity" do
    {config, record, opts} = api_fixture()
    {:ok, _} = Kubernetes.ensure(config, record, opts)
    Process.put(:kubernetes_api, Map.put(api_state(), "sandboxes", %{}))
    assert {:ok, [orphan]} = Kubernetes.discover(config, opts)
    assert orphan.metadata["orphaned"]
    assert orphan.proof == :unknown
    assert {:error, {:unknown, :retained_kubernetes_parent_missing}, _} = Kubernetes.ensure(config, orphan, opts)
  end

  test "WaitForFirstConsumer claims do not block authorization of the first Pod" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    state = api_state() |> put_in(["persistentvolumeclaims", "workspace-se-ticket", "spec", "volumeName"], nil) |> Map.put("persistentvolumes", %{})
    Process.put(:kubernetes_api, state)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:ok, started} = Kubernetes.start(config, intended, opts)
    assert started.metadata["authorized_pod_uids"] == ["pod-uid"]
    assert get_in(api_state(), ["pods", "se-ticket", "status", "phase"]) == "Running"
  end

  test "an incompatible installed CRD is rejected rather than silently selecting another API" do
    {config, record, opts} = api_fixture()
    state = update_in(api_state(), ["customresourcedefinitions", "sandboxes.agents.x-k8s.io", "spec", "versions"], fn [version] -> [Map.put(version, "name", "v1alpha1")] end)
    Process.put(:kubernetes_api, state)
    assert {:error, {:invalid, :kubernetes_schema_mismatch}, _} = Kubernetes.ensure(config, record, opts)
    assert api_state()["sandboxes"] == %{}
  end

  test "a foreign labeled Pod is never released" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    Process.put(:kubernetes_api, put_in(api_state(), ["pods", "se-ticket", "metadata", "ownerReferences"], [%{"uid" => "foreign", "kind" => "Sandbox"}]))
    assert {:error, {:unknown, :kubernetes_child_ownership_changed}, _} = Kubernetes.inspect(config, started, opts)
  end

  test "a ready connection adopts its private files into the shared authority holder" do
    {config, record, opts} = api_fixture()
    supervisor = start_supervised!(Task.Supervisor)
    opts = Keyword.merge(opts, task_supervisor: supervisor, authority: self())
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    assert {:ok, connection} = Kubernetes.connect(config, started, opts)
    assert :ok = GenServer.call(connection.owner, {:validate_connection, connection.id, connection.target})
    key = arg(connection.target.prefix, "-i")
    assert File.regular?(key)
    assert :ok = SymphonyElixir.ExecutionEnvironment.Operations.close_connection(connection)
    refute File.exists?(key)
  end

  test "expired inventory restarts from an empty accumulator" do
    Process.put(:page, 0)

    command = fn _, _, _ ->
      page = Process.get(:page)
      Process.put(:page, page + 1)

      body =
        case page do
          0 -> %{"metadata" => %{"continue" => "expired"}, "items" => [%{"name" => "stale"}]}
          1 -> %{"kind" => "Status", "code" => 410}
          2 -> %{"metadata" => %{}, "items" => [%{"name" => "current"}]}
        end

      json(body)
    end

    assert {:ok, [%{"name" => "current"}]} = Client.list(config(), "/api/v1/namespaces/test/pods", command_fun: command, timeout_ms: 1_000)
  end

  test "prepare donor death removes staged private keys before connection adoption" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    parent = self()
    snapshot = api_state()

    command = fn executable, args, options ->
      if Path.basename(executable) == "ssh-keygen" do
        path = arg(args, "-f")
        File.write!(path, "private-staged-key")
        send(parent, {:staged_key, path})

        receive do
          :continue -> {:ok, %{status: 0, output: ""}}
        end
      else
        api_command(executable, args, options)
      end
    end

    {donor, donor_ref} =
      spawn_monitor(fn ->
        Process.put(:kubernetes_api, snapshot)
        Process.put(:kubernetes_options, [])
        Process.put(:kubernetes_events, %{})
        Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))
      end)

    assert_receive {:staged_key, path}, 5_000
    [holder] = Task.Supervisor.children(opts[:task_supervisor])
    holder_ref = Process.monitor(holder)
    assert File.regular?(path)
    Process.exit(donor, :kill)
    assert_receive {:DOWN, ^donor_ref, :process, ^donor, :killed}
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, _}, 5_000
    refute File.exists?(path)
  end

  test "discovery and ensure restore durable attempt, terminal retention, and unknown operation state" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    pending = [%{verb: :start, id: "possible-release", outcome: :unknown}]
    candidate = %{created | pending: pending}
    intent = %{desired: :stopped, attempt_id: "attempt-after-restart", issue_state: "Done", terminal_observed_at: 1_789_084_800_000}
    candidate = %{candidate | issue_identifier: "MEM-42"}
    assert {:ok, _} = Kubernetes.put_intent(config, candidate, intent, opts)
    assert {:ok, [recovered]} = Kubernetes.discover(config, opts)
    assert recovered.pending == pending
    assert recovered.attempt_id == intent.attempt_id
    assert recovered.issue_identifier == "MEM-42"
    assert recovered.issue_state == "Done"
    assert recovered.terminal_observed_at == intent.terminal_observed_at
    assert recovered.desired == :stopped
    assert {:ok, ensured} = Kubernetes.ensure(config, record, opts)
    assert ensured.pending == recovered.pending
    assert ensured.attempt_id == recovered.attempt_id
    assert ensured.issue_identifier == recovered.issue_identifier
    assert ensured.issue_state == recovered.issue_state
    assert ensured.terminal_observed_at == recovered.terminal_observed_at
  end

  test "invalid durable operation enums prevent recovery instead of erasing uncertainty" do
    {config, record, opts} = api_fixture()
    {:ok, _} = Kubernetes.ensure(config, record, opts)
    parent = api_state()["sandboxes"][record.key]
    state = Jason.decode!(parent["metadata"]["annotations"]["symphony.dev/record"])
    state = Map.put(state, "pending", [%{"verb" => "unrecognized-provider-action", "id" => "unknown", "outcome" => "unknown"}])
    put_object("sandboxes", put_in(parent, ["metadata", "annotations", "symphony.dev/record"], Jason.encode!(state)))
    assert {:error, {:unknown, {:kubernetes_invalid_owned_record, resource_ids}}} = Kubernetes.discover(config, opts)
    assert record.key in resource_ids
    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = Kubernetes.ensure(config, record, opts)
  end

  test "an admitted unqualified WaitForFirstConsumer PVC cannot authorize first execution" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    pvc = api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    put_object("persistentvolumeclaims", put_in(pvc, ["spec"], %{"storageClassName" => "unqualified-default"}))
    Process.put(:kubernetes_api, Map.put(api_state(), "persistentvolumes", %{}))
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:error, {:invalid, :unqualified_kubernetes_pvc}, _} = Kubernetes.start(config, intended, opts)
    assert api_state()["pods"] == %{}
    assert api_state()["sandboxes"][record.key]["spec"]["operatingMode"] == "Suspended"
  end

  test "a bound PVC must still match its pinned template storage class" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    pvc = api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    put_object("persistentvolumeclaims", put_in(pvc, ["spec", "storageClassName"], "unqualified"))
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:error, {:invalid, :unqualified_kubernetes_pvc}, _} = Kubernetes.start(config, intended, opts)
    assert api_state()["pods"] == %{}
  end

  test "an owned PVC with an unexpected generated claim name cannot authorize execution" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    pvc = api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    remove_object("persistentvolumeclaims", "workspace-se-ticket")
    put_object("persistentvolumeclaims", put_in(pvc, ["metadata", "name"], "unexpected-se-ticket"))
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:error, {:invalid, :unqualified_kubernetes_pvc}, _} = Kubernetes.start(config, intended, opts)
    assert api_state()["pods"] == %{}
  end

  test "a foreign PVC occupying the generated claim name cannot authorize execution" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    pvc = api_state()["persistentvolumeclaims"]["workspace-se-ticket"]

    foreign =
      pvc
      |> put_in(["metadata", "labels", "symphony.dev/environment"], "another-environment")
      |> put_in(["metadata", "ownerReferences"], [%{"kind" => "Sandbox", "uid" => "foreign-parent"}])

    put_object("persistentvolumeclaims", foreign)
    {:ok, desired} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:error, {:unknown, :kubernetes_child_ownership_changed}, _} = Kubernetes.start(config, desired, opts)
    assert api_state()["pods"] == %{}
  end

  test "PVC admission changes after Running intent are revalidated before gate release" do
    {config, record, opts} = api_fixture(mutate_pvc_on_pod_creation: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, desired} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:error, {:invalid, :unqualified_kubernetes_pvc}, _} = Kubernetes.start(config, desired, opts)
    assert %{"name" => "symphony.dev/start-authorized"} in get_in(api_state(), ["pods", record.key, "spec", "schedulingGates"])
    refute get_in(api_state(), ["pods", record.key, "status", "phase"]) == "Running"
  end

  test "a matching staged client key cannot reuse a foreign SSH Secret before ungating" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, directory, lease} = Client.private_directory(opts)
    :ok = Client.write_private(Path.join(directory, "client"), "private-existing-key")
    :ok = Client.write_private(Path.join(directory, "client.pub"), "ssh-ed25519 existing\n")
    metadata = Map.merge(created.metadata, %{"client_key_directory" => directory, "client_key_lease" => lease})
    candidate = %{created | metadata: metadata}

    foreign = %{
      "metadata" => Map.put(meta(record.key <> "-ssh", "foreign-secret"), "ownerReferences", [%{"kind" => "Sandbox", "uid" => "foreign-parent"}]),
      "data" => %{"authorized_keys" => Base.encode64("ssh-ed25519 existing\n")}
    }

    put_object("secrets", foreign)
    {:ok, intended} = Kubernetes.put_intent(config, candidate, %{desired: :running}, opts)
    assert {:error, {:unknown, :kubernetes_child_ownership_changed}, _} = Kubernetes.start(config, intended, opts)
    assert api_state()["pods"] == %{}
    assert api_state()["sandboxes"][record.key]["spec"]["operatingMode"] == "Suspended"
    refute File.exists?(directory)
  end

  test "an admitted Pod missing the qualified network profile remains gated" do
    {config, record, opts} = api_fixture(strip_network_profile: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:error, {:unknown, :kubernetes_release_outcome}, _} = Kubernetes.start(config, intended, opts)
    pod = api_state()["pods"][record.key]
    assert Enum.any?(pod["spec"]["schedulingGates"], &(&1["name"] == "symphony.dev/start-authorized"))
    refute get_in(pod, ["status", "phase"]) == "Running"
  end

  test "a scaled-to-zero controller cannot pass preflight or create an environment" do
    {config, record, opts} = api_fixture()
    controller = api_state()["deployments"]["sandbox"] |> put_in(["spec", "replicas"], 0) |> put_in(["status", "availableReplicas"], 0)
    put_object("deployments", controller)
    assert {:error, {:invalid, :kubernetes_profile_not_qualified}} = Kubernetes.preflight(config, opts)
    assert {:error, {:invalid, :kubernetes_profile_not_qualified}, _} = Kubernetes.ensure(config, record, opts)
    assert api_state()["sandboxes"] == %{}
  end

  defp api_fixture(options \\ []) do
    config = %{
      provider: Map.merge(config().provider, %{"template" => "development", "ssh_user" => "worker", "ssh_port" => 2222, "ssh_auth_volume" => "ssh-auth"}),
      deployment_id: "deployment",
      tracker_kind: "memory",
      kind: "kubernetes"
    }

    record = %{record() | scope: SymphonyElixir.ExecutionEnvironment.Config.scope(config)}

    template = %{
      "metadata" => meta("development", "template-uid"),
      "spec" => %{
        "networkPolicyManagement" => "Unmanaged",
        "service" => true,
        "podTemplate" => %{
          "metadata" => %{"labels" => %{"profile" => "private"}},
          "spec" => %{
            "runtimeClassName" => "isolated",
            "containers" => [%{"name" => "worker", "image" => "qualified-worker", "volumeMounts" => [%{"name" => "ssh-auth", "mountPath" => "/ssh-auth", "readOnly" => true}]}],
            "volumes" => [%{"name" => "ssh-auth", "emptyDir" => %{}}],
            "schedulingGates" => [%{"name" => "operator.dev/approval"}]
          }
        },
        "volumeClaimTemplates" => [
          %{"metadata" => %{"name" => "workspace"}, "spec" => %{"storageClassName" => "private", "accessModes" => ["ReadWriteOnce"], "resources" => %{"requests" => %{"storage" => "1Gi"}}}}
        ]
      }
    }

    template = put_in(template, ["metadata", "annotations"], %{"symphony.dev/qualification" => "qualification"})
    image = "registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:" <> String.duplicate("a", 64)

    q = %{
      "release" => "v1.0.1",
      "template_uid" => "template-uid",
      "template_digest" => fixture_digest(template["spec"]),
      "qualification_report" => "operator-audit/test-profile",
      "termination_contract" => "qualified-kubelet-all-containers-v1",
      "controller_namespace" => "controllers",
      "controller_name" => "sandbox",
      "controller_uid" => "controller-uid",
      "controller_source_commit" => "3e77ccbac4db8a12b0157eafcad0d1ad5872f32a",
      "controller_image" => image,
      "runtime_class_uid" => "runtime-uid",
      "runtime_handler" => "qualified-vm",
      "storage_class_uids" => ["class-uid"],
      "csi_driver" => "qualified.csi",
      "network_policy_uid" => "policy-uid",
      "network_profile_label" => "profile"
    }

    schemas = __DIR__ |> Path.join("../fixtures/kubernetes_v1_0_1_schemas.json") |> File.read!() |> Jason.decode!()

    state = %{
      "sandboxtemplates" => %{"development" => template},
      "configmaps" => %{"qualification" => %{"metadata" => meta("qualification", "qualification-uid"), "immutable" => true, "data" => %{"contract.json" => Jason.encode!(q)}}},
      "customresourcedefinitions" => Map.new(schemas, &{&1["metadata"]["name"], &1}),
      "deployments" => %{
        "sandbox" => %{
          "metadata" => meta("sandbox", "controller-uid"),
          "spec" => %{"replicas" => 1, "template" => %{"spec" => %{"containers" => [%{"image" => image}]}}},
          "status" => %{"observedGeneration" => 1, "availableReplicas" => 1}
        }
      },
      "runtimeclasses" => %{"isolated" => %{"metadata" => meta("isolated", "runtime-uid"), "handler" => "qualified-vm"}},
      "storageclasses" => %{"private" => %{"metadata" => meta("private", "class-uid"), "reclaimPolicy" => "Delete", "provisioner" => "qualified.csi"}},
      "networkpolicies" => %{
        "private" => %{"metadata" => meta("private", "policy-uid"), "spec" => %{"podSelector" => %{"matchLabels" => %{"profile" => "private"}}, "policyTypes" => ["Ingress", "Egress"]}}
      },
      "sandboxes" => %{},
      "pods" => %{},
      "persistentvolumeclaims" => %{},
      "persistentvolumes" => %{},
      "secrets" => %{},
      "services" => %{}
    }

    Process.put(:kubernetes_api, state)
    Process.put(:kubernetes_options, options)
    Process.put(:kubernetes_events, %{})
    Process.put(:sandbox_creates, 0)
    supervisor = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))
    {config, record, [command_fun: &api_command/3, timeout_ms: 60_000, task_supervisor: supervisor, authority: self()]}
  end

  defp api_command(executable, args, _opts) do
    case Path.basename(executable) do
      "ssh-keygen" ->
        path = arg(args, "-f")
        on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
        File.write!(path, "private-test-key")
        File.chmod!(path, 0o600)
        File.write!(path <> ".pub", "ssh-ed25519 AAAAtest\n")
        {:ok, %{status: 0, output: ""}}

      "ssh" ->
        Process.put(:ssh_args, args)
        {:ok, %{status: if(option(:wrong_host), do: 255, else: 0), output: ""}}

      "kubectl" ->
        api_kubectl(args)
    end
  end

  defp api_kubectl(args) do
    cond do
      "patch" in args ->
        index = Enum.find_index(args, &(&1 == "patch"))
        resource = args |> Enum.at(index + 1) |> String.split(".") |> hd()
        name = Enum.at(args, index + 2)
        patch = args |> arg("--patch-file") |> File.read!() |> Jason.decode!()

        if resource == "pods" and option(:delay_release) and Enum.any?(patch, &(&1["op"] == "remove")) and Process.get(:delayed_release) == nil do
          Process.put(:delayed_release, {"/api/v1/namespaces/test/pods/" <> name, patch})
          {:error, {:unknown, :lost_patch_response}}
        else
          patch_object(resource, name, patch)
        end

      true ->
        path = arg(args, "--raw")
        uri = URI.parse(path)
        params = URI.decode_query(uri.query || "")
        parts = String.split(uri.path, "/", trim: true)
        resource = List.last(parts)

        cond do
          uri.path == "/version" ->
            json(%{"major" => "1", "minor" => "33"})

          params["watch"] == "true" ->
            watch_name = String.replace_prefix(params["fieldSelector"], "metadata.name=", "")
            events = Map.get(Process.get(:kubernetes_events), {resource, watch_name}, [])
            {:ok, %{status: 0, output: Enum.map_join(events, "\n", &Jason.encode!/1)}}

          "get" in args ->
            json(%{"metadata" => %{"resourceVersion" => "100"}, "items" => Map.values(Map.fetch!(api_state(), resource))})

          "create" in args ->
            body = args |> arg("-f") |> File.read!() |> Jason.decode!()
            create_object(resource, body)

          "delete" in args ->
            resource = Enum.at(parts, -2)
            body = args |> arg("-f") |> File.read!() |> Jason.decode!()
            delete_object(resource, List.last(parts), body)
        end
    end
  end

  defp create_object(resource, body) do
    name = body["metadata"]["name"]
    object = Map.put(body, "metadata", Map.merge(body["metadata"], meta(name, if(resource == "sandboxes", do: "sandbox-uid", else: "secret-uid"))))
    put_object(resource, object)

    if resource == "sandboxes" do
      Process.put(:sandbox_creates, Process.get(:sandbox_creates) + 1)
      object = suspend_status(object)
      put_object(resource, object)
      claim_template = hd(object["spec"]["volumeClaimTemplates"])
      pvc = %{"metadata" => Map.merge(claim_template["metadata"], child_meta(object, "workspace-" <> name, "pvc-uid")), "spec" => %{"storageClassName" => "private", "volumeName" => "pv-ticket"}}

      pv = %{
        "metadata" => Map.put(meta("pv-ticket", "pv-uid"), "finalizers", ["external-provisioner.volume.kubernetes.io/finalizer"]),
        "spec" => %{
          "claimRef" => %{"name" => pvc["metadata"]["name"], "namespace" => "test", "uid" => "pvc-uid"},
          "persistentVolumeReclaimPolicy" => "Delete",
          "csi" => %{"driver" => "qualified.csi", "volumeHandle" => "disk-ticket"}
        }
      }

      put_object("persistentvolumeclaims", pvc)
      put_object("persistentvolumes", pv)
      if option(:lost_create), do: {:error, {:unknown, :lost_create_response}}, else: json(object)
    else
      json(object)
    end
  end

  defp patch_object(resource, name, patch) do
    object = api_state()[resource][name]

    case apply_patch(object, patch) do
      {:ok, updated} ->
        updated = update_in(updated, ["metadata", "resourceVersion"], &Integer.to_string(String.to_integer(&1) + 1))
        put_object(resource, updated)

        cond do
          resource == "sandboxes" and get_in(updated, ["spec", "operatingMode"]) == "Running" and api_state()["pods"] == %{} ->
            pod = updated["spec"]["podTemplate"] |> Map.put("metadata", Map.merge(updated["spec"]["podTemplate"]["metadata"], child_meta(updated, name, "pod-uid")))
            pod = if option(:strip_network_profile), do: update_in(pod, ["metadata", "labels"], &Map.delete(&1, "profile")), else: pod
            put_object("pods", pod)

            if option(:mutate_pvc_on_pod_creation) do
              for pvc <- Map.values(api_state()["persistentvolumeclaims"]), do: put_object("persistentvolumeclaims", put_in(pvc, ["spec", "storageClassName"], "unqualified-admission"))
            end

          resource == "sandboxes" and get_in(updated, ["spec", "operatingMode"]) == "Suspended" ->
            put_object(resource, suspend_status(updated))

          resource == "pods" and not Enum.any?(get_in(updated, ["spec", "schedulingGates"]) || [], &(&1["name"] == "symphony.dev/start-authorized")) ->
            # The API script grants the operator's independent gate separately.
            if Enum.any?(patch, &(&1["op"] == "remove")), do: Process.put(:operator_gates_after_release, get_in(updated, ["spec", "schedulingGates"]))
            updated = put_in(updated, ["spec", "schedulingGates"], [])
            updated = Map.put(updated, "status", %{"phase" => "Running", "podIP" => "10.2.3.4", "conditions" => [%{"type" => "Ready", "status" => "True"}]})
            put_object(resource, updated)
            parent = api_state()["sandboxes"]["se-ticket"]
            put_object("sandboxes", Map.put(parent, "status", %{"conditions" => [%{"type" => "Ready", "status" => "True", "observedGeneration" => parent["metadata"]["generation"]}]}))

          true ->
            :ok
        end

        json(api_state()[resource][name])

      :conflict ->
        json(%{"kind" => "Status", "code" => 409})
    end
  end

  defp apply_patch(nil, _patch), do: :conflict

  defp apply_patch(object, patch) do
    Enum.reduce_while(patch, {:ok, object}, fn operation, {:ok, current} ->
      path = operation["path"] |> String.split("/", trim: true) |> Enum.map(&String.replace(String.replace(&1, "~1", "/"), "~0", "~"))

      case operation["op"] do
        "test" -> if at_path(current, path) == operation["value"], do: {:cont, {:ok, current}}, else: {:halt, :conflict}
        "add" -> {:cont, {:ok, set_path(current, path, operation["value"])}}
        "remove" -> {:cont, {:ok, remove_path(current, path)}}
      end
    end)
  end

  defp at_path(value, []), do: value
  defp at_path(value, [key | rest]) when is_list(value), do: at_path(Enum.at(value, String.to_integer(key)), rest)
  defp at_path(value, [key | rest]) when is_map(value), do: at_path(value[key], rest)
  defp at_path(_, _), do: nil
  defp set_path(map, [key], value), do: Map.put(map, key, value)
  defp set_path(map, [key | rest], value), do: Map.put(map, key, set_path(map[key] || %{}, rest, value))
  defp remove_path(list, [index]) when is_list(list), do: List.delete_at(list, String.to_integer(index))
  defp remove_path(map, [key | rest]), do: Map.put(map, key, remove_path(map[key], rest))

  defp delete_object(resource, name, body) do
    object = api_state()[resource][name]

    if object == nil or body["preconditions"] != Map.take(object["metadata"], ["uid", "resourceVersion"]) do
      json(%{"kind" => "Status", "code" => 409})
    else
      cond do
        resource == "sandboxes" ->
          put_object(resource, put_in(object, ["metadata", "deletionTimestamp"], "2026-09-11T00:00:00Z"))

        resource == "pods" ->
          if not option(:missing_termination) do
            terminal =
              object
              |> put_in(["metadata", "managedFields"], [%{"manager" => "kubelet", "subresource" => "status"}])
              |> Map.put("status", %{
                "phase" => "Succeeded",
                "containerStatuses" => [%{"name" => "worker", "state" => %{"terminated" => %{"finishedAt" => "2026-09-11T00:00:00Z", "containerID" => "containerd://worker", "reason" => "Completed"}}}]
              })

            put_event(resource, name, %{"type" => "MODIFIED", "object" => terminal})
          end

          remove_object(resource, name)

        resource == "persistentvolumeclaims" ->
          remove_object(resource, name)

          if not option(:delay_pv) do
            pv = api_state()["persistentvolumes"]["pv-ticket"]
            put_event("persistentvolumes", "pv-ticket", %{"type" => "DELETED", "object" => put_in(pv, ["metadata", "finalizers"], [])})
            remove_object("persistentvolumes", "pv-ticket")
          end

        true ->
          remove_object(resource, name)
      end

      json(%{"kind" => "Status", "code" => 200})
    end
  end

  defp suspend_status(object), do: Map.put(object, "status", %{"conditions" => [%{"type" => "Suspended", "status" => "True", "observedGeneration" => object["metadata"]["generation"]}]})

  defp child_meta(parent, name, uid),
    do:
      Map.put(meta(name, uid), "ownerReferences", [
        %{"apiVersion" => "agents.x-k8s.io/v1beta1", "kind" => "Sandbox", "uid" => parent["metadata"]["uid"], "name" => parent["metadata"]["name"], "controller" => true}
      ])

  defp meta(name, uid), do: %{"name" => name, "uid" => uid, "resourceVersion" => "1", "generation" => 1, "namespace" => "test"}
  defp put_object(resource, object), do: Process.put(:kubernetes_api, put_in(api_state(), [resource, object["metadata"]["name"]], object))
  defp remove_object(resource, name), do: Process.put(:kubernetes_api, Map.update!(api_state(), resource, &Map.delete(&1, name)))
  defp put_event(resource, name, event), do: Process.put(:kubernetes_events, Map.update(Process.get(:kubernetes_events), {resource, name}, [event], &(&1 ++ [event])))
  defp api_state, do: Process.get(:kubernetes_api)
  defp option(key), do: Keyword.get(Process.get(:kubernetes_options), key, false)
  defp arg(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)
  defp json(body), do: {:ok, %{status: 0, output: Jason.encode!(body)}}
  defp fixture_digest(value), do: :crypto.hash(:sha256, Jason.encode!(canonical_fixture(value))) |> Base.encode16(case: :lower) |> binary_part(0, 40)
  defp canonical_fixture(map) when is_map(map), do: map |> Enum.map(fn {key, value} -> [key, canonical_fixture(value)] end) |> Enum.sort()
  defp canonical_fixture(list) when is_list(list), do: Enum.map(list, &canonical_fixture/1)
  defp canonical_fixture(value), do: value

  defp config, do: %{provider: %{"kubeconfig" => __ENV__.file, "context" => "test", "namespace" => "test"}}

  defp record(metadata \\ %{}) do
    %Record{
      key: "se-ticket",
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "kubernetes",
      scope: %{},
      workspace_path: "/state/workspaces/se-ticket",
      template_identity: "template-v1",
      metadata: metadata
    }
  end

  defp sandbox do
    %{
      "metadata" => %{"uid" => "sandbox-uid", "generation" => 2},
      "spec" => %{"operatingMode" => "Suspended", "podTemplate" => %{"spec" => %{"schedulingGates" => [%{"name" => "symphony.dev/start-authorized"}]}}},
      "status" => %{"conditions" => [%{"type" => "Suspended", "status" => "True", "observedGeneration" => 2}]}
    }
  end
end
