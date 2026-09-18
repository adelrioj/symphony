# Operator loss declaration for permanently lost hosts

Date: 2026-09-18
Status: proposed; implementation NOT authorized; independent specification review not yet run

## Decision and approval boundary

Give an operator a scoped, audited, adapter-verified way to assert that a worker host is
permanently lost, so the obligations that host carried can be discharged. Nothing else in the
system may infer that assertion.

This is the case `2026-09-11-kubernetes-create-drain-design.md` deliberately excluded: its
*Not in scope* list names **operator force-finalization**. Create-drain chose to retain
unknown outcomes indefinitely rather than release them, and the user approved that
safety/availability trade-off. This document does not revisit that choice. It specifies the
single, explicit exception, and only for the case create-drain cannot resolve by
construction: the evidence needed to settle an operation no longer exists anywhere.

`node-fault-20260916T142903Z/execution-status.json` lists **"Permanent host or disk loss
recovery"** under `outside_this_qualification`. This closes that item's design, not its
qualification.

The production allocation stop is untouched. `Kubernetes.preflight/2` continues to return
`kubernetes_controller_cleanup_ordering_unproven`; this document does not lift it, and a
declaration must never be a path to lifting it.

## Scope and alternatives

In scope: a declaration naming one host and the explicit environment keys it carried;
adapter-side verification of that declaration; and discharge of the physical and storage
obligations resident on that host, including settling the pending operations stranded by its
loss.

Chosen: an operator-authored declaration object, adapter-verified, recorded against the
retained guard. Alternatives considered and rejected:

- **Provider-authoritative absence** — treat a Robot cancellation or a `Node` object deletion
  as proof. Rejected: on 2026-09-18 node `symphony-qual5-3076400` was reclaimed and its
  `Node` object disappeared while the machine itself had already been reassigned to another
  tenant. Disappearance is a *consequence* of loss, observable in cases that are not loss.
  It is a necessary precondition, never sufficient evidence.
- **Timeout-based release.** Rejected for the same reason create-drain rejected it: no
  elapsed time settles an issued create.
- **Do nothing.** Viable only while deployments are disposable. It stops being viable the
  moment workers carry production tickets, because one dead host strands its records forever.

Not in scope: automatic detection of loss; retroactive certification; recovering the lost
data; any declaration that names a host still observable; wildcard or deployment-wide
declarations; and lifting the production allocation stop.

## Existing sources and integration boundary

Worker state is a node-local TopoLVM volume, so loss of its contents is inherent and
accepted. The gap is bookkeeping, and it is currently total: `kubernetes.ex:185` marks such a
record

```elixir
{:ok, %{saved | metadata: Map.put(saved.metadata, "orphaned", true), proof: :unknown, phase: :unknown}}
```

and `orphaned` routes to `{:error, {:unknown, :retained_kubernetes_parent_missing}}` at
`kubernetes.ex:300`. There is no force, override or manual acknowledgement anywhere in the
tree. `orphaned` is a flag, not a resolution — which is itself instructive, because it lives
in `metadata`, and the `Record` contract states that agent-writable metadata is not evidence.

Outside the Kubernetes adapter, exactly five sites branch on `proof`:
`Lifecycle.quiescent?/1`, `Lifecycle.invalidate_start_proof/1`, `Operations.reached?/2`,
`Orchestrator.qualified_stopped_record?/1`, and the `@type` in `execution_environment.ex`.
The integration surface is therefore small; the semantics are not.

## Authority and trust boundary

The declaration is operator authority, not observation, and the design must keep those
distinguishable forever.

- It MUST NOT be carried in `Record.metadata`. The contract says metadata is not evidence,
  and `orphaned` already demonstrates what happens to a resolution recorded there.
- It MUST NOT reuse `{:quiescent, _}`. A declaration is a different kind of truth from
  something an adapter saw. It takes its own variant, `{:operator_declared_lost, evidence}`,
  so every later reader can tell them apart and no declaration can be mistaken for an
  observation.
- It MUST be admitted through the adapter, so that "only adapters establish proof" continues
  to hold literally.
- It MUST identify the host as the audited fault drivers already do — **server number and
  machine-id together** — and name the environment keys it discharges explicitly.

The declaration object is namespace-resident, alongside the retained guard. The guard
ConfigMaps live in the Kubernetes namespace rather than on the worker, so they survive the
host and are never deleted by design; this makes them the correct anchor and keeps the audit
trail in the one place that outlives the loss.

## Durable data model and invariants

`proof` gains one variant:

```elixir
proof :: :unknown | {:quiescent, term()} | {:compute_unknown, map()} | {:operator_declared_lost, map()}
```

Invariants, all of which an implementation must preserve:

1. `quiescent?/1` is **false** for a declaration. It is not quiescence.
2. `qualified_stopped_record?/1` is **false** for a declaration. A lost host did not stop
   cleanly; it ceased to exist.
3. A declaration is scoped. It may settle only operations whose owning resources were
   resident on the declared host, and only those named by the declaration.
4. A declaration is not retroactive cover. It cannot settle an operation issued after the
   declaration was admitted.
5. Contradiction wins. If the declared host or any of its volumes becomes observable again,
   the declaration is invalidated and the affected records return to unresolved, exactly as
   `invalidate_start_proof/1` already does for `{:compute_unknown, _}`.

## The invariant this change amends, and why it needs review

This is the substance of the document, and the reason it is a specification change rather
than a patch.

```elixir
defp reached?(%Record{absent?: true, pending: pending}, :absent),
  do: not Enum.any?(pending, &(&1.outcome in [:pending, :unknown]))
```

`absent?: true` alone never reaches `:absent`; every pending operation must be settled. A
permanently lost host is exactly the case that strands creates at `outcome: :unknown`, and
the `Record` contract states plainly that **a missing resource cannot clear an unresolved
create.**

A loss declaration therefore becomes the only mechanism in the system permitted to settle an
unresolved create on human authority rather than observation. That is not an additional code
path beside the invariant; it is an amendment to it, and it is the same invariant
`symphony-create-drain-v1` exists to protect.

Reviewers should treat the following as the questions to answer, not as settled:

- Should a declaration settle stranded operations to a distinct outcome — `:declared_lost`
  rather than `:failed` or `:succeeded` — so that `reached?/2` can admit it without ever
  claiming the operation resolved?
- Does admitting a declaration require the guard to be closed first, or does it close it?
- What prevents a declaration from being the easy path around a merely *inconvenient*
  unresolved create on a host that is only unreachable?

## Failure-case proof obligations

Before honouring a declaration the adapter MUST establish, and record:

- the `Node` object for the declared host is absent;
- the volumes bound to it are unresolvable;
- the declaration's server number and machine-id match the identity recorded for the
  environments it names;
- every environment key it names is owned by this deployment and resident on that host.

A declaration failing any check is refused and recorded as refused. Refusal is not an error
to be retried into success.

## Delivery and qualification gates

Design only. No implementation is authorized by this document. It does not approve a
controller baseline, qualify infrastructure, enable allocation or lift the production stop.

Sequencing: independent specification review (`/spec-review-codex`; Codex quota returns
2026-09-22), then a plan, then implementation with regression cases for each invariant above.
Create-drain required three review iterations before any code was written; the semantics of
"when may an unresolved create be cleared" deserve at least the same.

## Review and validation status

Independent review: **not yet run.** No implementation exists. The integration surface was
verified against the tree at `f82dbc7`; the `reached?/2`, `orphaned` and `Record` contract
citations above were read from that revision.
