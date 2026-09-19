# Discharging the physical obligations of a permanently lost host

Date: 2026-09-19 (revision 4)
Status: proposed; implementation partially landed (see Delivery)
Supersedes revisions 1–3. Code citations verified against `8660c44`.

## Delivery step 0 — restore the scope citation

**No approval or further implementation authorization until this is complete.**

Revisions 1–3 cited `node-fault-20260916T142903Z/execution-status.json` for the claim that
"Permanent host or disk loss recovery" is outside the node-fault qualification. That path does
not exist in this repository, in `trazadera-infra`, or in the history of either. Commit the
artifact to a stable path, or name an immutable external location with a revision or content
hash. Until then the boundary is uncitable and the authoritative statement is the Gate 2
section of `trazadera-infra/docs/symphony-production-gates.md`.

## The decision this revision asks for

Revisions 1 and 2 each invented a mechanism to settle unresolved creates and each was refused:
operator authority cannot settle a request the API server already holds, and an admission-time
fence is forbidden outright by `SPEC.md:2959` ("Admission … MUST NOT be treated as a
commit-time fence"). Revision 3 stopped trying, and that scope decision survived review.

Revision 3 then hit the wall this revision exists to break. `SPEC.md:2946-2950`:

> Bound-volume cleanup requires a complete exact-UID PV `DELETED` watch event matching the
> captured claim UID, CSI driver and volume handle, with CSI deletion protection observed
> before deletion. … Mere PVC/PV absence, lost watch history, or removing finalizers to force
> progress MUST NOT substitute for that evidence.

For a permanently lost host that event **can never arrive** — the node's CSI driver died with
the machine. The rule is unsatisfiable in exactly the case Gate 2 exists to handle, so Gate 2
cannot close without amending it.

### The amendment

Add one narrow exception, and nothing wider:

> For a host-local volume whose node has been declared permanently lost under an accepted
> `HostLossDeclaration`, an **immutable provider-side destruction receipt**, keyed by the
> machine identity recorded in that declaration and naming the exact CSI volume handle, MAY
> substitute for the exact-UID PV `DELETED` watch event. Absence of the PV, lost watch
> history, and finalizer removal remain forbidden as substitutes, with or without a
> declaration.

What makes this narrow rather than a loophole: it does not weaken the rule for any volume on a
live node; it requires *positive* evidence rather than accepting absence; and the evidence is
issued by the infrastructure provider, not by the operator asserting the loss. The declaration
establishes *which* machine; the receipt establishes that *that machine's disk is gone*.

**If this amendment is refused, Gate 2 has no solution** and a permanently lost host strands
its records indefinitely. That is a coherent position — it is Option 3 from the gates document
— and it should be recorded as a decision rather than left as a gap.

## Scope

**In scope:** discharge of physical obligations — owned compute UIDs and owned volume
identities — whose host binding was captured before loss, for a host an operator declares lost
and the adapter verifies is gone.

**Explicitly retained, permanently:** unresolved creates. They remain retained exactly as
`symphony-create-drain-v1` requires. An environment holding an unresolved create when its host
died **stays retained forever**; this design discharges only environments whose creates were
all resolved. It does not close every case and must not be described as though it does.

**Out of scope:** automatic loss detection; recovering lost data; declaring a host still
observable; wildcard or deployment-wide declarations.

## Eligibility, and proving the declaration is complete

A declaration names its own obligations, so nothing in revisions 1–3 prevented an operator
omitting one, or declaring an environment whose guard still held an `Issued` operation.
`Operations.reached?/2` does not read the guard's journals. Two predicates close that:

1. **Resolved-creates predicate.** Every provider guard operation committed and every
   controller journal operation resolved. An environment with any `Issued` or `:unknown`
   operation is **ineligible** — refused, not merely undischarged.
2. **Exact-cover predicate.** The declared obligation set must **equal** the frozen guard and
   controller inventories for that environment: every authorized Pod UID and every captured
   volume identity appears exactly once, with no extras. Set equality, not containment.

Both are computed by the adapter from the guard, never taken from the declaration.

## Prerequisite: durable host binding

### Where the node actually comes from

Revision 3 said the node is known at creation because the SandboxTemplate pins
`nodeSelector`. That is half the story, and the missing half was found on 2026-09-19:
**`RuntimeClass.scheduling` carries both the nodeSelector and the toleration**, and Kubernetes
merges them into the pod. The SandboxTemplate has no tolerations and the controller strips
rather than injects them. `kata-qemu` today reads:

```
nodeSelector: {kubernetes.io/hostname: symphony-lab-kvm-3071011,
               symphony.trazadera.net/qualification-victim: "true"}
tolerations:  [{key: symphony.trazadera.net/qualification-victim, …, effect: NoSchedule}]
```

So node placement is determined by the RuntimeClass *and* the template together, and either
can change it. Both must be pinned.

**Qualification invariant:** an exact singleton `kubernetes.io/hostname` selector, validated in
preflight, across the template and the RuntimeClass. Before releasing the Pod scheduling gate
(`kubernetes.ex:1594-1600`), verify `Pod.spec.nodeName` equals the pinned host; a mismatch is a
hard failure, not a warning.

### What to capture, and where it lives

A versioned `hostBinding` section in a **protected top-level field of the existing guard** —
not `Record.metadata`, which the `Record` contract states is not evidence, and not a new object
that could drift from the guard it describes. Adding a guard field changes an
admission-validated schema; the policy lives in the controller checkout
(`~/development/trazadera/agent-sandbox-symphony`, `k8s/`) and must be updated in the same
change.

| Field | Authoritative source |
|---|---|
| `node_name` | pinned singleton selector, cross-checked against `Pod.spec.nodeName` |
| `node_uid` | `Node.metadata.uid` |
| `machine_id` | `Node.status.nodeInfo.machineID` |
| `system_uuid` | `Node.status.nodeInfo.systemUUID` |
| `boot_id` | `Node.status.nodeInfo.bootID` |

All are API reads — no host access, no `/etc/machine-id`. Each records the `resourceVersion` it
was read at. A binding that cannot be established is a hard allocation failure.

`boot_id` identifies a boot, not a machine; `machine_id` + `system_uuid` + `node_uid` identify
the machine. A `boot_id` change alone is a reboot, not loss.

**Server number is not a predicate.** It has no Kubernetes source. If recorded it is
operator-supplied audit metadata, and no check may depend on it.

### Volume identity is read, not pre-captured

`WaitForFirstConsumer` means no PV exists until scheduling, so pre-capture is impossible. It is
also unnecessary: PV objects are cluster-scoped and survive the host, so after loss the
PVC → PV → `spec.csi.volumeHandle` → `spec.nodeAffinity` chain is still readable. Look up by
**PV name** (the adapter stores `pv_name` and `pv_uid`) and require the expected UID, CSI
driver, volume handle, claim UID and node affinity to match.

## The declaration

### Resource contract

CRD, namespace-scoped, co-resident with the retained guard.

- **GVK:** `symphony.dev/v1alpha1`, `Kind: HostLossDeclaration`, plural `hostlossdeclarations`.
  Status subresource enabled, so `spec` and `status` carry separate RBAC.
- **Deterministic name:** lowercase hex digest over `(deployment_id, node_uid, sorted
  environment keys, chunk_index)`, truncated to 63 characters. A replay is the same object; a
  name collision with a different canonical spec digest is rejected as a conflict.
- **Bounds and chunking.** At most 64 environment keys and 512 obligation UIDs per
  declaration. Because a single environment can exceed 512 obligations and cannot be split
  across declarations, enforce a per-environment maximum **at allocation** and prove it, or
  carry `chunk_index` / `chunk_total` in the name and require a coordinator that verifies
  every chunk is accepted before any is applied. Pick one; do not leave it implied.
- **Immutable after admission:** schema version, `deploymentId`, host identity, environment
  keys, obligation UIDs, guard UID and `resourceVersion` references, `operatorSubject`,
  chunk fields.
- **Adapter-owned status:** per-obligation disposition, per-environment state, aggregate
  outcome, the observations each predicate was decided on with their `resourceVersion`s.

Full `spec`/`status` JSON schemas — exact field names, types, required/nullable rules, set
semantics, enum values, cross-field constraints — are part of delivery step 2 and must be
written before implementation, not discovered during it.

### Authorization

Namespace residency does not distinguish an operator from a workload or a compromised
ServiceAccount. Pinned in the qualified baseline:

- a named **operator group** and a named **adapter ServiceAccount**, both pinned rather than
  configured;
- admission requires `spec.operatorSubject == request.userInfo.username` **and** the pinned
  group present in `request.userInfo.groups`, so the recorded subject is the authenticated
  one;
- only the adapter ServiceAccount writes `status`; only the operator group creates;
- workloads and controllers denied create/update/delete;
- accepted and refused declarations undeletable under normal operation.

Delivered as RBAC plus a ValidatingAdmissionPolicy in the controller checkout's `k8s/`,
alongside the create-drain policies, and pinned by the same baseline.

### Verification

| Predicate | Query | Authoritative true |
|---|---|---|
| Host destroyed | provider destruction receipt, keyed by machine identity | receipt present, immutable, names this machine |
| Node absent | `GET /api/v1/nodes/<name>` | `404` |
| Node identity | — | if the Node exists, **refused** |
| Volume irrecoverable | `GET` PV **by name**, require expected UID/driver/handle/claim/affinity | destruction receipt names this volume handle |
| Eligibility | guard + controller journals | resolved-creates and exact-cover predicates both hold |

**Node `404` is necessary, never sufficient.** A Node object disappears for reasons that are
not loss — the 2026-09-18 reclamation showed exactly that. The provider destruction receipt is
what carries the weight; the declaration says which machine, the receipt says it is gone.

Every other response — timeout, `403`, `429`, `5xx`, malformed body, inconsistent inventory —
is **unavailable**, never false.

### Outcomes and composition

Per obligation: `discharged`, `refused`, `unavailable`. Aggregate precedence, in order: any
`refused` ⇒ `refused`; else any `unavailable` ⇒ `unresolved`; else `accepted`.

`refused` is terminal and permanent. `unresolved` is the only retryable outcome and retry
re-reads every predicate rather than resuming a partial result.

Discharge is **atomic per environment**. Finalization uses the guard UID and
`resourceVersion` from the spec **to validate the initial snapshot only**; the transition then
persists the declaration UID and canonical spec digest into the guard, and on recovery the
reconciler reads the guard's *current* `resourceVersion` and matches on that digest. Matching
on the recorded `resourceVersion` at apply time would make replay impossible after any
intervening write.

### Proof variant — landed

`{:operator_declared_lost, map()}` is implemented and merged (`adelrioj/symphony#34`).
`execution_environment.ex:65` carries the variant; `quiescent?/1` and
`qualified_stopped_record?/1` are false for it; `invalidate_start_proof/1` passes it through;
Workstations rejects it at `identity/2`.

`lifecycle.ex` gated deletion on `quiescent?/1` alone, so the variant was inert. That gate now
admits two distinct grounds — observed quiescence, or a declaration — with `not unresolved?/1`
preserved on both, so an unresolved create still blocks release. Five regression cases pin it.

**The release path is NOT complete, and #34 overclaimed that it was.** One layer below the
lifecycle gate, `destroy_stopped/6` still requires quiescence:

```elixir
with true <- match?({:quiescent, _}, stopped.proof),   # kubernetes.ex:605
...
else
  false -> {:error, {:unknown, :kubernetes_cleanup_pending}, stopped}
```

So a declaration now *enters* deletion through the lifecycle and is then rejected by the
Kubernetes adapter as `:kubernetes_cleanup_pending`, indefinitely. The five regression cases
cover the generic lifecycle and the Workstations rejection; none exercises Kubernetes
destruction, which is why this was not caught.

This is not a gate to loosen in isolation. `destroy_stopped/6` proceeds to delete children and
storage, and for a lost host those objects are unreachable — which is precisely the physical
discharge that requires the destruction receipt and the verification predicates below. The
Kubernetes release path must be built **with** that verification, not ahead of it, and
`declare_lost/3` is where it belongs.

### Adapter entry point and the component that drives it

```elixir
@callback declare_lost(map(), HostLossDeclaration.t(), keyword()) :: {:ok, [Record.t()]} | {:error, failure()}
```

Arity 3, matching the behaviour's other callbacks (`execution_environment.ex:92-101`).
Callable while allocation preflight fails; never invokes allocation; replay-safe under the
deterministic name.

**Nothing today would call it.** The adapter is a set of invoked functions, not a resident
controller. A named declaration reconciler owns both driving admissions and the standing
contradiction check, with: a startup list, a watch with defined resync and `410 Gone`
recovery, per-operation deadlines, a durable alarm sink with a schema and deduplication key,
and an explicit monitoring lifetime. Until that process exists with those properties, the
design is not complete.

### Finalization is irreversible; contradiction is an alarm

`invalidate_start_proof/1` does not restore settled outcomes (`lifecycle.ex:164-167`), so
"contradiction reverts the declaration" was never implementable. Finalization is irreversible
and reappearance raises an alarm — by then the identity may have been reused. The reconciler
above owns that check.

## Required characterization matrix

Implementation must be accompanied by cases for, at least: an unresolved `Issued` operation;
an omitted obligation; a duplicated obligation; a live host whose Node object is absent; node
name reuse; PV `404`; lost watch history; a destruction receipt naming a different machine; a
declaration replayed after an intervening guard write; and partial chunk acceptance.

## Delivery

| Step | State |
|---|---|
| 0. Restore the scope citation | **blocking, not done** |
| — `SPEC.md` volume amendment | **decision required** |
| 1. Host binding capture + pinned placement invariant | not done; needs the controller `k8s/` policy |
| 2. CRD, schemas, RBAC, admission policies | not done |
| 3a. Proof variant + lifecycle gate | **done** (`#34`) |
| 3b. Kubernetes release path | **not done** — `destroy_stopped/6` still requires quiescence |
| 4. `declare_lost/3` + declaration reconciler | not done |

## Review status

Revision 1: 3 CRITICAL / 7 IMPORTANT. Revision 2: 4/10, its central mechanism invalid against
`SPEC.md:2959`. Revision 3: 4/10, blocked on `SPEC.md:2946-2950`. Revision 4 proposes the
amendment that unblocks it and has not yet been re-reviewed.
