defmodule SymphonyElixir.WorkstationsEnvironmentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionEnvironment.{Record, Workstations}
  alias SymphonyElixir.ExecutionEnvironment.Workstations.Client

  test "STOPPED with no listed operations cannot erase an unknown start" do
    record = %Record{key: "se-ticket", deployment_id: "deployment", tracker_kind: "memory", issue_id: "ticket", kind: "google_workstations", scope: %{},
      workspace_path: "/home/user/workspaces/se-ticket", template_identity: "config-uid", pending: [%{verb: :start, id: nil, outcome: :unknown}]}
    workstation = %{"uid" => "ws-uid", "etag" => "v2", "state" => "STATE_STOPPED", "reconciling" => false}
    observed = Workstations.normalize(record, workstation, [])
    assert observed.phase == :unknown
    assert observed.proof == :unknown
    assert observed.pending == record.pending
  end

  test "successful stop requires exact UID and terminal operation, not HTTP success" do
    record = %{record() | provider_ref: %{name: name(), uid: "ws-uid"}, pending: [%{verb: :stop, id: operation_name(), outcome: :pending}]}
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
    assert {:error, {:unknown, :workstations_transport}} = Client.request(config(), :post, "/v1/" <> name() <> ":start", [], %{}, opts(request))
  end

  test "definite authorization denial is not absence" do
    assert {:error, {:denied, :workstations_authorization}, _} = Workstations.inspect(config(), record(), opts(fn _ -> response(403, %{}) end))
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
    assert {:error, {:denied, :workstations_authorization}} = Workstations.discover(config(), opts(fn _ -> response(403, %{}) end))
    assert {:error, {:unknown, :partial_inventory}} = Workstations.discover(config(), opts(fn _ -> response(200, %{"unreachable" => ["scope"]}) end))
  end

  test "parent 404 with a labeled disk remains billable cleanup, never absence" do
    disk = %{"id" => "456", "selfLink" => "https://www.googleapis.com/compute/v1/projects/p/zones/z/disks/d", "labels" => labels()}
    record = %{record() | pending: [%{verb: :delete, id: operation_name(), outcome: :succeeded}], provider_ref: %{name: name(), uid: "ws-uid"}}
    request = fn req ->
      cond do
        String.ends_with?(req[:url], "/disks") -> response(200, %{"items" => %{"zones/z" => %{"disks" => [disk]}}})
        String.ends_with?(req[:url], "/instances") -> response(200, %{"items" => %{}})
        String.ends_with?(req[:url], "/operations") -> response(200, %{"operations" => []})
        true -> response(404, %{})
      end
    end
    assert {:error, {:unknown, {:backing_resources_remaining, _}}, returned} = Workstations.destroy(config(), record, opts(request))
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
    assert {:ok, _} = Workstations.put_intent(config(), stopped, %{desired: :stopped, terminal_observed_at: terminal}, options)
    assert {:ok, [recovered]} = Workstations.discover(config(), options)
    assert recovered.terminal_observed_at == terminal
    assert recovered.desired == :stopped
    assert {:ok, reopening} = Workstations.put_intent(config(), recovered, %{desired: :running, terminal_observed_at: nil, attempt_id: "attempt-2"}, options)
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
    record = %{record() | provider_ref: %{name: name(), uid: "ws-uid"}, pending: [%{verb: :stop, id: operation_name(), outcome: :succeeded}]}
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
    assert {:error, {:unknown, :workstations_deadline}} = Client.request(config(), :post, "/v1/" <> name() <> ":start", [], %{},
      Keyword.put(opts(request), :deadline, System.monotonic_time(:millisecond) - 1))
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
        other -> other
      end
    end
    assert {:error, {:unknown, _}, uncertain} = Workstations.put_intent(config(), created, %{desired: :running}, opts(stalled))
    no_replay = fn req ->
      if req[:method] == :patch, do: Process.put(:replayed_metadata, true)
      stalled.(req)
    end
    assert {:error, {:unknown, _}, _} = Workstations.put_intent(config(), uncertain, %{desired: :stopped}, opts(no_replay))
    refute Process.get(:replayed_metadata, false)
  end

  test "scripted CLI tunnel transfers lifetime and private pinned trust to the shared holder" do
    alias SymphonyElixir.ExecutionEnvironment.Operations
    {_server, request} = provider()
    assert {:ok, created} = Workstations.ensure(config(), record(), opts(request))
    assert {:ok, intent} = Workstations.put_intent(config(), created, %{desired: :running}, opts(request))
    assert {:ok, running} = Workstations.start(config(), intent, opts(request))
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    directory = Path.join(System.tmp_dir!(), "workstation-cli-test-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    on_exit(fn -> :gen_tcp.close(listener); File.rm_rf!(directory) end)
    gcloud = Path.join(directory, "gcloud")
    ssh = Path.join(directory, "ssh")
    File.write!(gcloud, "#!/bin/sh\nprintf 'Listening on port [#{port}].\\n'\nread ignored\n")
    File.write!(ssh, "#!/bin/sh\nfor arg in \"$@\"; do\ncase \"$arg\" in\nUserKnownHostsFile=*) hosts=${arg#UserKnownHostsFile=} ;;\nesac\ndone\nprintf 'pinned-test-key\\n' > \"$hosts\"\nprintf 'authenticated-worker\\n'\n")
    File.chmod!(gcloud, 0o700)
    File.chmod!(ssh, 0o700)
    supervisor = start_supervised!(Task.Supervisor)
    options = opts(request) ++ [gcloud_executable: gcloud, ssh_executable: ssh, task_supervisor: supervisor, authority: self()]
    task = Task.async(fn -> Workstations.connect(config(), running, options) end)
    assert {:ok, connection} = Task.await(task)
    assert :ok == GenServer.call(connection.owner, {:validate_connection, connection.id, connection.target})
    assert {:ok, {"authenticated-worker\n", 0}} = SymphonyElixir.SSH.run(connection.target, "true")
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
    on_exit(fn -> :gen_tcp.close(listener); File.rm_rf!(directory) end)
    marker = Path.join(directory, "staged-path")
    gcloud = Path.join(directory, "gcloud")
    ssh = Path.join(directory, "ssh")
    File.write!(gcloud, "#!/bin/sh\nprintf 'Listening on port [#{port}].\\n'\nread ignored\n")
    File.write!(ssh, "#!/bin/sh\nfor arg in \"$@\"; do\ncase \"$arg\" in\nUserKnownHostsFile=*) hosts=${arg#UserKnownHostsFile=} ;;\nesac\ndone\nprintf 'pinned-test-key\\n' > \"$hosts\"\nprintf '%s' \"$hosts\" > '#{marker}'\nread ignored\n")
    File.chmod!(gcloud, 0o700)
    File.chmod!(ssh, 0o700)
    supervisor = start_supervised!(Task.Supervisor)
    options = opts(request) ++ [gcloud_executable: gcloud, ssh_executable: ssh, task_supervisor: supervisor, authority: self()]
    task = Task.Supervisor.async_nolink(supervisor, fn -> Workstations.connect(config(), running, options) end)
    eventually(fn -> File.exists?(marker) end)
    hosts = File.read!(marker)
    assert File.exists?(hosts)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ref, :process, _, :killed}
    assert ref == task.ref
    eventually(fn -> not File.exists?(hosts) end)
  end

  defp eventually(predicate, attempts \\ 200) do
    cond do
      predicate.() -> :ok
      attempts == 0 -> flunk("bounded asynchronous condition was not observed")
      true -> Process.sleep(5); eventually(predicate, attempts - 1)
    end
  end

  defp provider(overrides \\ %{}) do
    template = %{"name" => "projects/p/locations/l/workstationClusters/c/workstationConfigs/cfg", "uid" => "config-uid", "reconciling" => false,
      "container" => %{"image" => "pinned-image"}, "host" => %{"gceInstance" => %{"poolSize" => 0}}, "idleTimeout" => "0s", "runningTimeout" => "0s",
      "persistentDirectories" => [%{"mountPath" => "/home", "gcePd" => %{"reclaimPolicy" => "DELETE", "archiveTimeout" => "0s"}}]}
    {:ok, server} = Agent.start_link(fn -> Map.merge(%{template: template, workstation: nil, operations: [], creates: 0, lose_create: false, stop_error: false}, overrides) end)
    request = fn req -> Agent.get_and_update(server, &respond(req, &1)) end
    {server, request}
  end

  defp respond(req, state) do
    url = req[:url]
    cond do
      req[:method] == :get and String.ends_with?(url, "/workstationConfigs") ->
        {response(200, %{"workstationConfigs" => [state.template]}), state}
      req[:method] == :get and String.ends_with?(url, "/cfg") -> {response(200, state.template), state}
      req[:method] == :get and String.ends_with?(url, "/workstations") ->
        {response(200, %{"workstations" => if(state.workstation, do: [state.workstation], else: [])}), state}
      req[:method] == :get and String.ends_with?(url, "/operations") -> {response(200, %{"operations" => state.operations}), state}
      req[:method] == :get and String.contains?(url, "/operations/") ->
        op = Enum.find(state.operations, &String.ends_with?(url, &1["name"]))
        {if(op, do: response(200, op), else: response(404, %{})), state}
      req[:method] == :get and String.contains?(url, "/aggregated/") ->
        kind = List.last(String.split(url, "/"))
        resource = %{"id" => kind, "selfLink" => "https://www.googleapis.com/compute/v1/projects/p/zones/z/" <> kind <> "/backing", "labels" => labels()}
        items = if state.workstation, do: [resource], else: []
        {response(200, %{"items" => %{"zones/z" => %{kind => items}}}), state}
      req[:method] == :get -> {if(state.workstation, do: response(200, state.workstation), else: response(404, %{})), state}
      true -> mutate_response(req, state)
    end
  end

  defp mutate_response(req, state) do
    verb = cond do
      req[:method] == :patch -> "update"
      req[:method] == :delete -> "delete"
      String.ends_with?(req[:url], ":start") -> "start"
      String.ends_with?(req[:url], ":stop") -> "stop"
      true -> "create"
    end
    if verb != "create" do
      expected_etag = if verb == "delete", do: req[:params][:etag], else: req[:json]["etag"]
      assert expected_etag == state.workstation["etag"]
    end
    op = operation(verb, true) |> Map.put("name", operation_name() <> Integer.to_string(length(state.operations))) |> put_in(["metadata", "createTime"], DateTime.to_iso8601(DateTime.utc_now()))
    op = if verb == "stop" and state.stop_error, do: Map.put(op, "error", %{"code" => 13}), else: op
    workstation = case verb do
      "create" -> Map.merge(workstation(), req[:json])
      "update" -> Map.merge(state.workstation, req[:json])
      "start" -> Map.put(state.workstation, "state", "STATE_RUNNING")
      "stop" -> Map.put(state.workstation, "state", "STATE_STOPPED")
      "delete" -> nil
    end
    workstation = if workstation, do: Map.put(workstation, "etag", "etag-" <> Integer.to_string(length(state.operations))), else: nil
    next = %{state | workstation: workstation, operations: state.operations ++ [op], creates: state.creates + if(verb == "create", do: 1, else: 0)}
    result = if verb == "create" and state.lose_create, do: {:error, :timeout}, else: response(200, op)
    {result, next}
  end

  defp config do
    %{kind: "google_workstations", deployment_id: "deployment", tracker_kind: "memory", workspace_root: "/home/user/workspaces", startup_timeout_ms: 10_000,
      shutdown_timeout_ms: 10_000, terminal_retention_ms: 60_000,
      provider: %{"project" => "p", "location" => "l", "cluster" => "c", "config" => "cfg", "credential_configuration" => "deploy", "impersonate_service_account" => "sa@example.com", "ssh_user" => "user"}}
  end

  defp record do
    %Record{key: SymphonyElixir.ExecutionEnvironment.resource_key("deployment", "memory", "ticket"), deployment_id: "deployment", tracker_kind: "memory", issue_id: "ticket",
      kind: "google_workstations", scope: Map.take(config().provider, ["project", "location", "cluster"]), workspace_path: "/home/user/workspaces/ticket", template_identity: "config-uid"}
  end

  defp name, do: "projects/p/locations/l/workstationClusters/c/workstationConfigs/cfg/workstations/" <> record().key
  defp operation_name, do: "projects/p/locations/l/operations/op"
  defp workstation, do: %{"name" => name(), "uid" => "ws-uid", "etag" => "v2", "state" => "STATE_STOPPED", "reconciling" => false}
  defp operation(verb, done), do: %{"name" => operation_name(), "done" => done, "metadata" => %{"target" => name(), "verb" => verb}}
  defp labels, do: %{"symphony-managed" => "true", "symphony-deployment" => :crypto.hash(:sha256, "deployment") |> Base.encode16(case: :lower) |> binary_part(0, 32), "symphony-ticket" => record().key}
  defp response(status, body), do: {:ok, %{status: status, body: body}}
  defp opts(request), do: [request_fun: request, token_fun: fn _, _ -> {:ok, "test-token"} end, timeout_ms: 10_000, poll_interval_ms: 0]
end
