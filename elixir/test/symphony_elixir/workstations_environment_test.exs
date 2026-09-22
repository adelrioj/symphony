defmodule SymphonyElixir.WorkstationsEnvironmentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.{Operations, Record, Workstations}
  alias SymphonyElixir.ExecutionEnvironment.Workstations.Client
  alias SymphonyElixir.SSH

  test "STOPPED with no listed operations cannot erase an unknown start" do
    record = %Record{
      key: "se-ticket",
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "google_workstations",
      scope: %{},
      workspace_path: "/home/user/workspaces/se-ticket",
      template_identity: "config-uid",
      pending: [%{verb: :start, id: nil, outcome: :unknown}]
    }

    workstation = %{"uid" => "ws-uid", "etag" => "v2", "state" => "STATE_STOPPED", "reconciling" => false}
    observed = Workstations.normalize(record, workstation, [])
    assert observed.phase == :unknown
    assert observed.proof == :unknown
    assert observed.pending == record.pending
  end

  test "successful stop requires exact UID and terminal operation, not HTTP success" do
    pending = [%{verb: :stop, id: operation_name(), outcome: :pending}]
    record = %{record() | provider_ref: %{name: name(), uid: "ws-uid"}, pending: pending}
    assert Workstations.normalize(record, workstation(), [operation("stop", false)]).proof == :unknown
    stopped = Workstations.normalize(record, workstation(), [operation("stop", true)])
    assert {:quiescent, _} = stopped.proof
    assert stopped.phase == :stopped
    assert Workstations.normalize(record, Map.put(workstation(), "uid", "replacement"), [operation("stop", true)]).proof == :unknown
    failed = Map.put(operation("stop", true), "error", %{"code" => 13})
    assert Workstations.normalize(record, workstation(), [failed]).proof == :unknown
  end

  test "operation correlation needs exact target, verb and saved time bounds" do
    marker = %{verb: :start, id: nil, outcome: :unknown, from: "2026-09-11T10:00:00Z", until: "2026-09-11T10:01:00Z"}
    record = %{record() | provider_ref: %{name: name(), uid: "ws-uid"}, pending: [marker]}
    op = operation("start", true) |> put_in(["metadata", "createTime"], "2026-09-11T10:00:30Z")
    observed = Workstations.normalize(record, workstation(), [op])
    assert [%{id: id, outcome: :succeeded}] = observed.pending
    assert id == operation_name()
    assert Workstations.normalize(record, workstation(), [put_in(op, ["metadata", "target"], name() <> "-other")]).pending == [marker]
    assert Workstations.normalize(record, workstation(), [op, Map.put(op, "name", operation_name() <> "2")]).pending == [marker]
  end

  test "client never replays an ambiguous mutation and redacts transport failures" do
    request = fn _ -> {:error, {:timeout, "secret-token"}} end
    path = "/v1/" <> name() <> ":start"
    assert {:error, {:unknown, :workstations_transport}} = Client.request(config(), :post, path, [], %{}, opts(request))
  end

  test "definite authorization denial is not absence" do
    options = opts(fn _ -> response(403, %{}) end)
    assert {:error, {:denied, :workstations_authorization}, _} = Workstations.inspect(config(), record(), options)
  end

  test "missing resource does not authorize replay of lost create" do
    record = %{record() | pending: [%{verb: :create, id: nil, outcome: :unknown}]}

    request = fn req ->
      case req[:method] do
        :get -> response(404, %{})
        _ -> flunk("ambiguous create was replayed")
      end
    end

    assert {:error, {:unknown, _}, returned} = Workstations.ensure(config(), record, opts(request))
    assert returned.pending == record.pending
    refute returned.absent?
  end

  test "page two orphan disk blocks discovery rather than manufacturing issue identity" do
    disk = %{"id" => "123", "selfLink" => "https://www.googleapis.com/compute/v1/projects/p/zones/z/disks/orphan", "labels" => labels()}

    request = fn req ->
      cond do
        String.ends_with?(req[:url], "/workstationConfigs") -> response(200, %{"workstationConfigs" => []})
        String.ends_with?(req[:url], "/operations") -> response(200, %{"operations" => []})
        String.ends_with?(req[:url], "/instances") -> response(200, %{"items" => %{}})
        req[:params][:pageToken] == "next" -> response(200, %{"items" => %{"zones/z" => %{"disks" => [disk]}}})
        String.ends_with?(req[:url], "/disks") -> response(200, %{"items" => %{}, "nextPageToken" => "next"})
      end
    end

    assert {:error, {:unknown, {:orphan_backing_resources, ids}}} = Workstations.discover(config(), opts(request))
    assert Enum.any?(ids, &(&1["id"] == "123"))
  end

  test "denied or unreachable inventory never becomes an empty successful discovery" do
    denied = opts(fn _ -> response(403, %{}) end)
    partial = opts(fn _ -> response(200, %{"unreachable" => ["scope"]}) end)
    assert {:error, {:denied, :workstations_authorization}} = Workstations.discover(config(), denied)
    assert {:error, {:unknown, :partial_inventory}} = Workstations.discover(config(), partial)
  end

  test "parent 404 with a labeled disk remains billable cleanup, never absence" do
    disk = %{"id" => "456", "selfLink" => "https://www.googleapis.com/compute/v1/projects/p/zones/z/disks/d", "labels" => labels()}
    pending = [%{verb: :delete, id: operation_name(), outcome: :succeeded}]
    record = %{record() | pending: pending, provider_ref: %{name: name(), uid: "ws-uid"}}

    request = fn req ->
      cond do
        String.ends_with?(req[:url], "/disks") -> response(200, %{"items" => %{"zones/z" => %{"disks" => [disk]}}})
        String.ends_with?(req[:url], "/instances") -> response(200, %{"items" => %{}})
        String.ends_with?(req[:url], "/operations") -> response(200, %{"operations" => []})
        true -> response(404, %{})
      end
    end

    result = Workstations.destroy(config(), record, opts(request))
    assert {:error, {:unknown, {:backing_resources_remaining, _}}, returned} = result
    refute returned.absent?
    assert returned.metadata["backing_resources"] != []
  end

  test "qualified lifecycle survives restart, retains terminal time, reopens and destroys" do
    {server, request} = provider()
    options = opts(request)
    assert {:ok, created} = Workstations.ensure(config(), %{record() | attempt_id: "attempt-1"}, options)
    assert {:ok, intent} = Workstations.put_intent(config(), created, %{desired: :running}, options)
    assert {:ok, running} = Workstations.start(config(), intent, options)
    assert running.phase == :running
    assert {:ok, stopped} = Workstations.stop(config(), running, options)
    assert {:quiescent, _} = stopped.proof
    terminal = 1_789_128_000_000
    terminal_intent = %{desired: :stopped, terminal_observed_at: terminal}
    assert {:ok, _} = Workstations.put_intent(config(), stopped, terminal_intent, options)
    assert {:ok, [recovered]} = Workstations.discover(config(), options)
    assert recovered.terminal_observed_at == terminal
    assert recovered.desired == :stopped
    reopen_intent = %{desired: :running, terminal_observed_at: nil, attempt_id: "attempt-2"}
    assert {:ok, reopening} = Workstations.put_intent(config(), recovered, reopen_intent, options)
    assert {:ok, reopened} = Workstations.start(config(), reopening, options)
    assert reopened.provider_ref.uid == running.provider_ref.uid
    assert reopened.terminal_observed_at == nil
    assert {:ok, destroyed} = Workstations.destroy(config(), reopened, options)
    assert destroyed.absent?
    assert {:quiescent, _} = destroyed.proof
    assert Agent.get(server, & &1.workstation) == nil
  end

  test "a lost create response is recovered by exact owned metadata without a second create" do
    {server, request} = provider(%{lose_create: true})
    assert {:error, {:unknown, _}, uncertain} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, recovered} = Workstations.ensure(config(), uncertain, opts(request))
    assert recovered.provider_ref.uid == "ws-uid"
    assert Agent.get(server, & &1.creates) == 1
  end

  test "foreign resource UID and retained config drift block reuse" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    Agent.update(server, &put_in(&1, [:workstation, "uid"], "replacement"))
    assert {:error, {:invalid, :workstations_ownership}, _} = Workstations.ensure(config(), created, opts(request))
    Agent.update(server, &put_in(&1, [:workstation, "uid"], "ws-uid"))
    Agent.update(server, &put_in(&1, [:template, "container", "image"], "changed-image"))
    assert {:error, {:invalid, :workstations_config_changed}, _} = Workstations.ensure(config(), created, opts(request))
  end

  test "stop LRO error never certifies cancellation" do
    {_server, request} = provider(%{stop_error: true})
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:error, {:unknown, {:operation_failed, :stop, 13}}, failed} = Workstations.stop(config(), created, opts(request))
    assert failed.proof == :unknown
    refute failed.absent?
  end

  test "a later failed start invalidates an earlier successful stop certificate" do
    pending = [%{verb: :stop, id: "old", outcome: :succeeded}, %{verb: :start, id: "new", outcome: :failed}]
    assert Workstations.normalize(%{record() | pending: pending}, workstation(), []).proof == :unknown
  end

  test "protobuf omitted false reconciliation is quiescent only with successful stop evidence" do
    pending = [%{verb: :stop, id: operation_name(), outcome: :succeeded}]
    record = %{record() | provider_ref: %{name: name(), uid: "ws-uid"}, pending: pending}
    assert {:quiescent, _} = Workstations.normalize(record, Map.delete(workstation(), "reconciling"), []).proof
    assert Workstations.normalize(record, Map.put(workstation(), "reconciling", true), []).proof == :unknown
  end

  test "one scoped OAuth token is reused across requests with at most one definite 401 refresh" do
    token_fun = fn _, _ ->
      count = Process.get(:tokens, 0) + 1
      Process.put(:tokens, count)
      {:ok, "token-#{count}"}
    end

    request = fn req ->
      case req[:headers] do
        [{"authorization", "Bearer token-1"}] -> response(401, %{})
        [{"authorization", "Bearer token-2"}] -> response(200, %{"done" => true})
      end
    end

    options = [request_fun: request, token_fun: token_fun, timeout_ms: 1_000]
    assert {:ok, %{status: 200}} = Client.request(config(), :get, "/v1/" <> operation_name(), [], nil, options)
    assert {:ok, %{status: 200}} = Client.request(config(), :get, "/v1/" <> operation_name(), [], nil, options)
    assert Process.get(:tokens) == 2
    assert {:ok, %{status: 401}} = Client.request(config(), :get, "/v1/" <> operation_name(), [], nil, Keyword.put(options, :request_fun, fn _ -> response(401, %{}) end))
    assert Process.get(:tokens) == 2
  end

  test "an expired lifecycle deadline cannot issue a provider request" do
    request = fn _ -> flunk("provider request after deadline") end

    assert {:error, {:unknown, :workstations_deadline}} =
             Client.request(config(), :post, "/v1/" <> name() <> ":start", [], %{}, Keyword.put(opts(request), :deadline, System.monotonic_time(:millisecond) - 1))
  end

  test "configuration page two finds retained resources after configured name changes" do
    {_server, base} = provider()
    assert {:ok, _} = Workstations.ensure(config(), record(), opts(base))

    request = fn req ->
      if String.ends_with?(req[:url], "/workstationConfigs") and req[:params][:pageToken] == nil,
        do: response(200, %{"workstationConfigs" => [], "nextPageToken" => "old-config"}),
        else: base.(req)
    end

    changed = put_in(config(), [:provider, "config"], "new-version")
    assert {:ok, [retained]} = Workstations.discover(changed, opts(request))
    assert retained.metadata["config_name"] == "projects/p/locations/l/workstationClusters/c/workstationConfigs/cfg"
    assert retained.issue_id == "ticket"
  end

  test "denied Compute inventory blocks even an otherwise empty discovery" do
    request = fn req ->
      if String.contains?(req[:url], "/aggregated/"), do: response(403, %{}), else: response(200, %{})
    end

    assert {:error, {:denied, :workstations_authorization}} = Workstations.discover(config(), opts(request))
  end

  test "metadata LRO timeout prevents a second intent mutation" do
    {_server, base} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(base))

    stalled = fn req ->
      case base.(req) do
        {:ok, %{status: 200, body: %{"metadata" => %{"verb" => "update"}} = body}} ->
          if req[:method] == :get, do: {:error, :timeout}, else: response(200, Map.put(body, "done", false))

        {:ok, %{status: 200, body: %{"operations" => operations}}} ->
          response(200, %{"operations" => Enum.map(operations, fn op -> if get_in(op, ["metadata", "verb"]) == "update", do: Map.put(op, "done", false), else: op end)})

        other ->
          other
      end
    end

    stalled_options = opts(stalled)

    assert {:error, {:unknown, _}, uncertain} =
             Workstations.put_intent(config(), created, %{desired: :running}, stalled_options)

    no_replay = fn req ->
      if req[:method] == :patch, do: Process.put(:replayed_metadata, true)
      stalled.(req)
    end

    retry_options = opts(no_replay)

    assert {:error, {:unknown, _}, _} =
             Workstations.put_intent(config(), uncertain, %{desired: :stopped}, retry_options)

    refute Process.get(:replayed_metadata, false)
  end

  test "scripted CLI tunnel transfers lifetime and private pinned trust to the shared holder" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, intent} = Workstations.put_intent(config(), created, %{desired: :running}, opts(request))
    assert {:ok, running} = Workstations.start(config(), intent, opts(request))
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    directory = Path.join(System.tmp_dir!(), "workstation-cli-test-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(directory)
    end)

    gcloud = Path.join(directory, "gcloud")
    ssh = Path.join(directory, "ssh")
    File.write!(gcloud, "#!/bin/sh\nprintf 'Listening on port [#{port}].\\n'\nread ignored\n")

    File.write!(
      ssh,
      "#!/bin/sh\nfor arg in \"$@\"; do\ncase \"$arg\" in\nUserKnownHostsFile=*) hosts=${arg#UserKnownHostsFile=} ;;\nesac\ndone\nprintf 'pinned-test-key\\n' > \"$hosts\"\nprintf 'authenticated-worker\\n'\n"
    )

    File.chmod!(gcloud, 0o700)
    File.chmod!(ssh, 0o700)
    supervisor = start_supervised!(Task.Supervisor)
    options = tunnel_options(request, gcloud, ssh, supervisor)
    task = Task.async(fn -> Workstations.connect(config(), running, options) end)
    assert {:ok, connection} = Task.await(task)
    assert :ok == GenServer.call(connection.owner, {:validate_connection, connection.id, connection.target})
    assert {:ok, {"authenticated-worker\n", 0}} = SSH.run(connection.target, "true")
    hosts = Enum.find_value(connection.target.prefix, fn value -> if String.starts_with?(value, "UserKnownHostsFile="), do: String.replace_prefix(value, "UserKnownHostsFile=", "") end)
    assert File.exists?(hosts)
    assert :ok == Operations.close_connection(connection)
    refute File.exists?(hosts)
  end

  test "abnormal prepare death removes staged trust before connection promotion" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, intent} = Workstations.put_intent(config(), created, %{desired: :running}, opts(request))
    assert {:ok, running} = Workstations.start(config(), intent, opts(request))
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    directory = Path.join(System.tmp_dir!(), "workstation-stage-test-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(directory)
    end)

    marker = Path.join(directory, "staged-path")
    gcloud = Path.join(directory, "gcloud")
    ssh = Path.join(directory, "ssh")
    File.write!(gcloud, "#!/bin/sh\nprintf 'Listening on port [#{port}].\\n'\nread ignored\n")

    File.write!(
      ssh,
      "#!/bin/sh\nset -eu\nfor arg in \"$@\"; do\ncase \"$arg\" in\nUserKnownHostsFile=*) hosts=${arg#UserKnownHostsFile=} ;;\nesac\ndone\nprintf 'pinned-test-key\\n' > \"$hosts\"\nprintf '%s\\n' \"$hosts\" > '#{marker}.tmp'\n/bin/mv '#{marker}.tmp' '#{marker}'\nread ignored\n"
    )

    File.chmod!(gcloud, 0o700)
    File.chmod!(ssh, 0o700)
    supervisor = start_supervised!(Task.Supervisor)
    options = tunnel_options(request, gcloud, ssh, supervisor)
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(options, :timeout_ms)
    options = Keyword.put(options, :deadline, deadline)
    task = Task.Supervisor.async_nolink(supervisor, fn -> Workstations.connect(config(), running, options) end)
    hosts = await_staged_trust(task, marker, deadline)
    assert File.exists?(hosts)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ref, :process, _, :killed}
    assert ref == task.ref
    eventually(fn -> not File.exists?(hosts) end)
  end

  test "preflight rejects disabled plain TCP even when port 22 is allowed" do
    {server, request} = provider()
    Agent.update(server, &put_in(&1, [:template, "disableTcpConnections"], true))
    assert {:error, {:invalid, :workstations_profile}} = Workstations.preflight(config(), opts(request))
  end

  test "retained configuration cannot change its captured plain TCP policy" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    Agent.update(server, &put_in(&1, [:template, "disableTcpConnections"], true))
    assert {:error, {:invalid, :workstations_config_changed}, _} = Workstations.ensure(config(), created, opts(request))
  end

  test "omitted and explicit false TCP policy have the same captured runtime identity" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    Agent.update(server, &put_in(&1, [:template, "disableTcpConnections"], false))
    assert {:ok, retained} = Workstations.ensure(config(), created, opts(request))
    assert retained.provider_ref == created.provider_ref
  end

  test "quiescence rejects succeeded stop journals without a valid scoped operation ID" do
    for id <- [nil, "", "arbitrary", "projects/p/locations/l/operations/", "projects/foreign/locations/l/operations/op"] do
      pending = [%{verb: :stop, id: id, outcome: :succeeded}]
      record = %{record() | provider_ref: %{name: name(), uid: "ws-uid"}, pending: pending}
      observed = Workstations.normalize(record, workstation(), [])
      assert observed.proof == :unknown
      assert observed.phase == :unknown
    end
  end

  test "invalid succeeded operation metadata cannot authorize destruction" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    for id <- [nil, "", "projects/foreign/locations/l/operations/op"] do
      change_annotation(server, &Map.put(&1, "pending", [%{"verb" => "stop", "id" => id, "outcome" => "succeeded"}]))
      before = Agent.get(server, & &1.operations)
      assert {:error, {:invalid, :workstations_ownership}, _} = Workstations.destroy(config(), created, opts(request))
      assert Agent.get(server, & &1.operations) == before
    end
  end

  test "missing or foreign captured config identity blocks destruction before provider adoption" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    original = Agent.get(server, &get_in(&1, [:workstation, "annotations", "symphony.dev/record"]))

    changes = [
      &Map.delete(&1, "template_identity"),
      &Map.put(&1, "template_identity", " "),
      &Map.put(&1, "template_identity", "foreign-config-uid"),
      &update_in(&1, ["metadata"], fn metadata -> Map.delete(metadata, "config_name") end),
      &put_in(&1, ["metadata", "config_fingerprint"], "")
    ]

    for change <- changes do
      Agent.update(server, &put_in(&1, [:workstation, "annotations", "symphony.dev/record"], original))
      change_annotation(server, change)
      before = Agent.get(server, & &1.operations)
      unadopted = %{created | provider_ref: nil}
      assert {:error, {:invalid, :workstations_ownership}, _} = Workstations.destroy(config(), unadopted, opts(request))
      assert Agent.get(server, & &1.operations) == before
    end
  end

  test "OAuth subprocess keeps supervised context and caller environment overrides" do
    directory = Path.join(System.tmp_dir!(), "workstation-token-test-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    executable = Path.join(directory, "gcloud")
    File.write!(executable, "#!/bin/sh\ntest \"$WORKSTATION_TEST_CONTEXT\" = scoped || exit 3\ntest \"$CLOUDSDK_CORE_DISABLE_PROMPTS\" = 1 || exit 4\nprintf 'scripted-access-token\\n'\n")
    File.chmod!(executable, 0o700)
    supervisor = start_supervised!(Task.Supervisor)
    request = fn _ -> response(200, %{"observed" => true}) end

    options = [
      gcloud_executable: executable,
      task_supervisor: supervisor,
      authority: self(),
      request_fun: request,
      deadline: System.monotonic_time(:millisecond) + 5_000,
      timeout_ms: 5_000,
      env: [{"WORKSTATION_TEST_CONTEXT", "scoped"}]
    ]

    assert {:ok, %{status: 200}} = Client.request(config(), :get, "/v1/" <> operation_name(), [], nil, options)
  end

  test "durable metadata recovery does not depend on retained completed operation history" do
    {server, request} = provider()
    options = opts(request)
    assert {:ok, created} = Workstations.ensure(config(), record(), options)
    assert {:ok, stopped} = Workstations.stop(config(), created, options)
    terminal = 1_789_128_000_000
    intent = %{desired: :stopped, terminal_observed_at: terminal}
    assert {:ok, _} = Workstations.put_intent(config(), stopped, intent, options)
    Agent.update(server, &%{&1 | operations: []})

    assert {:ok, [recovered]} = Workstations.discover(config(), options)
    assert {:quiescent, _} = recovered.proof
    assert recovered.terminal_observed_at == terminal
    assert {:ok, intended} = Workstations.put_intent(config(), recovered, %{desired: :running}, options)
    assert {:ok, running} = Workstations.start(config(), intended, options)
    assert running.phase == :running
    assert running.provider_ref.uid == stopped.provider_ref.uid
  end

  test "definitively denied initial create can stop and retry after complete empty inventory" do
    {server, request} = provider()
    denied = deny_initial_create(request)
    assert {:error, {:denied, _}, rejected} = Workstations.ensure(config(), record(), opts(denied))
    assert rejected.proof == :unknown
    refute rejected.absent?

    assert {:ok, stopped} = Workstations.stop(config(), rejected, opts(request))
    assert {:quiescent, _} = stopped.proof
    assert {:ok, intended} = Workstations.put_intent(config(), stopped, %{desired: :running}, opts(request))
    assert {:ok, created} = Workstations.ensure(config(), intended, opts(request))
    assert created.provider_ref.uid == "ws-uid"
    assert Agent.get(server, & &1.creates) == 1
  end

  test "denied create never releases uncertainty from an earlier compute mutation" do
    {_server, request} = provider()

    assert {:error, {:denied, _}, rejected} =
             Workstations.ensure(config(), record(), opts(deny_initial_create(request)))

    ambiguous = %{verb: :start, id: nil, outcome: :unknown}
    record = %{rejected | pending: [ambiguous | rejected.pending]}
    assert {:error, {:unknown, _}, blocked} = Workstations.stop(config(), record, opts(request))
    assert blocked.proof == :unknown
    refute blocked.absent?
    assert ambiguous in blocked.pending
  end

  test "denied create cannot certify quiescence from incomplete backing inventory" do
    {_server, request} = provider()

    assert {:error, {:denied, _}, rejected} =
             Workstations.ensure(config(), record(), opts(deny_initial_create(request)))

    partial = fn req ->
      if String.ends_with?(req[:url], "/disks"),
        do: response(200, %{"items" => %{"zones/z" => %{"warning" => %{"code" => "UNREACHABLE"}}}}),
        else: request.(req)
    end

    assert {:error, {:unknown, :partial_inventory}, blocked} =
             Workstations.stop(config(), rejected, opts(partial))

    assert blocked.proof == :unknown
    refute blocked.absent?
  end

  test "lost metadata response resolves only when its journal is observed on the owned resource" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, stopped} = Workstations.stop(config(), created, opts(request))

    landed = fn req ->
      result = request.(req)
      if req[:method] == :patch, do: {:error, :timeout}, else: result
    end

    assert {:error, {:unknown, _}, uncertain} =
             Workstations.put_intent(config(), stopped, %{desired: :stopped}, opts(landed))

    Agent.update(server, &%{&1 | operations: []})
    assert {:ok, recovered} = Workstations.inspect(config(), uncertain, opts(request))
    assert {:quiescent, _} = recovered.proof

    missing = fn req ->
      if req[:method] == :patch, do: {:error, :timeout}, else: request.(req)
    end

    assert {:error, {:unknown, _}, not_landed} =
             Workstations.put_intent(config(), recovered, %{desired: :running}, opts(missing))

    assert {:ok, observed} = Workstations.inspect(config(), not_landed, opts(request))
    assert observed.proof == :unknown
    assert {:error, {:unknown, _}, _} = Workstations.stop(config(), observed, opts(request))
  end

  test "malformed ownership journal blocks discovery rather than dropping an owned workstation" do
    {server, request} = provider()
    assert {:ok, _} = Workstations.ensure(config(), record(), opts(request))
    change_annotation(server, &Map.put(&1, "pending", %{}))
    assert {:error, {:invalid, :workstations_ownership}} = Workstations.discover(config(), opts(request))
    change_annotation(server, &Map.put(&1, "pending", [%{"verb" => "invented", "outcome" => "unknown"}]))
    assert {:error, {:invalid, :workstations_ownership}} = Workstations.discover(config(), opts(request))
  end

  test "unlisted active operations block a previously stopped workstation" do
    record = %{record() | provider_ref: %{name: name(), uid: "ws-uid"}}

    for verb <- ["start", "unrecognized"] do
      observed = Workstations.normalize(record, workstation(), [operation(verb, false)])
      assert observed.proof == :unknown
      assert observed.phase == :unknown
    end
  end

  test "invalid provider inventory shapes cannot prove empty discovery" do
    {_server, request} = provider()

    malformed = fn req ->
      if String.ends_with?(req[:url], "/workstationConfigs"),
        do: response(200, %{"workstationConfigs" => %{}}),
        else: request.(req)
    end

    assert {:error, {:unknown, :invalid_inventory}} = Workstations.discover(config(), opts(malformed))
  end

  test "repeated Workstations and Compute page tokens fail closed" do
    {_server, request} = provider()

    for suffix <- ["/workstationConfigs", "/disks"] do
      repeated = fn req ->
        if String.ends_with?(req[:url], suffix),
          do: response(200, %{"nextPageToken" => "same"}),
          else: request.(req)
      end

      assert {:error, {:unknown, :invalid_pagination}} = Workstations.discover(config(), opts(repeated))
    end
  end

  test "invalid intent and foreign identity cannot issue provider mutations" do
    request = fn _ -> flunk("invalid lifecycle input reached provider") end
    options = opts(request)

    assert {:error, {:invalid, :workstations_intent}, _} =
             Workstations.put_intent(config(), record(), %{desired: :invented}, options)

    foreign = %{record() | deployment_id: "foreign"}
    assert {:error, {:invalid, :workstations_ownership}, _} = Workstations.ensure(config(), foreign, options)
    assert {:error, {:invalid, :workstations_ownership}, _} = Workstations.destroy(config(), foreign, options)
  end

  test "credential failure prevents transport and raised transport errors stay redacted" do
    options = [
      token_fun: fn _, _ -> {:error, "secret credential diagnostics"} end,
      request_fun: fn _ -> flunk("request without credentials") end
    ]

    assert {:error, {:denied, :workstations_credentials}} =
             Client.request(config(), :get, "/v1/" <> name(), [], nil, options)

    raised = fn _ -> raise "secret transport diagnostics" end

    assert {:error, {:unknown, :workstations_transport}} =
             Client.request(config(), :get, "/v1/" <> name(), [], nil, opts(raised))
  end

  test "failed parent or template reads do not create or adopt an environment" do
    {_server, request} = provider()

    assert {:error, {:unknown, {:workstations_http, 503}}, _} =
             Workstations.ensure(config(), record(), opts(fn _ -> response(503, %{}) end))

    missing_template = fn req ->
      if String.ends_with?(req[:url], "/cfg"), do: response(404, %{}), else: request.(req)
    end

    assert {:error, {:unknown, :resource_not_found}, _} =
             Workstations.ensure(config(), record(), opts(missing_template))
  end

  test "create conflict adopts only the owned existing resource and does not replay creation" do
    {server, request} = provider()

    conflict = fn req ->
      result = request.(req)

      if req[:method] == :post and String.ends_with?(req[:url], "/workstations"),
        do: response(409, %{}),
        else: result
    end

    assert {:ok, recovered} = Workstations.ensure(config(), record(), opts(conflict))
    assert recovered.provider_ref.uid == "ws-uid"
    assert Agent.get(server, & &1.creates) == 1
  end

  test "unknown create acceptance with empty inventories cannot be replayed or stopped" do
    {_server, request} = provider()

    ambiguous = fn req ->
      if req[:method] == :post, do: {:error, :timeout}, else: request.(req)
    end

    assert {:error, {:unknown, _}, lost} = Workstations.ensure(config(), record(), opts(ambiguous))
    assert {:error, {:unknown, :uncorrelated_mutation}, blocked} = Workstations.stop(config(), lost, opts(request))
    assert blocked.proof == :unknown
    refute blocked.absent?
  end

  test "metadata denial does not become durable intent and can be retried safely" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    deny_patch = fn req ->
      if req[:method] == :patch, do: response(403, %{}), else: request.(req)
    end

    assert {:error, {:denied, _}, rejected} =
             Workstations.put_intent(config(), created, %{desired: :running}, opts(deny_patch))

    assert {:ok, retried} = Workstations.put_intent(config(), rejected, %{desired: :running}, opts(request))
    assert {:ok, running} = Workstations.start(config(), retried, opts(request))
    assert running.phase == :running
  end

  test "metadata conflicts revalidate ownership instead of authorizing a stale mutation" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    conflict = fn req ->
      if req[:method] == :patch, do: response(412, %{}), else: request.(req)
    end

    assert {:error, {:retryable, {:conflict, 412}}, rejected} =
             Workstations.put_intent(config(), created, %{desired: :running}, opts(conflict))

    Agent.update(server, &put_in(&1, [:workstation, "uid"], "replacement"))

    assert {:error, {:invalid, :workstations_ownership}, _} =
             Workstations.put_intent(config(), rejected, %{desired: :running}, opts(conflict))
  end

  test "a successful metadata operation without matching annotation readback stays unresolved" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    changed = fn req ->
      result = request.(req)
      if req[:method] == :patch, do: change_annotation(server, &Map.put(&1, "attempt_id", "another-writer"))
      result
    end

    assert {:error, {:unknown, :metadata_not_durable}, blocked} =
             Workstations.put_intent(config(), created, %{desired: :running}, opts(changed))

    assert blocked.proof == :unknown
  end

  test "foreign operation evidence cannot establish metadata durability" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    foreign = fn req ->
      result = request.(req)

      if req[:method] == :patch,
        do: response(200, put_in(operation("update", true), ["metadata", "target"], name() <> "-other")),
        else: result
    end

    assert {:error, {:unknown, :invalid_operation_evidence}, blocked} =
             Workstations.put_intent(config(), created, %{desired: :running}, opts(foreign))

    assert blocked.proof == :unknown
  end

  test "create operation must match its scope and target" do
    {_server, request} = provider()

    foreign = fn req ->
      result = request.(req)

      if req[:method] == :post,
        do: response(200, Map.put(operation("create", true), "name", "projects/foreign/locations/l/operations/op")),
        else: result
    end

    assert {:error, {:unknown, :invalid_operation_evidence}, blocked} =
             Workstations.ensure(config(), record(), opts(foreign))

    assert blocked.proof == :unknown
  end

  test "pending create polls the exact operation before completing" do
    {_server, request} = provider()

    pending = fn req ->
      result = request.(req)
      if req[:method] == :post, do: pending_response(result), else: result
    end

    assert {:ok, created} = Workstations.ensure(config(), record(), opts(pending))
    assert {:ok, stopped} = Workstations.stop(config(), created, opts(request))
    assert {:quiescent, _} = stopped.proof
  end

  test "a changed operation during polling cannot resolve an accepted create" do
    {_server, request} = provider()

    changed = fn req ->
      result = request.(req)

      cond do
        req[:method] == :post -> pending_response(result)
        String.contains?(req[:url], "/operations/") -> response(200, operation("delete", true))
        true -> result
      end
    end

    assert {:error, {:unknown, :invalid_operation_evidence}, blocked} =
             Workstations.ensure(config(), record(), opts(changed))

    assert blocked.proof == :unknown
    refute blocked.absent?
  end

  test "known pending operations settle from exact reads when omitted from the list" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    op = operation("start", true)
    Agent.update(server, &%{&1 | operations: &1.operations ++ [op]})
    pending = %{verb: :start, id: op["name"], outcome: :pending}
    record = %{created | pending: created.pending ++ [pending]}

    omitted = fn req ->
      if String.ends_with?(req[:url], "/operations"), do: response(200, %{}), else: request.(req)
    end

    assert {:ok, stopped} = Workstations.stop(config(), record, opts(omitted))
    assert {:quiescent, _} = stopped.proof
  end

  test "denied stop keeps capacity until a later successful stop is confirmed" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    denied = fn req ->
      if String.ends_with?(req[:url], ":stop"), do: response(403, %{}), else: request.(req)
    end

    assert {:error, {:denied, _}, rejected} = Workstations.stop(config(), created, opts(denied))
    assert rejected.proof == :unknown
    assert {:ok, stopped} = Workstations.stop(config(), rejected, opts(request))
    assert {:quiescent, _} = stopped.proof
  end

  test "successful delete operation alone does not prove parent absence" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    retained = fn req ->
      if req[:method] == :delete, do: response(200, operation("delete", true)), else: request.(req)
    end

    assert {:error, {:unknown, :delete_not_absent}, blocked} =
             Workstations.destroy(config(), created, opts(retained))

    refute blocked.absent?
    assert blocked.proof == :unknown
  end

  test "destroy refuses uncaptured reclaim policy even when the worker is stopped" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    change_annotation(server, &put_in(&1, ["metadata", "disk_reclaim_policy"], "RETAIN"))
    record = %{created | metadata: Map.put(created.metadata, "disk_reclaim_policy", "RETAIN")}

    assert {:error, {:unknown, :uncaptured_disk_policy}, blocked} =
             Workstations.destroy(config(), record, opts(request))

    refute blocked.absent?
  end

  test "running without attributable instance and disk cannot qualify for connection" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, intended} = Workstations.put_intent(config(), created, %{desired: :running}, opts(request))

    no_backing = fn req ->
      if String.contains?(req[:url], "/aggregated/"), do: response(200, %{}), else: request.(req)
    end

    assert {:error, {:unknown, :backing_ownership_unqualified}, blocked} =
             Workstations.start(config(), intended, opts(no_backing))

    assert blocked.proof == :unknown
  end

  test "malformed Compute scope and denied workstation list cannot be ignored" do
    {_server, request} = provider()

    malformed = fn req ->
      if String.ends_with?(req[:url], "/instances"),
        do: response(200, %{"items" => %{"zones/z" => nil}}),
        else: request.(req)
    end

    assert {:error, {:unknown, :partial_inventory}} = Workstations.discover(config(), opts(malformed))

    denied = fn req ->
      if String.ends_with?(req[:url], "/workstations"), do: response(403, %{}), else: request.(req)
    end

    assert {:error, {:denied, _}} = Workstations.discover(config(), opts(denied))
  end

  test "connection rejects stopped workers and denied provider observations" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    assert {:error, {:unknown, :workstations_connection_not_ready}} =
             Workstations.connect(config(), created, opts(request))

    denied = opts(fn _ -> response(403, %{}) end)
    assert {:error, {:denied, :workstations_authorization}} = Workstations.connect(config(), created, denied)
    assert {:error, {:denied, _}, _} = Workstations.destroy(config(), created, denied)
  end

  test "preflight accepts a safe profile only after complete authorized discovery" do
    {server, request} = provider()
    assert :ok = Workstations.preflight(config(), opts(request))
    Agent.update(server, &put_in(&1, [:template, "persistentDirectories"], []))
    assert {:error, {:invalid, :workstations_profile}} = Workstations.preflight(config(), opts(request))

    Agent.update(
      server,
      &put_in(&1, [:template, "persistentDirectories"], [
        %{"mountPath" => "/home", "gcePd" => %{"reclaimPolicy" => "DELETE", "archiveTimeout" => "0s"}}
      ])
    )

    Agent.update(server, &put_in(&1, [:template, "host", "gceInstance", "poolSize"], 1))
    assert {:error, {:invalid, :workstations_profile}} = Workstations.preflight(config(), opts(request))
  end

  test "provider transitional states never certify stopped compute" do
    record = %{record() | provider_ref: %{name: name(), uid: "ws-uid"}}
    starting = Workstations.normalize(record, Map.put(workstation(), "state", "STATE_STARTING"), [])
    stopping = Workstations.normalize(record, Map.put(workstation(), "state", "STATE_STOPPING"), [])
    assert starting.phase == :preparing
    assert stopping.phase == :stopping
    assert starting.proof == :unknown
    assert stopping.proof == :unknown
  end

  test "foreign intent and unavailable operation inventory fail before persistence" do
    {_server, request} = provider()
    foreign = %{record() | deployment_id: "foreign"}

    assert {:error, {:invalid, :workstations_ownership}, _} =
             Workstations.put_intent(config(), foreign, %{desired: :running}, opts(request))

    denied = fn req ->
      if String.ends_with?(req[:url], "/operations"), do: response(403, %{}), else: request.(req)
    end

    assert {:error, {:denied, _}, _} =
             Workstations.put_intent(config(), record(), %{desired: :running}, opts(denied))
  end

  test "conflicting create without a resource never retries creation automatically" do
    {server, request} = provider()

    conflict = fn req ->
      if req[:method] == :post, do: response(409, %{}), else: request.(req)
    end

    assert {:error, {:unknown, :resource_not_found}, blocked} =
             Workstations.ensure(config(), record(), opts(conflict))

    assert blocked.proof == :unknown
    assert Agent.get(server, & &1.creates) == 0
  end

  test "stop refuses a denied write-ahead journal rather than issuing the compute mutation" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    denied = fn req ->
      cond do
        req[:method] == :patch -> response(403, %{})
        String.ends_with?(req[:url], ":stop") -> flunk("stop issued without durable journal")
        true -> request.(req)
      end
    end

    assert {:error, {:denied, _}, blocked} = Workstations.stop(config(), created, opts(denied))
    assert blocked.proof == :unknown
  end

  test "replacement after metadata readback fences the following compute mutation" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    replaced = fn req ->
      result = request.(req)

      cond do
        req[:method] == :patch ->
          Process.put(:replace_after_readback, true)

        req[:method] == :get and String.ends_with?(req[:url], record().key) ->
          if Process.delete(:replace_after_readback),
            do: Agent.update(server, &put_in(&1, [:workstation, "uid"], "replacement"))

        true ->
          :ok
      end

      result
    end

    assert {:error, {:invalid, :workstations_ownership}, blocked} =
             Workstations.stop(config(), created, opts(replaced))

    assert blocked.proof == :unknown
  end

  test "destroy cannot proceed after a failed stop or denied backing inspection" do
    {_server, request} = provider(%{stop_error: true})
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    assert {:error, {:unknown, {:operation_failed, :stop, 13}}, _} =
             Workstations.destroy(config(), created, opts(request))

    {_server, healthy} = provider()
    assert {:ok, another} = Workstations.ensure(config(), record(), opts(healthy))

    denied = fn req ->
      if String.contains?(req[:url], "/aggregated/"), do: response(403, %{}), else: healthy.(req)
    end

    assert {:error, {:denied, _}, blocked} = Workstations.destroy(config(), another, opts(denied))
    refute blocked.absent?
  end

  test "accepted delete with a denied final parent read cannot certify absence" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    denied = fn req ->
      if Process.get(:deleted_parent, false) and req[:method] == :get do
        response(403, %{})
      else
        result = request.(req)
        if req[:method] == :delete, do: Process.put(:deleted_parent, true)
        result
      end
    end

    assert {:error, {:denied, _}, blocked} = Workstations.destroy(config(), created, opts(denied))
    refute blocked.absent?
  end

  test "successful compute operations still require the requested runtime state" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, intended} = Workstations.put_intent(config(), created, %{desired: :running}, opts(request))

    unchanged_start = fn req ->
      result = request.(req)

      if String.ends_with?(req[:url], ":start"),
        do: Agent.update(server, &put_in(&1, [:workstation, "state"], "STATE_STOPPED"))

      result
    end

    assert {:error, {:unknown, :start_not_confirmed}, blocked} =
             Workstations.start(config(), intended, opts(unchanged_start))

    unchanged_stop = fn req ->
      result = request.(req)

      if String.ends_with?(req[:url], ":stop"),
        do: Agent.update(server, &put_in(&1, [:workstation, "state"], "STATE_RUNNING"))

      result
    end

    assert {:error, {:unknown, :stop_not_confirmed}, _} =
             Workstations.stop(config(), blocked, opts(unchanged_stop))
  end

  test "denied metadata readback and conflict revalidation keep the operation unresolved" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))

    denied = fn req ->
      if Process.get(:metadata_written, false) and req[:method] == :get do
        response(403, %{})
      else
        result = request.(req)
        if req[:method] == :patch, do: Process.put(:metadata_written, true)
        result
      end
    end

    assert {:error, {:denied, _}, blocked} =
             Workstations.put_intent(config(), created, %{desired: :running}, opts(denied))

    assert blocked.proof == :unknown
    Process.delete(:metadata_written)

    conflict = fn req ->
      if req[:method] == :patch do
        Agent.update(server, &put_in(&1, [:workstation, "uid"], "replacement"))
        response(412, %{})
      else
        request.(req)
      end
    end

    assert {:error, {:invalid, :workstations_ownership}, _} =
             Workstations.put_intent(config(), created, %{desired: :running}, opts(conflict))
  end

  test "a known operation read must still match the expected mutation target" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    pending = %{verb: :start, id: operation_name() <> "-unlisted", outcome: :pending}
    record = %{created | pending: created.pending ++ [pending]}

    wrong_target = fn req ->
      if String.ends_with?(req[:url], "-unlisted"),
        do: response(200, put_in(operation("start", true), ["metadata", "target"], name() <> "-foreign")),
        else: request.(req)
    end

    assert {:error, {:unknown, :invalid_operation_evidence}, blocked} =
             Workstations.stop(config(), record, opts(wrong_target))

    assert blocked.proof == :unknown
  end

  test "lost operation polling keeps accepted create uncertainty" do
    {_server, request} = provider()

    lost_poll = fn req ->
      cond do
        req[:method] == :post -> pending_response(request.(req))
        String.contains?(req[:url], "/operations/") -> {:error, :timeout}
        true -> request.(req)
      end
    end

    assert {:error, {:unknown, :workstations_transport}, blocked} =
             Workstations.ensure(config(), record(), opts(lost_poll))

    assert blocked.proof == :unknown
  end

  test "missing previously adopted parent without successful delete remains unknown" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    Agent.update(server, &%{&1 | workstation: nil})

    assert {:error, {:unknown, :absence_without_delete_evidence}, blocked} =
             Workstations.inspect(config(), created, opts(request))

    refute blocked.absent?
  end

  test "denied backing inventory prevents qualification of a running workstation" do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, intended} = Workstations.put_intent(config(), created, %{desired: :running}, opts(request))

    denied = fn req ->
      if String.contains?(req[:url], "/aggregated/"), do: response(403, %{}), else: request.(req)
    end

    assert {:error, {:denied, _}, blocked} = Workstations.start(config(), intended, opts(denied))
    assert blocked.proof == :unknown
  end

  test "dead connection authority cannot acquire a tunnel stage" do
    {running, options} = tunnel_fixture("read ignored")
    {authority, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^authority, :normal}
    options = Keyword.put(options, :authority, authority)
    assert {:error, {:invalid, :connection_authority}} = Workstations.connect(config(), running, options)
  end

  test "missing tunnel executable cannot promote an owned connection" do
    {running, options} = tunnel_fixture("read ignored")
    missing = Keyword.fetch!(options, :gcloud_executable) <> "-missing"
    assert {:error, _} = Workstations.connect(config(), running, Keyword.put(options, :gcloud_executable, missing))
  end

  test "invalid tunnel authentication configuration is redacted at the connection boundary" do
    {running, options} = tunnel_fixture("read ignored")
    invalid = put_in(config(), [:provider, "credential_configuration"], nil)
    assert {:error, {:unknown, :workstations_tunnel_failed}} = Workstations.connect(invalid, running, options)
  end

  test "local SSH launch exception is redacted after authenticated tunnel readiness" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {running, options} = tunnel_fixture("printf 'Listening on port [#{port}].\\n'\nread ignored")
    options = Keyword.put(options, :clock, fn -> raise "private local command failure" end)
    assert {:error, {:unknown, :workstations_tunnel_failed}} = Workstations.connect(config(), running, options)
  end

  test "expired operation history never erases a genuinely ambiguous start from durable metadata" do
    {server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, intended} = Workstations.put_intent(config(), created, %{desired: :running}, opts(request))

    lost_start = fn req ->
      result = request.(req)
      if String.ends_with?(req[:url], ":start"), do: {:error, :timeout}, else: result
    end

    assert {:error, {:unknown, _}, _} = Workstations.start(config(), intended, opts(lost_start))
    Agent.update(server, &%{&1 | operations: []})
    assert {:ok, [recovered]} = Workstations.discover(config(), opts(request))
    assert recovered.proof == :unknown

    assert {:error, {:unknown, :uncorrelated_mutation}, blocked} =
             Workstations.stop(config(), recovered, opts(request))

    refute blocked.absent?
  end

  test "failed tunnel process cannot promote a connection" do
    {running, options} = tunnel_fixture("exit 3")

    assert {:error, {:unknown, :workstations_tunnel_not_ready}} =
             Workstations.connect(config(), running, options)
  end

  test "tunnel output is bounded before a listening port is accepted" do
    {running, options} = tunnel_fixture("printf '%70000s' garbage\nread ignored")

    assert {:error, {:unknown, :workstations_tunnel_not_ready}} =
             Workstations.connect(config(), running, options)
  end

  test "a silent tunnel obeys the connection deadline" do
    {running, options} = tunnel_fixture("read ignored")
    options = Keyword.put(options, :timeout_ms, 200)

    assert {:error, {:unknown, :workstations_tunnel_not_ready}} =
             Workstations.connect(config(), running, options)
  end

  test "tunnel announcement rejects an invalid TCP port" do
    {running, options} = tunnel_fixture("printf 'Listening on port [65536].\\n'\nread ignored")

    assert {:error, {:unknown, :workstations_tunnel_not_ready}} =
             Workstations.connect(config(), running, options)
  end

  defp tunnel_fixture(script) do
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, intended} = Workstations.put_intent(config(), created, %{desired: :running}, opts(request))
    assert {:ok, running} = Workstations.start(config(), intended, opts(request))
    directory = Path.join(System.tmp_dir!(), "workstation-tunnel-failure-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    gcloud = Path.join(directory, "gcloud")
    File.write!(gcloud, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(gcloud, 0o700)
    supervisor = start_supervised!(Task.Supervisor)
    {running, tunnel_options(request, gcloud, "/usr/bin/false", supervisor)}
  end

  defp pending_response({:ok, %{body: body}}), do: response(200, Map.put(body, "done", false))

  defp tunnel_options(request, gcloud, ssh, supervisor) do
    opts(request) ++
      [gcloud_executable: gcloud, ssh_executable: ssh, task_supervisor: supervisor, authority: self()]
  end

  defp deny_initial_create(request) do
    fn req ->
      if req[:method] == :post and String.ends_with?(req[:url], "/workstations"),
        do: response(403, %{}),
        else: request.(req)
    end
  end

  defp change_annotation(server, change) do
    Agent.update(server, fn state ->
      update_in(state, [:workstation, "annotations", "symphony.dev/record"], fn value -> value |> Jason.decode!() |> change.() |> Jason.encode!() end)
    end)
  end

  defp await_staged_trust(task, marker, deadline) do
    case File.read(marker) do
      {:ok, path} ->
        String.trim_trailing(path, "\n")

      {:error, :enoent} ->
        wait_for_staged_trust(task, marker, deadline)

      {:error, reason} ->
        flunk("could not read staged trust handoff: #{inspect(reason)}")
    end
  end

  defp wait_for_staged_trust(task, marker, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "SSH fixture did not publish staged trust within the connection deadline"
    ref = task.ref

    receive do
      {^ref, result} ->
        flunk("connection returned before the staged trust handoff: #{inspect(result)}")

      {:DOWN, ^ref, :process, _, reason} ->
        flunk("connection died before the staged trust handoff: #{inspect(reason)}")
    after
      min(remaining, 10) -> await_staged_trust(task, marker, deadline)
    end
  end

  defp eventually(predicate, attempts \\ 200) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("bounded asynchronous condition was not observed")

      true ->
        Process.sleep(5)
        eventually(predicate, attempts - 1)
    end
  end

  defp provider(overrides \\ %{}) do
    template = %{
      "name" => "projects/p/locations/l/workstationClusters/c/workstationConfigs/cfg",
      "uid" => "config-uid",
      "reconciling" => false,
      "container" => %{"image" => "pinned-image"},
      "host" => %{"gceInstance" => %{"poolSize" => 0}},
      "idleTimeout" => "0s",
      "runningTimeout" => "0s",
      "persistentDirectories" => [%{"mountPath" => "/home", "gcePd" => %{"reclaimPolicy" => "DELETE", "archiveTimeout" => "0s"}}]
    }

    {:ok, server} = Agent.start_link(fn -> Map.merge(%{template: template, workstation: nil, operations: [], creates: 0, lose_create: false, stop_error: false}, overrides) end)
    request = fn req -> Agent.get_and_update(server, &respond(req, &1)) end
    {server, request}
  end

  defp respond(req, state) do
    if req[:method] == :get, do: get_response(req[:url], state), else: mutate_response(req, state)
  end

  defp get_response(url, state) do
    cond do
      String.ends_with?(url, "/workstationConfigs") ->
        {response(200, %{"workstationConfigs" => [state.template]}), state}

      String.ends_with?(url, "/cfg") ->
        {response(200, state.template), state}

      String.ends_with?(url, "/workstations") ->
        {response(200, %{"workstations" => List.wrap(state.workstation)}), state}

      String.ends_with?(url, "/operations") ->
        {response(200, %{"operations" => state.operations}), state}

      String.contains?(url, "/operations/") ->
        op = Enum.find(state.operations, &String.ends_with?(url, &1["name"]))
        {resource_response(op), state}

      String.contains?(url, "/aggregated/") ->
        {backing_response(url, state.workstation), state}

      true ->
        {resource_response(state.workstation), state}
    end
  end

  defp resource_response(nil), do: response(404, %{})
  defp resource_response(resource), do: response(200, resource)

  defp backing_response(url, workstation) do
    kind = List.last(String.split(url, "/"))
    link = "https://www.googleapis.com/compute/v1/projects/p/zones/z/" <> kind <> "/backing"
    resource = %{"id" => kind, "selfLink" => link, "labels" => labels()}
    items = if workstation, do: [resource], else: []
    response(200, %{"items" => %{"zones/z" => %{kind => items}}})
  end

  defp mutate_response(req, state) do
    verb = mutation_verb(req)
    validate_etag(req, state, verb)
    op = next_operation(state, verb)
    workstation = mutate_workstation(verb, req[:json], state.workstation)
    workstation = stamp_etag(workstation, length(state.operations))
    creates = state.creates + if(verb == "create", do: 1, else: 0)
    next = %{state | workstation: workstation, operations: state.operations ++ [op], creates: creates}
    result = if verb == "create" and state.lose_create, do: {:error, :timeout}, else: response(200, op)
    {result, next}
  end

  defp mutation_verb(req) do
    cond do
      req[:method] == :patch -> "update"
      req[:method] == :delete -> "delete"
      String.ends_with?(req[:url], ":start") -> "start"
      String.ends_with?(req[:url], ":stop") -> "stop"
      true -> "create"
    end
  end

  defp validate_etag(_req, _state, "create"), do: :ok

  defp validate_etag(req, state, verb) do
    expected = if verb == "delete", do: req[:params][:etag], else: req[:json]["etag"]
    assert expected == state.workstation["etag"]
  end

  defp next_operation(state, verb) do
    id = operation_name() <> Integer.to_string(length(state.operations))
    created = DateTime.to_iso8601(DateTime.utc_now())
    op = operation(verb, true) |> Map.put("name", id) |> put_in(["metadata", "createTime"], created)
    if verb == "stop" and state.stop_error, do: Map.put(op, "error", %{"code" => 13}), else: op
  end

  defp mutate_workstation("create", body, _workstation), do: Map.merge(workstation(), body)
  defp mutate_workstation("update", body, workstation), do: Map.merge(workstation, body)
  defp mutate_workstation("start", _body, workstation), do: Map.put(workstation, "state", "STATE_RUNNING")
  defp mutate_workstation("stop", _body, workstation), do: Map.put(workstation, "state", "STATE_STOPPED")
  defp mutate_workstation("delete", _body, _workstation), do: nil

  defp stamp_etag(nil, _version), do: nil
  defp stamp_etag(workstation, version), do: Map.put(workstation, "etag", "etag-" <> Integer.to_string(version))

  defp config do
    %{
      kind: "google_workstations",
      deployment_id: "deployment",
      tracker_kind: "memory",
      workspace_root: "/home/user/workspaces",
      startup_timeout_ms: 10_000,
      shutdown_timeout_ms: 10_000,
      terminal_retention_ms: 60_000,
      provider: %{
        "project" => "p",
        "location" => "l",
        "cluster" => "c",
        "config" => "cfg",
        "credential_configuration" => "deploy",
        "impersonate_service_account" => "sa@example.com",
        "ssh_user" => "user"
      }
    }
  end

  defp record do
    %Record{
      key: ExecutionEnvironment.resource_key("deployment", "memory", "ticket"),
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "google_workstations",
      scope: Map.take(config().provider, ["project", "location", "cluster"]),
      workspace_path: "/home/user/workspaces/ticket",
      template_identity: "config-uid"
    }
  end

  defp name, do: "projects/p/locations/l/workstationClusters/c/workstationConfigs/cfg/workstations/" <> record().key
  defp operation_name, do: "projects/p/locations/l/operations/op"
  defp workstation, do: %{"name" => name(), "uid" => "ws-uid", "etag" => "v2", "state" => "STATE_STOPPED", "reconciling" => false}
  defp operation(verb, done), do: %{"name" => operation_name(), "done" => done, "metadata" => %{"target" => name(), "verb" => verb}}
  defp labels, do: %{"symphony-managed" => "true", "symphony-deployment" => :crypto.hash(:sha256, "deployment") |> Base.encode16(case: :lower) |> binary_part(0, 32), "symphony-ticket" => record().key}
  defp response(status, body), do: {:ok, %{status: status, body: body}}
  defp opts(request), do: [request_fun: request, token_fun: fn _, _ -> {:ok, "test-token"} end, timeout_ms: 10_000, poll_interval_ms: 0]
end
