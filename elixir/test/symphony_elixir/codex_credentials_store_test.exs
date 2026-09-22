defmodule SymphonyElixir.CodexCredentialsStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CodexCredentials
  alias SymphonyElixir.CodexCredentials.{ControlStore, GoogleClient, Record}
  alias SymphonyElixir.GoogleCredentials

  @secret "projects/fixture-workers/secrets/features-codex"
  @version @secret <> "/versions/1"
  @generation "90071992547409931234"

  test "a read pins media to the selected generation and preserves decimal precision" do
    {_server, request} = store(seed())
    assert {:ok, %{generation: @generation, record: record}} = ControlStore.read(config(), request: request)
    assert record == seed()
  end

  test "two simultaneous claims cannot both acquire the same authority" do
    {server, request} = store(seed())
    parent = self()

    synchronized = fn method, url, headers, body ->
      if method == :post do
        send(parent, {:write_ready, self()})
        receive do: (:write -> :ok)
      end

      request.(method, url, headers, body)
    end

    tasks = for attempt <- ["attempt-a", "attempt-b"], do: Task.async(fn -> CodexCredentials.claim(config(), owner(attempt), request: synchronized) end)
    assert_receive {:write_ready, first}
    assert_receive {:write_ready, second}
    send(first, :write)
    send(second, :write)
    results = Enum.map(tasks, &Task.await/1)
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, :credential_busy} in results
    assert winner.record == Agent.get(server, &Jason.decode!(&1.bytes))
    assert winner.record["owner"]["attempt_id"] in ["attempt-a", "attempt-b"]
    assert winner.record["claim_id"] != winner.record["transition_id"]
  end

  test "a committed write with a lost response is recognized without replay" do
    {server, request} = store(seed(), mode: :lose_response)
    assert {:ok, snapshot} = CodexCredentials.claim(config(), owner(), request: request)
    assert snapshot.record["state"] == "OWNED"
    assert snapshot.record == Agent.get(server, &Jason.decode!(&1.bytes))
    assert Agent.get(server, & &1.writes) == 1
  end

  test "failed readback and a forged matching transition ID never imply a committed claim" do
    for mode <- [:lose_and_hide, :lose_and_swap] do
      {server, request} = store(seed(), mode: mode)
      assert {:error, :credential_outcome_unknown} = CodexCredentials.claim(config(), owner(), request: request)
      assert Agent.get(server, & &1.writes) == 1
    end
  end

  test "missing authority is never initialized" do
    {server, request} = store(nil)
    assert {:error, :credential_outcome_unknown} = CodexCredentials.claim(config(), owner(), request: request)
    assert Agent.get(server, & &1.writes) == 0
  end

  test "a deleted selected generation requires a fresh current read" do
    replacement = Record.initial("features-personal-codex", 2, @secret <> "/versions/2")
    {_server, request} = store(seed(), race_record: replacement)
    assert {:ok, %{record: ^replacement}} = ControlStore.read(config(), request: request)
  end

  test "unknown schemas and authority belonging to another credential or secret fail closed" do
    for invalid <- [Map.put(seed(), "schema", 2), Map.put(seed(), "credential_id", "foreign"), Map.put(seed(), "head_version", "projects/foreign/secrets/other/versions/1")] do
      {server, request} = store(invalid)
      assert {:error, :credential_outcome_unknown} = CodexCredentials.claim(config(), owner(), request: request)
      assert Agent.get(server, & &1.writes) == 0
    end
  end

  test "conditional replacement cannot reseed the epoch or use a zero generation" do
    {server, request} = store(seed())
    assert {:ok, snapshot} = ControlStore.read(config(), request: request)
    assert {:ok, next} = Record.transition(seed(), {:claim, "new-claim", owner()}, "new-transition")
    assert {:error, :credential_outcome_unknown} = ControlStore.replace(config(), snapshot, Map.put(next, "epoch", 2), request: request)
    assert {:error, :credential_outcome_unknown} = ControlStore.replace(config(), %{snapshot | generation: "0"}, next, request: request)
    assert Agent.get(server, & &1.writes) == 0
  end

  test "current cloud ownership defeats stale local claims and foreign epoch receipts" do
    {server, request} = store(owned())
    assert {:error, {:credential_recovery_required, :claim_mismatch}} = CodexCredentials.transition(config(), "stale-local-claim", {:bind_uid, "stale-local-claim", "uid-a"}, request: request)
    assert {:error, {:credential_recovery_required, :checkpoint_mismatch}} = CodexCredentials.transition(config(), "claim-a", {:checkpoint, Map.put(receipt(), "epoch", 2)}, request: request)
    assert Agent.get(server, & &1.writes) == 0
  end

  test "checkpoint requires enabled metadata for the exact numeric version before committing" do
    {server, request} = store(owned())
    assert {:ok, checkpoint} = CodexCredentials.transition(config(), "claim-a", {:checkpoint, receipt()}, request: request)
    assert checkpoint.record["candidate"] == receipt()
    assert Agent.get(server, & &1.metadata_reads) == 1

    for metadata <- [%{"name" => @secret <> "/versions/2", "state" => "DISABLED"}, %{"name" => @version, "state" => "ENABLED"}] do
      {denied, request} = store(owned(), metadata: metadata)
      assert {:error, :credential_outcome_unknown} = CodexCredentials.transition(config(), "claim-a", {:checkpoint, receipt()}, request: request)
      assert Agent.get(denied, & &1.writes) == 0
    end
  end

  test "release readback retains the handoff barrier and only the matching claim acknowledges it" do
    {:ok, checkpoint} = Record.transition(owned(), {:checkpoint, receipt()}, "checkpoint")
    {:ok, stopped} = Record.transition(checkpoint, {:stopped, "claim-a", proof()}, "stopped")
    {server, request} = store(stopped, mode: :lose_response)
    assert {:ok, released} = CodexCredentials.transition(config(), "claim-a", {:release, "claim-a"}, request: request)
    assert released.record["last_handoff"]["resource_acknowledged"] == false
    assert {:error, :credential_busy} = CodexCredentials.claim(config(), owner("next-attempt"), request: request)
    assert {:error, {:credential_recovery_required, :claim_mismatch}} = CodexCredentials.transition(config(), "foreign", {:acknowledge_handoff, "foreign"}, request: request)
    assert {:ok, acknowledged} = CodexCredentials.transition(config(), "claim-a", {:acknowledge_handoff, "claim-a"}, request: request)
    assert acknowledged.record["last_handoff"]["resource_acknowledged"]
    assert {:ok, next} = CodexCredentials.claim(config(), owner("next-attempt"), request: request)
    refute next.record["claim_id"] == "claim-a"
    assert Agent.get(server, & &1.writes) == 3
  end

  test "controller metadata and storage requests never use lifecycle or backup identity" do
    parent = self()
    token_fun = fn identity, _ ->
      send(parent, {:identity, identity})
      {:ok, "controller-test-token"}
    end

    request_fun = fn options ->
      assert options[:retry] == false
      assert options[:receive_timeout] > 0 and options[:receive_timeout] <= 2_000
      assert options[:connect_options][:timeout] <= 2_000
      assert {"authorization", "Bearer controller-test-token"} in options[:headers]
      uri = URI.parse(options[:url])
      response =
        case uri.host do
          "secretmanager.googleapis.com" ->
            assert uri.path == "/v1/" <> @version
            refute String.contains?(uri.path, ":access")
            %{"name" => @version, "state" => "ENABLED", "createTime" => "2026-09-22T00:00:00Z"}

          "storage.googleapis.com" ->
            assert uri.path == "/storage/v1/b/fixture-codex-control/o/features%2Fauthority.json"
            if uri.query, do: Jason.encode!(seed()), else: %{"generation" => @generation}
        end

      {:ok, %{status: 200, headers: %{}, body: response}}
    end

    assert {:ok, %{"name" => @version, "state" => "ENABLED"}} = GoogleClient.version_metadata(config(), @version, token_fun: token_fun, request_fun: request_fun, timeout_ms: 2_000)
    assert {:ok, %{record: record}} = ControlStore.read(config(), token_fun: token_fun, request_fun: request_fun, timeout_ms: 2_000)
    assert record == seed()
    assert_receive {:identity, %{"credential_configuration" => "symphony-codex"} = identity}
    refute Map.has_key?(identity, "impersonate_service_account")
    refute Map.has_key?(identity, "project")
    refute_receive {:identity, _}
  end

  test "metadata rejects aliases, foreign secrets and payload endpoints before any request" do
    request = fn _, _, _, _ -> flunk("invalid version reached transport") end

    for version <- [@secret <> "/versions/latest", @secret <> "/versions/0", @version <> ":access", "projects/foreign/secrets/other/versions/1"] do
      assert {:error, :credential_outcome_unknown} = GoogleClient.version_metadata(config(), version, request: request)
    end
  end

  test "Google client refuses endpoint passthrough and redacts uncertain writes without replay" do
    request = fn _ -> flunk("unapproved host reached transport") end
    opts = [request_fun: request, token_fun: fn _, _ -> {:ok, "fixture-token"} end]
    assert {:error, :credential_outcome_unknown} = GoogleClient.request(config(), :post, "https://attacker.invalid/upload", [], "{}", opts)
    assert {:error, :credential_outcome_unknown} = GoogleClient.request(config(), :get, "https://secretmanager.googleapis.com/v1/" <> @version <> ":access", [], nil, opts)

    parent = self()
    failing = fn _ -> send(parent, :write); {:error, {:timeout, "private response"}} end
    url = "https://storage.googleapis.com/upload/storage/v1/b/fixture-codex-control/o?uploadType=media&name=features%2Fauthority.json&ifGenerationMatch=123"
    assert {:error, :credential_outcome_unknown} = GoogleClient.request(config(), :post, url, [{"content-type", "application/json"}], "{}", Keyword.put(opts, :request_fun, failing))
    assert_receive :write
    refute_receive :write
  end

  test "only one definitely rejected 401 can renew controller auth and resend" do
    token_fun = fn _, _ ->
      count = Process.get(:controller_tokens, 0) + 1
      Process.put(:controller_tokens, count)
      {:ok, "controller-#{count}"}
    end

    request_fun = fn options ->
      if {"authorization", "Bearer controller-1"} in options[:headers],
        do: {:ok, %{status: 401, headers: %{}, body: %{}}},
        else: {:ok, %{status: 200, headers: %{}, body: %{"name" => @version, "state" => "ENABLED"}}}
    end

    opts = [token_fun: token_fun, request_fun: request_fun]
    assert {:ok, _} = GoogleClient.version_metadata(config(), @version, opts)
    assert {:ok, _} = GoogleClient.version_metadata(config(), @version, opts)
    assert Process.get(:controller_tokens) == 2
    denied = fn _ -> {:ok, %{status: 401, headers: %{}, body: %{}}} end
    assert {:error, :credential_outcome_unknown} = GoogleClient.version_metadata(config(), @version, Keyword.put(opts, :request_fun, denied))
    assert Process.get(:controller_tokens) == 2
  end

  test "expired shared credential deadlines cannot invoke token acquisition even with a cached token" do
    identity = %{"project" => "fixture-workers", "credential_configuration" => "symphony-codex"}
    opts = [token_fun: fn _, _ -> {:ok, "fixture-token"} end, timeout_ms: 1_000]
    assert {:ok, "fixture-token"} = GoogleCredentials.token(identity, opts)
    expired = Keyword.merge(opts, deadline: System.monotonic_time(:millisecond) - 1, token_fun: fn _, _ -> flunk("expired token acquisition") end)
    assert {:error, {:unknown, :google_deadline}} = GoogleCredentials.token(identity, expired)
  end

  test "controller token subprocess selects only the dedicated non-impersonating profile" do
    directory = Path.join(System.tmp_dir!(), "codex-controller-token-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    executable = Path.join(directory, "gcloud")
    File.write!(executable, """
    #!/bin/sh
    selected=no
    for arg in "$@"; do
      case "$arg" in
        --configuration=symphony-codex) selected=yes ;;
        --configuration=*|--impersonate-service-account*|--project=*) exit 3 ;;
      esac
    done
    test "$selected" = yes || exit 4
    test "$CLOUDSDK_CORE_DISABLE_PROMPTS" = 1 || exit 5
    printf 'scripted-controller-token\\n'
    """)
    File.chmod!(executable, 0o700)
    supervisor = start_supervised!(Task.Supervisor)

    request = fn options ->
      assert {"authorization", "Bearer scripted-controller-token"} in options[:headers]
      {:ok, %{status: 200, body: %{"name" => @version, "state" => "ENABLED"}}}
    end

    assert {:ok, _} = GoogleClient.version_metadata(config(), @version,
      gcloud_executable: executable, task_supervisor: supervisor, authority: self(), request_fun: request, timeout_ms: 5_000)
  end

  defp config do
    %{
      provider: %{"project" => "lifecycle-project", "credential_configuration" => "symphony-lifecycle", "impersonate_service_account" => "lifecycle@example.invalid"},
      codex_credentials: %{"credential_id" => "features-personal-codex", "secret" => @secret, "control_bucket" => "fixture-codex-control", "control_object" => "features/authority.json"}
    }
  end

  defp seed, do: Record.initial("features-personal-codex", 1, @version)

  defp owner(attempt \\ "attempt-a") do
    %{"deployment_id" => "deployment-a", "lane" => "features", "workstation_name" => "projects/fixture-workers/locations/europe-west1/workstationClusters/fixture/workstationConfigs/features/workstations/ticket-1", "workstation_uid" => nil, "attempt_id" => attempt}
  end

  defp owned do
    {:ok, claimed} = Record.transition(seed(), {:claim, "claim-a", owner()}, "claim-transition")
    {:ok, bound} = Record.transition(claimed, {:bind_uid, "claim-a", "uid-a"}, "bind-transition")
    bound
  end

  defp receipt do
    %{"schema" => 1, "credential_id" => "features-personal-codex", "epoch" => 1, "claim_id" => "claim-a", "owner" => Map.put(owner(), "workstation_uid", "uid-a"), "secret_version" => @secret <> "/versions/2", "sha256" => String.duplicate("a", 64), "admission" => "sealed"}
  end

  defp proof, do: %{"uid" => "uid-a", "operation" => "projects/fixture-workers/locations/europe-west1/operations/stop-1", "attempt_id" => "attempt-a"}

  defp store(record, opts \\ []) do
    server = start_supervised!({Agent, fn -> %{generation: @generation, bytes: if(record, do: Jason.encode!(record)), writes: 0, metadata_reads: 0, mode: Keyword.get(opts, :mode), race_record: Keyword.get(opts, :race_record), metadata: Keyword.get(opts, :metadata)} end}, id: make_ref())

    request = fn method, url, headers, body ->
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")

      Agent.get_and_update(server, fn state ->
        cond do
          uri.host == "secretmanager.googleapis.com" ->
            assert method == :get
            assert uri.path == "/v1/" <> @secret <> "/versions/2"
            metadata = state.metadata || %{"name" => @secret <> "/versions/2", "state" => "ENABLED"}
            {{:ok, 200, [], metadata}, %{state | metadata_reads: state.metadata_reads + 1}}

          method == :get ->
            assert uri.host == "storage.googleapis.com"
            assert uri.path == "/storage/v1/b/fixture-codex-control/o/features%2Fauthority.json"
            read_object(state, query)

          method == :post ->
            assert uri.host == "storage.googleapis.com"
            assert uri.path == "/upload/storage/v1/b/fixture-codex-control/o"
            assert query["uploadType"] == "media"
            assert query["name"] == "features/authority.json"
            assert query["ifGenerationMatch"] not in [nil, "0"]
            assert {"content-type", "application/json"} in headers
            replace_object(state, query["ifGenerationMatch"], body)

          true ->
            flunk("unsupported authority operation")
        end
      end)
    end

    {server, request}
  end

  defp read_object(%{bytes: nil} = state, _query), do: {{:ok, 404, [], %{}}, state}
  defp read_object(%{mode: :hidden} = state, _query), do: {{:error, :timeout}, state}

  defp read_object(state, %{"alt" => "media", "generation" => generation}) do
    cond do
      state.race_record != nil ->
        updated = %{state | generation: increment(state.generation), bytes: Jason.encode!(state.race_record), race_record: nil}
        {{:ok, 404, [], %{}}, updated}

      generation == state.generation -> {{:ok, 200, [], state.bytes}, state}
      true -> {{:ok, 404, [], %{}}, state}
    end
  end

  defp read_object(state, query) do
    assert query == %{}
    {{:ok, 200, [], %{"generation" => state.generation}}, state}
  end

  defp replace_object(state, expected, body) do
    state = %{state | writes: state.writes + 1}

    if expected == state.generation and state.bytes != nil do
      record = Jason.decode!(body)
      updated = %{state | generation: increment(state.generation), bytes: body, mode: nil}

      case state.mode do
        :lose_response -> {{:error, :timeout}, updated}
        :lose_and_hide -> {{:error, :timeout}, %{updated | mode: :hidden}}
        :lose_and_swap -> {{:error, :timeout}, %{updated | bytes: Jason.encode!(put_in(record, ["owner", "attempt_id"], "foreign-attempt"))}}
        _ -> {{:ok, 200, [], %{"generation" => updated.generation}}, updated}
      end
    else
      {{:ok, 412, [], %{}}, state}
    end
  end

  defp increment(generation), do: generation |> String.to_integer() |> Kernel.+(1) |> Integer.to_string()
end
