defmodule SymphonyElixir.EnvironmentLifecycleTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ExecutionEnvironment.{Lifecycle, Record}

  defp record do
    %Record{
      key: "se-ticket",
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "kubernetes",
      scope: %{},
      workspace_path: "/state/workspaces/se-ticket",
      template_identity: "template-v1"
    }
  end

  test "agent exit cannot release capacity until remote stop is proved" do
    record = record()
    entry = %{Lifecycle.new(record, "attempt-1", :agent) | phase: :running}
    {stopping, [{:provider, :stop, operation_id}]} = Lifecycle.step(entry, {:agent_exited, "attempt-1", :retry}, 1_000)
    assert Lifecycle.occupied?(stopping)
    unknown = %{record | phase: :unknown}
    {unresolved, effects} = Lifecycle.step(stopping, {:failed, operation_id, {:unknown, :timeout}, unknown}, 2_000)
    assert Lifecycle.occupied?(unresolved)
    refute Enum.any?(effects, &match?({:release, _}, &1))
    proof = %{record | phase: :stopped, pending: [], proof: {:quiescent, %{uid: "pod-1"}}}
    {stopped, [{:release, :retry}]} = Lifecycle.step(unresolved, {:stopped, operation_id, proof}, 3_000)
    refute Lifecycle.occupied?(stopped)
    assert {stopped, []} == Lifecycle.step(stopped, {:stopped, operation_id, proof}, 4_000)
  end

  test "cancel fences late prepare and stale agent completions" do
    {preparing, [{:provider, :prepare, old_id}]} = Lifecycle.step(Lifecycle.new(record(), "a", :agent), :prepare, 0)
    pending = %{preparing.record | pending: [%{verb: :start, id: "start-1", outcome: :unknown}]}
    {stopping, [{:provider, :stop, id}]} = Lifecycle.step(%{preparing | record: pending}, {:cancel, :cancelled}, 1)
    assert id == {"a", 2}
    assert stopping.record.pending == pending.pending
    assert {stopping, []} == Lifecycle.step(stopping, {:prepared, old_id, record()}, 2)
    assert {stopping, []} == Lifecycle.step(stopping, {:agent_exited, "old", :done}, 2)
    unsafe = %{pending | phase: :stopped, proof: {:quiescent, %{uid: "old"}}}
    {unresolved, []} = Lifecycle.step(stopping, {:stopped, id, unsafe}, 3)
    assert Lifecycle.occupied?(unresolved)
  end

  test "preparation requires matching ready result and launches once" do
    {entry, _} = Lifecycle.step(Lifecycle.new(record(), "a", :agent), :prepare, 0)
    assert {entry, []} == Lifecycle.step(entry, :launch, 1)
    ready = %{record() | phase: :running}
    {prepared, []} = Lifecycle.step(entry, {:prepared, entry.operation_id, ready}, 2)
    {running, [{:launch_agent, "a"}]} = Lifecycle.step(prepared, :launch, 3)
    assert {running, []} == Lifecycle.step(running, :launch, 4)
  end

  test "unknown disk deletion retains quiescence but outstanding start invalidates it" do
    proof = %{record() | phase: :stopped, proof: {:quiescent, %{uid: "pod"}}}
    entry = %{Lifecycle.new(proof, "a", :cleanup) | phase: :stopped}
    {deleting, [{:provider, :destroy, id}]} = Lifecycle.step(entry, :destroy, 0)
    unknown = %{proof | phase: :unknown, proof: :unknown, pending: [%{verb: :destroy, id: "disk", outcome: :unknown}]}
    {retained, []} = Lifecycle.step(deleting, {:failed, id, {:unknown, :timeout}, unknown}, 1)
    refute Lifecycle.occupied?(retained)
    assert retained.record.proof == proof.proof
    unsafe = %{unknown | pending: [%{verb: :start, id: "start", outcome: :unknown}]}
    {occupied, []} = Lifecycle.step(retained, {:failed, id, {:unknown, :timeout}, unsafe}, 2)
    assert Lifecycle.occupied?(occupied)
    refute occupied.record.proof == proof.proof
  end

  test "new physical obligations invalidate an older stop proof across repeated cleanup failures" do
    stopped = %{record() | phase: :stopped, proof: {:quiescent, %{uid: "earlier-worker"}}}
    {deleting, [{:provider, :destroy, id}]} = Lifecycle.step(%{Lifecycle.new(stopped, "a", :cleanup) | phase: :stopped}, :destroy, 0)
    unresolved = %{stopped | phase: :unknown, proof: {:compute_unknown, %{worker_uid: "late-worker"}}}
    {retained, []} = Lifecycle.step(deleting, {:failed, id, {:unknown, :physical_outcome}, unresolved}, 1)
    assert Lifecycle.occupied?(retained)
    assert retained.record.desired == :absent
    assert retained.record.proof == unresolved.proof
    disk_unknown = %{retained.record | proof: :unknown}
    {still_occupied, []} = Lifecycle.step(retained, {:failed, id, {:unknown, :disk_outcome}, disk_unknown}, 2)
    assert Lifecycle.occupied?(still_occupied)
    assert still_occupied.record.proof != stopped.proof
  end

  test "only confirmed complete absence forgets retained resources" do
    proof = %{record() | phase: :stopped, proof: {:quiescent, %{uid: "pod"}}}
    {entry, _} = Lifecycle.step(%{Lifecycle.new(proof, "a", :cleanup) | phase: :stopped}, :destroy, 0)
    assert {entry, []} == Lifecycle.step(entry, {:destroyed, entry.operation_id, proof}, 1)
    {_, [:forget]} = Lifecycle.step(entry, {:destroyed, entry.operation_id, %{proof | absent?: true}}, 2)
  end

  test "later authoritative absence supersedes unknown deletion with an outstanding start" do
    proof = %{record() | phase: :stopped, proof: {:quiescent, %{uid: "pod"}}}
    {deleting, [{:provider, :destroy, id}]} = Lifecycle.step(%{Lifecycle.new(proof, "a", :cleanup) | phase: :stopped}, :destroy, 0)
    late_start = %{proof | phase: :unknown, pending: [%{verb: :start, id: "late-start", outcome: :unknown}]}
    {unknown, []} = Lifecycle.step(deleting, {:failed, id, {:unknown, :timeout}, late_start}, 1)
    assert Lifecycle.occupied?(unknown)
    absent = %{late_start | absent?: true, pending: [], proof: :unknown}
    assert {unknown, []} == Lifecycle.step(unknown, {:destroyed, {"a", 99}, absent}, 2)
    {forgotten, [:forget]} = Lifecycle.step(unknown, {:destroyed, id, absent}, 3)
    refute Lifecycle.occupied?(forgotten)
    assert {forgotten, []} == Lifecycle.step(forgotten, {:destroyed, id, absent}, 4)
  end

  test "managed unknown hook exit preserves completion and context until provider stop" do
    context = %{connection: :existing_connection}
    record = %{record() | version: "latest"}
    entry = %{Lifecycle.new(record, "a", :agent) | phase: :running, context: context}
    completion = {:managed_execution_unknown, {:remote_command_timeout, :before_run, 1_000}}
    {stopping, [{:provider, :stop, id}]} = Lifecycle.step(entry, {:agent_exited, "a", completion}, 0)
    assert stopping.context == context
    assert stopping.record == record
    assert stopping.completion == completion
    {unknown, []} = Lifecycle.step(stopping, {:failed, id, {:unknown, :timeout}, record}, 1)
    assert unknown.context == context
    assert Lifecycle.occupied?(unknown)
  end

  test "unknown execution with an unresolved stop cannot borrow old quiescence" do
    record = %{record() | proof: {:quiescent, %{uid: "old"}}, pending: [%{verb: :stop, id: "stop", outcome: :unknown}]}
    entry = %{Lifecycle.new(record, "a", :agent) | phase: :unknown}
    assert Lifecycle.occupied?(entry)
  end

  test "late stop cannot forget unresolved deletion and later absence remains authoritative" do
    proof = %{record() | phase: :stopped, proof: {:quiescent, %{workers: []}}}
    stopped = %{Lifecycle.new(proof, "a", :cleanup) | phase: :stopped}
    {deleting, [{:provider, :destroy, id}]} = Lifecycle.step(stopped, :destroy, 0)
    pending = %{proof | pending: [%{verb: :destroy, id: "disk", outcome: :unknown}]}
    {unknown, []} = Lifecycle.step(deleting, {:failed, id, {:unknown, :timeout}, pending}, 1)
    assert {unknown, []} == Lifecycle.step(unknown, {:stopped, id, proof}, 2)
    assert {unknown, []} == Lifecycle.step(unknown, {:destroyed, id, %{pending | absent?: true}}, 3)
    {absent, [:forget]} = Lifecycle.step(unknown, {:destroyed, id, %{proof | absent?: true}}, 4)
    refute Lifecycle.occupied?(absent)
  end

  test "repeated stop failure does not borrow a previous proof or invent deletion intent" do
    entry = Lifecycle.new(record(), "a", :cleanup)
    {stopping, [{:provider, :stop, id}]} = Lifecycle.step(entry, {:cancel, :denied}, 0)
    {unknown, []} = Lifecycle.step(stopping, {:failed, id, {:unknown, :timeout}, record()}, 1)
    {still_unknown, []} = Lifecycle.step(unknown, {:failed, id, {:denied, :permission}, record()}, 2)
    assert Lifecycle.occupied?(still_unknown)
    proof = %{record() | phase: :stopped, proof: {:quiescent, %{workers: []}}}
    {released, [{:release, :denied}]} = Lifecycle.step(still_unknown, {:stopped, id, proof}, 3)
    refute Lifecycle.occupied?(released)
  end

  test "retention uses saved UTC terminal stamp and fresh authoritative observation" do
    record = %{record() | terminal_observed_at: 1_000}
    refute Lifecycle.deletion_due?(record, :terminal, 500, 1_499)
    assert Lifecycle.deletion_due?(record, :terminal, 500, 1_500)

    for observation <- [:missing, :error, :nonterminal] do
      refute Lifecycle.deletion_due?(record, observation, 500, 5_000)
    end

    refute Lifecycle.deletion_due?(%{record | terminal_observed_at: nil}, :terminal, 0, 5_000)
  end
end
