defmodule SymphonyElixir.OperatorDeclaredLostProofTest do
  @moduledoc """
  `{:operator_declared_lost, _}` is an operator assertion, not an observation. These cases pin
  the properties that keep the two distinguishable, and pin the one thing the Gate 2 design
  must not quietly acquire: a route to being forgotten that skips an unresolved create.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionEnvironment.{Lifecycle, Record, Workstations}

  @declared {:operator_declared_lost, %{node_uid: "node-1", machine_id: "m1"}}

  defp record(overrides \\ %{}) do
    Map.merge(
      %Record{
        key: "se-ticket",
        deployment_id: "deployment",
        tracker_kind: "memory",
        issue_id: "ticket",
        kind: "kubernetes",
        scope: %{},
        workspace_path: "/state/workspaces/se-ticket",
        template_identity: "template-v1"
      },
      overrides
    )
  end

  defp destroying(proof) do
    entry = %{Lifecycle.new(record(%{phase: :stopped, proof: proof}), "a", :cleanup) | phase: :stopped}
    {deleting, [{:provider, :destroy, id}]} = Lifecycle.step(entry, :destroy, 0)
    {deleting, id}
  end

  test "a declaration is not quiescence and is not promoted into it" do
    {deleting, id} = destroying(@declared)
    unknown = record(%{phase: :unknown, proof: :unknown, pending: [%{verb: :destroy, id: "disk", outcome: :unknown}]})
    {retained, []} = Lifecycle.step(deleting, {:failed, id, {:unknown, :timeout}, unknown}, 1)

    refute match?({:quiescent, _}, retained.record.proof)
  end

  test "an unresolved start does not erase a declaration" do
    # invalidate_start_proof/1 rewrites proof to :unknown when a start is unresolved, but
    # passes {:compute_unknown, _} through. A declaration must pass through too, or the record
    # of the operator's assertion is silently destroyed by an unrelated pending start.
    {deleting, id} = destroying(@declared)
    late_start = record(%{phase: :unknown, proof: @declared, pending: [%{verb: :start, id: "late", outcome: :unknown}]})
    {retained, []} = Lifecycle.step(deleting, {:failed, id, {:unknown, :timeout}, late_start}, 1)

    assert retained.record.proof == @declared
    assert Lifecycle.occupied?(retained)
  end

  test "a declared-lost record is not forgotten while a create is unresolved" do
    # The invariant revisions 1 and 2 of the Gate 2 spec tried to amend. It stays.
    {deleting, id} = destroying(@declared)

    unresolved_create =
      record(%{absent?: true, proof: @declared, pending: [%{verb: :create, id: "c1", outcome: :unknown}]})

    {retained, emitted} = Lifecycle.step(deleting, {:destroyed, id, unresolved_create}, 1)

    refute :forget in emitted
    assert Lifecycle.occupied?(retained)
  end

  test "a declared-lost record is forgotten once every operation is resolved" do
    {deleting, id} = destroying(@declared)
    resolved = record(%{absent?: true, proof: @declared, pending: [%{verb: :create, id: "c1", outcome: :succeeded}]})

    {_entry, emitted} = Lifecycle.step(deleting, {:destroyed, id, resolved}, 1)

    assert :forget in emitted
  end

  test "Workstations rejects the Kubernetes-only declaration variant" do
    # The proof type is shared across adapters. A declaration reaching Workstations is a
    # programming error and must fail loudly rather than fall through as "not quiescent".
    declared = record(%{kind: "google_workstations", proof: @declared})

    # inspect/3 returns the 3-tuple result() shape, carrying the record alongside the failure.
    assert {:error, {:invalid, :workstations_proof_unsupported}, %Record{}} = Workstations.inspect(%{}, declared, [])
  end
end
