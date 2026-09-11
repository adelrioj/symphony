defmodule SymphonyElixir.KubernetesEnvironmentTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecutionEnvironment.{Config, Kubernetes, Operations, Record}
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

    opts = [command_fun: command, timeout_ms: 1_000, task_supervisor: supervisor, authority: self()]
    assert {:ok, %{status: 409}} = Client.request(config(), :patch, "/api/v1/namespaces/test/pods/ticket", patch, opts)

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
    result = Kubernetes.destroy(config, created, opts)
    assert {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}, deleting} = result
    assert get_in(deleting.metadata, ["volumes", "workspace-se-ticket", "deleted"]) == true
    refute deleting.absent?
    parent = api_state()["sandboxes"][record.key]
    assert parent["metadata"]["deletionTimestamp"] != nil
    assert "symphony.dev/environment-cleanup" in parent["metadata"]["finalizers"]
  end

  test "delayed PV deletion never becomes disk absence" do
    {config, record, opts} = api_fixture(delay_pv: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    result = Kubernetes.destroy(config, created, opts)
    assert {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}, deleting} = result
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
    assert :ok = Operations.close_connection(connection)
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

  test "definitively denied initial create releases compute and supports ordinary stop intent and retry" do
    {config, record, opts} = api_fixture(deny_create: true)
    assert {:error, {:denied, :kubernetes_api}, denied} = Kubernetes.ensure(config, record, opts)
    assert {:quiescent, _} = denied.proof
    assert denied.absent?
    assert {:ok, stopped} = Kubernetes.stop(config, denied, opts)
    assert {:quiescent, _} = stopped.proof
    assert {:ok, inspected} = Kubernetes.inspect(config, stopped, opts)
    assert inspected.absent?
    assert {:ok, intended} = Kubernetes.put_intent(config, inspected, %{desired: :running}, opts)
    assert {:ok, []} = Kubernetes.discover(config, opts)
    Process.put(:kubernetes_options, [])
    assert {:ok, created} = Kubernetes.ensure(config, intended, opts)
    assert {:ok, started} = Kubernetes.start(config, created, opts)
    assert started.provider_ref == "sandbox-uid"
    assert get_in(api_state(), ["pods", record.key, "status", "phase"]) == "Running"
  end

  test "denied initial create never erases earlier ambiguous mutation evidence" do
    {config, record, opts} = api_fixture(deny_create: true)
    prior = %{verb: :create, id: "earlier-request", outcome: :unknown}
    assert {:error, _, unresolved} = Kubernetes.ensure(config, %{record | pending: [prior]}, opts)
    assert unresolved.proof == :unknown
    refute unresolved.absent?
    assert prior in unresolved.pending
    assert {:error, _, still_unresolved} = Kubernetes.stop(config, unresolved, opts)
    assert still_unresolved.proof == :unknown
  end

  test "denied create with incomplete post-denial inventory retains the reservation" do
    {config, record, opts} = api_fixture(deny_create: true, deny_post_create_inventory: true)
    assert {:error, {:denied, :kubernetes_api}, denied} = Kubernetes.ensure(config, record, opts)
    assert denied.proof == :unknown
    refute denied.absent?
    assert {:error, _, unresolved} = Kubernetes.inspect(config, denied, opts)
    assert unresolved.proof == :unknown
    Process.put(:kubernetes_options, [])
    assert {:ok, stopped} = Kubernetes.stop(config, unresolved, opts)
    assert {:quiescent, _} = stopped.proof
  end

  test "denied create tracks a remaining owned artifact without inventing parent absence" do
    {config, record, opts} = api_fixture(deny_create: true, denied_artifact: true)
    assert {:error, {:denied, :kubernetes_api}, denied} = Kubernetes.ensure(config, record, opts)
    assert denied.proof == :unknown
    refute denied.absent?
    assert %{"name" => "partial-secret", "uid" => "partial-secret-uid"} in denied.metadata["cleanup_remaining"]["secrets"]
    assert {:ok, [orphan]} = Kubernetes.discover(config, opts)
    assert orphan.proof == :unknown
    assert {:error, _, _} = Kubernetes.ensure(config, orphan, opts)
    assert api_state()["secrets"]["partial-secret"] != nil
  end

  test "unaccepted transport timeout is not absence evidence even with empty inventory" do
    {config, record, opts} = api_fixture(timeout_create: true)
    assert {:error, {:unknown, :kubernetes_create_outcome}, unresolved} = Kubernetes.ensure(config, record, opts)
    assert unresolved.proof == :unknown
    refute unresolved.absent?
    assert {:error, _, stopped} = Kubernetes.stop(config, unresolved, opts)
    assert stopped.proof == :unknown
  end

  test "client rejects duplicate identities and malformed complete inventory" do
    duplicate = %{"metadata" => %{"name" => "same"}}
    opts = [command_fun: fn _, _, _ -> json(%{"metadata" => %{}, "items" => [duplicate, duplicate]}) end]
    assert {:error, {:unknown, :duplicate_kubernetes_identity}} = Client.lookup(config(), "/pods", "same", opts)
    malformed = [command_fun: fn _, _, _ -> json(%{"metadata" => %{}, "items" => ["not-an-object"]}) end]
    assert {:error, {:unknown, :kubernetes_incomplete_inventory}} = Client.list(config(), "/pods", malformed)
    missing = [command_fun: fn _, _, _ -> json(%{"items" => []}) end]
    assert {:error, {:unknown, :kubernetes_incomplete_inventory}} = Client.list(config(), "/pods", missing)
  end

  test "client pagination refuses repeated tokens and discards partial transport history" do
    loop = [command_fun: fn _, _, _ -> json(%{"metadata" => %{"continue" => "again"}, "items" => []}) end]
    assert {:error, {:unknown, :kubernetes_continuation_loop}} = Client.list(config(), "/pods", loop)
    Process.put(:inventory_step, 0)

    command = fn _, _, _ ->
      step = Process.get(:inventory_step)
      Process.put(:inventory_step, step + 1)

      case step do
        0 -> json(%{"metadata" => %{"continue" => "stale"}, "items" => [%{"name" => "stale"}]})
        1 -> {:error, :timeout}
        2 -> json(%{"metadata" => %{}, "items" => [%{"name" => "current"}]})
      end
    end

    assert {:ok, [%{"name" => "current"}]} = Client.list(config(), "/pods", command_fun: command)
  end

  test "client fails closed on credentials paths expired budgets and malformed command results" do
    never = fn _, _, _ -> flunk("invalid request reached kubectl") end
    assert {:error, {:invalid, :kubernetes_credentials}} = Client.list(%{provider: %{}}, "/pods", command_fun: never)

    assert {:error, {:unknown, :kubernetes_deadline_or_path}} =
             Client.list(config(), "/pods", command_fun: never, timeout_ms: 0)

    assert {:error, {:unknown, :kubernetes_deadline_or_path}} =
             Client.request(config(), :get, "relative", nil, command_fun: never)

    broken = fn _, _, _ -> raise "malformed transport" end
    assert {:error, {:unknown, :kubernetes_command_failed}} = Client.list(config(), "/pods", command_fun: broken)

    assert {:error, {:unknown, :kubernetes_command_failed}} =
             Client.request(config(), :patch, "/not/a/patch/path", nil, command_fun: never)

    assert {:error, {:unknown, :kubernetes_command_failed}} =
             Client.request(config(), :unsupported, "/pods", nil, command_fun: never)
  end

  test "watch denial malformed events and expired history never produce termination evidence" do
    denied = [
      command_fun: fn _, _, _ ->
        {:ok, %{status: 1, output: Jason.encode!(%{"kind" => "Status", "code" => 403})}}
      end
    ]

    assert {:error, {:denied, :kubernetes_watch}} = Client.watch(config(), "/pods", "p", "1", denied)
    malformed = [command_fun: fn _, _, _ -> {:ok, %{status: 0, output: "not-json"}} end]
    assert {:error, {:unknown, :kubernetes_watch_history_lost}} = Client.watch(config(), "/pods", "p", "1", malformed)

    expired = [
      command_fun: fn _, _, _ ->
        {:ok, %{status: 1, output: Jason.encode!(%{"kind" => "Status", "code" => 410})}}
      end
    ]

    assert {:error, {:unknown, :kubernetes_watch_history_lost}} = Client.watch(config(), "/pods", "p", "1", expired)
    assert {:error, {:unknown, :watch_deadline_or_history_missing}} = Client.watch(config(), "/pods", "p", "0", [])
  end

  test "stop cannot accept incomplete all-container kubelet evidence" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    pod = api_state()["pods"][record.key]
    pod = put_in(pod, ["spec", "initContainers"], [%{"name" => "init"}])
    put_object("pods", pod)
    assert {:ok, stopped} = Kubernetes.stop(config, started, opts)
    assert stopped.proof == :unknown
    refute stopped.phase == :stopped
  end

  test "stale intent and cancelled start cannot mutate the execution gate" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:ok, _} = Kubernetes.put_intent(config, created, %{desired: :stopped}, opts)

    assert {:error, {:retryable, :kubernetes_cas_conflict}, _} =
             Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    assert {:error, {:unknown, :kubernetes_start_cancelled}, _} = Kubernetes.start(config, created, opts)
    assert api_state()["pods"] == %{}
  end

  test "credential rotation after local key loss retains pinned host identity" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    host = api_state()["secrets"][record.key <> "-ssh"]["data"]["ssh_host_ed25519_key.pub"]
    {:ok, stopped} = Kubernetes.stop(config, started, opts)
    {:ok, intended} = Kubernetes.put_intent(config, stopped, %{desired: :running}, opts)
    assert {:ok, resumed} = Kubernetes.start(config, intended, opts)
    assert resumed.provider_ref == started.provider_ref
    assert api_state()["secrets"][record.key <> "-ssh"]["data"]["ssh_host_ed25519_key.pub"] == host
  end

  test "repeated definitive denial remains recoverable and never-created destroy needs no controller barrier" do
    {config, record, opts} = api_fixture(deny_create: true)
    {:error, {:denied, _}, denied} = Kubernetes.ensure(config, record, opts)
    {:ok, stopped} = Kubernetes.stop(config, denied, opts)
    {:ok, intended} = Kubernetes.put_intent(config, stopped, %{desired: :running}, opts)
    assert {:error, {:denied, _}, denied_again} = Kubernetes.ensure(config, intended, opts)
    assert {:quiescent, _} = denied_again.proof
    assert {:ok, absent} = Kubernetes.destroy(config, denied_again, opts)
    assert absent.absent?
    assert absent.desired == :absent
    Process.put(:kubernetes_options, [])
    assert {:ok, fresh} = Kubernetes.ensure(config, record, opts)
    assert fresh.provider_ref == "sandbox-uid"
    refute fresh.absent?
  end

  test "observed post-denial artifacts and backing references cannot disappear into an absence proof" do
    {config, record, opts} = api_fixture(deny_create: true, denied_artifact: true)
    {:error, {:denied, _}, denied} = Kubernetes.ensure(config, record, opts)
    remove_object("secrets", "partial-secret")
    assert {:error, _, unresolved} = Kubernetes.inspect(config, denied, opts)
    assert unresolved.proof == :unknown
    refute unresolved.absent?
    assert %{"name" => "partial-secret", "uid" => "partial-secret-uid"} in unresolved.metadata["cleanup_remaining"]["secrets"]
    pv = %{"metadata" => meta("orphan-pv", "orphan-pv-uid"), "spec" => %{"claimRef" => %{"name" => "workspace-" <> record.key, "namespace" => "test"}}}
    put_object("persistentvolumes", pv)
    assert {:error, _, captured} = Kubernetes.inspect(config, denied, opts)
    assert %{"name" => "orphan-pv", "uid" => "orphan-pv-uid"} in captured.metadata["cleanup_remaining"]["persistentvolumes"]
  end

  test "a lost parent never permits stale absence or connection readiness" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:error, {:unknown, _}} = Kubernetes.connect(config, created, opts)
    Process.put(:kubernetes_api, Map.put(api_state(), "sandboxes", %{}))
    assert {:error, {:unknown, :kubernetes_parent_missing}, unresolved} = Kubernetes.inspect(config, created, opts)
    assert unresolved.proof == :unknown
    assert {:error, {:unknown, _}} = Kubernetes.connect(config, created, opts)
    refute unresolved.absent?
  end

  test "network expressions are enforced conjunctively before creation" do
    {config, record, opts} = api_fixture()
    policy = api_state()["networkpolicies"]["private"]

    expressions = [
      %{"key" => "profile", "operator" => "In", "values" => ["private"]},
      %{"key" => "profile", "operator" => "NotIn", "values" => ["public"]},
      %{"key" => "profile", "operator" => "Exists"},
      %{"key" => "forbidden", "operator" => "DoesNotExist"}
    ]

    policy = put_in(policy, ["spec", "podSelector", "matchExpressions"], expressions)
    put_object("networkpolicies", policy)
    assert :ok = Kubernetes.preflight(config, opts)
    invalid = expressions ++ [%{"key" => "profile", "operator" => "Unrecognized"}]
    put_object("networkpolicies", put_in(policy, ["spec", "podSelector", "matchExpressions"], invalid))
    assert {:error, {:invalid, :kubernetes_profile_not_qualified}, _} = Kubernetes.ensure(config, record, opts)
    assert api_state()["sandboxes"] == %{}
  end

  test "invalid versions and corrupt qualification contracts cannot allocate compute" do
    {config, record, opts} = api_fixture()

    for version <- [%{"major" => "2", "minor" => "1"}, %{"major" => "1", "minor" => "invalid"}] do
      command = fn exe, args, options ->
        if "--raw" in args and arg(args, "--raw") == "/version", do: json(version), else: api_command(exe, args, options)
      end

      assert {:error, {:invalid, :kubernetes_profile_not_qualified}, _} =
               Kubernetes.ensure(config, record, Keyword.put(opts, :command_fun, command))
    end

    cm = api_state()["configmaps"]["qualification"]
    put_object("configmaps", put_in(cm, ["data", "contract.json"], "[]"))
    assert {:error, {:invalid, :kubernetes_profile_not_qualified}} = Kubernetes.preflight(config, opts)
    assert {:error, {:invalid, :kubernetes_configuration}} = Kubernetes.validate_config(nil)
    assert api_state()["sandboxes"] == %{}
  end

  test "multiple admitted Pods cannot release any execution gate" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      response = api_command(exe, args, options)
      duplicate_live_pod()
      response
    end

    assert {:error, {:retryable, :kubernetes_waiting_for_gated_pod}, _} =
             Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))

    assert Enum.all?(Map.values(api_state()["pods"]), fn pod ->
             %{"name" => "symphony.dev/start-authorized"} in pod["spec"]["schedulingGates"]
           end)
  end

  test "existing running credentials reconnect without authorizing a released UID twice" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    assert {:ok, observed} = Kubernetes.start(config, started, opts)
    assert observed.phase == :running
    assert observed.metadata["authorized_pod_uids"] == ["pod-uid"]
    assert {:ok, stopped} = Kubernetes.stop(config, observed, opts)
    assert {:quiescent, _} = stopped.proof
  end

  test "missing host key cannot be silently rotated after retained credentials lose their local key" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    {:ok, stopped} = Kubernetes.stop(config, started, opts)
    secret = api_state()["secrets"][record.key <> "-ssh"]
    put_object("secrets", update_in(secret, ["data"], &Map.delete(&1, "ssh_host_ed25519_key.pub")))
    {:ok, intended} = Kubernetes.put_intent(config, stopped, %{desired: :running}, opts)
    assert {:error, {:unknown, :kubernetes_credentials_outcome}, failed} = Kubernetes.start(config, intended, opts)
    refute Map.has_key?(failed.metadata, "client_key_lease")
    assert api_state()["pods"] == %{}
  end

  test "a running environment without its private client key cannot rotate credentials in place" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    File.rm_rf!(started.metadata["client_key_directory"])
    assert {:error, {:unknown, :client_key_rotation_requires_stop}, _} = Kubernetes.start(config, started, opts)
    assert {:ok, stopped} = Kubernetes.stop(config, started, opts)
    assert {:quiescent, _} = stopped.proof
  end

  test "watch transport loss never certifies compute or disk deletion" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)

    command = fn exe, args, options ->
      if watch_request?(args), do: {:error, :timeout}, else: api_command(exe, args, options)
    end

    blocked_opts = Keyword.put(opts, :command_fun, command)
    assert {:ok, unresolved} = Kubernetes.stop(config, started, blocked_opts)
    assert unresolved.proof == :unknown
    assert {:error, {:unknown, :kubernetes_cleanup_pending}, _} = Kubernetes.destroy(config, unresolved, blocked_opts)
    assert {:ok, stopped} = Kubernetes.inspect(config, unresolved, opts)
    assert {:quiescent, _} = stopped.proof

    assert {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}, deleting} =
             Kubernetes.destroy(config, stopped, blocked_opts)

    refute get_in(deleting.metadata, ["volumes", "workspace-se-ticket", "deleted"]) == true
  end

  test "private reachability accepts private IPv4 and ULA but rejects public malformed and missing addresses" do
    for address <- ["172.16.1.2", "192.168.1.2", "fd00::1", "8.8.8.8", "not-an-address", nil] do
      {config, record, opts} = api_fixture()
      {:ok, created} = Kubernetes.ensure(config, record, opts)
      {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
      {:ok, started} = Kubernetes.start(config, intended, opts)
      pod = api_state()["pods"][record.key]
      put_object("pods", put_in(pod, ["status", "podIP"], address))
      assert_address_connection(config, started, opts, address)
    end
  end

  defp assert_address_connection(config, record, opts, address) when address in ["172.16.1.2", "192.168.1.2", "fd00::1"] do
    assert {:ok, connection} = Kubernetes.connect(config, record, opts)
    assert :ok = Operations.close_connection(connection)
  end

  defp assert_address_connection(config, record, opts, _address) do
    assert {:error, {:unknown, :kubernetes_ssh_authentication_failed}} = Kubernetes.connect(config, record, opts)
  end

  test "a delayed first Pod is authorized only after observation and fresh intent checks" do
    {config, record, opts} = api_fixture(delay_pod: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    sleep = fn _ ->
      Process.put(:kubernetes_options, [])
      create_pod(api_state()["sandboxes"][record.key])
    end

    assert {:ok, started} = Kubernetes.start(config, intended, Keyword.put(opts, :sleep_fun, sleep))
    assert started.metadata["authorized_pod_uids"] == ["pod-uid"]
    assert get_in(api_state(), ["pods", record.key, "status", "phase"]) == "Running"
  end

  test "cancellation after credentials or after Running CAS never ungates a Pod" do
    for boundary <- [:credentials, :running] do
      {config, record, opts} = api_fixture()
      {:ok, created} = Kubernetes.ensure(config, record, opts)
      {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

      command = fn exe, args, options ->
        response = api_command(exe, args, options)
        cancel_at_boundary(args, boundary)
        response
      end

      assert {:error, {:unknown, :kubernetes_start_cancelled}, _} =
               Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))

      refute Enum.any?(Map.values(api_state()["pods"]), &(get_in(&1, ["status", "phase"]) == "Running"))
    end
  end

  test "a missing expected PVC cannot be replaced by ungating the first Pod" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    remove_object("persistentvolumeclaims", "workspace-se-ticket")
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    assert {:error, {:retryable, :kubernetes_waiting_for_qualified_claims}, _} =
             Kubernetes.start(config, intended, opts)

    assert %{"name" => "symphony.dev/start-authorized"} in get_in(api_state(), ["pods", record.key, "spec", "schedulingGates"])
  end

  test "bound disk identity and CSI finalizer remain mandatory after stop" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, captured} = Kubernetes.inspect(config, created, opts)
    pv = api_state()["persistentvolumes"]["pv-ticket"]
    remove_object("persistentvolumes", "pv-ticket")
    assert {:error, {:unknown, :bound_pv_missing}, _} = Kubernetes.inspect(config, captured, opts)
    put_object("persistentvolumes", put_in(pv, ["metadata", "uid"], "replacement-pv"))
    assert {:error, {:unknown, :retained_pv_replaced}, _} = Kubernetes.inspect(config, captured, opts)
    put_object("persistentvolumes", put_in(pv, ["metadata", "finalizers"], []))
    assert {:error, {:unknown, :csi_deletion_evidence_unavailable}, _} = Kubernetes.inspect(config, captured, opts)
    assert api_state()["pods"] == %{}
  end

  test "metadata write denial leaves intent unresolved instead of reporting success" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    command = fn exe, args, options ->
      if "patch" in args, do: json(%{"kind" => "Status", "code" => 403}), else: api_command(exe, args, options)
    end

    assert {:error, {:denied, :kubernetes_api}, denied} =
             Kubernetes.put_intent(config, created, %{desired: :running}, Keyword.put(opts, :command_fun, command))

    assert denied.proof == :unknown
    assert api_state()["sandboxes"][record.key]["spec"]["operatingMode"] == "Suspended"
  end

  test "non-list durable operation state blocks discovery and execution" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    parent = api_state()["sandboxes"][record.key]
    durable = Jason.decode!(parent["metadata"]["annotations"]["symphony.dev/record"])
    parent = put_in(parent, ["metadata", "annotations", "symphony.dev/record"], Jason.encode!(%{durable | "pending" => %{}}))
    put_object("sandboxes", parent)
    assert {:error, {:unknown, {:kubernetes_invalid_owned_record, _}}} = Kubernetes.discover(config, opts)
    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = Kubernetes.start(config, created, opts)
    assert api_state()["pods"] == %{}
  end

  defp cancel_at_boundary(args, :credentials) do
    if "create" in args and String.contains?(arg(args, "--raw"), "/secrets"), do: cancel_saved_intent()
  end

  defp cancel_at_boundary(args, :running) do
    if "patch" in args and get_in(api_state(), ["sandboxes", "se-ticket", "spec", "operatingMode"]) == "Running",
      do: cancel_saved_intent()
  end

  defp cancel_saved_intent do
    sandbox = api_state()["sandboxes"]["se-ticket"]
    saved = Jason.decode!(sandbox["metadata"]["annotations"]["symphony.dev/record"])
    sandbox = put_in(sandbox, ["metadata", "annotations", "symphony.dev/record"], Jason.encode!(%{saved | "desired" => "stopped"}))
    put_object("sandboxes", sandbox)
  end

  defp duplicate_live_pod do
    case api_state()["pods"]["se-ticket"] do
      nil ->
        :ok

      pod ->
        metadata = Map.merge(pod["metadata"], %{"name" => "duplicate", "uid" => "duplicate-uid"})
        put_object("pods", Map.put(pod, "metadata", metadata))
    end
  end

  defp watch_request?(args) do
    "--raw" in args and String.contains?(arg(args, "--raw"), "watch=true")
  end

  test "private directory creation failure releases its owned staging process" do
    root = Path.join(System.tmp_dir!(), "kubernetes-no-traverse-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o600)
    previous = System.get_env("TMPDIR")
    supervisor = start_supervised!(Task.Supervisor)
    System.put_env("TMPDIR", root)

    try do
      assert {:error, _} = Client.private_directory(task_supervisor: supervisor, authority: self())
      await_staging_release(supervisor)
    after
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
      File.chmod!(root, 0o700)
      File.rm_rf!(root)
    end
  end

  defp await_staging_release(supervisor) do
    for owner <- Task.Supervisor.children(supervisor) do
      ref = Process.monitor(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}
    end
  end

  test "changed parent ownership blocks discovery inspect intent stop and destroy" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    parent = api_state()["sandboxes"][record.key]
    put_object("sandboxes", put_in(parent, ["metadata", "labels", "symphony.dev/environment"], "foreign"))
    assert {:error, {:unknown, :kubernetes_ownership_changed}} = Kubernetes.discover(config, opts)
    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = Kubernetes.inspect(config, created, opts)

    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} =
             Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = Kubernetes.stop(config, created, opts)
    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = Kubernetes.destroy(config, created, opts)
    assert api_state()["pods"] == %{}
  end

  test "missing SSH Secret prevents a connection even for otherwise running compute" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    remove_object("secrets", record.key <> "-ssh")
    assert {:error, {:unknown, _}} = Kubernetes.connect(config, started, opts)
    refute File.exists?(started.metadata["client_key_directory"])
    refute Process.get(:ssh_args)
  end

  test "create rejection cannot prove absence when a parent or owner-only Service appears concurrently" do
    {config, record, opts} = api_fixture(deny_create: true)

    command = fn exe, args, options ->
      response = api_command(exe, args, options)
      concurrent_denial_artifacts(args, record)
      response
    end

    assert {:error, {:denied, _}, denied} =
             Kubernetes.ensure(config, record, Keyword.put(opts, :command_fun, command))

    assert denied.proof == :unknown
    refute denied.absent?
    assert %{"name" => record.key, "uid" => "concurrent-parent"} in denied.metadata["cleanup_remaining"]["sandboxes"]
    assert %{"name" => "owner-only", "uid" => "owner-service"} in denied.metadata["cleanup_remaining"]["services"]
  end

  test "storage-free templates and missing selected network policies are not qualified" do
    {config, record, opts} = api_fixture()
    template = api_state()["sandboxtemplates"]["development"]
    qualify_template(put_in(template, ["spec", "volumeClaimTemplates"], []))
    assert {:error, {:invalid, :kubernetes_storage_not_qualified}, _} = Kubernetes.ensure(config, record, opts)
    qualify_template(template)
    remove_object("networkpolicies", "private")
    assert {:error, {:invalid, :kubernetes_profile_not_qualified}} = Kubernetes.preflight(config, opts)
    assert api_state()["sandboxes"] == %{}
  end

  test "additional safe template volumes retain qualified execution while network profile mismatch blocks it" do
    {config, record, opts} = api_fixture()
    template = api_state()["sandboxtemplates"]["development"]
    qualify_template(update_in(template, ["spec", "podTemplate", "spec", "volumes"], &(&1 ++ [%{"name" => "scratch", "emptyDir" => %{}}])))
    policy = api_state()["networkpolicies"]["private"]
    put_object("networkpolicies", put_in(policy, ["spec", "podSelector", "matchLabels", "profile"], "wrong"))
    assert {:error, {:invalid, :kubernetes_profile_not_qualified}} = Kubernetes.preflight(config, opts)
    put_object("networkpolicies", policy)
    assert {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:ok, started} = Kubernetes.start(config, intended, opts)
    assert {:ok, stopped} = Kubernetes.stop(config, started, opts)
    assert {:quiescent, _} = stopped.proof
  end

  test "startup deadline never authorizes an unobserved first Pod" do
    {config, record, opts} = api_fixture(delay_pod: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    deadline = System.monotonic_time(:millisecond) + 1_000
    sleep = fn _ -> Process.sleep(max(0, deadline - System.monotonic_time(:millisecond)) + 1) end
    opts = Keyword.merge(opts, deadline: deadline, sleep_fun: sleep)
    assert {:error, {:unknown, :kubernetes_pod_creation_pending}, unresolved} = Kubernetes.start(config, intended, opts)
    assert unresolved.proof == :unknown
    assert api_state()["pods"] == %{}
  end

  test "parent loss after credential creation cannot issue Running intent" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      response = api_command(exe, args, options)

      if "create" in args and String.contains?(arg(args, "--raw"), "/secrets"),
        do: remove_object("sandboxes", record.key)

      response
    end

    assert {:error, {:unknown, _}, unresolved} =
             Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))

    refute unresolved.phase == :running
    assert api_state()["pods"] == %{}
    refute Map.has_key?(unresolved.metadata, "client_key_directory")
  end

  test "unavailable stop qualification preserves running uncertainty" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)

    command = fn exe, args, options ->
      denied = "get" in args and arg(args, "--raw") == "/version"
      if denied, do: json(%{"kind" => "Status", "code" => 403}), else: api_command(exe, args, options)
    end

    assert {:error, _failure, unresolved} =
             Kubernetes.stop(config, started, Keyword.put(opts, :command_fun, command))

    assert unresolved.proof == :unknown
    assert get_in(api_state(), ["pods", record.key, "status", "phase"]) == "Running"
  end

  test "lost parent observation after Running CAS forbids gate release" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      if running_parent_read?(args), do: {:error, :timeout}, else: api_command(exe, args, options)
    end

    assert {:error, {:unknown, _}, _} = Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))
    assert %{"name" => "symphony.dev/start-authorized"} in get_in(api_state(), ["pods", record.key, "spec", "schedulingGates"])
  end

  test "a foreign admitted Pod is refused before its first release" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      response = api_command(exe, args, options)
      foreign_live_pod()
      response
    end

    assert {:error, {:unknown, :kubernetes_child_ownership_changed}, _} =
             Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))

    refute Enum.any?(Map.values(api_state()["pods"]), &(get_in(&1, ["status", "phase"]) == "Running"))
  end

  test "reintroducing a scheduling gate never permits a second release of an authorized UID" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    pod = api_state()["pods"][record.key]
    put_object("pods", put_in(pod, ["spec", "schedulingGates"], [%{"name" => "symphony.dev/start-authorized"}]))
    assert {:error, {:unknown, :kubernetes_release_already_recorded}, _} = Kubernetes.start(config, started, opts)

    assert get_in(api_state(), ["pods", record.key, "spec", "schedulingGates"]) ==
             [%{"name" => "symphony.dev/start-authorized"}]
  end

  test "stop fence denial retains physical uncertainty and does not delete running Pods" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)

    command = fn exe, args, options ->
      if "patch" in args and arg(args, "patch") == "pods", do: json(%{"kind" => "Status", "code" => 403}), else: api_command(exe, args, options)
    end

    assert {:error, {:denied, _}, unresolved} = Kubernetes.stop(config, started, Keyword.put(opts, :command_fun, command))
    assert unresolved.proof == :unknown
    assert get_in(api_state(), ["pods", record.key, "status", "phase"]) == "Running"
  end

  test "foreign PV claim binding is not backing storage evidence" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    pv = api_state()["persistentvolumes"]["pv-ticket"]
    put_object("persistentvolumes", put_in(pv, ["spec", "claimRef", "uid"], "another-claim"))
    assert {:error, {:unknown, :csi_deletion_evidence_unavailable}, _} = Kubernetes.inspect(config, created, opts)
    assert api_state()["pods"] == %{}
  end

  test "late gated children are safely deleted but still do not settle controller ordering" do
    {config, record, opts} = api_fixture(late_cleanup_pod: :gated)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    result = Kubernetes.destroy(config, created, opts)
    assert {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}, deleting} = result
    assert api_state()["pods"] == %{}
    refute deleting.absent?
    Process.put(:kubernetes_options, [])
    result = Kubernetes.destroy(config, deleting, opts)
    assert {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}, retained} = result
    assert retained.metadata["volumes"]["workspace-se-ticket"]["deleted"]
    refute retained.absent?
  end

  test "late ungated children block destructive cleanup without physical termination evidence" do
    {config, record, opts} = api_fixture(late_cleanup_pod: :ungated)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:error, {:unknown, :kubernetes_child_termination_unresolved}, _} = Kubernetes.destroy(config, created, opts)
    assert api_state()["pods"][record.key] != nil
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"] != nil
  end

  test "late child delete denial preserves discoverable parent and retained disks" do
    {config, record, opts} = api_fixture(late_cleanup_pod: :gated)
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    command = fn exe, args, options ->
      denied = "delete" in args and String.contains?(arg(args, "--raw"), "/pods/")
      if denied, do: json(%{"kind" => "Status", "code" => 403}), else: api_command(exe, args, options)
    end

    assert {:error, {:denied, _}, _} = Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))
    assert api_state()["pods"][record.key] != nil
    assert api_state()["sandboxes"][record.key] != nil
  end

  test "credential creation waits for current suspended acknowledgement" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    parent = api_state()["sandboxes"][record.key]
    put_object("sandboxes", Map.put(parent, "status", %{"conditions" => []}))
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    put_object("sandboxes", Map.put(api_state()["sandboxes"][record.key], "status", %{"conditions" => []}))
    sleep = fn _ -> put_object("sandboxes", suspend_status(api_state()["sandboxes"][record.key])) end
    assert {:ok, started} = Kubernetes.start(config, intended, Keyword.put(opts, :sleep_fun, sleep))
    assert {:ok, stopped} = Kubernetes.stop(config, started, opts)
    assert {:quiescent, _} = stopped.proof
  end

  test "mutating API failures never become a successful start or durable intent" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      failed = "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes")
      if failed, do: json(%{"kind" => "Status", "code" => 500}), else: api_command(exe, args, options)
    end

    assert {:error, {:unknown, :kubernetes_api_outcome}, _} =
             Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))

    assert api_state()["pods"] == %{}

    conflict = fn exe, args, options ->
      if "patch" in args, do: json(%{"kind" => "Status", "code" => 409}), else: api_command(exe, args, options)
    end

    assert {:error, {:retryable, :kubernetes_cas_conflict}, _} =
             Kubernetes.put_intent(config, intended, %{desired: :stopped}, Keyword.put(opts, :command_fun, conflict))
  end

  test "a malformed successful create observation never grants execution proof" do
    {config, record, opts} = api_fixture()

    command = fn exe, args, options ->
      response = api_command(exe, args, options)
      malformed_create_response(args, response)
    end

    assert {:ok, unresolved} = Kubernetes.ensure(config, record, Keyword.put(opts, :command_fun, command))
    assert unresolved.proof == :unknown
    assert unresolved.phase == :unknown
    assert Enum.any?(unresolved.pending, &(&1.outcome == :unknown))
  end

  defp malformed_create_response(args, response) do
    if "create" in args and String.contains?(arg(args, "--raw"), "/sandboxes") do
      {:ok, %{output: output}} = response
      body = output |> Jason.decode!() |> put_in(["metadata", "annotations", "symphony.dev/record"], "invalid")
      json(body)
    else
      response
    end
  end

  defp concurrent_denial_artifacts(args, record) do
    if "create" in args and String.contains?(arg(args, "--raw"), "/sandboxes") do
      parent = %{"metadata" => meta(record.key, "concurrent-parent")}
      put_object("sandboxes", parent)
      refs = [%{"kind" => "Sandbox", "name" => record.key, "uid" => "concurrent-parent"}]
      put_object("services", %{"metadata" => Map.put(meta("owner-only", "owner-service"), "ownerReferences", refs)})
    end
  end

  defp qualify_template(template) do
    put_object("sandboxtemplates", template)
    cm = api_state()["configmaps"]["qualification"]
    q = Jason.decode!(cm["data"]["contract.json"])
    put_object("configmaps", put_in(cm, ["data", "contract.json"], Jason.encode!(%{q | "template_digest" => fixture_digest(template["spec"])})))
  end

  defp running_parent_read?(args) do
    "get" in args and String.contains?(arg(args, "--raw"), "/sandboxes?") and
      get_in(api_state(), ["sandboxes", "se-ticket", "spec", "operatingMode"]) == "Running"
  end

  defp foreign_live_pod do
    case api_state()["pods"]["se-ticket"] do
      nil -> :ok
      pod -> put_object("pods", put_in(pod, ["metadata", "ownerReferences"], [%{"kind" => "Sandbox", "uid" => "foreign"}]))
    end
  end

  defp late_cleanup_pod(parent) do
    case option(:late_cleanup_pod) do
      :gated ->
        create_pod(parent)

      :ungated ->
        create_pod(parent)
        put_object("pods", put_in(api_state()["pods"]["se-ticket"], ["spec", "schedulingGates"], []))

      _ ->
        :ok
    end
  end

  defp api_fixture(options \\ []) do
    config = %{
      provider: Map.merge(config().provider, %{"template" => "development", "ssh_user" => "worker", "ssh_port" => 2222, "ssh_auth_volume" => "ssh-auth"}),
      deployment_id: "deployment",
      tracker_kind: "memory",
      kind: "kubernetes"
    }

    record = %{record() | scope: Config.scope(config)}

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
    Process.put(:pod_incarnation, 0)
    Process.delete(:denied_create_seen)
    Process.delete(:delayed_release)
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
    if "patch" in args, do: api_patch(args), else: api_raw(args)
  end

  defp api_patch(args) do
    index = Enum.find_index(args, &(&1 == "patch"))
    resource = args |> Enum.at(index + 1) |> String.split(".") |> hd()
    name = Enum.at(args, index + 2)
    patch = args |> arg("--patch-file") |> File.read!() |> Jason.decode!()
    release = resource == "pods" and Enum.any?(patch, &(&1["op"] == "remove"))

    if release and option(:delay_release) and Process.get(:delayed_release) == nil do
      Process.put(:delayed_release, {"/api/v1/namespaces/test/pods/" <> name, patch})
      {:error, {:unknown, :lost_patch_response}}
    else
      patch_object(resource, name, patch)
    end
  end

  defp api_raw(args) do
    uri = URI.parse(arg(args, "--raw"))
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
        inventory_response(resource)

      "create" in args ->
        body = args |> arg("-f") |> File.read!() |> Jason.decode!()
        create_response(resource, body)

      "delete" in args ->
        resource = Enum.at(parts, -2)
        body = args |> arg("-f") |> File.read!() |> Jason.decode!()
        delete_object(resource, List.last(parts), body)
    end
  end

  defp create_response("sandboxes", body) do
    cond do
      option(:deny_create) ->
        Process.put(:denied_create_seen, true)
        retain_denied_artifact(body)
        json(%{"kind" => "Status", "code" => 403})

      option(:timeout_create) ->
        {:error, :timeout}

      true ->
        create_object("sandboxes", body)
    end
  end

  defp create_response(resource, body), do: create_object(resource, body)

  defp retain_denied_artifact(body) do
    if option(:denied_artifact) do
      metadata = Map.merge(body["metadata"], meta("partial-secret", "partial-secret-uid"))
      put_object("secrets", %{"metadata" => metadata})
    end
  end

  defp inventory_response(resource) do
    if resource == "persistentvolumes" and option(:deny_post_create_inventory) and Process.get(:denied_create_seen) do
      json(%{"kind" => "Status", "code" => 403})
    else
      json(%{"metadata" => %{"resourceVersion" => "100"}, "items" => Map.values(Map.fetch!(api_state(), resource))})
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

        reconcile_patch(resource, updated, patch)

        json(api_state()[resource][name])

      :conflict ->
        json(%{"kind" => "Status", "code" => 409})
    end
  end

  defp reconcile_patch("sandboxes", updated, _patch) do
    cond do
      get_in(updated, ["spec", "operatingMode"]) == "Running" and api_state()["pods"] == %{} and not option(:delay_pod) ->
        create_pod(updated)

      get_in(updated, ["spec", "operatingMode"]) == "Suspended" ->
        put_object("sandboxes", suspend_status(updated))

      true ->
        :ok
    end
  end

  defp reconcile_patch("pods", updated, patch) do
    gates = get_in(updated, ["spec", "schedulingGates"]) || []

    if not Enum.any?(gates, &(&1["name"] == "symphony.dev/start-authorized")) do
      run_pod(updated, patch, gates)
    end
  end

  defp reconcile_patch(_resource, _updated, _patch), do: :ok

  defp create_pod(parent) do
    incarnation = Process.get(:pod_incarnation, 0) + 1
    Process.put(:pod_incarnation, incarnation)
    uid = if incarnation == 1, do: "pod-uid", else: "pod-uid-#{incarnation}"
    metadata = Map.merge(parent["spec"]["podTemplate"]["metadata"], child_meta(parent, parent["metadata"]["name"], uid))
    pod = Map.put(parent["spec"]["podTemplate"], "metadata", metadata)
    pod = if option(:strip_network_profile), do: update_in(pod, ["metadata", "labels"], &Map.delete(&1, "profile")), else: pod
    put_object("pods", pod)
    mutate_pvc_admission()
  end

  defp mutate_pvc_admission do
    if option(:mutate_pvc_on_pod_creation) do
      for pvc <- Map.values(api_state()["persistentvolumeclaims"]) do
        put_object("persistentvolumeclaims", put_in(pvc, ["spec", "storageClassName"], "unqualified-admission"))
      end
    end
  end

  defp run_pod(updated, patch, gates) do
    # The API script grants the operator's independent gate separately.
    if Enum.any?(patch, &(&1["op"] == "remove")), do: Process.put(:operator_gates_after_release, gates)
    updated = put_in(updated, ["spec", "schedulingGates"], [])
    status = %{"phase" => "Running", "podIP" => "10.2.3.4", "conditions" => [%{"type" => "Ready", "status" => "True"}]}
    put_object("pods", Map.put(updated, "status", status))
    parent = api_state()["sandboxes"]["se-ticket"]
    condition = %{"type" => "Ready", "status" => "True", "observedGeneration" => parent["metadata"]["generation"]}
    put_object("sandboxes", Map.put(parent, "status", %{"conditions" => [condition]}))
  end

  defp apply_patch(nil, _patch), do: :conflict

  defp apply_patch(object, patch) do
    Enum.reduce_while(patch, {:ok, object}, fn operation, {:ok, current} ->
      path = operation["path"] |> String.split("/", trim: true) |> Enum.map(&String.replace(String.replace(&1, "~1", "/"), "~0", "~"))

      case operation["op"] do
        "test" -> compare_patch(current, path, operation["value"])
        "add" -> {:cont, {:ok, set_path(current, path, operation["value"])}}
        "remove" -> {:cont, {:ok, remove_path(current, path)}}
      end
    end)
  end

  defp compare_patch(current, path, expected) do
    if at_path(current, path) == expected, do: {:cont, {:ok, current}}, else: {:halt, :conflict}
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
      delete_effect(resource, name, object)

      json(%{"kind" => "Status", "code" => 200})
    end
  end

  defp delete_effect("sandboxes", _name, object) do
    put_object("sandboxes", put_in(object, ["metadata", "deletionTimestamp"], "2026-09-11T00:00:00Z"))
    late_cleanup_pod(object)
  end

  defp delete_effect("pods", name, object) do
    if not option(:missing_termination) do
      terminated = %{"finishedAt" => "2026-09-11T00:00:00Z", "containerID" => "containerd://worker", "reason" => "Completed"}
      statuses = [%{"name" => "worker", "state" => %{"terminated" => terminated}}]

      terminal =
        object
        |> put_in(["metadata", "managedFields"], [%{"manager" => "kubelet", "subresource" => "status"}])
        |> Map.put("status", %{"phase" => "Succeeded", "containerStatuses" => statuses})

      put_event("pods", name, %{"type" => "MODIFIED", "object" => terminal})
    end

    remove_object("pods", name)
  end

  defp delete_effect("persistentvolumeclaims", name, _object) do
    remove_object("persistentvolumeclaims", name)

    if not option(:delay_pv) do
      pv = api_state()["persistentvolumes"]["pv-ticket"]
      put_event("persistentvolumes", "pv-ticket", %{"type" => "DELETED", "object" => put_in(pv, ["metadata", "finalizers"], [])})
      remove_object("persistentvolumes", "pv-ticket")
    end
  end

  defp delete_effect(resource, name, _object), do: remove_object(resource, name)

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
