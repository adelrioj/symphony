# Discharging the physical obligations of a permanently lost host

Date: 2026-09-18 (revision 3)
Status: proposed; implementation NOT authorized
Supersedes revisions 1 and 2. Code citations verified against `c198317`.

## Delivery step 0 — restore the scope citation

**No design approval or implementation authorization may occur until this is complete.**

Revisions 1 and 2 cited `node-fault-20260916T142903Z/execution-status.json` for the claim
that "Permanent host or disk loss recovery" is outside the node-fault qualification. That
path does not exist in this repository, in `trazadera-infra`, or in the history of either —
checked directly. The scope boundary this document exists to close is therefore currently
uncitable.

Either commit the artifact to a stable path, or name an immutable external location with a
revision or content hash. Revision 2 listed this last in the delivery order while also making
it a precondition of approval; since implementation is unauthorized until approval, those two
could not both hold. It is step 0.

## What changed in revision 3, and why

Revision 1 let an operator declaration settle unresolved creates. Revision 2 replaced that
with an admission-time "issuance fence". **Both were wrong, and revision 3 abandons the goal
rather than attempting a third mechanism.**

Revision 2's fence is invalid against this repository's own specification. `SPEC.md:2959`:

> Admission protects original attribution and the separate provider/controller writers; it
> **MUST NOT be treated as a commit-time fence.**

A ValidatingAdmissionPolicy runs at admission, not at storage commit. A create can pass
admission while the guard is open, stall before persistence, the closing CAS can commit, and
the create can then commit after it. Admission and a ConfigMap CAS are not one transaction.

A second defect is independent of the first: even a perfect fence would not help, because an
object can commit *before* closure and be deleted before the post-fence read. Absence now
does not prove a create never committed — an absent Pod may have executed, an absent PVC may
have provisioned backing storage.

**Conclusion: an unresolved create cannot be settled after host loss, by any authority or any
fence this system can build.** Only positive commit evidence settles it, and after a host is
lost that evidence may never have existed. Revision 3 therefore does not try.

## Scope

### In scope

Discharge of **physical obligations** — owned compute UIDs and owned volume identities —
whose host binding was durably captured before loss, for a host an operator declares
permanently lost and the adapter verifies is gone.

### Explicitly not in scope, and permanently retained

**Unresolved creates are not settled by this design.** They remain retained indefinitely,
exactly as `symphony-create-drain-v1` already requires. This is not a deferral; it is the
accepted trade-off create-drain was approved on, and nothing here revisits it.

**The consequence, stated so it is not discovered later:** an environment that had an
unresolved create at the moment its host died **stays retained forever**. Its guard ConfigMap
is never deleted and its identity is never reused. This design discharges the case where
every create was already resolved and only physical obligations remain. It does not close
every case, and it must not be described as though it does.

Also out of scope: automatic detection of loss; recovering lost data; any declaration naming
a host still observable; wildcard or deployment-wide declarations; and lifting the production
allocation stop. `Kubernetes.preflight/2` continues to return
`kubernetes_controller_cleanup_ordering_unproven`.

## Prerequisite: durable host binding

### What exists

Nothing. There is no server number, machine-id, or host binding anywhere in `elixir/lib`;
`Record` carries no host field. `kubernetes_candidate_evidence.exs:9` lists `node_uid` and
`node_name` in a serializer allowlist, but **no production code produces either field** — it
is an allowlist anticipating data that is not yet captured, not a partial binding.

### Why this is capturable before execution

Revision 2 claimed capture "at allocation time and before any execution" without checking
whether that point exists. Two facts, both verified, make a realizable version of it:

1. **The target node is known at creation.** The SandboxTemplate pins
   `nodeSelector: {kubernetes.io/hostname: <node>}`. The worker is not freely scheduled; its
   node is chosen by configuration before the object is created.
2. **Host identity is an API read, not a host read.** The Kubernetes `Node` object carries
   `status.nodeInfo.machineID`, `.systemUUID`, `.bootID`, and `metadata.uid`. No
   `/etc/machine-id` read and no host access is required. Confirmed against the live node:
   `machineID 91d53397210e4abeae824abe6c6032a7`, `systemUUID ef04afce-…`, `bootID c31c5615-…`,
   `metadata.uid 3e485bce-…`.

### What to capture, and from where

| Field | Authoritative source | When |
|---|---|---|
| `node_name` | template `nodeSelector["kubernetes.io/hostname"]` | creation |
| `node_uid` | `Node.metadata.uid` | creation |
| `machine_id` | `Node.status.nodeInfo.machineID` | creation |
| `system_uuid` | `Node.status.nodeInfo.systemUUID` | creation |
| `boot_id` | `Node.status.nodeInfo.bootID` | creation, refreshed on observation |

Captured into **adapter-owned durable state** — never `Record.metadata`, which the `Record`
contract states is not evidence. Each read records the `resourceVersion` it was taken at. A
binding that cannot be established is a hard allocation failure: an environment allocated
without one can never be declared lost.

**Server number is not a verification predicate.** It is a Hetzner Robot concept with no
Kubernetes source. If recorded it is operator-supplied audit metadata only, and no check may
depend on it. Revisions 1 and 2 asserted the "audited fault drivers" pair it with machine-id;
those drivers are not in this repository and that claim was never verified here.

### Volume identity needs no pre-capture

`WaitForFirstConsumer` (confirmed on `symphony-state-qual9-3071011`) means no PV exists until
scheduling, so revision 2's demand to capture topology before execution was unsatisfiable.

It is also unnecessary. **PV objects are cluster-scoped and survive the host.** After loss,
the PVC → PV → `spec.csi.volumeHandle` → `spec.nodeAffinity` chain is still readable from the
API server. Volume identity is therefore *verified at declaration time from the API*, not
captured in advance. A snapshot may be recorded opportunistically for tamper-evidence, but no
check may depend on its presence.

`boot_id` changes on reboot, so it proves a specific boot, not the machine; `machine_id` plus
`system_uuid` plus `node_uid` identify the machine. A `boot_id` mismatch alone is not loss.

## The declaration

### Resource contract

A CustomResourceDefinition, namespace-scoped, co-resident with the retained guard — guards
outlive the host and are never deleted, which makes the namespace the correct anchor.

- **GVK:** `symphony.dev/v1alpha1`, `Kind: HostLossDeclaration`, plural
  `hostlossdeclarations`.
- **Status subresource enabled**, so spec and status have separate RBAC.
- **Deterministic name:** a lowercase hex digest over
  `(deployment_id, node_uid, sorted environment keys)`, truncated to 63 characters. A replay
  produces the same object rather than a second declaration; a name collision with a
  different spec is rejected as a conflict.
- **Bounds:** at most 64 environment keys and 512 obligation UIDs per declaration; each
  string at most 253 characters. A larger loss is expressed as several declarations.

**Immutable after admission** (enforced by admission policy): schema version, `deploymentId`,
host identity block, `environmentKeys`, per-environment obligation UIDs, guard UID and
`resourceVersion` references, `operatorSubject`.

**Adapter-owned status:** per-obligation disposition, per-environment state, aggregate
outcome, the observations each predicate was decided on with their `resourceVersion`s, and
admission timestamp.

### Authorization

Namespace residency does not distinguish an operator from a workload, a controller, or a
compromised ServiceAccount. Without this section any namespace writer could manufacture a
declaration and discharge real obligations.

Pinned in the qualified baseline, not left to configuration drift:

- an **operator group** name and an **adapter ServiceAccount** username, both pinned;
- admission requires `spec.operatorSubject == request.userInfo.username` **and** the pinned
  group present in `request.userInfo.groups`, so the recorded subject is the authenticated
  one rather than a self-asserted string;
- only the adapter ServiceAccount may write `status`; only the operator group may create;
- workloads and controllers are denied create/update/delete;
- accepted and refused declarations are undeletable under normal operation.

The five existing `symphony-create-drain-*` policies are **not in this repository**. They
come from the candidate controller checkout as `k8s/symphony-create-drain-policy.yaml`
(`elixir/README.md:639`), installed separately. This design's policies must be delivered the
same way and pinned by the same baseline, and the reference must name the controller
repository and commit.

### Verification

Predicates, each with a named authoritative query and an exact success response:

| Predicate | Query | Authoritative true |
|---|---|---|
| Node absent | `GET /api/v1/nodes/<name>` | `404` |
| Node identity matches | — | if the Node exists at all, the declaration is **refused** |
| Volume cannot reappear | `GET` PV by UID; `GET` PVC | PV `404` **or** PV present with `deletionTimestamp` and no CSI finalizer |
| Ownership | guard record at the pinned UID/`resourceVersion` | every named key owned by this deployment and bound to this node |

Every other response — timeout, `403`, `429`, `5xx`, malformed body, inconsistent inventory —
is **unavailable**, never false. "Unresolvable" is not used as a predicate; it has no testable
meaning.

### Three outcomes, and how they compose

Per obligation: `discharged`, `refused`, or `unavailable`.

Aggregate precedence, applied in order: **any `refused` ⇒ declaration `refused`**; else any
`unavailable` ⇒ `unresolved`; else `accepted`.

- **`refused`** is terminal and recorded permanently. Not retried into success. An operator
  asserting loss of a live host is a mistake worth failing on.
- **`unresolved`** is the only retryable outcome, and retry re-reads every predicate rather
  than resuming from a partial result.
- Discharge is **atomic per environment**, not per declaration: an environment whose
  obligations are all `discharged` is finalized even if a sibling environment is
  `unavailable`. Finalization is applied by CAS against the guard `resourceVersion` recorded
  in the spec, so a crash mid-application is safely re-applied and never double-applied.

### Proof variant

`proof` gains one variant at `execution_environment.ex:65`:

```elixir
proof :: :unknown | {:quiescent, term()} | {:compute_unknown, map()} | {:operator_declared_lost, map()}
```

- `quiescent?/1` (`lifecycle.ex:149`) is **false** for it. It is not quiescence.
- `qualified_stopped_record?/1` (`orchestrator.ex:2128`) is **false** for it. A lost host did
  not stop cleanly.
- `Operations.reached?/2` (`operations.ex:537`) is **unchanged**. Because unresolved creates
  are not settled, a record still only reaches `:absent` when its pending operations are
  genuinely resolved. This design adds no escape from that rule.

**Integration surface.** Revision 1 claimed five branch sites and omitted the Workstations
adapter, which shares the type and branches at `workstations.ex:127`, `:342` and `:630`.
Sites: `Lifecycle.quiescent?/1` and `invalidate_start_proof/1`; `Operations.reached?/2`;
`Orchestrator.qualified_stopped_record?/1`; the `@type`; and the three Workstations branches,
which MUST reject the variant rather than ignore it.

### Adapter entry point

The `ExecutionEnvironment` behaviour (`execution_environment.ex:92-101`) has ten callbacks
and none administrative, and ordinary discovery is blocked by the deliberately failing
`preflight/2`. A new callback is required:

```elixir
@callback declare_lost(map(), HostLossDeclaration.t(), keyword()) :: {:ok, [Record.t()]} | {:error, failure()}
```

It MUST remain callable while allocation preflight fails; MUST NOT invoke allocation or be a
path to lifting the stop; MUST be replay-safe under the deterministic name; and returns
updated records to the orchestrator through the same path a discovery result takes.

### Finalization is irreversible; contradiction is an alarm

Revision 1 claimed a reappearing host invalidates the declaration "exactly as
`invalidate_start_proof/1` already does". It does not: `lifecycle.ex:153-154` only replaces
`proof` with `:unknown` where an unresolved start remains, and passes `{:compute_unknown, _}`
through untouched. It restores no settled outcome.

Finalization is therefore **irreversible**, and reappearance raises an alarm rather than
silently reverting — by then the identity may have been reused.

**Owner:** the Kubernetes adapter is a set of invoked functions, not a resident controller, so
"a standing check" has no home today. The check belongs to a named durable reconciler with:
a startup scan over accepted declarations; a list/watch with defined resync and watch-recovery;
a durable alarm sink with a defined payload and deduplication key; and an explicit monitoring
lifetime. If that reconciler is not built, this section is unimplemented and the design is not
complete — it must not be left implicit.

## Delivery order

0. Restore the scope citation. Nothing proceeds without it.
1. Durable host binding capture from the `Node` object.
2. Declaration CRD, RBAC and admission policies, pinned in the qualified baseline.
3. `declare_lost/4`, the proof variant, and the Workstations rejections.
4. The contradiction reconciler.

Design only. No implementation is authorized. This does not approve a baseline, qualify
infrastructure, enable allocation, or lift the production stop.

## Review status

Revision 1: 3 CRITICAL / 7 IMPORTANT. Revision 2: 4 CRITICAL / 10 IMPORTANT, including the
invalidation of its own central mechanism against `SPEC.md:2959`. Revision 3 narrows the goal
to what can actually be proved and has not yet been re-reviewed.
