defmodule SymphonyElixir.CodexCredentialsRecoveryTest do
  use ExUnit.Case, async: true
  alias Exqlite.Sqlite3
  alias SymphonyElixir.CodexCredentials.{Record, Recovery}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionEnvironment.{Config, Credentials, Operations}
  alias SymphonyElixir.ExecutionEnvironment.Record, as: Resource

  defmodule Provider do
    def validate_config(_), do: :ok
    def preflight(_, _), do: :ok
    def discover(_, opts), do: opts[:provider].(:discover, nil, opts)
    def inspect(_, record, opts), do: opts[:provider].(:inspect, record, opts)
    def put_intent(_, record, intent, opts), do: opts[:provider].({:metadata, intent}, record, opts)
    def stop(_, record, opts), do: opts[:provider].(:stop, record, opts)
    def ensure(_, record, opts), do: opts[:provider].(:ensure, record, opts)
    def start(_, record, opts), do: opts[:provider].(:start, record, opts)

    def connect(_, _, opts) do
      target = %SymphonyElixir.SSH.Target{executable: "/usr/bin/ssh", prefix: ["fixture"], label: "fixture"}
      Operations.open_connection(opts[:task_supervisor], opts[:authority], target, [])
    end
  end

  setup context do
    root_owned_pvc? = Map.get(context, :root_owned_pvc, false)

    root =
      if root_owned_pvc?,
        do: System.fetch_env!("SYMPHONY_TEST_ROOT_OWNED_PVC"),
        else: Path.join(System.tmp_dir!(), "codex-recovery-#{System.unique_integer([:positive])}")

    if root_owned_pvc? do
      refute File.exists?(Path.join(root, "symphony.sqlite3"))
    else
      File.mkdir_p!(root)
      File.chmod!(root, 0o700)
    end

    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)

    on_exit(fn ->
      if root_owned_pvc? do
        Enum.each(
          ~w(symphony.sqlite3 symphony.sqlite3-wal symphony.sqlite3-shm WORKFLOW.md),
          &File.rm(Path.join(root, &1))
        )
      else
        File.rm_rf!(root)
      end
    end)

    refs = %{
      "credential_id" => "features-codex",
      "secret" => "projects/123456/secrets/features-codex",
      "control_bucket" => "fixture-control",
      "control_object" => "authority.json"
    }

    environment = %{
      "kind" => "google_workstations",
      "deployment_id" => "deployment",
      "startup_timeout_ms" => 1000,
      "shutdown_timeout_ms" => 1000,
      "codex_credentials" => refs,
      "provider" => %{
        "project" => "p",
        "location" => "l",
        "cluster" => "c",
        "config" => "features",
        "credential_configuration" => "maintenance",
        "impersonate_service_account" => "lifecycle@example.iam.gserviceaccount.com",
        "ssh_user" => "worker"
      }
    }

    front =
      Jason.encode!(%{
        "tracker" => %{"kind" => "memory"},
        "workspace" => %{"root" => "/state/workspaces"},
        "worker" => %{"environment" => environment}
      })

    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, SymphonyElixir.Workflow.render(front, "Current Features prompt"))
    database = Path.join(root, "symphony.sqlite3")
    {:ok, db} = Sqlite3.open(database)

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TABLE lanes (id INTEGER PRIMARY KEY, slug TEXT, enabled INTEGER, deleted_at TEXT, current_version_id INTEGER); CREATE TABLE lane_versions (id INTEGER PRIMARY KEY, lane_id INTEGER, front_matter TEXT, prompt TEXT); INSERT INTO lanes VALUES (1, 'features', 0, NULL, 1);"
      )

    {:ok, statement} = Sqlite3.prepare(db, "INSERT INTO lane_versions VALUES (1, 1, ?, ?)")
    :ok = Sqlite3.bind(statement, [front, "Current Features prompt"])
    :done = Sqlite3.step(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
    key = SymphonyElixir.ExecutionEnvironment.resource_key("deployment", "memory", "ticket")
    name = "projects/p/locations/l/workstationClusters/c/workstationConfigs/features/workstations/" <> key

    owner = %{
      "deployment_id" => "deployment",
      "lane" => "features",
      "workstation_name" => name,
      "workstation_uid" => nil,
      "attempt_id" => "original-attempt"
    }

    {:ok, claimed} =
      Record.transition(
        Record.initial(refs["credential_id"], 1, refs["secret"] <> "/versions/1"),
        {:claim, "original-claim", owner},
        "claim-transition"
      )

    {:ok, owned} = Record.transition(claimed, {:bind_uid, "original-claim", "uid-1"}, "bound-transition")
    {:ok, assignment} = Record.assignment(owned)

    receipt =
      Map.merge(assignment, %{
        "secret_version" => refs["secret"] <> "/versions/2",
        "sha256" => String.duplicate("a", 64),
        "admission" => "sealed"
      })

    {:ok, checkpointed} = Record.transition(owned, {:checkpoint, receipt}, "checkpoint-transition")

    resource = %Resource{
      key: key,
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "google_workstations",
      scope: %{"project" => "p", "location" => "l", "cluster" => "c"},
      workspace_path: "/state/workspaces/" <> key,
      template_identity: "template",
      provider_ref: %{name: name, uid: "uid-1"},
      attempt_id: "original-attempt",
      desired: :stopped,
      phase: :stopped,
      proof: {:quiescent, %{uid: "uid-1", operation: "projects/p/locations/l/operations/stop-1"}}
    }

    resource =
      Credentials.put(resource, %{
        "assignment" => assignment,
        "stage" => "checkpointed",
        "mode" => "recover",
        "disposition" => nil
      })

    cloud =
      start_supervised!({Agent, fn -> %{record: checkpointed, generation: 8, writes: [], fail: nil} end}, id: :cloud)

    remote = start_supervised!({Agent, fn -> %{records: [resource], writes: [], fail: nil} end}, id: :remote)

    request = fn method, url, _headers, body ->
      refute String.ends_with?(URI.parse(url).path, ":access")
      query = URI.decode_query(URI.parse(url).query || "")

      Agent.get_and_update(cloud, fn state ->
        cond do
          String.contains?(url, "secretmanager.googleapis.com") ->
            {{:ok, 200, [], %{"name" => receipt["secret_version"], "state" => "ENABLED"}}, state}

          is_nil(state.record) ->
            {{:ok, 404, [], %{}}, state}

          method == :get and query["alt"] == "media" ->
            {{:ok, 200, [], Jason.encode!(state.record)}, state}

          method == :get ->
            {{:ok, 200, [], %{"generation" => to_string(state.generation)}}, state}

          method == :post and query["ifGenerationMatch"] != to_string(state.generation) ->
            {{:ok, 412, [], %{}}, state}

          method == :post ->
            next = %{
              state
              | record: Jason.decode!(body),
                generation: state.generation + 1,
                writes: state.writes ++ [Jason.decode!(body)]
            }

            reply =
              if state.fail == :lost_write,
                do: {:error, :timeout},
                else: {:ok, 200, [], %{"generation" => to_string(next.generation)}}

            {reply, next}
        end
      end)
    end

    provider = fn operation, record, opts ->
      assert is_pid(opts[:task_supervisor]) and Process.alive?(opts[:task_supervisor])
      assert opts[:authority] == self()

      Agent.get_and_update(remote, fn state ->
        case operation do
          :discover ->
            {{:ok, state.records}, state}

          :inspect ->
            {{:ok, Enum.find(state.records, &(&1.key == record.key))}, state}

          {:metadata, intent} ->
            acknowledged = get_in(Credentials.data(record), ["disposition", "resource_acknowledged"])

            if state.fail == :metadata or (state.fail == :final_metadata and acknowledged == true) do
              {{:error, {:unknown, :write_lost}, record}, state}
            else
              next = struct!(record, intent)
              {{:ok, next}, %{state | records: [next], writes: state.writes ++ [:metadata]}}
            end

          :ensure ->
            {{:ok, record}, %{state | records: [record]}}

          :start ->
            next = %{record | phase: :running, proof: :unknown}
            {{:ok, next}, %{state | records: [next]}}

          :stop ->
            next = %{record | phase: :stopped, pending: [], proof: resource.proof}
            {{:ok, next}, %{state | records: [next], writes: state.writes ++ [:stop]}}
        end
      end)
    end

    options = [data_root: root, workflow: workflow, action: "inspect"]

    command = fn _, arguments, _ ->
      text = List.last(arguments)

      result =
        if String.contains?(text, "codex_guard.py checkpoint") do
          if Agent.get(remote, & &1.fail) == :receipt_mismatch,
            do: Map.put(receipt, "sha256", String.duplicate("b", 64)),
            else: receipt
        else
          %{"assignment" => assignment, "state" => "CHECKPOINTED", "admission" => "sealed", "reason" => nil}
        end

      {:ok, %{status: 0, output: Jason.encode!(%{"ok" => true, "result" => result})}}
    end

    owner = File.stat!(root)

    deps = [
      verify_maintenance: fn ^root, :operator -> :ok end,
      filesystem_identity: fn -> {:ok, owner.uid, owner.gid} end,
      adapter: Provider,
      operation_options: [provider: provider, request: request, command_fun: command]
    ]

    %{
      root: root,
      database: database,
      workflow: workflow,
      options: options,
      deps: deps,
      cloud: cloud,
      remote: remote,
      resource: resource,
      receipt: receipt,
      owned: owned,
      name: name
    }
  end

  @tag :root_owned_pvc
  @tag skip: is_nil(System.get_env("SYMPHONY_TEST_ROOT_OWNED_PVC"))
  test "root-owned PVC accepts a process-owned private checkpoint receipt under the real maintenance lock", c do
    root_info = File.stat!(c.root)
    assert root_info.uid == 0
    assert Bitwise.band(root_info.mode, 0o7777) == 0o2770
    private = Path.join(c.root, "private-receipt")
    File.mkdir!(private)
    File.chmod!(private, 0o700)
    on_exit(fn -> File.rm_rf!(private) end)
    receipt = Path.join(private, "receipt.json")
    File.write!(receipt, Jason.encode!(c.receipt))
    File.chmod!(receipt, 0o600)
    receipt_info = File.stat!(receipt)
    assert receipt_info.uid != root_info.uid
    assert File.stat!(private).uid == receipt_info.uid
    deps = Keyword.drop(c.deps, [:verify_maintenance, :filesystem_identity])
    options = Keyword.put(mutation(c, "checkpoint"), :receipt_file, receipt)
    assert {:ok, %{authority: %{record: record}}} = Recovery.reconcile(options, deps)
    assert record["state"] == "AVAILABLE"
    assert record["last_handoff"]["resource_acknowledged"]
    assert record["last_handoff"]["owner"]["attempt_id"] == "original-attempt"
  end

  test "receipt ownership follows filesystem identity rather than installation directory ownership", c do
    owner = File.stat!(c.root)
    deps = Keyword.put(c.deps, :filesystem_identity, fn -> {:ok, owner.uid + 1, owner.gid} end)
    assert {:error, :receipt_invalid} = Recovery.reconcile(receipt_options(c, c.receipt), deps)
    assert Agent.get(c.cloud, & &1.writes) == []
    assert Agent.get(c.remote, & &1.writes) == []
  end

  test "inspect uses existing disabled database without scheduler or provider mutations", c do
    assert {:ok, result} = Recovery.reconcile(c.options, c.deps)
    assert result.action == "inspect" and result.admission == "maintenance"
    assert [%{name: name, assignment: assignment}] = result.resources
    assert name == c.name and assignment["owner"]["attempt_id"] == "original-attempt"
    assert Agent.get(c.cloud, & &1.writes) == []
    assert Agent.get(c.remote, & &1.writes) == []
  end

  test "strict lock is checked before missing installation or any provider request", c do
    deps = Keyword.put(c.deps, :verify_maintenance, fn _, _ -> {:error, :maintenance_required} end)
    assert {:error, :maintenance_required} = Recovery.reconcile(c.options, deps)
    assert Agent.get(c.cloud, & &1.writes) == []
  end

  test "missing database is never created", c do
    File.rm!(c.database)
    assert {:error, :installation_required} = Recovery.reconcile(c.options, c.deps)
    refute File.exists?(c.database)
  end

  test "enabled deleted lane still blocks maintenance", c do
    sql(c.database, "INSERT INTO lanes VALUES (2, 'deleted', 1, '2026-01-01', NULL)")
    assert {:error, :lanes_enabled} = Recovery.reconcile(c.options, c.deps)
  end

  test "stale Features prompt cannot substitute for the persisted current version", c do
    File.write!(c.workflow, String.replace(File.read!(c.workflow), "Current Features prompt", "Stale prompt"))
    assert {:error, :workflow_mismatch} = Recovery.reconcile(c.options, c.deps)
  end

  test "inspect reports absent authority without creating it", c do
    Agent.update(c.cloud, &%{&1 | record: nil})
    Agent.update(c.remote, &%{&1 | records: []})
    assert {:ok, %{authority: nil, resources: []}} = Recovery.reconcile(c.options, c.deps)
  end

  test "stale epoch and generation reject before physical stop or authority write", c do
    for override <- [[expected_epoch: 2], [expected_generation: "7"]] do
      assert {:error, :authority_changed} =
               Recovery.reconcile(Keyword.merge(mutation(c, "reseed-stop"), override), c.deps)
    end

    assert Agent.get(c.remote, & &1.writes) == []
    assert Agent.get(c.cloud, & &1.writes) == []
  end

  test "UID mismatch and pending inventory cannot authorize reseed", c do
    for resource <- [
          %{c.resource | provider_ref: %{name: c.name, uid: "replacement"}},
          %{c.resource | pending: [%{id: "projects/p/locations/l/operations/start", verb: :start, outcome: :pending}]}
        ] do
      Agent.update(c.remote, &%{&1 | records: [resource]})
      assert {:error, _} = Recovery.reconcile(mutation(c, "reseed-stop"), c.deps)
    end

    assert Agent.get(c.cloud, & &1.writes) == []
  end

  test "assignment epoch and startup version must match current bound authority before reseed proof", c do
    for {field, value} <- [{"epoch", 2}, {"secret_version", "projects/123456/secrets/features-codex/versions/3"}] do
      assigned = Map.put(Credentials.assignment(c.resource), field, value)
      record = Credentials.put(c.resource, %{"assignment" => assigned})
      Agent.update(c.remote, &%{&1 | records: [record]})
      assert {:error, :inventory_unaccounted} = Recovery.reconcile(mutation(c, "reseed-stop"), c.deps)
    end

    assert Agent.get(c.cloud, & &1.writes) == []
    assert Agent.get(c.remote, & &1.writes) == []
  end

  test "reseed safety stop preserves quarantined ownership and does not checkpoint", c do
    {:ok, quarantine} = Record.transition(c.owned, {:quarantine, "original-claim", "checkpoint_failed"}, "quarantine")
    Agent.update(c.cloud, &%{&1 | record: quarantine})
    Agent.update(c.remote, &%{&1 | records: [%{c.resource | phase: :running, proof: nil}]})
    assert {:ok, %{resources: [%{stop_proof: proof}]}} = Recovery.reconcile(mutation(c, "reseed-stop"), c.deps)
    assert proof["attempt_id"] == "original-attempt"
    assert Agent.get(c.cloud, & &1.record) == quarantine
    assert :stop in Agent.get(c.remote, & &1.writes)
  end

  test "known authoritative checkpoint explicitly resolves quarantine and acknowledges original owner", c do
    Agent.update(c.cloud, fn state ->
      %{state | record: Map.merge(state.record, %{"state" => "RECOVERY_REQUIRED", "reason" => "checkpoint_failed"})}
    end)

    options = receipt_options(c, c.receipt)
    assert {:ok, result} = Recovery.reconcile(options, c.deps)
    assert result.authority.record["state"] == "AVAILABLE"
    assert result.authority.record["last_handoff"]["resource_acknowledged"]
    assert result.authority.record["last_handoff"]["owner"]["attempt_id"] == "original-attempt"
    assert [%{disposition: %{"resource_acknowledged" => true}}] = result.resources
  end

  test "forged receipt cannot release clean authority", c do
    receipt = put_in(c.receipt, ["owner", "attempt_id"], "maintenance-attempt")
    assert {:error, _} = Recovery.reconcile(receipt_options(c, receipt), c.deps)
    assert Agent.get(c.cloud, & &1.writes) == []
  end

  test "lost checkpoint CAS response reconciles exact committed transition", c do
    Agent.update(c.cloud, &%{&1 | fail: :lost_write})
    assert {:ok, %{authority: %{record: record}}} = Recovery.reconcile(receipt_options(c, c.receipt), c.deps)
    assert record["last_handoff"]["resource_acknowledged"]
  end

  test "lost checkpoint publication is recovered only from matching authenticated worker evidence", c do
    Agent.update(c.cloud, &%{&1 | record: c.owned})
    assert {:ok, %{authority: %{record: record}}} = Recovery.reconcile(receipt_options(c, c.receipt), c.deps)
    assert record["last_handoff"]["owner"]["attempt_id"] == "original-attempt"
    assert record["last_handoff"]["resource_acknowledged"]
  end

  test "uncommitted receipt that disagrees with the worker cannot release ownership", c do
    Agent.update(c.cloud, &%{&1 | record: c.owned})
    Agent.update(c.remote, &%{&1 | fail: :receipt_mismatch})
    assert {:error, _} = Recovery.reconcile(receipt_options(c, c.receipt), c.deps)
    assert Agent.get(c.cloud, & &1.record) == c.owned
  end

  for failure <- [:metadata, :final_metadata] do
    test "reseed recovers #{failure} without changing original assignment epoch", c do
      reseeded = reseed(c)
      Agent.update(c.cloud, &%{&1 | record: reseeded, generation: 9})
      Agent.update(c.remote, &%{&1 | fail: unquote(failure)})
      options = Keyword.merge(mutation(c, "reseed-commit"), expected_epoch: 2, expected_generation: "9")
      assert {:error, _} = Recovery.reconcile(options, c.deps)
      current = Agent.get(c.cloud, & &1)
      assert current.record["last_handoff"]["resource_acknowledged"] == (unquote(failure) == :final_metadata)
      Agent.update(c.remote, &%{&1 | fail: nil})
      options = Keyword.put(options, :expected_generation, to_string(current.generation))

      assert {:ok, %{resources: [%{assignment: assignment, disposition: disposition}]}} =
               Recovery.reconcile(options, c.deps)

      assert assignment["epoch"] == 1 and assignment["owner"]["attempt_id"] == "original-attempt"
      assert disposition["epoch"] == 1 and disposition["resolved_epoch"] == 2 and disposition["resource_acknowledged"]
    end
  end

  test "epoch advancement without matching handoff never resolves an old claim", c do
    Agent.update(
      c.cloud,
      &%{
        &1
        | record: Record.initial("features-codex", 2, "projects/123456/secrets/features-codex/versions/2"),
          generation: 9
      }
    )

    options = Keyword.merge(mutation(c, "reseed-commit"), expected_epoch: 2, expected_generation: "9")
    assert {:error, _} = Recovery.reconcile(options, c.deps)
    assert Agent.get(c.remote, & &1.writes) == []
  end

  test "unbound original claim with complete empty inventory reseeds without invented stop evidence", c do
    unbound = put_in(c.owned, ["owner", "workstation_uid"], nil)
    Agent.update(c.cloud, &%{&1 | record: unbound})
    Agent.update(c.remote, &%{&1 | records: []})

    assert {:ok, %{authority: %{record: ^unbound}, resources: []}} =
             Recovery.reconcile(mutation(c, "reseed-stop"), c.deps)

    assert Agent.get(c.cloud, & &1.writes) == []
  end

  test "acknowledged historical disposition survives a later epoch but unresolved claims do not", c do
    assert {:ok, _} = Recovery.reconcile(receipt_options(c, c.receipt), c.deps)
    [committed] = Agent.get(c.remote, & &1.records)
    later = Record.initial("features-codex", 2, "projects/123456/secrets/features-codex/versions/2")
    Agent.update(c.cloud, &%{&1 | record: later, generation: &1.generation + 1})
    {:ok, workflow} = SymphonyElixir.Workflow.parse(File.read!(c.workflow))
    {:ok, settings} = Schema.parse(workflow.config, resolve_secrets: false)
    config = Config.runtime(settings)
    assert {:ok, historical} = Credentials.reconcile(config, committed, c.deps[:operation_options])
    assert Credentials.resolved?(historical)
    assert :ok = Credentials.authorize_destroy(config, historical, c.deps[:operation_options])
    assert {:error, _, unresolved} = Credentials.reconcile(config, c.resource, c.deps[:operation_options])
    refute Credentials.resolved?(unresolved)
  end

  test "a historical resource name cannot substitute for the bound recovery owner", c do
    assert {:ok, _} = Recovery.reconcile(receipt_options(c, c.receipt), c.deps)
    [committed] = Agent.get(c.remote, & &1.records)
    name = String.replace(c.name, ~r{/workstations/[^/]+$}, "/workstations/historical")
    owner = Map.merge(c.owned["owner"], %{"workstation_name" => name, "workstation_uid" => "historical-uid"})
    assignment = Credentials.assignment(committed) |> Map.merge(%{"owner" => owner, "claim_id" => "historical-claim"})

    disposition =
      Credentials.disposition(committed)
      |> Map.merge(%{"owner" => owner, "claim_id" => "historical-claim"})
      |> put_in(["stop_proof", "uid"], "historical-uid")

    historical =
      %{
        committed
        | key: "historical",
          provider_ref: %{name: name, uid: "historical-uid"},
          proof: {:quiescent, %{uid: "historical-uid", operation: "projects/p/locations/l/operations/stop-1"}}
      }
      |> Credentials.put(%{"assignment" => assignment, "disposition" => disposition})

    Agent.update(c.cloud, &%{&1 | record: c.owned, generation: 8, writes: []})
    Agent.update(c.remote, &%{&1 | records: [c.resource, historical], writes: []})

    assert {:error, :resource_mismatch} =
             Recovery.reconcile(Keyword.put(mutation(c, "reseed-stop"), :resource, name), c.deps)

    assert Agent.get(c.cloud, & &1.writes) == []
    assert Agent.get(c.remote, & &1.writes) == []
  end

  test "all four actions cross real CLI parsing and isolated recovery with durable resource acknowledgement", c do
    parent = self()

    deps = %{
      reconcile_credentials: &Recovery.reconcile(&1, c.deps),
      ensure_all_started: fn -> flunk("scheduler started") end,
      start_repo: fn -> flunk("Repo or migrations started") end,
      operator_token: fn -> flunk("operator secret accessed") end,
      write_output: fn output ->
        send(parent, {:cli_output, Jason.decode!(output)})
        :ok
      end
    }

    invoke = fn action, extra ->
      snapshot = Agent.get(c.cloud, & &1)
      base = ["credentials", "reconcile", "--data-root", c.root, "--workflow", c.workflow, "--action", action]

      mutation =
        if action == "inspect",
          do: [],
          else: [
            "--resource",
            c.name,
            "--expected-epoch",
            to_string(snapshot.record["epoch"]),
            "--expected-generation",
            to_string(snapshot.generation)
          ]

      assert :ok = SymphonyElixir.CLI.evaluate(base ++ mutation ++ extra, deps)
      assert_receive {:cli_output, %{"ok" => true, "result" => result}}
      assert result["action"] == action and result["admission"] == "maintenance"
      result
    end

    assert invoke.("inspect", [])["authority"]["record"]["state"] == "CHECKPOINTED"
    receipt = receipt_options(c, c.receipt)[:receipt_file]

    assert invoke.("checkpoint", ["--receipt-file", receipt])["authority"]["record"]["last_handoff"][
             "resource_acknowledged"
           ]

    before = Agent.get(c.cloud, & &1)
    assert invoke.("reseed-stop", [])["authority"]["generation"] == to_string(before.generation)
    Agent.update(c.cloud, &%{&1 | record: reseed(c), generation: &1.generation + 1})
    result = invoke.("reseed-commit", [])
    assert result["authority"]["record"]["epoch"] == 2
    assert result["authority"]["record"]["last_handoff"]["resource_acknowledged"]
    assert [resource] = result["resources"]
    assert resource["assignment"]["epoch"] == 1
    assert resource["disposition"]["resolved_epoch"] == 2
  end

  defp mutation(c, action),
    do: Keyword.merge(c.options, action: action, resource: c.name, expected_epoch: 1, expected_generation: "8")

  defp receipt_options(c, receipt) do
    path = Path.join(c.root, "receipt.json")
    File.write!(path, Jason.encode!(receipt))
    File.chmod!(path, 0o600)
    Keyword.put(mutation(c, "checkpoint"), :receipt_file, path)
  end

  defp reseed(c) do
    record = Record.initial("features-codex", 2, "projects/123456/secrets/features-codex/versions/2")

    Map.merge(record, %{
      "transition_id" => "operator-reseed",
      "last_handoff" => %{
        "claim_id" => "original-claim",
        "owner" => c.owned["owner"],
        "secret_version" => record["head_version"],
        "stop_proof" => %{
          "uid" => "uid-1",
          "operation" => "projects/p/locations/l/operations/stop-1",
          "attempt_id" => "original-attempt"
        },
        "resource_acknowledged" => false
      }
    })
  end

  defp sql(path, command) do
    {:ok, db} = Sqlite3.open(path, mode: :readwrite)
    :ok = Sqlite3.execute(db, command)
    :ok = Sqlite3.close(db)
  end
end
