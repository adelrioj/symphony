Code.require_file("../support/managed_environment_fixture/control.exs", __DIR__)

defmodule SymphonyElixir.ManagedEnvironmentQualificationStateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Agent.Codex
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.ExecutionEnvironment.{Operations, Record}
  alias SymphonyElixir.ManagedEnvironmentFixture.Control
  alias SymphonyElixir.SSH.Target
  alias SymphonyElixir.Tracker.{Issue, Memory}

  setup do
    previous = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:symphony_elixir, :memory_tracker_issues),
        else: Application.put_env(:symphony_elixir, :memory_tracker_issues, previous)
    end)

    :ok
  end

  test "captured backing identities survive inventory failure and interrupted recovery" do
    control = start_supervised!({Control, checks: ["final_absence"], session_limit: 3})
    handle = "_tenant#disk%2F=雪\\\"\n" <> String.duplicate("x", 2_100)

    record = %{
      key: "environment-1",
      issue_id: "issue-1",
      provider_ref: %{name: "workstation-1", uid: "worker-uid"},
      metadata: %{
        "backing_resources" => [%{"id" => "disk-1", "name" => "ticket-disk", "token" => "SECRET"}],
        "volumes" => %{
          "claim-1" => %{
            "pvc_name" => "claim-1",
            "pvc_uid" => "claim-uid",
            "pv_name" => "pv-1",
            "pv_uid" => "pv-uid",
            "volume_handle" => handle,
            "claim_ref" => %{"token" => "SECRET"}
          }
        },
        "cleanup_remaining" => %{"pods" => [%{"name" => "pod-1", "uid" => "pod-uid"}]}
      }
    }

    :ok = inventory(control, {:ok, %{records: [record], live_worker_counts: %{"environment-1" => 1}}})
    :ok = inventory(control, {:error, {:unknown, :inventory_unavailable}})
    state = GenServer.call(control, :snapshot)
    captured = Map.get(state, :captured_resources, [])
    encoded = Jason.encode!(captured)
    for id <- ["disk-1", "claim-uid", "pv-uid", "pod-uid"], do: assert(encoded =~ id)
    assert Enum.any?(Jason.decode!(encoded), &(&1["volume_handle"] == handle))
    refute encoded =~ "SECRET"
    assert Map.get(state, :inventory_complete) == false
    assert Map.get(state, :observed_resources) == []

    recovered = start_supervised!({Control, checks: ["final_absence"], session_limit: 0}, id: :recovered)
    persisted = Jason.decode!(Jason.encode!(%{captured_resources: captured, backend_sessions: 1, events: []}))
    :ok = GenServer.call(recovered, {:interrupted, persisted})
    :ok = inventory(recovered, {:error, {:unknown, :inventory_unavailable}})
    assert GenServer.call(recovered, :snapshot).captured_resources == captured
  end

  test "safe partial inventory and direct orphan errors retain remediation identifiers without raw bodies" do
    control = start_supervised!({Control, checks: [], session_limit: 0})
    resources = [%{"kind" => "disk", "id" => "disk-orphan", "authorization" => "SECRET"}]
    :ok = inventory(control, {:error, {:unknown, {:qualification_inventory_unresolved, resources}}})
    :ok = inventory(control, {:error, {:unknown, {:orphan_backing_resources, [%{"id" => "other-disk"}]}}})
    :ok = inventory(control, {:error, {:unknown, {:kubernetes_invalid_owned_record, ["claim-orphan", "orphan-uid"]}}})
    state = GenServer.call(control, :snapshot)
    encoded = Jason.encode!(Map.get(state, :captured_resources, []))
    for id <- ["disk-orphan", "other-disk", "claim-orphan", "orphan-uid"], do: assert(encoded =~ id)
    refute encoded =~ "SECRET"
    assert Map.get(state, :inventory_complete) == false
  end

  test "mixed invalid resource diagnostics retain exact storage identities" do
    control = start_supervised!({Control, checks: [], session_limit: 0})
    handle = "_tenant#disk%2F=雪"
    resources = ["guard-name", %{"uid" => "pv-uid", "volume_handle" => handle, "token" => "SECRET"}]
    :ok = inventory(control, {:error, {:unknown, {:kubernetes_invalid_owned_record, resources}}})
    state = GenServer.call(control, :snapshot)
    assert %{"id" => "guard-name"} in state.captured_resources
    assert %{"uid" => "pv-uid", "volume_handle" => handle} in state.captured_resources
    refute state.inventory_complete
  end

  test "completed guard receipts survive absence and interruption separately from resources" do
    control = start_supervised!({Control, checks: ["absence"], session_limit: 0})

    record = %{
      key: "se-ticket",
      kind: "kubernetes",
      deployment_id: "deployment",
      scope: %{"namespace" => "workers"},
      provider_ref: "parent-uid",
      metadata: %{},
      absent?: true,
      proof: {:quiescent, %{guard_uid: "guard-uid", parent_uid: "parent-uid", protocol: "symphony-create-drain-v1"}}
    }

    active = %{record | absent?: false, proof: :unknown, metadata: %{"guard" => %{"kind" => "ConfigMap", "uid" => "guard-uid", "namespace" => "workers"}}}
    :ok = inventory(control, {:ok, %{records: [active], live_worker_counts: %{"se-ticket" => 0}}})
    :ok = GenServer.call(control, {:check, "absence", %{status: :passed}})
    refute Control.qualified?(GenServer.call(control, :snapshot))
    :ok = GenServer.call(control, {:event, %{event: :record_observation, result: {:ok, record}}})
    :ok = inventory(control, {:ok, %{records: [], live_worker_counts: %{}}})
    state = GenServer.call(control, :snapshot)
    assert [%{"uid" => "guard-uid", "kind" => "ConfigMap"} = receipt] = state.retained_guards
    assert receipt["namespace"] == "workers"
    assert state.observed_resources == []
    refute Enum.any?(state.captured_resources, &(&1["uid"] == "guard-uid"))
    :ok = GenServer.call(control, {:interrupted, Jason.decode!(Jason.encode!(%{retained_guards: state.retained_guards, events: []}))})
    assert GenServer.call(control, :snapshot).retained_guards == state.retained_guards
    refute Control.qualified?(GenServer.call(control, :snapshot))
  end

  test "fresh interrupted control restores original and recovery issues as terminal cleanup intents" do
    original = %Issue{id: "qualification-1", identifier: "QUAL-1", state: "In Review"}
    recovery = %Issue{id: "qualification-recovery", identifier: "QUAL-RECOVERY", state: "Qualification Codex"}
    control = start_supervised!({Control, checks: [], session_limit: 0})
    :ok = GenServer.call(control, {:issues, [original, recovery]})
    persisted = Jason.encode!(%{cleanup_issue_ids: Enum.map(GenServer.call(control, :snapshot).issues, & &1.id)})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    recovered = start_supervised!({Control, checks: [], session_limit: 0}, id: :recovered_cleanup)
    :ok = GenServer.call(recovered, {:interrupted, Jason.decode!(persisted)})
    restored = GenServer.call(recovered, :snapshot)
    :ok = GenServer.call(recovered, {:issues, Enum.map(restored.issues, &%{&1 | state: "Done"})})
    assert {:ok, terminal} = Memory.fetch_issues_by_states(["Done"])
    assert MapSet.new(Enum.map(terminal, & &1.id)) == MapSet.new([original.id, recovery.id])
    assert {:ok, []} = Memory.fetch_issues_by_states(["Qualification Codex", "In Review"])
    refute Control.qualified?(GenServer.call(recovered, :snapshot))
  end

  test "runner rejection remains failed after good events cleanup and interrupted recovery" do
    control = start_supervised!({Control, checks: ["final_absence"], session_limit: 3})
    opts = [execution_context: ExecutionContext.local("/SECRET"), attempt_id: "attempt-1", token: "SECRET"]
    request = %{event: :runner_invocation, issue_id: "issue-1", options: opts}
    assert {:error, :qualification_runner_context_rejected} = GenServer.call(control, {:event, request})
    :ok = GenServer.call(control, {:event, %{event: :operation_result, outcome: :ok}})
    :ok = GenServer.call(control, {:check, "final_absence", %{status: :passed}})
    :ok = inventory(control, {:ok, %{records: [], live_worker_counts: %{}}})
    state = GenServer.call(control, :snapshot)
    assert Map.get(state, :runner_rejected) == true
    refute Jason.encode!(state.events) =~ "SECRET"

    recovered = start_supervised!({Control, checks: ["final_absence"], session_limit: 0}, id: :recovered)
    :ok = GenServer.call(recovered, {:interrupted, %{"runner_rejected" => true, "events" => []}})
    :ok = GenServer.call(recovered, {:check, "final_absence", %{status: :passed}})
    assert GenServer.call(recovered, :snapshot).runner_rejected
  end

  test "missing static and forged managed runner contexts are refused before session admission" do
    control = start_supervised!({Control, checks: [], session_limit: 3})

    contexts = [nil, ExecutionContext.ssh("/work", "SECRET-host"), %{mode: :managed, target: "SECRET"}]

    for context <- contexts do
      opts = [execution_context: context, attempt_id: "attempt-1"]
      event = %{event: :runner_invocation, issue_id: "issue-1", options: opts}
      assert {:error, :qualification_runner_context_rejected} = GenServer.call(control, {:event, event})
    end

    assert GenServer.call(control, :snapshot).sessions == 0
    refute Jason.encode!(GenServer.call(control, :snapshot).events) =~ "SECRET"
  end

  test "a later valid managed runner cannot erase rejection and a stale attempt is refused" do
    {config, context, issue} = managed_context()
    control = start_supervised!({Control, checks: ["final_absence"], session_limit: 3, config: config})
    :ok = GenServer.call(control, {:issues, [issue]})
    opts = [attempt: nil, execution_context: context, attempt_id: context.environment.record.attempt_id, backend_module: Codex]
    valid = %{event: :runner_invocation, issue_id: issue.id, options: opts}
    assert :ok = GenServer.call(control, {:event, valid})
    [invocation] = GenServer.call(control, :snapshot).events
    assert invocation.outcome == :accepted
    assert invocation.attempt_id == opts[:attempt_id]
    assert invocation.issue_id == issue.id
    refute Jason.encode!(invocation) =~ "SECRET"
    assert GenServer.call(control, :session)
    :ok = inventory(control, {:ok, %{records: [], live_worker_counts: %{}}})
    :ok = GenServer.call(control, {:check, "final_absence", %{status: :passed}})
    assert Control.qualified?(GenServer.call(control, :snapshot))

    stale = %{valid | options: Keyword.put(opts, :attempt_id, "old-attempt")}
    assert {:error, :qualification_runner_context_rejected} = GenServer.call(control, {:event, stale})
    assert :ok = GenServer.call(control, {:event, valid})
    :ok = inventory(control, {:ok, %{records: [], live_worker_counts: %{}}})
    :ok = GenServer.call(control, {:check, "final_absence", %{status: :passed}})
    state = GenServer.call(control, :snapshot)
    assert state.runner_rejected
    assert state.runner_invocations == 3
    refute Control.qualified?(state)
    refute Jason.encode!(state.events) =~ "SECRET"
  end

  test "negative control fingerprints survive interruption and legacy UID-only baselines fail closed" do
    control = start_supervised!({Control, checks: [], session_limit: 0})
    baseline = [%{path: "/v1/projects/p/locations/r/resources/unrelated", uid: "uid-1", fingerprint: String.duplicate("a", 64)}]
    :ok = GenServer.call(control, {:baseline, baseline})
    persisted = Jason.decode!(Jason.encode!(%{unrelated_baseline: GenServer.call(control, :snapshot).baseline}))
    :ok = GenServer.call(control, {:interrupted, persisted})
    assert Control.unrelated_unchanged?(GenServer.call(control, :snapshot), baseline)
    changed = Map.put(hd(baseline), :fingerprint, String.duplicate("b", 64))
    refute Control.unrelated_unchanged?(GenServer.call(control, :snapshot), [changed])

    legacy = [%{"path" => "/v1/projects/p/locations/r/resources/unrelated", "uid" => "uid-1"}]
    :ok = GenServer.call(control, {:interrupted, %{"unrelated_baseline" => legacy}})
    refute Control.unrelated_unchanged?(GenServer.call(control, :snapshot), baseline)
  end

  defp managed_context do
    config = %{
      kind: "google_workstations",
      deployment_id: "qualification",
      tracker_kind: "memory",
      workspace_root: "/workspaces",
      startup_timeout_ms: 60_000,
      shutdown_timeout_ms: 60_000,
      provider: %{
        "project" => "project",
        "location" => "region",
        "cluster" => "cluster",
        "config" => "config",
        "credential_configuration" => "/operator/SECRET",
        "ssh_user" => "worker",
        "impersonate_service_account" => "worker@example.test"
      }
    }

    issue = %Issue{id: "issue-1", identifier: "QUAL-1", state: "Qualification Codex"}
    attempt_id = Base.url_encode64(:binary.copy(<<255>>, 16), padding: false)
    key = ExecutionEnvironment.resource_key(config.deployment_id, config.tracker_kind, issue.id)

    record = %Record{
      key: key,
      deployment_id: config.deployment_id,
      tracker_kind: config.tracker_kind,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_state: issue.state,
      kind: config.kind,
      scope: EnvironmentConfig.scope(config),
      workspace_path: Path.join(config.workspace_root, key),
      template_identity: "template",
      phase: :running,
      attempt_id: attempt_id
    }

    target = %Target{executable: "/usr/bin/ssh", prefix: ["worker@SECRET"], env: [{"TOKEN", "SECRET"}], label: "worker"}
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, connection} = Operations.open_connection(supervisor, self(), target, [])
    {config, ExecutionContext.managed(config, record, connection), issue}
  end

  defp inventory(control, result), do: GenServer.call(control, {:event, %{event: :inventory_observation, result: result}})
end
