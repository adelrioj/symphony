defmodule SymphonyElixir.KubernetesEnvironmentTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentRuntimeSupervisor, Lanes, Repo, TestSupport}
  alias SymphonyElixir.ExecutionEnvironment.{Config, Kubernetes, Lifecycle, Operations, Record}
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.{Client, Declaration, DeclarationReconciler, Guard, LossAlarm}

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

  test "production discovery is open on the approved baseline and allocates nothing by itself" do
    # This asserted the cleanup-ordering stop until 2026-09-19. Discovery now succeeds, but
    # the property worth keeping is the second one: discovery must still not mutate anything.
    {config, _record, opts} = api_fixture()
    inventory = api_state()

    assert {:ok, _records} = Operations.run(Kubernetes, config, nil, :discover, opts)

    assert api_state() == inventory
  end

  test "production refuses a baseline the deployment does not match" do
    {config, _record, opts} = api_fixture()
    stale = put_in(api_state()["configmaps"]["qualification"]["data"]["contract.json"], Jason.encode!(%{"release" => "v1.0.1"}))
    put_object("configmaps", %{"metadata" => meta("qualification", "qualification-uid"), "immutable" => true, "data" => %{"contract.json" => stale}})

    assert {:error, _} = Kubernetes.preflight(config, opts)
  end

  test "a loss declaration is refused while the declared host's Node object still exists" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    put_object("nodes", node_object())

    assert refusal(config, record, opts) == :kubernetes_declared_host_observable
  end

  test "a declared lost host discharges its obligations and the environment then releases" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _running} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])

    assert {:ok, [declared]} = Kubernetes.declare_lost(config, loss_declaration(record), opts)
    assert {:operator_declared_lost, evidence} = declared.proof
    assert evidence["receipt"] == "symphony-destruction-receipt-3070466"
    refute declared.absent?

    assert {:ok, deleted} = Kubernetes.destroy(config, declared, opts)
    assert deleted.absent?
    assert guard_data(record)["phase"] == "Complete"
  end

  test "a declaration whose receipt names a different machine is refused" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    other = Jason.decode!(api_state()["configmaps"]["symphony-destruction-receipt-3070466"]["data"]["receipt.json"])
    put_object("configmaps", put_in(api_state()["configmaps"]["symphony-destruction-receipt-3070466"], ["data", "receipt.json"], Jason.encode!(%{other | "machine_id" => "another-machine"})))

    assert refusal(config, record, opts) == :kubernetes_destruction_receipt_invalid
  end

  test "a declaration is refused when no destruction receipt has been issued" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    remove_object("configmaps", "symphony-destruction-receipt-3070466")

    assert refusal(config, record, opts) == :kubernetes_destruction_receipt_unavailable
  end

  test "a receipt that does not name this environment's volume handle discharges nothing" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["some-other-disk"])

    assert refusal(config, record, opts) == :kubernetes_declared_volume_not_in_receipt
    assert api_state()["persistentvolumes"]["pv-ticket"]
  end

  # The refusal comes from guard discovery rather than from the volume predicate, which is why
  # this asserts the outcome and not a reason code: an absent PV leaves the environment's storage
  # obligation unreadable, and nothing downstream may treat that absence as discharge.
  test "an absent PersistentVolume is not a substitute for the receipt's evidence" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = loss_declaration(record)
    remove_object("persistentvolumes", "pv-ticket")

    assert {:error, _} = Kubernetes.declare_lost(config, declaration, opts)
    saved = guard_data(record)["record"]["metadata"]
    refute saved["loss_declaration"]
    refute Enum.any?(saved["volumes"], fn {_, volume} -> volume["deleted"] == true end)
  end

  test "a reused node name is refused even when the machine behind it is new" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    reused = put_in(node_object(), ["metadata", "uid"], "a-different-node")
    put_object("nodes", put_in(reused, ["status", "nodeInfo", "machineID"], "a-different-machine"))

    assert refusal(config, record, opts) == :kubernetes_declared_host_observable
  end

  test "a declaration that omits an owned obligation is refused" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])

    assert refusal(config, record, opts, %{"obligationUIDs" => ["pvc-uid"]}) == :kubernetes_declared_obligations_inexact
    assert refusal(config, record, opts, %{"obligationUIDs" => ~w(pod-uid pvc-uid a-stranger)}) == :kubernetes_declared_obligations_inexact
  end

  test "a declaration naming a host this environment was never bound to is refused" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    host = %{"node_name" => "worker-1", "node_uid" => "someone-elses-node", "machine_id" => "machine", "system_uuid" => "system"}

    assert refusal(config, record, opts, %{"host" => host}) == :kubernetes_declared_host_mismatch
  end

  test "an environment that pinned no host can never be declared lost" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    refute guard_data(record)["hostBinding"]

    host = %{"node_name" => "worker-1", "node_uid" => "node-uid", "machine_id" => "machine", "system_uuid" => "system"}

    guards = %{
      record.key => %{"uid" => api_state()["configmaps"][Guard.name(record)]["metadata"]["uid"], "resourceVersion" => api_state()["configmaps"][Guard.name(record)]["metadata"]["resourceVersion"]}
    }

    {:ok, declaration} =
      Declaration.decode(%{
        "schemaVersion" => 1,
        "deploymentId" => record.deployment_id,
        "host" => host,
        "environmentKeys" => [record.key],
        "obligationUIDs" => ["pod-uid", "pvc-uid"],
        "guards" => guards,
        "receiptName" => "symphony-destruction-receipt-3070466",
        "operatorSubject" => "operator@example.test",
        "chunkIndex" => 0,
        "chunkTotal" => 1
      })

    assert {:error, {_, :kubernetes_declared_host_mismatch}} = Kubernetes.declare_lost(config, declaration, opts)
  end

  test "a declaration never settles an unresolved Issued create" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = loss_declaration(record)
    parent = api_state()["sandboxes"][record.key]
    put_object("sandboxes", update_in(parent, ["status", "creationJournal", "operations"], &Enum.map(&1, fn op -> Map.put(op, "state", "Issued") end)))

    assert {:error, _} = Kubernetes.declare_lost(config, declaration, opts)
    refute guard_data(record)["record"]["metadata"]["loss_declaration"]
  end

  test "a declaration for another deployment is refused" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])

    assert refusal(config, record, opts, %{"deploymentId" => "another-deployment"}) == :kubernetes_declaration_foreign
  end

  test "a declaration naming an environment this deployment does not hold is refused" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    stranger = %{"environmentKeys" => ["se-stranger"], "guards" => %{"se-stranger" => %{"uid" => "guard-uid", "resourceVersion" => "1"}}}

    assert refusal(config, record, opts, stranger) == :kubernetes_declared_environment_missing
  end

  test "a declaration whose guard reference no longer matches is refused" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    guards = %{record.key => %{"uid" => "a-different-guard", "resourceVersion" => "1"}}

    assert refusal(config, record, opts, %{"guards" => guards}) == :kubernetes_declared_guard_changed
  end

  # Capture re-reads the handle from live state, so a swapped handle does not show up as a
  # mismatch against our own records. The receipt is what catches it: it names the disk that was
  # destroyed, and that is no longer the disk this claim points at.
  test "a volume whose handle was swapped is not the disk the receipt destroyed" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    put_object("persistentvolumes", put_in(api_state()["persistentvolumes"]["pv-ticket"], ["spec", "csi", "volumeHandle"], "a-different-disk"))

    assert refusal(config, record, opts) == :kubernetes_declared_volume_not_in_receipt
  end

  test "a claim that never bound is not host-local storage and is not discharged by a receipt" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    state = api_state() |> put_in(["persistentvolumeclaims", "workspace-se-ticket", "spec", "volumeName"], nil) |> Map.put("persistentvolumes", %{})
    Process.put(:kubernetes_api, state)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])

    assert refusal(config, record, opts) == :kubernetes_declared_volume_unbound
  end

  test "an unreadable predicate is unavailable and never false" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = loss_declaration(record)

    for collection <- ["/api/v1/nodes", "configmaps"] do
      forbidden = {:ok, %{status: 1, output: "Error from server (Forbidden)"}}

      refuse = fn exe, args, options ->
        reading? = "get" in args and raw_path?(args, collection)
        if reading?, do: forbidden, else: api_command(exe, args, options)
      end

      assert {:error, {reason, _}} = Kubernetes.declare_lost(config, declaration, Keyword.put(opts, :command_fun, refuse))
      assert reason in [:denied, :unknown]
    end
  end

  test "a chunked declaration is refused while no coordinator verifies every chunk" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])

    assert refusal(config, record, opts, %{"chunkTotal" => 2}) == :kubernetes_declaration_chunked
  end

  test "a declaration replayed after an intervening guard write is the same declaration" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = loss_declaration(record)

    assert {:ok, [first]} = Kubernetes.declare_lost(config, declaration, opts)
    assert {:ok, [again]} = Kubernetes.declare_lost(config, declaration, opts)
    assert first.proof == again.proof
    assert guard_data(record)["record"]["metadata"]["loss_declaration"]["name"] == declaration.name
  end

  test "the reconciler drives a pending declaration and records the outcome" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = publish_declaration(record)

    assert {:ok, summary} = DeclarationReconciler.reconcile(config, opts)
    assert summary.accepted == 1
    assert summary.alarms == 0

    status = declaration_status(declaration)
    assert status["outcome"] == "accepted"
    assert status["observedAt"]
    assert Enum.sort(Enum.map(status["obligations"], & &1["uid"])) == ["pod-uid", "pvc-uid"]
    assert Enum.all?(status["obligations"], &(&1["disposition"] == "discharged"))
  end

  test "the reconciler records a refusal without discharging anything" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["some-other-disk"])
    declaration = publish_declaration(record)

    assert {:ok, summary} = DeclarationReconciler.reconcile(config, opts)
    assert summary.refused == 1
    assert declaration_status(declaration)["outcome"] == "refused"
    refute guard_data(record)["record"]["metadata"]["loss_declaration"]
  end

  test "the reconciler leaves a settled declaration alone" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = publish_declaration(record)

    assert {:ok, %{accepted: 1}} = DeclarationReconciler.reconcile(config, opts)
    settled = declaration_status(declaration)

    assert {:ok, %{accepted: 0, refused: 0}} = DeclarationReconciler.reconcile(config, opts)
    assert declaration_status(declaration) == settled
  end

  # Finalization is irreversible, so a host that comes back cannot be undone. Saying so exactly
  # once is the whole of what is left to do.
  test "a declared lost host observed again raises one standing alarm" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = publish_declaration(record)
    assert {:ok, %{accepted: 1}} = DeclarationReconciler.reconcile(config, opts)

    put_object("nodes", node_object())

    assert {:ok, %{alarms: 1}} = DeclarationReconciler.reconcile(config, opts)
    assert {:ok, %{alarms: 0}} = DeclarationReconciler.reconcile(config, opts)

    assert [alarm] = LossAlarm.all()
    assert alarm.kind == "host_reappeared"
    assert alarm.declaration == declaration.name
    assert alarm.machine_id == "machine"
  end

  test "a different machine under the declared node name is not the host coming back" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    publish_declaration(record)
    assert {:ok, %{accepted: 1}} = DeclarationReconciler.reconcile(config, opts)

    replacement = node_object() |> put_in(["metadata", "uid"], "a-new-node") |> put_in(["status", "nodeInfo", "machineID"], "a-new-machine")
    put_object("nodes", replacement)

    assert {:ok, %{alarms: 0}} = DeclarationReconciler.reconcile(config, opts)
    assert LossAlarm.all() == []
  end

  test "monitoring for a reappearing host has an explicit end" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = publish_declaration(record)
    assert {:ok, %{accepted: 1}} = DeclarationReconciler.reconcile(config, opts)

    past = -DeclarationReconciler.monitoring_lifetime_ms() - 1000
    expired = DateTime.utc_now() |> DateTime.add(past, :millisecond) |> DateTime.to_iso8601()
    object = put_in(api_state()["hostlossdeclarations"][declaration.name], ["status", "observedAt"], expired)
    put_object("hostlossdeclarations", object)
    put_object("nodes", node_object())

    assert {:ok, %{alarms: 0}} = DeclarationReconciler.reconcile(config, opts)
    assert LossAlarm.all() == []
  end

  test "a declaration list that cannot be read is an error rather than an empty pass" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    destroy_host(["disk-ticket"])
    _ = created

    forbidden = {:ok, %{status: 1, output: "Error from server (Forbidden)"}}

    refuse = fn exe, args, options ->
      reading? = "get" in args and raw_path?(args, "hostlossdeclarations")
      if reading?, do: forbidden, else: api_command(exe, args, options)
    end

    assert {:error, _} = DeclarationReconciler.reconcile(config, Keyword.put(opts, :command_fun, refuse))
  end

  test "a reconciler tick drives the pass and schedules the next one" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = publish_declaration(record)

    {:ok, state} = DeclarationReconciler.init(Keyword.merge(opts, config: config, interval_ms: 60_000))
    assert {:noreply, next} = DeclarationReconciler.handle_info(:reconcile, state)
    assert next.timer
    assert declaration_status(declaration)["outcome"] == "accepted"

    put_object("nodes", node_object())
    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, next)
    assert [_alarm] = LossAlarm.all()
  end

  test "a tick with no configured environment does nothing, and one that cannot read says so" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, _} = Kubernetes.ensure(config, record, opts)

    {:ok, idle} = DeclarationReconciler.init(interval_ms: 60_000)
    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, idle)

    forbidden = {:ok, %{status: 1, output: "Error from server (Forbidden)"}}

    refuse = fn exe, args, options ->
      reading? = "get" in args and raw_path?(args, "hostlossdeclarations")
      if reading?, do: forbidden, else: api_command(exe, args, options)
    end

    {:ok, blind} = DeclarationReconciler.init(Keyword.merge(opts, config: config, command_fun: refuse, interval_ms: 60_000))
    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, blind)
  end

  test "the reconciler is startable anonymously or under its own name" do
    spec = %{id: :anonymous_reconciler, start: {DeclarationReconciler, :start_link, [[name: nil, interval_ms: 60_000]]}}
    anonymous = start_supervised!(spec)
    assert Process.alive?(anonymous)

    named = start_supervised!({DeclarationReconciler, [interval_ms: 60_000]})
    assert Process.whereis(DeclarationReconciler) == named
  end

  test "a tick resolves the lane's own environment and skips one that is not Kubernetes" do
    {config, _record, opts} = api_fixture(pinned_host: true)

    # No lane and no injected config: nothing to reconcile, and no crash for the absence.
    {:ok, laneless} = DeclarationReconciler.init(interval_ms: 60_000)
    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, laneless)

    # A lane id that resolves to nothing at all is skipped the same way.
    {:ok, missing} = DeclarationReconciler.init(lane_id: 424_242, interval_ms: 60_000)
    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, missing)

    # A real lane running somewhere other than Kubernetes is not this reconciler's business.
    TestSupport.reset_lanes!()
    on_exit(&TestSupport.reset_lanes!/0)
    {:ok, plain} = Lanes.create(%{slug: "reconciler-plain", front_matter: "tracker:\n  kind: memory", prompt: "P"})
    {:ok, unmanaged} = DeclarationReconciler.init(lane_id: plain.id, interval_ms: 60_000)
    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, unmanaged)

    # A lane that does run on Kubernetes resolves its own provider and reconciles against it.
    {:ok, managed} = Lanes.create(%{slug: "reconciler-managed", front_matter: kubernetes_front_matter(), prompt: "P"})
    {:ok, on_k8s} = DeclarationReconciler.init(Keyword.merge(opts, lane_id: managed.id, interval_ms: 60_000))
    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, on_k8s)

    {:ok, injected} = DeclarationReconciler.init(Keyword.merge(opts, config: config, interval_ms: 60_000))
    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, injected)
  end

  # The reconciler shares a one_for_all runtime with the Orchestrator, so a provider that blows up
  # mid-pass must not take agent execution down with it. The audited transport is what contains
  # it; the reconciler adds no rescue of its own and so hides no real bug.
  test "a provider that raises mid-pass is contained and the reconciler carries on" do
    {config, _record, opts} = api_fixture(pinned_host: true)

    explode = fn _exe, _args, _options -> raise "provider exploded" end

    {:ok, state} = DeclarationReconciler.init(Keyword.merge(opts, config: config, command_fun: explode, interval_ms: 60_000))
    assert {:noreply, next} = DeclarationReconciler.handle_info(:reconcile, state)
    assert next.timer
  end

  test "the lane runtime supervises a declaration reconciler" do
    children = AgentRuntimeSupervisor.child_specs(lane_id: 7)
    assert Enum.any?(children, &(&1.id == DeclarationReconciler))
  end

  test "a tick with nothing to do is quiet" do
    {config, _record, opts} = api_fixture(pinned_host: true)
    {:ok, state} = DeclarationReconciler.init(Keyword.merge(opts, config: config, interval_ms: 60_000))

    assert {:noreply, _} = DeclarationReconciler.handle_info(:reconcile, state)
    assert api_state()["hostlossdeclarations"] == %{}
  end

  test "a declaration the schema should have rejected is refused rather than retried forever" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = publish_declaration(record)
    object = update_in(api_state()["hostlossdeclarations"][declaration.name], ["spec"], &Map.delete(&1, "operatorSubject"))
    put_object("hostlossdeclarations", object)

    assert {:ok, %{refused: 1}} = DeclarationReconciler.reconcile(config, opts)
    assert declaration_status(declaration)["outcome"] == "refused"
  end

  test "a pass that cannot read a predicate leaves the declaration unresolved and retryable" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = publish_declaration(record)
    forbidden = {:ok, %{status: 1, output: "Error from server (Forbidden)"}}

    refuse = fn exe, args, options ->
      reading? = "get" in args and raw_path?(args, "configmaps")
      if reading?, do: forbidden, else: api_command(exe, args, options)
    end

    assert {:ok, %{unresolved: 1}} = DeclarationReconciler.reconcile(config, Keyword.put(opts, :command_fun, refuse))
    assert declaration_status(declaration)["outcome"] == "unresolved"
  end

  test "an outcome that could not be recorded is re-recorded on the next pass" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    declaration = publish_declaration(record)

    block = fn exe, args, options ->
      status? = "patch" in args and String.starts_with?(arg(args, "patch"), "hostlossdeclarations")
      if status?, do: {:error, :timeout}, else: api_command(exe, args, options)
    end

    assert {:ok, %{accepted: 1}} = DeclarationReconciler.reconcile(config, Keyword.put(opts, :command_fun, block))
    refute declaration_status(declaration)

    assert {:ok, %{accepted: 1}} = DeclarationReconciler.reconcile(config, opts)
    assert declaration_status(declaration)["outcome"] == "accepted"
  end

  test "a Node read that fails is not a host coming back" do
    {config, record, opts} = api_fixture(pinned_host: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, _} = Kubernetes.start(config, intended, opts)
    destroy_host(["disk-ticket"])
    publish_declaration(record)
    assert {:ok, %{accepted: 1}} = DeclarationReconciler.reconcile(config, opts)

    put_object("nodes", node_object())
    forbidden = {:ok, %{status: 1, output: "Error from server (Forbidden)"}}

    refuse = fn exe, args, options ->
      reading? = "get" in args and raw_path?(args, "/nodes")
      if reading?, do: forbidden, else: api_command(exe, args, options)
    end

    assert {:ok, %{alarms: 0}} = DeclarationReconciler.reconcile(config, Keyword.put(opts, :command_fun, refuse))
    assert LossAlarm.all() == []
  end

  test "cleanup retains storage before authoritative create-drain acknowledgement" do
    {config, record, opts} = api_fixture(missing_ack: true)
    assert {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:error, _, _} = Kubernetes.destroy(config, created, opts)
    assert Map.has_key?(api_state()["persistentvolumeclaims"], "workspace-se-ticket")
  end

  test "ordinary destroy operation resumes a live ReadyToFinalize parent without rewriting its receipt" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    command = fn exe, args, options ->
      blocked =
        "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes") and
          Enum.any?(Jason.decode!(File.read!(arg(args, "--patch-file"))), &(&1["path"] == "/metadata/finalizers"))

      if blocked, do: {:error, :timeout}, else: api_command(exe, args, options)
    end

    entry = Lifecycle.new(created, "cleanup", :cleanup)
    assert {:error, _, retained} = Operations.run(Kubernetes, config, entry, :destroy, Keyword.put(opts, :command_fun, command))
    ready = guard_data(record)
    assert ready["phase"] == "ReadyToFinalize"
    assert api_state()["sandboxes"][record.key]
    assert {:ok, deleted} = Operations.run(Kubernetes, config, Lifecycle.new(retained, "retry", :cleanup), :destroy, opts)
    assert deleted.absent?
    complete = guard_data(record)
    assert complete["phase"] == "Complete"
    assert complete["record"] == ready["record"]
    assert complete["evidence"] == ready["evidence"]
    assert {:ok, []} = Kubernetes.discover(config, opts)
    assert {:error, _, _} = Kubernetes.ensure(config, record, opts)
  end

  test "ordinary destroy operation resumes after parent deletion and does not rediscover completed ownership" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    command = fn exe, args, options ->
      target = guard_patch_target(args)
      if target && target["phase"] == "Complete", do: {:error, :timeout}, else: api_command(exe, args, options)
    end

    assert {:error, _, _} = Operations.run(Kubernetes, config, Lifecycle.new(created, "cleanup", :cleanup), :destroy, Keyword.put(opts, :command_fun, command))
    assert api_state()["sandboxes"] == %{}
    assert {:ok, [recovered]} = Kubernetes.discover(config, opts)
    assert {:ok, deleted} = Operations.run(Kubernetes, config, Lifecycle.new(recovered, "restart", :cleanup), :destroy, opts)
    assert deleted.absent?
    assert {:ok, []} = Kubernetes.discover(config, opts)
  end

  test "inspect keeps guard absent intent after a split guard and parent annotation write" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, captured} = Kubernetes.inspect(config, created, opts)
    original = api_state()["sandboxes"][record.key]["metadata"]["annotations"]["symphony.dev/record"]

    command = fn exe, args, options ->
      if "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes") do
        {:error, :timeout}
      else
        api_command(exe, args, options)
      end
    end

    assert {:error, _, closing} = Kubernetes.put_intent(config, captured, %{desired: :absent}, Keyword.put(opts, :command_fun, command))
    assert api_state()["sandboxes"][record.key]["metadata"]["annotations"]["symphony.dev/record"] == original
    assert guard_data(record)["record"]["desired"] == "absent"
    assert {:ok, observed} = Operations.run(Kubernetes, config, Lifecycle.new(closing, "inspect", :cleanup), :inspect, opts)
    assert observed.desired == :absent
    assert observed.metadata["volumes"] == guard_data(record)["record"]["metadata"]["volumes"]
    assert {:error, _, _} = Kubernetes.start(config, observed, opts)
  end

  test "guard-only execution authorization survives stale parent annotations and unrelated parent status changes" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      blocked =
        if "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes") do
          Enum.any?(Jason.decode!(File.read!(arg(args, "--patch-file"))), fn op ->
            if op["path"] == "/metadata/annotations" do
              saved = Jason.decode!(op["value"]["symphony.dev/record"])
              "pod-uid" in (saved["metadata"]["authorized_pod_uids"] || [])
            else
              false
            end
          end)
        else
          false
        end

      if blocked, do: {:error, :timeout}, else: api_command(exe, args, options)
    end

    assert {:error, _, unresolved} = Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))
    assert guard_data(record)["record"]["metadata"]["authorized_pod_uids"] == ["pod-uid"]
    annotation = Jason.decode!(api_state()["sandboxes"][record.key]["metadata"]["annotations"]["symphony.dev/record"])
    refute "pod-uid" in annotation["metadata"]["authorized_pod_uids"]
    assert {:ok, ensured} = Kubernetes.ensure(config, created, opts)
    assert ensured.metadata["authorized_pod_uids"] == ["pod-uid"]

    command = fn exe, args, options ->
      response = api_command(exe, args, options)

      if "get" in args and String.contains?(arg(args, "--raw"), "/pods?") do
        parent = api_state()["sandboxes"][record.key]
        put_object("sandboxes", update_in(parent, ["metadata", "resourceVersion"], &Integer.to_string(String.to_integer(&1) + 1)))
      end

      response
    end

    assert {:ok, observed} = Operations.run(Kubernetes, config, Lifecycle.new(unresolved, "inspect", :agent), :inspect, Keyword.put(opts, :command_fun, command))
    assert observed.metadata["authorized_pod_uids"] == ["pod-uid"]
    assert {:compute_unknown, _} = observed.proof
  end

  test "a committed unclassified missing Pod keeps capacity through inspect and stop" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    create_pod(api_state()["sandboxes"][record.key])
    remove_object("pods", record.key)
    assert {:ok, observed} = Operations.run(Kubernetes, config, Lifecycle.new(created, "inspect", :agent), :inspect, opts)
    assert {:compute_unknown, _} = observed.proof
    assert Lifecycle.occupied?(%{Lifecycle.new(observed, "inspect", :cleanup) | phase: :stopped})
    assert {:ok, stopped} = Kubernetes.stop(config, observed, opts)
    assert {:compute_unknown, _} = stopped.proof
    assert Lifecycle.occupied?(%{Lifecycle.new(stopped, "stop", :cleanup) | phase: :stopped})
  end

  test "a late committed missing Pod invalidates prior quiescence on an ordinary deletion failure" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, stopped} = Kubernetes.stop(config, created, opts)
    assert {:quiescent, _} = stopped.proof
    entry = %{Lifecycle.new(stopped, "cleanup", :cleanup) | phase: :stopped}
    {deleting, [{:provider, :destroy, id}]} = Lifecycle.step(entry, :destroy, 0)

    command = late_missing_pod_after_close(record, :none)

    assert {:error, failure, unresolved} = Operations.run(Kubernetes, config, deleting, :destroy, Keyword.put(opts, :command_fun, command))
    assert {:compute_unknown, _} = unresolved.proof
    {retained, []} = Lifecycle.step(deleting, {:failed, id, failure, unresolved}, 1)
    assert Lifecycle.occupied?(retained)
    assert retained.record.proof == unresolved.proof
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
  end

  test "a stale cleanup intent cannot restore old quiescence after a newly committed Pod vanishes" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, stopped} = Kubernetes.stop(config, created, opts)
    assert {:quiescent, _} = stopped.proof
    create_pod(api_state()["sandboxes"][record.key])
    remove_object("pods", record.key)
    parent = api_state()["sandboxes"][record.key]
    put_object("sandboxes", update_in(parent, ["metadata", "resourceVersion"], &Integer.to_string(String.to_integer(&1) + 1)))
    entry = %{Lifecycle.new(stopped, "cleanup", :cleanup) | phase: :stopped}
    {deleting, [{:provider, :destroy, id}]} = Lifecycle.step(entry, :destroy, 0)

    assert {:error, {:retryable, :kubernetes_cas_conflict} = failure, unresolved} = Operations.run(Kubernetes, config, deleting, :destroy, opts)
    assert {:compute_unknown, _} = unresolved.proof
    {retained, []} = Lifecycle.step(deleting, {:failed, id, failure, unresolved}, 1)
    assert Lifecycle.occupied?(retained)
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    assert guard_data(record)["phase"] == "Closing"
  end

  test "an intent write failure preserves newly observed physical uncertainty before cleanup begins" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, stopped} = Kubernetes.stop(config, created, opts)
    create_pod(api_state()["sandboxes"][record.key])
    remove_object("pods", record.key)

    command = fn exe, args, options ->
      if "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes"),
        do: {:error, :timeout},
        else: api_command(exe, args, options)
    end

    entry = %{Lifecycle.new(stopped, "cleanup", :cleanup) | phase: :stopped}
    assert {:error, _, unresolved} = Operations.run(Kubernetes, config, entry, :destroy, Keyword.put(opts, :command_fun, command))
    assert {:compute_unknown, _} = unresolved.proof
    assert Lifecycle.occupied?(%{entry | record: unresolved})
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
  end

  test "a guard reread failure cannot discard the newly observed owned parent journal" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, stopped} = Kubernetes.stop(config, created, opts)
    create_pod(api_state()["sandboxes"][record.key])
    remove_object("pods", record.key)

    command = fn exe, args, options ->
      path = if "get" in args, do: arg(args, "--raw"), else: ""
      if String.contains?(path, "/sandboxes?"), do: Process.put(:intent_parent_observed, true)

      if String.contains?(path, "/configmaps?") and Process.get(:intent_parent_observed),
        do: {:error, :timeout},
        else: api_command(exe, args, options)
    end

    entry = %{Lifecycle.new(stopped, "cleanup", :cleanup) | phase: :stopped}
    assert {:error, _, unresolved} = Operations.run(Kubernetes, config, entry, :destroy, Keyword.put(opts, :command_fun, command))
    assert {:compute_unknown, _} = unresolved.proof
    assert Lifecycle.occupied?(%{entry | record: unresolved})
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
  end

  for storage_failure <- [:missing_pv, :missing_pvc] do
    test "a #{storage_failure} failure cannot mask a late committed missing Pod during deletion" do
      {config, record, opts} = api_fixture()
      {:ok, created} = Kubernetes.ensure(config, record, opts)
      {:ok, stopped} = Kubernetes.stop(config, created, opts)
      assert {:quiescent, _} = stopped.proof
      entry = %{Lifecycle.new(stopped, "cleanup", :cleanup) | phase: :stopped}
      {deleting, [{:provider, :destroy, id}]} = Lifecycle.step(entry, :destroy, 0)
      command = late_missing_pod_after_close(record, unquote(storage_failure))

      assert {:error, failure, unresolved} = Operations.run(Kubernetes, config, deleting, :destroy, Keyword.put(opts, :command_fun, command))

      expected =
        case unquote(storage_failure) do
          :missing_pv -> {:unknown, :bound_pv_missing}
          :missing_pvc -> {:unknown, {:kubernetes_storage_obligation_missing, "late-pvc-uid"}}
        end

      assert failure == expected
      assert {:compute_unknown, _} = unresolved.proof
      {retained, []} = Lifecycle.step(deleting, {:failed, id, failure, unresolved}, 1)
      assert Lifecycle.occupied?(retained)
      assert retained.record.proof == unresolved.proof
      assert api_state()["sandboxes"][record.key]
    end
  end

  test "inspect reports newly unresolved compute despite an earlier storage capture failure" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, stopped} = Kubernetes.stop(config, created, opts)
    assert {:quiescent, _} = stopped.proof
    create_pod(api_state()["sandboxes"][record.key])
    remove_object("pods", record.key)
    remove_object("persistentvolumes", "pv-ticket")
    entry = %{Lifecycle.new(stopped, "inspect", :cleanup) | phase: :stopped}

    assert {:error, {:unknown, :bound_pv_missing}, unresolved} = Operations.run(Kubernetes, config, entry, :inspect, opts)
    assert {:compute_unknown, _} = unresolved.proof
    assert Lifecycle.occupied?(%{entry | record: unresolved})
  end

  test "lost bootstrap response requires observing the exact initial guard before parent creation" do
    {config, record, opts} = api_fixture()

    command = fn exe, args, options ->
      response = api_command(exe, args, options)
      if "--path" in args and String.contains?(arg(args, "--path"), "/configmaps"), do: {:error, :timeout}, else: response
    end

    assert {:ok, created} = Kubernetes.ensure(config, record, Keyword.put(opts, :command_fun, command))
    assert created.provider_ref == "sandbox-uid"
    assert [{"sandboxes", _}, {"configmaps", _}] = Process.get(:post_attempts)
    assert [%{"state" => "Committed", "guardUID" => "guard-uid"}] = guard_data(record)["operations"]
  end

  test "a changed previously accepted drained journal cannot replace durable cleanup evidence" do
    {config, record, opts} = api_fixture(delay_pv: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:error, {:unknown, :kubernetes_cleanup_pending}, retained} = Kubernetes.destroy(config, created, opts)
    parent = api_state()["sandboxes"][record.key]
    journal = parent["status"]["creationJournal"]
    journal = journal |> Map.update!("revision", &(&1 + 1)) |> update_in(["acknowledgement", "revision"], &(&1 + 1))
    put_object("sandboxes", put_in(parent, ["status", "creationJournal"], journal))
    assert {:error, {:unknown, :kubernetes_controller_journal_changed}, _} = Kubernetes.destroy(config, retained, opts)
    assert guard_data(record)["phase"] == "Closing"
    assert api_state()["persistentvolumes"]["pv-ticket"]
  end

  test "running compute cleanup records termination for every committed Pod before completion" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, running} = Kubernetes.start(config, intended, opts)
    outcome = Kubernetes.destroy(config, running, opts)
    assert {:ok, deleted} = outcome
    assert deleted.absent?
    evidence = guard_data(record)["evidence"]
    assert evidence["physical"]["pod-uid"]["kind"] == "terminated"
    assert evidence["termination"]["pod-uid"]["kind"] == "kubelet_terminated"
    assert api_state()["pods"] == %{}
    assert api_state()["secrets"] == %{}
  end

  test "discovery preserves a running attempt only while its authorized Pod is ready" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running, attempt_id: "active-agent"}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    assert {:ok, %{phase: :running}} = Kubernetes.inspect(config, started, opts)

    assert {:ok, [discovered]} = Kubernetes.discover(config, opts)
    assert discovered.phase == :running
    assert discovered.attempt_id == "active-agent"

    put_object("pods", put_in(api_state()["pods"][record.key], ["status", "conditions"], []))
    assert {:ok, [unready]} = Kubernetes.discover(config, opts)
    assert unready.phase == :unknown
  end

  test "forged controller attempt attribution cannot authorize a Pod or cleanup storage" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      response = api_command(exe, args, options)

      case api_state()["pods"][record.key] do
        nil -> :ok
        pod -> put_object("pods", put_in(pod, ["metadata", "annotations", "agents.x-k8s.io/create-attempt-id"], "forged"))
      end

      response
    end

    assert {:error, {:unknown, :kubernetes_unjournaled_child}, unresolved} =
             Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))

    assert {:error, {:unknown, :kubernetes_unjournaled_child}, _} = Kubernetes.destroy(config, unresolved, opts)
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    assert %{"name" => "symphony.dev/start-authorized"} in api_state()["pods"][record.key]["spec"]["schedulingGates"]
  end

  test "unknown guard protocol remains discoverable uncertainty and cannot be reused" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    guard = api_state()["configmaps"][Guard.name(record)]
    data = Map.put(guard_data(record), "protocol", "unsupported-v2")
    put_object("configmaps", put_in(guard, ["data", "guard.json"], Jason.encode!(data)))
    assert {:error, _, _} = Kubernetes.ensure(config, created, opts)
    assert {:error, _} = Kubernetes.discover(config, opts)
    assert {:error, _, _} = Kubernetes.destroy(config, created, opts)
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
  end

  test "lost issuance append never authorizes a parent POST on recovery" do
    {config, record, opts} = api_fixture()

    command = fn exe, args, options ->
      target = guard_patch_target(args)
      response = api_command(exe, args, options)
      if target && Enum.any?(target["operations"], &(&1["state"] == "Issued")), do: {:error, :timeout}, else: response
    end

    assert {:error, _, _} = Kubernetes.ensure(config, record, Keyword.put(opts, :command_fun, command))
    assert api_state()["sandboxes"] == %{}
    assert [%{"state" => "Issued"}] = guard_data(record)["operations"]
    assert {:ok, [recovered]} = Kubernetes.discover(config, opts)
    assert {:error, _, _} = Kubernetes.ensure(config, recovered, opts)
    assert {:error, _, _} = Kubernetes.destroy(config, recovered, opts)
    assert api_state()["sandboxes"] == %{}
  end

  test "a delayed issuance CAS loses to closure and cannot append afterwards" do
    {config, record, opts} = api_fixture()

    command = fn exe, args, options ->
      target = guard_patch_target(args)

      if target && Enum.any?(target["operations"], &(&1["state"] == "Issued")) do
        Process.put(:delayed_guard_patch, {args, Jason.decode!(File.read!(arg(args, "--patch-file")))})
        {:error, :timeout}
      else
        api_command(exe, args, options)
      end
    end

    assert {:error, _, unresolved} = Kubernetes.ensure(config, record, Keyword.put(opts, :command_fun, command))
    assert {:error, _, _} = Kubernetes.destroy(config, unresolved, opts)
    {_args, patch} = Process.get(:delayed_guard_patch)
    assert {:ok, %{status: 409}} = Client.request(config, :patch, "/api/v1/namespaces/test/configmaps/" <> Guard.name(record), patch, opts)
    assert guard_data(record)["phase"] == "Closing"
    assert guard_data(record)["operations"] == []
    assert api_state()["sandboxes"] == %{}
  end

  test "late parent commit settles its original guarded attempt after close" do
    {config, record, opts} = api_fixture(timeout_create: true)
    assert {:error, _, unresolved} = Kubernetes.ensure(config, record, opts)
    result = Kubernetes.destroy(config, unresolved, opts)
    assert {:error, {:unknown, :kubernetes_provider_issuance_unresolved}, _} = result
    [{"sandboxes", body}] = Enum.filter(Process.get(:post_attempts), fn {resource, _} -> resource == "sandboxes" end)
    create_object("sandboxes", body)
    Process.put(:kubernetes_options, [])
    assert {:ok, deleted} = Kubernetes.destroy(config, unresolved, opts)
    assert deleted.absent?
    assert guard_data(record)["phase"] == "Complete"
    assert Enum.count(Process.get(:post_attempts), fn {resource, _} -> resource == "sandboxes" end) == 1
  end

  test "late Secret commit remains owned across closure and is never replayed" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      if "--path" in args and String.contains?(arg(args, "--path"), "/secrets") do
        Process.put(:late_secret, Jason.decode!(File.read!(arg(args, "--file"))))
        {:error, :timeout}
      else
        api_command(exe, args, options)
      end
    end

    assert {:error, _, unresolved} = Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))
    result = Kubernetes.destroy(config, unresolved, opts)
    assert {:error, {:unknown, :kubernetes_provider_issuance_unresolved}, _} = result
    refute api_state()["sandboxes"][record.key]["metadata"]["deletionTimestamp"]
    create_object("secrets", Process.get(:late_secret))
    assert {:ok, deleted} = Kubernetes.destroy(config, unresolved, opts)
    assert deleted.absent?
    assert api_state()["secrets"] == %{}
    assert Enum.count(guard_data(record)["operations"], &(&1["resource"] == "secrets")) == 1
  end

  for target_phase <- ["ReadyToFinalize", "Complete"] do
    test "lost #{target_phase} update with unchanged guard cannot claim completion" do
      {config, record, opts} = api_fixture()
      {:ok, created} = Kubernetes.ensure(config, record, opts)
      target_phase = unquote(target_phase)

      command = fn exe, args, options ->
        target = guard_patch_target(args)
        if target && target["phase"] == target_phase, do: {:error, :timeout}, else: api_command(exe, args, options)
      end

      assert {:error, _, unresolved} = Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))
      refute unresolved.absent?
      assert guard_data(record)["phase"] == if(target_phase == "Complete", do: "ReadyToFinalize", else: "Closing")

      if target_phase == "ReadyToFinalize" do
        assert "symphony.dev/environment-cleanup" in api_state()["sandboxes"][record.key]["metadata"]["finalizers"]
      else
        assert api_state()["sandboxes"] == %{}
      end

      assert {:ok, [recovered]} = Kubernetes.discover(config, opts)
      refute recovered.absent?
      assert {:ok, deleted} = Kubernetes.destroy(config, recovered, opts)
      assert deleted.absent?
      assert guard_data(record)["phase"] == "Complete"
    end
  end

  test "lost receipt update responses recover only exact durable target payloads" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    command = fn exe, args, options ->
      target = guard_patch_target(args)
      response = api_command(exe, args, options)
      if target && target["phase"] in ["ReadyToFinalize", "Complete"], do: {:error, :timeout}, else: response
    end

    assert {:ok, deleted} = Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))
    assert deleted.absent?
    assert guard_data(record)["phase"] == "Complete"
  end

  for {field, value} <- [{"protocol", "unknown-v2"}, {"parentUID", "other-parent"}, {"closeRequestId", "old-close"}, {"revision", 0}, {"operationCount", 0}] do
    test "wrong controller acknowledgement #{field} retains finalizer and storage" do
      {config, record, opts} = api_fixture()
      {:ok, created} = Kubernetes.ensure(config, record, opts)

      command = fn exe, args, options ->
        response = api_command(exe, args, options)

        if close_patch?(args) do
          parent = api_state()["sandboxes"][record.key]
          put_object("sandboxes", put_in(parent, ["status", "creationJournal", "acknowledgement", unquote(field)], unquote(value)))
        end

        response
      end

      assert {:error, {:unknown, :kubernetes_controller_acknowledgement_invalid}, _} =
               Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))

      assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
      assert "symphony.dev/environment-cleanup" in api_state()["sandboxes"][record.key]["metadata"]["finalizers"]
    end
  end

  test "drained envelope with an outstanding controller attempt is rejected" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    command = fn exe, args, options ->
      response = api_command(exe, args, options)

      if close_patch?(args) do
        parent = api_state()["sandboxes"][record.key]
        put_object("sandboxes", update_in(parent, ["status", "creationJournal", "operations"], &Enum.map(&1, fn op -> Map.put(op, "state", "Issued") end)))
      end

      response
    end

    assert {:error, _, _} = Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
  end

  test "committed Pod disappearance before physical classification remains unresolved" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    create_pod(api_state()["sandboxes"][record.key])
    remove_object("pods", record.key)
    assert {:error, {:unknown, {:kubernetes_pod_safety_unresolved, "pod-uid"}}, _} = Kubernetes.destroy(config, created, opts)
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
  end

  test "committed PVC disappearance before PV capture remains a storage obligation" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    remove_object("persistentvolumeclaims", "workspace-se-ticket")
    result = Kubernetes.destroy(config, created, opts)
    assert {:error, {:unknown, {:kubernetes_storage_obligation_missing, "pvc-uid"}}, _} = result
    assert api_state()["persistentvolumes"]["pv-ticket"]
    assert api_state()["sandboxes"][record.key]
  end

  test "forged provider attribution cannot settle a late same-name parent" do
    {config, record, opts} = api_fixture(timeout_create: true)
    assert {:error, _, unresolved} = Kubernetes.ensure(config, record, opts)
    [{"sandboxes", body}] = Enum.filter(Process.get(:post_attempts), fn {resource, _} -> resource == "sandboxes" end)
    body = put_in(body, ["metadata", "annotations", "symphony.dev/create-attempt-id"], "forged")
    create_object("sandboxes", body)
    assert {:error, _, _} = Kubernetes.destroy(config, unresolved, opts)
    assert [%{"state" => "Issued"}] = guard_data(record)["operations"]
    assert api_state()["sandboxes"][record.key]
  end

  test "missing guard beside a live parent is never recreated" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    remove_object("configmaps", Guard.name(record))
    assert {:error, {:unknown, :kubernetes_guard_missing}, _} = Kubernetes.ensure(config, created, opts)
    assert {:error, _, _} = Kubernetes.destroy(config, created, opts)
    assert {:error, _, _} = Kubernetes.stop(config, created, opts)
    assert {:error, _, _} = Kubernetes.put_intent(config, created, %{desired: :absent}, opts)
    refute api_state()["configmaps"][Guard.name(record)]
    assert api_state()["sandboxes"][record.key]
  end

  test "an owned Secret with forged attempt attribution cannot be reused for startup" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, running} = Kubernetes.start(config, intended, opts)
    [secret] = Map.values(api_state()["secrets"])
    put_object("secrets", put_in(secret, ["metadata", "annotations", "symphony.dev/create-attempt-id"], "forged"))
    attempts = Process.get(:post_attempts)
    assert {:error, {:unknown, :kubernetes_create_attribution_conflict}, _} = Kubernetes.start(config, running, opts)
    assert Process.get(:post_attempts) == attempts
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
  end

  test "uncommitted Pod membership cannot authorize gate release" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    command = fn exe, args, options ->
      response = api_command(exe, args, options)
      if "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes"), do: uncommit_fixture_pod(record)
      response
    end

    assert {:error, {:unknown, :kubernetes_unjournaled_child}, _} =
             Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))

    assert %{"name" => "symphony.dev/start-authorized"} in api_state()["pods"][record.key]["spec"]["schedulingGates"]
  end

  defp uncommit_fixture_pod(record) do
    parent = api_state()["sandboxes"][record.key]
    operations = parent["status"]["creationJournal"]["operations"]

    changed =
      Enum.map(operations, fn operation ->
        if operation["resource"] == "pods",
          do: operation |> Map.put("state", "Issued") |> Map.delete("objectUID"),
          else: operation
      end)

    put_object("sandboxes", put_in(parent, ["status", "creationJournal", "operations"], changed))
  end

  test "a terminated Pod retained by API deletion does not prevent exact cleanup" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, running} = Kubernetes.start(config, intended, opts)

    command = fn exe, args, options ->
      response = api_command(exe, args, options)

      if "delete" in args and String.contains?(arg(args, "--raw"), "/pods/"),
        do: retain_first_terminated_pod(record)

      response
    end

    assert {:ok, deleted} = Kubernetes.destroy(config, running, Keyword.put(opts, :command_fun, command))
    assert deleted.absent?
    assert api_state()["pods"] == %{}
    assert guard_data(record)["evidence"]["termination"]["pod-uid"]["kind"] == "kubelet_terminated"
  end

  defp retain_first_terminated_pod(record) do
    unless Process.get(:retained_terminal_pod) do
      Process.put(:retained_terminal_pod, true)
      event = Process.get(:kubernetes_events)[{"pods", record.key}] |> List.last()
      put_object("pods", put_in(event["object"], ["metadata", "deletionTimestamp"], "2026-09-11T00:00:00Z"))
    end
  end

  test "inventory failure after proven stop preserves quiescence while retaining storage" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, running} = Kubernetes.start(config, intended, opts)
    command = fn exe, args, options -> stopped_inventory_failure(exe, args, options) end
    result = Kubernetes.destroy(config, running, Keyword.put(opts, :command_fun, command))
    assert {:error, {:denied, :kubernetes_inventory}, retained} = result
    assert {:quiescent, _} = retained.proof
    refute retained.absent?
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    assert api_state()["sandboxes"][record.key]
  end

  for {scenario, storage_failure} <- [{"alone", false}, {"before a storage failure", true}] do
    test "a fresh ungated Pod #{scenario} invalidates earlier never-executable proof" do
      {config, record, opts} = api_fixture()
      {:ok, created} = Kubernetes.ensure(config, record, opts)
      create_pod(api_state()["sandboxes"][record.key])
      {:ok, observed} = Kubernetes.inspect(config, created, opts)
      assert {:quiescent, _} = observed.proof
      pod = api_state()["pods"][record.key]
      remove_object("pods", record.key)

      command = fn exe, args, options ->
        expose_changed_pod_after_stop(args, pod, unquote(storage_failure))
        api_command(exe, args, options)
      end

      assert {:error, failure, unresolved} = Kubernetes.destroy(config, observed, Keyword.put(opts, :command_fun, command))
      if unquote(storage_failure), do: assert(failure == {:unknown, :bound_pv_missing})
      assert {:compute_unknown, _} = unresolved.proof
      assert Lifecycle.occupied?(Lifecycle.new(unresolved, "cleanup", :cleanup))
      assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
      assert api_state()["sandboxes"][record.key]
    end
  end

  defp expose_changed_pod_after_stop(args, pod, storage_failure) do
    if close_patch?(args), do: Process.put(:closed_inventory_count, 0)
    count = Process.get(:closed_inventory_count)

    cond do
      is_integer(count) and get_resource?(args, "persistentvolumeclaims") ->
        Process.put(:closed_inventory_count, count + 1)

      count == 2 and get_resource?(args, "pods") ->
        put_object("pods", put_in(pod, ["spec", "schedulingGates"], []))
        if storage_failure, do: remove_object("persistentvolumes", "pv-ticket")

      true ->
        :ok
    end
  end

  defp get_resource?(args, resource) do
    "get" in args and String.contains?(arg(args, "--raw"), "/" <> resource <> "?")
  end

  defp stopped_inventory_failure(exe, args, options) do
    path = if "--raw" in args, do: arg(args, "--raw"), else: ""

    if String.contains?(path, "/pods?") and String.contains?(path, "watch=true"),
      do: Process.put(:terminal_watch_observed, true)

    count = Process.get(:post_stop_inventory, 0)

    if Process.get(:terminal_watch_observed, false) and "get" in args and String.contains?(path, "/persistentvolumeclaims?") do
      Process.put(:post_stop_inventory, count + 1)
      if count == 1, do: json(%{"kind" => "Status", "code" => 403}), else: api_command(exe, args, options)
    else
      api_command(exe, args, options)
    end
  end

  test "absent intent closes credentials permanently and survives stop and inspect" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, closing} = Kubernetes.put_intent(config, created, %{desired: :absent}, opts)
    assert {:ok, stopped} = Kubernetes.stop(config, closing, opts)
    assert stopped.desired == :absent
    assert {:ok, inspected} = Kubernetes.inspect(config, stopped, opts)
    assert inspected.desired == :absent
    assert {:error, _, _} = Kubernetes.put_intent(config, inspected, %{desired: :running}, opts)
    assert {:error, _, _} = Kubernetes.start(config, inspected, opts)
    assert api_state()["secrets"] == %{}
  end

  test "discovery ignores another deployment guard but rejects undecodable local guard candidates" do
    {config, record, opts} = api_fixture()
    {:ok, _} = Kubernetes.ensure(config, record, opts)

    foreign = %{
      "metadata" => meta("symphony-guard-foreign", "foreign-uid"),
      "data" => %{"guard.json" => Jason.encode!(%{"identity" => %{"deploymentID" => "another-deployment"}})}
    }

    put_object("configmaps", foreign)
    assert {:ok, [discovered]} = Kubernetes.discover(config, opts)
    assert discovered.key == record.key
    put_object("configmaps", put_in(foreign, ["data", "guard.json"], "private-invalid-guard"))
    assert {:error, {:unknown, :kubernetes_guard_invalid}} = Kubernetes.discover(config, opts)
    assert api_state()["sandboxes"][record.key]
  end

  test "missing guard diagnostics preserve references but never serialize malformed durable volume contents" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    remove_object("configmaps", Guard.name(record))
    parent = api_state()["sandboxes"][record.key]
    saved = Jason.decode!(parent["metadata"]["annotations"]["symphony.dev/record"])

    for volumes <- [["private-volume-body"], %{"invalid" => "private-volume-body"}] do
      changed = put_in(saved, ["metadata", "volumes"], volumes)
      put_object("sandboxes", put_in(parent, ["metadata", "annotations", "symphony.dev/record"], Jason.encode!(changed)))
      assert {:error, {:unknown, {:kubernetes_invalid_owned_record, references}}} = Kubernetes.discover(config, opts)
      assert "sandbox-uid" in references
      refute inspect(references) =~ "private-volume-body"
      assert {:error, {:unknown, :kubernetes_guard_missing}, _} = Kubernetes.ensure(config, created, opts)
    end

    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    refute api_state()["configmaps"][Guard.name(record)]
  end

  test "a closed retained parent cannot be adopted for another execution" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, closing} = Kubernetes.put_intent(config, created, %{desired: :absent}, opts)
    assert {:error, {:unknown, :kubernetes_issuance_closed}, _} = Kubernetes.ensure(config, closing, opts)
    assert Process.get(:sandbox_creates) == 1
    assert {:ok, deleted} = Kubernetes.destroy(config, closing, opts)
    assert deleted.absent?
    assert {:ok, still_deleted} = Kubernetes.destroy(config, deleted, opts)
    assert still_deleted.absent?
  end

  test "parent loss during intent cannot turn a retained obligation into successful cleanup" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    remove_object("sandboxes", record.key)
    result = Kubernetes.put_intent(config, created, %{desired: :absent}, opts)
    assert {:error, {:unknown, :kubernetes_parent_missing}, unresolved} = result
    refute unresolved.absent?
    assert {:error, {:unknown, :kubernetes_parent_missing}, _} = Kubernetes.stop(config, unresolved, opts)
    assert api_state()["persistentvolumes"]["pv-ticket"]
  end

  test "a completed tombstone cannot hide an owner-only child that reappears" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    parent = api_state()["sandboxes"][record.key]
    {:ok, deleted} = Kubernetes.destroy(config, created, opts)
    child = %{"metadata" => child_meta(parent, "late-secret", "late-secret-uid")}
    put_object("secrets", child)

    assert {:ok, [orphan]} = Kubernetes.discover(config, opts)
    refute orphan.absent?
    assert {:error, {:unknown, :kubernetes_parent_missing}, unresolved} = Kubernetes.destroy(config, deleted, opts)
    refute unresolved.absent?
    assert api_state()["secrets"]["late-secret"] == child
    remove_object("secrets", "late-secret")
    assert {:ok, recovered} = Kubernetes.destroy(config, unresolved, opts)
    assert recovered.absent?
  end

  test "an unrecorded backing claim with the retained environment name blocks tombstone absence" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, deleted} = Kubernetes.destroy(config, created, opts)
    pv = %{"metadata" => meta("late-pv", "late-pv-uid"), "spec" => %{"claimRef" => %{"namespace" => "test", "name" => "late-" <> record.key}}}
    put_object("persistentvolumes", pv)

    assert {:ok, [orphan]} = Kubernetes.discover(config, opts)
    refute orphan.absent?
    assert {:error, {:unknown, :kubernetes_parent_missing}, _} = Kubernetes.destroy(config, deleted, opts)
    assert api_state()["persistentvolumes"]["late-pv"] == pv
  end

  for {boundary, malformed} <- [{"missing journal", nil}, {"non-list operations", %{}}, {"non-object operation", [nil]}] do
    test "#{boundary} cannot authorize controller drain or storage deletion" do
      {config, record, opts} = api_fixture()
      {:ok, created} = Kubernetes.ensure(config, record, opts)

      command = fn exe, args, options ->
        response = api_command(exe, args, options)

        if close_patch?(args) do
          parent = api_state()["sandboxes"][record.key]
          journal = parent["status"]["creationJournal"]
          Process.put(:valid_drained_journal, journal)
          changed = journal_with_invalid_operations(journal, unquote(Macro.escape(malformed)))
          put_object("sandboxes", put_in(parent, ["status", "creationJournal"], changed))
        end

        response
      end

      assert {:error, {:unknown, :kubernetes_controller_acknowledgement_invalid}, unresolved} =
               Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))

      assert {:compute_unknown, _} = unresolved.proof
      assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
      parent = api_state()["sandboxes"][record.key]
      put_object("sandboxes", put_in(parent, ["status", "creationJournal"], Process.get(:valid_drained_journal)))
      assert {:ok, deleted} = Kubernetes.destroy(config, unresolved, opts)
      assert deleted.absent?
    end
  end

  test "issued Pod obligations remain uncertain until committed and cannot disappear from later journals" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    create_pod(api_state()["sandboxes"][record.key])
    parent = api_state()["sandboxes"][record.key]
    operations = parent["status"]["creationJournal"]["operations"]
    committed = Enum.find(operations, &(&1["resource"] == "pods"))
    issued = committed |> Map.put("state", "Issued") |> Map.delete("objectUID")
    changed = Enum.map(operations, &if(&1["id"] == committed["id"], do: issued, else: &1))
    put_object("sandboxes", put_in(parent, ["status", "creationJournal", "operations"], changed))

    assert {:ok, unresolved} = Kubernetes.inspect(config, created, opts)
    assert {:compute_unknown, _} = unresolved.proof
    parent = api_state()["sandboxes"][record.key]
    put_object("sandboxes", put_in(parent, ["status", "creationJournal", "operations"], operations))
    assert {:ok, stopped} = Kubernetes.inspect(config, unresolved, opts)
    assert {:quiescent, _} = stopped.proof
    parent = api_state()["sandboxes"][record.key]
    put_object("sandboxes", update_in(parent, ["status", "creationJournal", "operations"], &Enum.reject(&1, fn op -> op["resource"] == "pods" end)))
    result = Kubernetes.inspect(config, stopped, opts)
    assert {:error, {:unknown, :kubernetes_controller_journal_invalid}, lost} = result
    assert {:compute_unknown, _} = lost.proof
  end

  test "a malformed open journal cannot preserve prior suspension proof" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, stopped} = Kubernetes.stop(config, created, opts)
    parent = api_state()["sandboxes"][record.key]
    put_object("sandboxes", put_in(parent, ["status", "creationJournal", "operations"], %{}))
    result = Kubernetes.inspect(config, stopped, opts)
    assert {:error, {:unknown, :kubernetes_controller_journal_invalid}, unresolved} = result
    assert {:compute_unknown, _} = unresolved.proof
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
  end

  defp journal_with_invalid_operations(_journal, nil), do: nil
  defp journal_with_invalid_operations(journal, operations), do: Map.put(journal, "operations", operations)

  test "inspect rejects a revised accepted drain without overwriting its saved journal" do
    {config, record, opts} = api_fixture(delay_pv: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:error, {:unknown, :kubernetes_cleanup_pending}, retained} = Kubernetes.destroy(config, created, opts)
    saved = guard_data(record)["record"]["metadata"]["creation_journal"]
    parent = api_state()["sandboxes"][record.key]
    changed = saved |> Map.update!("revision", &(&1 + 1)) |> update_in(["acknowledgement", "revision"], &(&1 + 1))
    put_object("sandboxes", put_in(parent, ["status", "creationJournal"], changed))

    assert {:error, {:unknown, :kubernetes_controller_journal_changed}, _} = Kubernetes.inspect(config, retained, opts)
    assert guard_data(record)["record"]["metadata"]["creation_journal"] == saved
    assert api_state()["persistentvolumes"]["pv-ticket"]
  end

  test "ReadyToFinalize receipt cannot substitute another parent or a different saved physical payload" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    retained = retain_ready_parent(config, created, opts)
    ready = guard_data(record)
    put_guard_data(record, put_in(ready, ["evidence", "parentUID"], "other-parent"))
    assert {:error, {:unknown, :kubernetes_finalization_unconfirmed}, _} = Kubernetes.destroy(config, retained, opts)
    refute api_state()["sandboxes"][record.key]["metadata"]["deletionTimestamp"]

    put_guard_data(record, put_in(ready, ["evidence", "physical"], %{"unrelated-pod" => %{}}))
    result = Kubernetes.put_intent(config, retained, %{desired: :absent}, opts)
    assert {:error, {:unknown, :kubernetes_finalization_unconfirmed}, _} = result
    assert api_state()["sandboxes"][record.key]
    put_guard_data(record, ready)
    assert {:ok, deleted} = Kubernetes.destroy(config, retained, opts)
    assert deleted.absent?
  end

  test "a replacement parent cannot inherit a valid ReadyToFinalize receipt" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    retained = retain_ready_parent(config, created, opts)
    parent = api_state()["sandboxes"][record.key]
    replacement = put_in(parent, ["metadata", "uid"], "replacement-uid")
    put_object("sandboxes", replacement)
    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = Kubernetes.destroy(config, retained, opts)
    result = Kubernetes.put_intent(config, retained, %{desired: :absent}, opts)
    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = result
    assert api_state()["sandboxes"][record.key] == replacement
    assert guard_data(record)["phase"] == "ReadyToFinalize"
  end

  test "parent reread loss after DELETE preserves its cleanup finalizer until a successful retry" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    command = fn exe, args, options ->
      blocked =
        "get" in args and String.contains?(arg(args, "--raw"), "/sandboxes?") and
          get_in(api_state(), ["sandboxes", record.key, "metadata", "deletionTimestamp"]) != nil

      if blocked, do: {:error, :timeout}, else: api_command(exe, args, options)
    end

    assert {:error, {:unknown, :kubernetes_finalization_unconfirmed}, retained} =
             Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))

    refute retained.absent?
    assert "symphony.dev/environment-cleanup" in api_state()["sandboxes"][record.key]["metadata"]["finalizers"]
    assert guard_data(record)["phase"] == "ReadyToFinalize"
    assert {:ok, deleted} = Kubernetes.destroy(config, retained, opts)
    assert deleted.absent?
  end

  test "a journaled Service delete failure retains cleanup authority and retries the exact child" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    parent = api_state()["sandboxes"][record.key]
    service = %{"kind" => "Service", "metadata" => child_meta(parent, "worker-service", "service-uid")}
    service = journal_child(parent, "services", service)
    put_object("services", service)

    command = fn exe, args, options ->
      if "delete" in args and String.contains?(arg(args, "--raw"), "/services/"),
        do: {:error, :timeout},
        else: api_command(exe, args, options)
    end

    assert {:error, _, retained} = Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))
    assert api_state()["services"]["worker-service"] == service
    assert guard_data(record)["phase"] == "Closing"
    assert {:ok, deleted} = Kubernetes.destroy(config, retained, opts)
    assert deleted.absent?
    assert api_state()["services"] == %{}
  end

  test "destroy cannot delete storage when its stop observation still lacks kubelet termination" do
    {config, record, opts} = api_fixture(missing_termination: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, running} = Kubernetes.start(config, intended, opts)
    assert {:error, {:unknown, :kubernetes_cleanup_pending}, unresolved} = Kubernetes.destroy(config, running, opts)
    assert {:compute_unknown, _} = unresolved.proof
    assert api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    assert api_state()["persistentvolumes"]["pv-ticket"]
    assert guard_data(record)["phase"] == "Closing"
  end

  test "a distribution whose embedded kubelet writes status under its own name still proves stop" do
    # k3s runs the kubelet inside the server binary and records "k3s" as the status
    # field manager. The manager string is writer-chosen, so requiring "kubelet" made
    # terminal status unprovable there and left every stopped worker observed forever.
    {config, record, opts} = api_fixture(status_field_manager: "k3s")
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, running} = Kubernetes.start(config, intended, opts)
    assert {:ok, stopped} = Kubernetes.stop(config, running, opts)
    assert stopped.phase == :stopped
    assert {:quiescent, _} = stopped.proof
    assert {:ok, destroyed} = Kubernetes.destroy(config, stopped, opts)
    assert destroyed.absent?
    assert api_state()["pods"] == %{}
  end

  test "inspect refuses a damaged closed acknowledgement without losing retained disk authority" do
    {config, record, opts} = api_fixture(delay_pv: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:error, {:unknown, :kubernetes_cleanup_pending}, retained} = Kubernetes.destroy(config, created, opts)
    parent = api_state()["sandboxes"][record.key]
    put_object("sandboxes", put_in(parent, ["status", "creationJournal", "acknowledgement", "closeRequestId"], "stale-close"))
    result = Kubernetes.inspect(config, retained, opts)
    assert {:error, {:unknown, :kubernetes_controller_acknowledgement_invalid}, _} = result
    assert api_state()["persistentvolumes"]["pv-ticket"]
    assert "symphony.dev/environment-cleanup" in api_state()["sandboxes"][record.key]["metadata"]["finalizers"]
  end

  test "a server CAS conflict cannot remove the parent cleanup finalizer or certify absence" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    command = fn exe, args, options ->
      blocked =
        "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes") and
          Enum.any?(Jason.decode!(File.read!(arg(args, "--patch-file"))), &(&1["path"] == "/metadata/finalizers"))

      if blocked, do: json(%{"kind" => "Status", "code" => 409}), else: api_command(exe, args, options)
    end

    assert {:error, {:unknown, :kubernetes_parent_deletion_pending}, retained} =
             Kubernetes.destroy(config, created, Keyword.put(opts, :command_fun, command))

    refute retained.absent?
    assert "symphony.dev/environment-cleanup" in api_state()["sandboxes"][record.key]["metadata"]["finalizers"]
    assert {:ok, deleted} = Kubernetes.destroy(config, retained, opts)
    assert deleted.absent?
  end

  defp retain_ready_parent(config, record, opts) do
    command = fn exe, args, options ->
      if "delete" in args and String.contains?(arg(args, "--raw"), "/sandboxes/"),
        do: {:error, :timeout},
        else: api_command(exe, args, options)
    end

    assert {:error, {:unknown, :kubernetes_finalization_unconfirmed}, retained} =
             Kubernetes.destroy(config, record, Keyword.put(opts, :command_fun, command))

    assert guard_data(record)["phase"] == "ReadyToFinalize"
    retained
  end

  defp put_guard_data(record, data) do
    guard = api_state()["configmaps"][Guard.name(record)]
    put_object("configmaps", put_in(guard, ["data", "guard.json"], Jason.encode!(data)))
  end

  defp guard_patch_target(args) do
    if "patch" in args and arg(args, "patch") == "configmaps" do
      patch = Jason.decode!(File.read!(arg(args, "--patch-file")))
      Enum.find_value(patch, &guard_patch_value/1)
    end
  end

  defp guard_patch_value(%{"path" => "/data/guard.json", "op" => "add", "value" => value}), do: Jason.decode!(value)
  defp guard_patch_value(_), do: nil

  defp close_patch?(args) do
    "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes") and
      Enum.any?(Jason.decode!(File.read!(arg(args, "--patch-file"))), &(&1["path"] == "/spec/creationControl/closeRequestId"))
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
    assert {:compute_unknown, _} = stopped.proof
    refute stopped.phase == :stopped
  end

  test "CSI backing deletion and both drained journals permit durable completion" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:ok, deleted} = Kubernetes.destroy(config, created, opts)
    assert get_in(deleted.metadata, ["volumes", "workspace-se-ticket", "deleted"]) == true
    assert deleted.absent?
    assert api_state()["sandboxes"] == %{}
    assert guard_data(record)["phase"] == "Complete"
    assert {:ok, []} = Kubernetes.discover(config, opts)
    assert {:error, _, _} = Kubernetes.ensure(config, record, opts)
  end

  test "delayed PV deletion never becomes disk absence" do
    {config, record, opts} = api_fixture(delay_pv: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    result = Kubernetes.destroy(config, created, opts)
    assert {:error, {:unknown, :kubernetes_cleanup_pending}, deleting} = result
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

  # Each adapter binds its own template identity onto the scheduler's bare record. Without it
  # ExecutionContext.managed/3 raises and preparation dies as {:invalid, :managed_execution_context},
  # so the environment is allocated and then never usable — no agent can ever be dispatched to it.
  test "a started environment carries the template identity a managed context requires" do
    {config, record, opts} = api_fixture()
    # Orchestrator.managed_record/2 builds records with template_identity: nil and leaves each
    # adapter to bind its own.
    bare = %{record | template_identity: nil}

    {:ok, created} = Kubernetes.ensure(config, bare, opts)
    assert created.template_identity == "template-uid"

    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    assert started.template_identity == "template-uid"
    assert {:ok, [discovered]} = Kubernetes.discover(config, opts)
    assert discovered.template_identity == "template-uid"
  end

  # The Pod and its journal entry become visible independently. Aborting on the gap deletes the
  # Pod, the controller recreates it, and the environment churns through its bounded journal
  # without ever starting — observed live as 59 Pod operations for one environment.
  test "a Pod observed before its journal entry is awaited rather than destroyed" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)

    hide = fn exe, args, options ->
      result = api_command(exe, args, options)
      raw = if "get" in args, do: arg(args, "--raw"), else: nil
      hidden = Process.get(:hidden_journal, 0)

      pod? = is_map(api_state()["pods"]["se-ticket"])

      if Path.basename(exe) == "kubectl" and is_binary(raw) and String.contains?(raw, "/sandboxes") and pod? and hidden < 1 do
        Process.put(:hidden_journal, hidden + 1)
        {:ok, %{status: 0, output: body}} = result
        {:ok, %{status: 0, output: Jason.encode!(update_in(Jason.decode!(body), ["items"], fn items -> Enum.map(items, &strip_pod_operations/1) end))}}
      else
        result
      end
    end

    assert {:ok, started} = Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, hide))
    assert started.metadata["authorized_pod_uids"] == ["pod-uid"]
    assert Process.get(:pod_incarnation) == 1
    assert get_in(api_state(), ["pods", "se-ticket", "status", "phase"]) == "Running"
  end

  # A WaitForFirstConsumer claim that never binds has no PV whose deletion could be proven, so
  # the evidence path can never discharge it and the identity would be retained forever. Absence
  # of both the claim and any PV referencing it is the proof that no storage was provisioned.
  test "a claim that never bound is discharged by proven absence instead of retained forever" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    state = api_state() |> put_in(["persistentvolumeclaims", "workspace-se-ticket", "spec", "volumeName"], nil) |> Map.put("persistentvolumes", %{})
    Process.put(:kubernetes_api, state)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    assert get_in(started.metadata, ["volumes", "workspace-se-ticket", "unbound"]) == true

    assert {:ok, deleted} = Kubernetes.destroy(config, started, opts)
    assert deleted.absent?
    assert api_state()["persistentvolumeclaims"] == %{}
    assert api_state()["persistentvolumes"] == %{}
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
    assert {:error, {:unknown, :kubernetes_guard_discovery_conflict}} = Kubernetes.discover(config, opts)
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

  test "denied initial POST retains its guard and never grants replay after restart" do
    {config, record, opts} = api_fixture(deny_create: true)
    assert {:error, {:unknown, :kubernetes_create_outcome}, denied} = Kubernetes.ensure(config, record, opts)
    assert denied.proof == :unknown
    refute denied.absent?
    assert {:error, _, _} = Kubernetes.stop(config, denied, opts)
    assert {:ok, [recovered]} = Kubernetes.discover(config, opts)
    assert recovered.proof == :unknown
    Process.put(:kubernetes_options, [])
    assert {:error, _, _} = Kubernetes.ensure(config, record, opts)
    assert {:error, _, _} = Kubernetes.destroy(config, recovered, opts)
    assert api_state()["sandboxes"] == %{}
    assert [%{"state" => "Issued"}] = guard_data(record)["operations"]
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
    assert {:error, {:unknown, :kubernetes_create_outcome}, denied} = Kubernetes.ensure(config, record, opts)
    assert denied.proof == :unknown
    refute denied.absent?
    assert {:error, _, unresolved} = Kubernetes.inspect(config, denied, opts)
    assert unresolved.proof == :unknown
    Process.put(:kubernetes_options, [])
    assert {:error, _, stopped} = Kubernetes.stop(config, unresolved, opts)
    assert stopped.proof == :unknown
  end

  test "denied create tracks a remaining owned artifact without inventing parent absence" do
    {config, record, opts} = api_fixture(deny_create: true, denied_artifact: true)
    assert {:error, {:unknown, :kubernetes_create_outcome}, denied} = Kubernetes.ensure(config, record, opts)
    assert denied.proof == :unknown
    refute denied.absent?
    assert [%{"state" => "Issued"}] = guard_data(record)["operations"]
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
    assert {:compute_unknown, _} = stopped.proof
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

  # A failed JSON-Patch precondition is a 422 whose prose goes to stderr, leaving no JSON body to
  # classify. Treating that as unknown poisons the record and makes the scheduler recreate and
  # re-suspend the guest forever; a read-back proves the atomic patch never applied.
  test "a stale parent precondition reported as prose is a retryable conflict, not unknown" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)

    assert {:error, {:retryable, :kubernetes_cas_conflict}, _} =
             Kubernetes.put_intent(config, created, %{desired: :running}, Keyword.put(opts, :command_fun, stale_parent_patch(record)))

    assert api_state()["sandboxes"][record.key]["spec"]["operatingMode"] == "Suspended"
    assert {:ok, observed} = Kubernetes.inspect(config, created, opts)
    assert {:ok, intended} = Kubernetes.put_intent(config, observed, %{desired: :running}, opts)
    assert intended.desired == :running
  end

  # The controller writes status and journal revisions continuously, so the parent's
  # resourceVersion moves under nearly every write. Surfacing that as a conflict failed
  # preparation outright and the environment was allocated but never usable.
  test "a parent that only moved underneath us is re-read and the write re-applied" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    once = stale_parent_patch(record, once: true)

    assert {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, Keyword.put(opts, :command_fun, once))
    assert intended.desired == :running
    assert {:ok, observed} = Kubernetes.inspect(config, intended, opts)
    assert observed.desired == :running
  end

  test "a parent whose record moved is a real conflict and is never overwritten" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    competing = stale_parent_patch(record, once: true, record_annotation: "competing-writer")

    assert {:error, {:retryable, :kubernetes_cas_conflict}, _} =
             Kubernetes.put_intent(config, created, %{desired: :running}, Keyword.put(opts, :command_fun, competing))

    assert api_state()["sandboxes"][record.key]["metadata"]["annotations"]["symphony.dev/record"] == "competing-writer"
    assert api_state()["sandboxes"][record.key]["spec"]["operatingMode"] == "Suspended"
  end

  # The live controller writes status and journal revisions continuously, so the parent's
  # resourceVersion has almost always moved by the time we write. Preparation must still
  # complete: this is the shape that left an environment allocated but never usable.
  test "a continuously reconciling controller does not block preparation" do
    {config, record, opts} = api_fixture()
    busy = busy_controller()
    opts = Keyword.put(opts, :command_fun, busy)

    assert {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    assert {:ok, started} = Kubernetes.start(config, intended, opts)
    assert started.pending == [%{verb: :start, id: "pod-uid", outcome: :succeeded}]
    assert {:ok, observed} = Kubernetes.inspect(config, started, opts)
    assert observed.phase == :running
  end

  # Every successful write is followed by an unrelated status bump, exactly as the
  # sandbox controller behaves while it reconciles.
  defp busy_controller do
    fn executable, args, call_options ->
      result = api_command(executable, args, call_options)
      parent = api_state()["sandboxes"]["se-ticket"]

      if is_map(parent) and Path.basename(executable) == "kubectl" and "patch" in args do
        put_object("sandboxes", update_in(parent, ["metadata", "resourceVersion"], &Integer.to_string(String.to_integer(&1) + 1)))
      end

      result
    end
  end

  # Only a parent that provably moved without our intent proves the patch never applied. A parent
  # that vanished, was recreated, or did not move at all leaves the failed write unexplained.
  test "an unexplained failed parent patch stays unknown instead of becoming a conflict" do
    for rewrite <- [& &1, &put_in(&1, ["metadata", "uid"], "recreated-uid"), fn _parent -> nil end] do
      {config, record, opts} = api_fixture()
      {:ok, created} = Kubernetes.ensure(config, record, opts)
      command = stale_parent_patch(record, rewrite: rewrite)
      assert {:error, {:unknown, _}, _} = Kubernetes.put_intent(config, created, %{desired: :running}, Keyword.put(opts, :command_fun, command))
    end
  end

  test "a claim that never bound stays unresolved while its volumes cannot be read or one still references it" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    claim = api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    state = api_state() |> put_in(["persistentvolumeclaims", "workspace-se-ticket", "spec", "volumeName"], nil) |> Map.put("persistentvolumes", %{})
    Process.put(:kubernetes_api, state)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    {:ok, started} = Kubernetes.start(config, intended, opts)
    assert get_in(started.metadata, ["volumes", "workspace-se-ticket", "unbound"]) == true

    assert {:error, reason, unresolved} = Kubernetes.destroy(config, started, Keyword.put(opts, :command_fun, unreadable_volumes()))
    refute reason == {:unknown, :unbound_pvc_provisioning_unresolved}
    assert api_state()["persistentvolumeclaims"] == %{}

    orphan = %{"metadata" => %{"name" => "orphan", "uid" => "orphan-uid"}, "spec" => %{"claimRef" => %{"uid" => claim["metadata"]["uid"]}}}
    put_object("persistentvolumes", orphan)
    assert {:error, {:unknown, :unbound_pvc_provisioning_unresolved}, _} = Kubernetes.destroy(config, unresolved, opts)
    assert api_state()["persistentvolumes"]["orphan"]
  end

  test "a failed authoritative parent re-read denies an unjournaled Pod with the read failure" do
    {config, record, opts} = api_fixture()
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    command = unreadable_parent_after_uncommit(record)

    assert {:error, reason, _} = Kubernetes.start(config, intended, Keyword.put(opts, :command_fun, command))
    refute reason == {:unknown, :kubernetes_unjournaled_child}
    assert Process.get(:parent_unreadable) == true
  end

  # Once the claim itself is gone, the volume list that would prove nothing references it fails.
  defp unreadable_volumes do
    fn executable, args, call_options ->
      if api_state()["persistentvolumeclaims"] == %{} and raw_path_ends_with?(args, "/persistentvolumes") do
        {:ok, %{status: 1, output: Jason.encode!(%{"kind" => "Status", "code" => 500, "message" => "volumes unavailable"})}}
      else
        api_command(executable, args, call_options)
      end
    end
  end

  # The controller issues the Pod while reconciling the start patch, and the fixture uncommits it
  # from the journal at once. The authoritative parent re-read is the first parent read after that
  # Pod has been observed, and it is the read that fails.
  defp unreadable_parent_after_uncommit(record) do
    fn executable, args, call_options ->
      if Process.get(:parent_unreadable) == true and "get" in args and raw_path_ends_with?(args, "/sandboxes") do
        {:ok, %{status: 1, output: Jason.encode!(%{"kind" => "Status", "code" => 500, "message" => "parent unavailable"})}}
      else
        respond_then_uncommit(record, executable, args, call_options)
      end
    end
  end

  defp respond_then_uncommit(record, executable, args, call_options) do
    response = api_command(executable, args, call_options)

    if "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes"), do: uncommit_fixture_pod(record)
    if "get" in args and raw_path_ends_with?(args, "/pods") and api_state()["pods"] != %{}, do: Process.put(:parent_unreadable, true)

    response
  end

  defp raw_path_ends_with?(args, suffix), do: "--raw" in args and String.ends_with?(URI.parse(arg(args, "--raw")).path || "", suffix)

  # Models the controller bumping the parent between our read and our patch: the patch is
  # rejected as prose with no body, exactly as kubectl reports a failed precondition.
  defp stale_parent_patch(record, options \\ []) do
    fn executable, args, call_options ->
      spent = options[:once] == true and Process.get(:stale_parent_patch) != nil

      if Path.basename(executable) == "kubectl" and "patch" in args and Enum.any?(args, &String.starts_with?(&1, "sandboxes.")) and not spent do
        Process.put(:stale_parent_patch, true)
        rewrite_parent(record, options)
        {:ok, %{status: 1, output: "The request is invalid: the server rejected our request due to an error in our request"}}
      else
        api_command(executable, args, call_options)
      end
    end
  end

  defp rewrite_parent(record, options) do
    parent = api_state()["sandboxes"][record.key]
    rewritten = Keyword.get(options, :rewrite, &bump_resource_version/1).(parent)
    store_parent(record, annotate_record(rewritten, options[:record_annotation]))
  end

  defp store_parent(record, nil), do: Process.put(:kubernetes_api, update_in(api_state(), ["sandboxes"], &Map.delete(&1, record.key)))
  defp store_parent(_record, parent), do: put_object("sandboxes", parent)
  defp bump_resource_version(parent), do: update_in(parent, ["metadata", "resourceVersion"], &Integer.to_string(String.to_integer(&1) + 1))
  defp annotate_record(object, annotation) when annotation in [nil, false], do: object
  defp annotate_record(object, annotation), do: put_in(object, ["metadata", "annotations", "symphony.dev/record"], annotation)

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

  test "denied POST remains unresolved after owned artifacts vanish" do
    {config, record, opts} = api_fixture(deny_create: true, denied_artifact: true)
    {:error, {:unknown, _}, denied} = Kubernetes.ensure(config, record, opts)
    remove_object("secrets", "partial-secret")
    assert {:error, _, unresolved} = Kubernetes.inspect(config, denied, opts)
    assert unresolved.proof == :unknown
    refute unresolved.absent?
    assert {:error, _, _} = Kubernetes.destroy(config, unresolved, opts)
    assert guard_data(record)["phase"] == "Closing"
    assert [%{"state" => "Issued"}] = guard_data(record)["operations"]
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
    assert {:compute_unknown, _} = unresolved.proof
    result = Kubernetes.destroy(config, unresolved, blocked_opts)
    assert {:error, {:unknown, {:kubernetes_pod_safety_unresolved, "pod-uid"}}, _} = result
    assert {:ok, stopped} = Kubernetes.inspect(config, unresolved, opts)
    assert {:quiescent, _} = stopped.proof

    assert {:error, {:unknown, :kubernetes_cleanup_pending}, deleting} =
             Kubernetes.destroy(config, stopped, blocked_opts)

    refute get_in(deleting.metadata, ["volumes", "workspace-se-ticket", "deleted"]) == true
  end

  test "CSI deletion accepts the last stored PV metadata when finalizer removal deletes atomically" do
    {config, record, opts} = api_fixture(delay_pv: true)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:error, {:unknown, :kubernetes_cleanup_pending}, deleting} = Kubernetes.destroy(config, created, opts)

    pv = api_state()["persistentvolumes"]["pv-ticket"]
    put_event("persistentvolumes", "pv-ticket", %{"type" => "DELETED", "object" => pv})
    remove_object("persistentvolumes", "pv-ticket")

    assert {:ok, deleted} = Kubernetes.destroy(config, deleting, opts)
    assert deleted.absent?
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

    assert {:error, {:unknown, :kubernetes_guard_update_unconfirmed}, denied} =
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
    assert {:error, {:unknown, :kubernetes_guard_discovery_conflict}} = Kubernetes.discover(config, opts)
    assert {:error, {:unknown, :kubernetes_ownership_changed}, _} = Kubernetes.start(config, created, opts)
    assert api_state()["pods"] == %{}
  end

  defp cancel_at_boundary(args, :credentials) do
    if "--path" in args and String.contains?(arg(args, "--path"), "/secrets"), do: cancel_saved_intent()
  end

  defp cancel_at_boundary(args, :running) do
    if "patch" in args and get_in(api_state(), ["sandboxes", "se-ticket", "spec", "operatingMode"]) == "Running",
      do: cancel_saved_intent()
  end

  defp cancel_saved_intent do
    sandbox = api_state()["sandboxes"]["se-ticket"]
    saved = Jason.decode!(sandbox["metadata"]["annotations"]["symphony.dev/record"])
    sandbox = put_in(sandbox, ["metadata", "annotations", "symphony.dev/record"], Jason.encode!(%{saved | "desired" => "stopped"}))
    {guard_name, guard} = Enum.find(api_state()["configmaps"], fn {_, object} -> get_in(object, ["data", "guard.json"]) != nil end)
    data = Jason.decode!(guard["data"]["guard.json"])
    data = put_in(data, ["record", "desired"], "stopped")

    patch_object("configmaps", guard_name, [
      %{"op" => "test", "path" => "/metadata/uid", "value" => guard["metadata"]["uid"]},
      %{"op" => "test", "path" => "/metadata/resourceVersion", "value" => guard["metadata"]["resourceVersion"]},
      %{"op" => "add", "path" => "/data/guard.json", "value" => Jason.encode!(data)}
    ])

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
    assert {:error, {:unknown, :kubernetes_guard_discovery_conflict}} = Kubernetes.discover(config, opts)
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

    assert {:error, {:unknown, _}, denied} =
             Kubernetes.ensure(config, record, Keyword.put(opts, :command_fun, command))

    assert denied.proof == :unknown
    refute denied.absent?
    assert api_state()["sandboxes"][record.key]["metadata"]["uid"] == "concurrent-parent"
    assert api_state()["services"]["owner-only"]["metadata"]["uid"] == "owner-service"
    assert [%{"state" => "Issued"}] = guard_data(record)["operations"]
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

      if "--path" in args and String.contains?(arg(args, "--path"), "/secrets"),
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

  test "late committed gated Pod is physically classified before complete cleanup" do
    {config, record, opts} = api_fixture(late_cleanup_pod: :gated)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:ok, deleted} = Kubernetes.destroy(config, created, opts)
    assert deleted.absent?
    assert api_state()["pods"] == %{}
    assert guard_data(record)["evidence"]["physical"]["pod-uid"]["kind"] == "terminated"
  end

  test "late committed ungated Pod blocks cleanup without physical evidence" do
    {config, record, opts} = api_fixture(late_cleanup_pod: :ungated)
    {:ok, created} = Kubernetes.ensure(config, record, opts)
    assert {:error, {:unknown, {:kubernetes_pod_safety_unresolved, "pod-uid"}}, _} = Kubernetes.destroy(config, created, opts)
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
    put_object("sandboxes", put_in(parent, ["status", "conditions"], []))
    {:ok, intended} = Kubernetes.put_intent(config, created, %{desired: :running}, opts)
    put_object("sandboxes", put_in(api_state()["sandboxes"][record.key], ["status", "conditions"], []))
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

    assert {:error, {:unknown, :kubernetes_guard_update_unconfirmed}, _} =
             Kubernetes.put_intent(config, intended, %{desired: :stopped}, Keyword.put(opts, :command_fun, conflict))
  end

  test "malformed create response is recovered only by a matching authoritative object" do
    {config, record, opts} = api_fixture()

    command = fn exe, args, options ->
      response = api_command(exe, args, options)
      malformed_create_response(args, response)
    end

    assert {:ok, recovered} = Kubernetes.ensure(config, record, Keyword.put(opts, :command_fun, command))
    assert recovered.provider_ref == "sandbox-uid"
    assert [%{"state" => "Committed", "objectUID" => "sandbox-uid"}] = guard_data(record)["operations"]
    assert Process.get(:sandbox_creates) == 1
  end

  defp malformed_create_response(args, response) do
    if "--path" in args and String.contains?(arg(args, "--path"), "/sandboxes") do
      {:ok, %{output: output}} = response
      body = output |> Jason.decode!() |> put_in(["metadata", "annotations", "symphony.dev/record"], "invalid")
      json(body)
    else
      response
    end
  end

  defp concurrent_denial_artifacts(args, record) do
    if "--path" in args and String.contains?(arg(args, "--path"), "/sandboxes") do
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

    template =
      if options[:pinned_host],
        do: put_in(template, ["spec", "podTemplate", "spec", "nodeSelector"], %{"kubernetes.io/hostname" => "worker-1"}),
        else: template

    image = "ghcr.io/trazadera/agent-sandbox-symphony-controller@sha256:" <> String.duplicate("a", 64)

    q = %{
      "release" => "approved-7140d4b65725",
      "template_uid" => "template-uid",
      "template_digest" => fixture_digest(template["spec"]),
      "qualification_report" => "operator-audit/test-profile",
      "termination_contract" => "approved-pending-fault-matrix-kubelet-all-containers-v1",
      "controller_namespace" => "controllers",
      "controller_name" => "sandbox",
      "controller_uid" => "controller-uid",
      "controller_source_commit" => "7140d4b657253e6bf318bd93e2a66ba67094d8d3",
      "controller_image" => image,
      "runtime_class_uid" => "runtime-uid",
      "runtime_handler" => "qualified-vm",
      "storage_class_uids" => ["class-uid"],
      "csi_driver" => "qualified.csi",
      "network_policy_uid" => "policy-uid",
      "network_profile_label" => "profile"
    }

    schemas = __DIR__ |> Path.join("../fixtures/kubernetes_approved_schemas.json") |> File.read!() |> Jason.decode!()

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
      "nodes" => if(options[:pinned_host], do: %{"worker-1" => node_object()}, else: %{}),
      "hostlossdeclarations" => %{},
      "sandboxes" => %{},
      "pods" => %{},
      "persistentvolumeclaims" => %{},
      "persistentvolumes" => %{},
      "secrets" => %{},
      "services" => %{}
    }

    # Alarms are durable by design and nothing prunes them, so they outlive a test unless the
    # fixture clears them.
    Repo.delete_all(LossAlarm)
    on_exit(fn -> Repo.delete_all(LossAlarm) end)

    Process.put(:kubernetes_api, state)
    Process.put(:kubernetes_options, options)
    Process.put(:kubernetes_events, %{})
    Process.put(:sandbox_creates, 0)
    Process.put(:post_attempts, [])
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

      "symphony-kubernetes-create" ->
        path = arg(args, "--path")
        assert URI.parse(path).query == nil
        resource = path |> String.split("/", trim: true) |> List.last()
        body = args |> arg("--file") |> File.read!() |> Jason.decode!()
        Process.put(:post_attempts, [{resource, body} | Process.get(:post_attempts, [])])
        create_response(resource, body)
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

    object_uid =
      case resource do
        "sandboxes" -> "sandbox-uid"
        "configmaps" -> "guard-uid"
        "secrets" -> "secret-uid"
      end

    object = Map.put(body, "metadata", Map.merge(body["metadata"], meta(name, object_uid)))
    if api_state()[resource][name], do: raise("fixture attempted duplicate POST")
    put_object(resource, object)

    if resource == "sandboxes" do
      Process.put(:sandbox_creates, Process.get(:sandbox_creates) + 1)
      object = suspend_status(object)
      put_object(resource, object)
      claim_template = hd(object["spec"]["volumeClaimTemplates"])

      pvc = %{
        "kind" => "PersistentVolumeClaim",
        "metadata" => Map.merge(claim_template["metadata"], child_meta(object, "workspace-" <> name, "pvc-uid")),
        "spec" => %{"storageClassName" => "private", "volumeName" => "pv-ticket"}
      }

      pvc = journal_child(object, "persistentvolumeclaims", pvc)

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
      if option(:lost_create), do: {:error, {:unknown, :lost_create_response}}, else: json(api_state()["sandboxes"][name])
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

        json(api_state()[resource][name] || %{"kind" => "Status", "code" => 200})

      :conflict ->
        json(%{"kind" => "Status", "code" => 409})
    end
  end

  defp reconcile_patch("sandboxes", updated, _patch) do
    cond do
      get_in(updated, ["metadata", "deletionTimestamp"]) != nil and get_in(updated, ["metadata", "finalizers"]) == [] ->
        remove_object("sandboxes", updated["metadata"]["name"])

      get_in(updated, ["spec", "creationControl", "closeRequestId"]) != nil ->
        reconcile_closed_parent(updated)

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

  defp reconcile_closed_parent(updated) do
    if get_in(updated, ["status", "creationJournal", "phase"]) == "Open", do: late_cleanup_pod(updated)
    close_fixture_journal(api_state()["sandboxes"][updated["metadata"]["name"]])
  end

  defp create_pod(parent) do
    incarnation = Process.get(:pod_incarnation, 0) + 1
    Process.put(:pod_incarnation, incarnation)
    uid = if incarnation == 1, do: "pod-uid", else: "pod-uid-#{incarnation}"
    metadata = Map.merge(parent["spec"]["podTemplate"]["metadata"], child_meta(parent, parent["metadata"]["name"], uid))
    pod = Map.put(parent["spec"]["podTemplate"], "metadata", metadata) |> Map.put("kind", "Pod")
    pod = journal_child(parent, "pods", pod)
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
    put_object("sandboxes", Map.update(parent, "status", %{"conditions" => [condition]}, &Map.put(&1, "conditions", [condition])))
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
  end

  defp delete_effect("pods", name, object) do
    if not option(:missing_termination) do
      terminated = %{"finishedAt" => "2026-09-11T00:00:00Z", "containerID" => "containerd://worker", "reason" => "Completed"}
      statuses = [%{"name" => "worker", "state" => %{"terminated" => terminated}}]

      terminal =
        object
        |> put_in(["metadata", "managedFields"], [%{"manager" => option(:status_field_manager) || "kubelet", "subresource" => "status"}])
        |> Map.put("status", %{"phase" => "Succeeded", "containerStatuses" => statuses})

      put_event("pods", name, %{"type" => "MODIFIED", "object" => terminal})
    end

    remove_object("pods", name)
  end

  defp delete_effect("persistentvolumeclaims", name, _object) do
    remove_object("persistentvolumeclaims", name)
    pv = api_state()["persistentvolumes"]["pv-ticket"]

    # A claim that never bound has no volume to release, so only a provisioned one emits a
    # deletion event. Without this the fixture raises instead of modelling the real API.
    if is_map(pv) and not option(:delay_pv) do
      put_event("persistentvolumes", "pv-ticket", %{"type" => "DELETED", "object" => put_in(pv, ["metadata", "finalizers"], [])})
      remove_object("persistentvolumes", "pv-ticket")
    end
  end

  defp delete_effect(resource, name, _object), do: remove_object(resource, name)

  defp suspend_status(object) do
    condition = %{"type" => "Suspended", "status" => "True", "observedGeneration" => object["metadata"]["generation"]}
    Map.update(object, "status", %{"conditions" => [condition]}, &Map.put(&1, "conditions", [condition]))
  end

  defp strip_pod_operations(sandbox) do
    if get_in(sandbox, ["status", "creationJournal", "operations"]) do
      update_in(sandbox, ["status", "creationJournal", "operations"], &Enum.reject(&1, fn op -> op["resource"] == "pods" end))
    else
      sandbox
    end
  end

  defp late_missing_pod_after_close(record, storage_failure) do
    fn exe, args, options ->
      response = api_command(exe, args, options)

      if "patch" in args and String.starts_with?(arg(args, "patch"), "sandboxes") and
           guard_data(record)["phase"] == "Closing" and Process.get(:late_missing_pod) != true do
        Process.put(:late_missing_pod, true)

        parent = api_state()["sandboxes"][record.key]
        inject_missing_storage(storage_failure, parent)
        create_pod(api_state()["sandboxes"][record.key])
        remove_object("pods", record.key)
      end

      response
    end
  end

  defp inject_missing_storage(:none, _parent), do: :ok
  defp inject_missing_storage(:missing_pv, _parent), do: remove_object("persistentvolumes", "pv-ticket")

  defp inject_missing_storage(:missing_pvc, parent) do
    pvc = api_state()["persistentvolumeclaims"]["workspace-se-ticket"]
    late = %{pvc | "metadata" => child_meta(parent, "late-workspace-se-ticket", "late-pvc-uid")}
    journal_child(parent, "persistentvolumeclaims", late)
  end

  defp journal_child(parent, resource, object) do
    parent = api_state()["sandboxes"][parent["metadata"]["name"]]

    operation = %{
      "id" => "attempt-" <> object["metadata"]["uid"],
      "issuerId" => "fixture-controller",
      "group" => "",
      "resource" => resource,
      "namespace" => "test",
      "name" => object["metadata"]["name"],
      "parentUID" => parent["metadata"]["uid"],
      "state" => "Committed",
      "objectUID" => object["metadata"]["uid"]
    }

    journal = get_in(parent, ["status", "creationJournal"]) || %{"parentUID" => parent["metadata"]["uid"], "phase" => "Open", "revision" => 1, "operations" => []}
    journal = journal |> Map.update!("operations", &(&1 ++ [operation])) |> Map.update!("revision", &(&1 + 1))
    put_object("sandboxes", put_in(parent, ["status", "creationJournal"], journal))

    annotations = %{
      "agents.x-k8s.io/create-protocol" => "symphony-create-drain-v1",
      "agents.x-k8s.io/create-parent-uid" => parent["metadata"]["uid"],
      "agents.x-k8s.io/create-attempt-id" => operation["id"]
    }

    update_in(object, ["metadata", "annotations"], &Map.merge(&1 || %{}, annotations))
  end

  defp close_fixture_journal(parent) do
    journal = get_in(parent, ["status", "creationJournal"])

    if journal["phase"] != "Drained" and not option(:missing_ack) do
      revision = journal["revision"] + 1

      ack = %{
        "protocol" => "symphony-create-drain-v1",
        "parentUID" => parent["metadata"]["uid"],
        "closeRequestId" => parent["spec"]["creationControl"]["closeRequestId"],
        "revision" => revision,
        "operationCount" => length(journal["operations"])
      }

      journal = Map.merge(journal, %{"phase" => "Drained", "revision" => revision, "acknowledgement" => ack})
      put_object("sandboxes", put_in(parent, ["status", "creationJournal"], journal))
    end
  end

  defp guard_data(record), do: Jason.decode!(api_state()["configmaps"][Guard.name(record)]["data"]["guard.json"])

  defp child_meta(parent, name, uid),
    do:
      Map.put(meta(name, uid), "ownerReferences", [
        %{"apiVersion" => "agents.x-k8s.io/v1beta1", "kind" => "Sandbox", "uid" => parent["metadata"]["uid"], "name" => parent["metadata"]["name"], "controller" => true}
      ])

  defp kubernetes_front_matter do
    """
    tracker:
      kind: memory
    workspace:
      root: /state/workspaces
    worker:
      environment:
        kind: kubernetes
        deployment_id: deployment
        startup_timeout_ms: 1000
        shutdown_timeout_ms: 1000
        provider:
          kubeconfig: #{__ENV__.file}
          context: test
          namespace: test
          template: development
          ssh_user: worker
          ssh_port: 2222
          ssh_auth_volume: ssh-auth
    """
  end

  defp node_object do
    info = %{"machineID" => "machine", "systemUUID" => "system", "bootID" => "boot"}
    %{"metadata" => meta("worker-1", "node-uid"), "status" => %{"nodeInfo" => info}}
  end

  # The machine is gone: its Node object is collected and the provider issues the receipt that
  # names it and the disk that died with it.
  defp destroy_host(handles) do
    remove_object("nodes", "worker-1")

    body = %{
      "provider" => "fixture-provider",
      "machine_id" => "machine",
      "system_uuid" => "system",
      "destroyedVolumeHandles" => handles,
      "destroyedAt" => "2026-09-19T00:00:00Z"
    }

    put_object("configmaps", %{"metadata" => meta("symphony-destruction-receipt-3070466", "receipt-uid"), "immutable" => true, "data" => %{"receipt.json" => Jason.encode!(body)}})
  end

  defp refusal(config, record, opts, overrides \\ %{}) do
    {:error, {_, reason}} = Kubernetes.declare_lost(config, loss_declaration(record, overrides), opts)
    reason
  end

  defp loss_declaration(record, overrides \\ %{}) do
    guard = api_state()["configmaps"][Guard.name(record)]
    saved = guard_data(record)

    spec = %{
      "schemaVersion" => 1,
      "deploymentId" => record.deployment_id,
      "host" => Map.take(saved["hostBinding"], ~w(node_name node_uid machine_id system_uuid)),
      "environmentKeys" => [record.key],
      "obligationUIDs" => Enum.sort(saved["record"]["metadata"]["authorized_pod_uids"] ++ ["pvc-uid"]),
      "guards" => %{record.key => %{"uid" => guard["metadata"]["uid"], "resourceVersion" => guard["metadata"]["resourceVersion"]}},
      "receiptName" => "symphony-destruction-receipt-3070466",
      "operatorSubject" => "operator@example.test",
      "chunkIndex" => 0,
      "chunkTotal" => 1
    }

    {:ok, declaration} = Declaration.decode(Map.merge(spec, overrides))
    declaration
  end

  defp publish_declaration(record, overrides \\ %{}) do
    declaration = loss_declaration(record)
    object = %{"metadata" => meta(declaration.name, "declaration-uid"), "spec" => declaration.spec}
    object = Map.merge(object, overrides)
    put_object("hostlossdeclarations", object)
    declaration
  end

  defp declaration_status(declaration), do: get_in(api_state(), ["hostlossdeclarations", declaration.name, "status"])

  defp meta(name, uid), do: %{"name" => name, "uid" => uid, "resourceVersion" => "1", "generation" => 1, "namespace" => "test"}
  defp put_object(resource, object), do: Process.put(:kubernetes_api, put_in(api_state(), [resource, object["metadata"]["name"]], object))
  defp remove_object(resource, name), do: Process.put(:kubernetes_api, Map.update!(api_state(), resource, &Map.delete(&1, name)))
  defp put_event(resource, name, event), do: Process.put(:kubernetes_events, Map.update(Process.get(:kubernetes_events), {resource, name}, [event], &(&1 ++ [event])))
  defp api_state, do: Process.get(:kubernetes_api)
  defp option(key), do: Keyword.get(Process.get(:kubernetes_options), key, false)
  defp arg(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)
  # arg/2 raises when the flag is absent, and a kubectl patch has no --raw at all.
  defp raw_path?(args, fragment), do: "--raw" in args and String.contains?(arg(args, "--raw"), fragment)
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
