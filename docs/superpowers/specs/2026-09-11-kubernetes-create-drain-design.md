# Kubernetes create-drain and cleanup ownership

Date: 2026-09-11
Status: implementation authorized; independent specification review passed; production allocation blocked

## Decision and approval boundary

Use a durable per-Sandbox create-intent journal with irreversible closure. Unknown outcomes retain ownership, potentially indefinitely. The user explicitly approved that safety/availability trade-off after the upstream source audit. This is a proposed cross-project protocol, not implemented Kubernetes support or an approved controller release.

The production allocation stop introduced by Symphony commit `3687a178283550db4f3361bd7c6da996553bd8bc` remains unconditional throughout design and implementation. Neither this document, a controller patch, a passing model, nor a qualification ConfigMap lifts it. A later explicitly approved source/image/schema baseline and failure-case evidence are required before live worker qualification; allocation enablement requires successful full-system qualification and a separate reviewed change.

Administrative access and funding are settled, not blockers. The remaining technical gates are ordering, a suitable isolated target, and end-to-end safety evidence. The migration target places both Symphony and its workers in Kubernetes. The existing VM must remain operational during migration; this work does not deploy to, stop, or transfer ownership from that VM.

## Scope and alternatives

The protocol covers every controller-issued Pod, PVC and Service create, and every Symphony-issued Sandbox and Secret create, including replacements and sends originating before cleanup. It handles lost responses, delayed commits, reconciliation retries and controller replacement without claiming exactly-once delivery or guaranteed eventual cleanup. Controller attempts live on the parent; Symphony attempts live in a retained provider guard that exists before the parent.

Chosen: a write-ahead journal, single-attempt issuance, and positive outcome evidence. Alternative: a storage-integrated commit-time fence that atomically rejects stale creates after closure. That alternative could resolve more ambiguity but requires a different API-server/storage contract and is not approved here. A controller mutex, leader lease, admission-time read, fixed grace period or fork by itself is not a substitute for either protocol.

Not in scope: automatically releasing ambiguous operations by timeout; retroactively certifying old Sandboxes; transparent failover from the VM; operator force-finalization; broad controller refactoring; changing local, static SSH or Workstations behavior. Fork versus upstream contribution is a delivery decision, not a proof of ordering.

## Existing sources and integration boundary

The immutable audited Agent Sandbox baseline is `3e77ccbac4db8a12b0157eafcad0d1ad5872f32a`:

- [controllers/sandbox_controller.go](https://github.com/kubernetes-sigs/agent-sandbox/blob/3e77ccbac4db8a12b0157eafcad0d1ad5872f32a/controllers/sandbox_controller.go): PVC, Pod and Service creation; adoption; suspension; expiry; deletion and status updates.
- [api/v1beta1/sandbox_types.go](https://github.com/kubernetes-sigs/agent-sandbox/blob/3e77ccbac4db8a12b0157eafcad0d1ad5872f32a/api/v1beta1/sandbox_types.go): current types lack a durable journal and acknowledgement.
- [k8s/crds/agents.x-k8s.io_sandboxes.yaml](https://github.com/kubernetes-sigs/agent-sandbox/blob/3e77ccbac4db8a12b0157eafcad0d1ad5872f32a/k8s/crds/agents.x-k8s.io_sandboxes.yaml): current structural schema. Generated Helm and OLM distribution schemas must change with the source types.
- [cmd/agent-sandbox-controller/main.go](https://github.com/kubernetes-sigs/agent-sandbox/blob/3e77ccbac4db8a12b0157eafcad0d1ad5872f32a/cmd/agent-sandbox-controller/main.go): cached client and transport construction.
- [client-go rest/request.go](https://github.com/kubernetes/client-go/blob/4e24acf5e20d3be54d345c5f747261e650ea9edf/rest/request.go) and [rest/with_retry.go](https://github.com/kubernetes/client-go/blob/4e24acf5e20d3be54d345c5f747261e650ea9edf/rest/with_retry.go): POST can be retried on response-driven Retry-After paths. One `Create` invocation is not one network attempt.
- [controller-runtime typed client](https://github.com/kubernetes-sigs/controller-runtime/blob/3be3f1bf2b2fcc6b5c9510d55c6a9972294653d0/pkg/client/typed_client.go): ordinary typed Create does not disable those retries.
- [Go HTTP client](https://github.com/golang/go/blob/a9ce111d580581fb925ae88f125c69b7d93504ea/src/net/http/client.go) and [x/net HTTP/2 transport](https://github.com/golang/net/blob/acc78e0d2b2c855c0c4fbdcfe5f42a9e3d0f9778/http2/transport_common.go): redirects and transport retries are additional proof obligations. HTTP/2 retry eligibility is not itself evidence of duplicate commits.

Symphony integration is confined to the existing execution-environment boundary:

- `elixir/lib/symphony_elixir/execution_environment/kubernetes.ex`: `preflight/2`, `destroy/3`, private `destroy_stopped/4`, qualification, storage evidence and persisted ownership.
- `elixir/lib/symphony_elixir/execution_environment/operations.ex`: ordinary discovery calls adapter preflight. No provider-specific scheduler branch is needed.
- `elixir/test/symphony_elixir/kubernetes_environment_test.exs` and `elixir/test/symphony_elixir/managed_orchestrator_test.exs`: provider and ownership/capacity behavioral regressions.
- `elixir/test/support/managed_environment_fixture/provider.exs` and `elixir/test/symphony_elixir/managed_environment_provider_fixture_test.exs`: qualification retains the production stop until its own explicit release gate.
- `SPEC.md`, root `README.md`, `elixir/README.md` and, if configuration contracts change, `elixir/WORKFLOW.md`: update alongside the implementation; this proposed design does not replace the current implemented contract.

The current cleanup path deletes the parent under Symphony's finalizer, deletes children, then deliberately returns ordering-unproven. The new path must move irreversible close and create-drain proof ahead of final cleanup, not merely replace that final error with success. The existing early already-absent path must also require durable completion evidence for the original parent UID; parent absence alone cannot bypass the new barrier.

## Authority and trust boundary

The journal lives on the same Sandbox object as the close request and controller status. Kubernetes UID and resourceVersion CAS serialize transitions. A separate intent CRD appended after an independent open check is prohibited: those operations would not be atomic with closure. Resource versions are opaque equality tokens, never integer counters.

The protocol version is `symphony-create-drain-v1`. A managed parent is created with the protocol request and Symphony cleanup finalizer already present. Before any child create, the qualified controller initializes the UID-bound journal by CAS. Missing, invalid, unsupported or legacy journal state means no create and no acknowledgement. The parent finalizer and journal remain until Symphony proves complete cleanup.

Only the qualified controller may write journal outcomes and acknowledgement status. Symphony may request closure and manage its ownership/finalizer fields, not manufacture controller evidence. Workers cannot write Sandbox objects, status, finalizers, or reserved child attribution. RBAC, admission policy and namespace isolation must enforce this separation; cooperative labels alone are insufficient. Cluster administrators and corruption/rollback of the authoritative Kubernetes store are outside the protocol's trusted-control-plane model, not events it silently tolerates.

Protected attribution is supplied by each object's issuer at original creation: the controller for Pods/PVCs/Services, Symphony for Sandbox parents/Secrets. It is never copied from workload templates or added during adoption. In this managed profile, adoption of unjournaled preexisting objects is forbidden. A conflicting or spoofed object produces an ownership conflict and retains the journal/guard. Non-protocol controller binaries must not operate in this qualified scope.

## Durable data model and invariants

The following names define the proposed semantic schema, not fields already available upstream:

| Field | Owner and meaning |
| --- | --- |
| `spec.creationControl.protocol` | Immutable protocol request, exactly `symphony-create-drain-v1`. |
| `spec.creationControl.closeRequestId` | Symphony-generated unique cleanup request ID; absent while open, set once and never replaced or removed. |
| `status.creationJournal.parentUID` | Exact Sandbox UID; immutable after initialization. |
| `status.creationJournal.revision` | Monotonic journal transition counter maintained by CAS, independent of resourceVersion. |
| `status.creationJournal.phase` | `Open`, `Closed`, or `Drained`; only forward transitions. |
| `status.creationJournal.operations` | Append-only uniquely keyed issued operations; membership freezes once close is requested. |
| `status.creationJournal.acknowledgement` | Present only in `Drained`; exact protocol, parent UID, close request ID, final journal revision and operation count. |

Each operation contains a globally unique attempt ID, issuing process-incarnation ID, exact group/resource/namespace/name, parent UID, and state `Issued` or `Committed`. `Committed` additionally records the authoritative child UID. Attempt attribution on the child includes protocol, parent UID and attempt ID. Child identity fields and attribution are immutable within an operation; a replacement is a new operation. No user-supplied attempt IDs are accepted.

Decision: v1 deliberately has no generic `Failed` or `NotSent` terminal state. Any result without positive matching child-commit evidence stays `Issued`, including definite-looking HTTP rejection, timeout and ambiguous journal-write completion. This sacrifices availability to avoid conflating a client error with an authoritative operation-resolution guarantee. Pre-send validation happens before journal issuance; failures there produce no operation and no request.

Required invariants:

1. Every commit-capable child create has an earlier durable issued operation on this exact parent UID.
2. An issued operation can authorize at most one commit-capable transmission. Journal presence is not replay permission.
3. Issuance CAS requires no close request and phase `Open` in the same object revision. Once the close request is accepted, no new issuance can commit.
4. Existing issued operations may still send or commit after closure; closure alone is not a drained acknowledgement.
5. Only positive, uniquely attributed commit evidence can settle an issued operation. GET 404, empty lists, cancellation, elapsed time or leadership change cannot.
6. Outcomes, close identity and membership are never erased or reopened by reconcile, expiry, status replacement, recovery or a stale write.
7. `Drained` is published atomically with the final complete journal state. All operations are `Committed`, and no new operation can be appended.
8. Drain proof establishes no future controller child-create commits for that UID. It does not establish physical termination, child absence or backing-storage deletion.

Schema transition validation must reject mutation/removal of protected immutable data and backward transitions, including writes through the status subresource. Every controller writer must still use UID/resourceVersion-checked updates: schema checks are defense in depth, not issuance fencing. Status merges without optimistic locking and conditions-only status replacement must be migrated. Admission enforcement protects writer identity where field-level RBAC cannot.

Journal size is bounded by an explicit serialized-size limit selected below the qualified API object's limit, with reserved space for all outstanding outcomes and the final acknowledgement. Exceeding available issuance capacity fails closed before another operation is appended or sent. Entries are not compacted or pruned during the parent's lifetime. If externally enlarged state makes even close/settlement impossible, retain ownership and report unknown; never truncate evidence to recover availability. The chosen limits form part of the reviewed schema baseline.

## Issuance and transport

1. Read the parent authoritatively, not from the informer cache. Validate protocol, finalizer, parent UID, absence of close request and open journal.
2. Validate and freeze the intended child payload and its reserved attribution before issuance. For a resource/name with an unresolved issued operation, do not issue another operation. A committed child may be replaced only after its exact UID is authoritatively absent and the parent remains open.
3. Append `Issued` by CAS. Only the still-running call whose issuance CAS returned authoritative success may send. If the CAS response is lost, recovery may find the entry but must not send it; the operation stays unknown. A delayed issuance CAS ordered after close fails its resourceVersion precondition.
4. Perform at most one child POST for that operation. A controller replacement or another reconcile only observes/settles it, never acquires a right to resend. There is no transferable execution lease.
5. Record matching positive commit evidence by fresh-read CAS. A concurrent close or unrelated status update requires re-reading and preserving all newer state before retrying the outcome write; it never repeats the child POST.

Use a dedicated, audited create transport, not the normal replay-capable controller-runtime Create client. The approved baseline must use direct authenticated TLS to the API-server endpoint over HTTP/1.1, with redirects and HTTP/2 disabled, no connection reuse, no replayable `GetBody`, no idempotency headers, and no application/client-go/auth-wrapper retry of POST. The exact Go/SDK configuration and any unavoidable endpoint intermediary must be examined and tested for at-most-one commit-capable transmission. An unverified retrying proxy makes the profile unqualified. Disabling `MaxRetries` alone or counting only outer RoundTrip calls is insufficient.

Read, CAS-update and UID-preconditioned delete retries are separate from the create transport and retain bounded operation deadlines. A deadline stops waiting; it cannot settle a create. No reconnect, 429/5xx response, redirect, authentication refresh or process restart may turn an existing issued operation into another create send. If a transport safety assumption cannot be established, implementation remains gated rather than falling back to the stock client.

A decoded successful Create response is positive evidence only if its resource identity, parent ownership, protected attempt attribution and nonempty child UID exactly match the issued operation. An authoritative GET/list observation with the same checks is also positive evidence. Positive evidence can be durably recorded after closure and by a replacement controller. Any mismatch is unknown/conflict, not evidence for a similarly named operation. A successful-looking response without verifiable identity is not enough.

Decision: Symphony uses the same qualified single-attempt transport for all POSTs, through a small `symphony-kubernetes-create` executable built from the controller source. It accepts explicit kubeconfig/context, API collection path, private JSON file and bounded timeout; it emits the server JSON response and never retries a POST. Missing helper, unsupported authentication/transport wrapper, proxy or malformed response fails closed; there is no `kubectl create --raw` fallback. The helper binary/source and its supported authentication modes join the approved baseline.

Before sending a Sandbox or Secret POST, Symphony CAS-appends a uniquely attributed `Issued` operation to its durable guard. Only the invocation whose append returned success can send. Lost append responses, lost POST responses and restart never authorize resend. Positive matching response/inventory evidence can settle the operation to `Committed` with its exact object UID. Secret operations bind the parent UID; the Sandbox operation binds the preexisting guard UID and environment identity, then binds its observed parent UID once. Cleanup first closes Symphony issuance by guard CAS, resolves all its issued attempts, then closes and drains the controller journal. Both journals must be drained before final cleanup. A terminal guard never reopens for another environment incarnation.

Provider attribution is explicit: every Sandbox POST body carries immutable annotations `symphony.dev/create-protocol=symphony-create-drain-v1`, `symphony.dev/create-guard-uid` and `symphony.dev/create-attempt-id`, supplied by Symphony. Every Secret POST carries those fields plus `symphony.dev/create-parent-uid` equal to its exact Sandbox owner UID. Admission authorizes only Symphony to set these keys at original creation and rejects copying, removal or mutation by other writers; templates cannot supply them. A recovered response/object settles an operation only if protocol, guard UID, attempt ID, resource, namespace, name and applicable parent UID all match the recorded attempt before its observed object UID is bound. A same-name object with missing or different attribution is a conflict, never evidence. Multiple attempts cannot settle against another attempt's object.

## Close and acknowledgement protocol

Symphony first closes its provider guard to new issuance by CAS, persists `desired: absent`, cleanup request identity and existing termination/storage evidence, and resolves all earlier Symphony-issued attempts. It then sets the same close request ID on the exact live Sandbox using resourceVersion/UID CAS, preserving the finalizer. Lost close-write responses are resolved by reading the same UID and request ID; retries never generate a new ID.

The close request is the issuance fence. Controller phase may temporarily remain `Open` while the spec already closes issuance; every create issuer checks both in its issuance CAS. The controller changes phase to `Closed`, preserves all earlier operations, and resolves them only through the positive-evidence rules. An already-issued sender paused before its POST remains outstanding until it commits and is observed; closing does not revoke a request that may already exist.

When closed with no unresolved operations, the controller CAS-writes `Drained` and an acknowledgement bound to protocol, parent UID, close request ID, the resulting journal revision and operation count. Zero operations are a valid drained journal only for a protocol-enabled parent initialized before any create. No operations or acknowledgement fields change after `Drained`; unrelated conditions may change without altering the journal revision. The journal and acknowledgement survive controller restarts, deletionTimestamp and expiration.

Symphony obtains this status from an authoritative API read and validates the full envelope against its persisted ownership and cleanup request. It checks the journal's phase, revision, operation count, unique membership and that every operation is committed to an exact child UID. Unknown version, missing fields, mismatched UID/request, regressed or contradictory journal, stale acknowledgement, API error or missing parent without prior completion evidence means unknown. It persists accepted drain evidence with the owned record before proceeding.

The acknowledgement's authority is the qualified controller and protected Kubernetes object, not a self-reported annotation or cryptographic signature. Qualification must prove those writer/transport assumptions for the actual deployed image and target. Symphony does not infer support from a release string alone.

## Final cleanup and ownership release

Close and obtain create-drain proof before deleting the parent or destroying remaining children. Suspension is reversible and does not close PVC or Service creation; it is not this barrier. Existing safe stop operations may occur earlier, but their proof must be reconciled against the completed journal before release because earlier creates can commit after the initial stop snapshot.

After drain, perform a fresh inventory that accounts for all committed child UIDs, every existing owned child, all authorized Pod UIDs and recorded PVC/PV identities. The journal becomes an authoritative list of controller-created child identities, not a replacement for inventory. A committed PVC that vanished before its PV identity/evidence was captured is an unresolved storage obligation, not permission to treat an empty inventory as clean. Likewise, a missing previously authorized Pod requires the existing qualified physical-termination evidence; API object absence alone is insufficient.

Every committed Pod UID, including one Symphony never authorized, requires durable physical-safety classification before release. A live authoritative Pod can be classified `never_executable` only after validating the required scheduling gate, empty nodeName and qualified admission/writer restrictions; removal of that gate by Symphony first records execution authorization durably. Authorized Pods require the existing qualified termination evidence. A committed Pod that vanished before classification stays unresolved indefinitely. Controller `Committed` evidence alone does not classify physical safety; admission stripping the gate or any unsafe admitted property prevents a never-executable proof.

Capture and persist storage evidence before destructive cleanup. Delete children and parent only with exact UID preconditions; never delete a namesake replacement. Preserve Symphony's finalizer and discoverable ownership throughout child deletion and CSI deletion evidence collection. Symphony-created Secrets are covered by the provider guard's issuance journal, not by the controller journal.

Release requires the conjunction of both drained issuance journals, accepted controller acknowledgement, durable physical-safety classification for every committed Pod UID, qualified physical quiescence for every execution-authorized Pod, no remaining owned children, and qualified CSI backing-deletion evidence for every storage obligation. Any mismatch or missing evidence retains the finalizer, ownership and unknown state. Operator-facing diagnostics identify unresolved attempt/child UIDs and evidence class, not secret payloads.

Decision: the current annotation-based owner record disappears with the parent. Add a provider-owned guard/cleanup receipt as a namespaced ConfigMap before any Sandbox POST. Its deterministic name binds deployment and environment identity, not the as-yet-unknown parent UID; it has no ownerReference and is never deleted, including after completion. This retained anchor prevents bootstrap recursion: delayed bootstrap POSTs collide with the same permanently retained name and cannot replace or reopen the guard. No Sandbox POST is authorized before the guard's exact identity and initial state are observed. Failure to establish the guard means no resource allocation.

The ConfigMap stores versioned `symphony-create-drain-v1` data containing immutable deployment/environment identity, guard UID binding, monotonic phase, attempt list, nullable parent UID before its committed create, nullable close request before closure, existing serialized owner record, drain evidence and physical/storage obligations. Missing/unknown version or malformed state blocks discovery and reuse. Each attempt has unique ID, resource/namespace/name, guard UID, parent UID where applicable, `Issued`/`Committed` state and a committed object UID. No credentials or payloads are stored. Only Symphony may mutate the guard, using UID/resourceVersion CAS; workload identities cannot delete it or alter its protected fields.

The guard progresses monotonically from `Open` to `Closing` to `ReadyToFinalize` to `Complete`. Issuance append and `Open → Closing` serialize on the same guard revision. `ReadyToFinalize` contains all durable proofs required by the release conjunction, written before finalizer removal. A lost guard-create response succeeds only after an authoritative read matches the complete initial payload and immutable identity. A lost update response succeeds only when a read confirms the intended target state and complete expected proof payload; identity alone is insufficient. Prior state means retry the same transition through fresh CAS, divergent content means unknown. Immediately before finalizer removal, read back and validate `ReadyToFinalize`; remove using a fresh parent CAS bound to its UID, the same close request and unchanged drained journal. Mark and authoritatively confirm `Complete` only after proving that exact parent UID absent. A same-name different UID is an ownership conflict, never a deletion target. Cleanup success requires durable `Complete`.

Discovery must inventory receipts as well as parents and children, merge by exact ownership and parent UID, and reject contradictory copies instead of letting iteration order overwrite evidence. A `Closing` receipt with a missing parent stays unknown. `ReadyToFinalize` plus exact parent absence permits finishing the receipt after a crash; absence without that durable evidence does not. A `Complete` receipt certifies only the old parent UID, never a new environment incarnation. Completed receipts are retained as nonblocking tombstones; automatic receipt deletion/compaction is outside this change. Existing generic inventory/foreign-resource checks must recognize these receipts rather than classifying them as leaked worker resources.

The retained guard fences Symphony-issued creates; the Sandbox close CAS separately fences controller-issued creates. Neither substitutes for the other. Unexpected guard disappearance is a qualification/writer-policy violation and blocks all allocation and cleanup; never recreate a missing guard for a discovered existing parent or child. Missing or inconsistent evidence retains discoverable ownership and blocks identity reuse. Completed guards cannot be reused to authorize a new parent; a new explicit environment incarnation needs a new identity, while the prior tombstone remains.

Retain cleanup ownership independently of scheduler compute capacity. Existing rules may release a compute slot only when physical quiescence is proven; unresolved create-drain or storage cleanup cannot release the environment identity. The provider continues returning the existing unknown/error result shapes rather than leaking controller-specific policy into the scheduler.

## Failure-case proof obligations

These are acceptance scenarios, not claims that tests or experiments have run. Use the real supported API server and exact qualified transport with deterministic fault injection and a replacement controller. Fake clients and state models may supplement but cannot establish actual network/persistence semantics. Test fixtures must exercise the production controller and Symphony adapter paths; they may not bypass the allocation stop in an ordinary workflow.

| Scenario | Required observable result |
| --- | --- |
| Zero creates; close repeated or response lost | One stable cleanup request; exact empty journal can drain; no issuance after close. |
| Issuance CAS races close in either order | Close-first rejects issuance; issuance-first remains a required member until committed. |
| Issuance response lost, including commit delayed until after close attempt | No send based on recovery alone; CAS serialization preserves any winning issued member. |
| Crash after issuance before send | Replacement never replays; no acknowledgement, even after long waits and absent-child reads. |
| POST paused before server commit; close and controller replacement | No drain while unresolved; late child belongs to the original attempt and must be accounted for. |
| Commit succeeds, response lost | Exact positive child observation settles without a second POST. |
| Child disappears before outcome persistence | Unresolved operation retains ownership unless positive evidence was durably retained; absence never settles. |
| 429/5xx plus Retry-After; redirects; connection failures; auth refresh | No hidden second commit-capable create transmission; ambiguous or rejected attempts stay issued. |
| Pod, PVC and Service partial progress | Every issued kind remains in the same closure boundary; later kinds cannot bypass close. |
| Duplicate/stale reconcilers; old issuer resumes after replacement | At most one send per issued attempt; no replay authorization from leadership or journal read. |
| Same name, different UID or forged attribution; attempted adoption | No false settlement, no deletion of unrelated UID, no acknowledgement based on copied metadata. |
| Parent expiry/deletion/status update races close/settlement | Journal survives; close never reopens; no conditions-only reset or stale merge erases evidence. |
| Stale acknowledgement, replaced parent, changed cleanup ID or protocol | Symphony retains ownership and rejects proof. |
| Full journal or API object-size boundary | No new send without durable capacity; evidence is never pruned to admit work. |
| Drain followed by late physical/container or CSI completion | Finalizer/identity retained until independent evidence satisfies all obligations. |
| Missing PVC before PV capture; API disappearance without termination evidence | Unknown storage/compute obligation remains, even with a valid drain acknowledgement. |
| Symphony crashes around close, evidence persistence or finalizer removal | Restart cannot release identity based only on absence; durable evidence binds exact UID/request. |
| Receipt create/update response lost; crash after parent deletion | Recover exact receipt identity; require durable `ReadyToFinalize` proofs before marking `Complete`; never rely on a vanished parent annotation. |
| Delayed Sandbox/Secret POST after close or final inventory | Provider guard retains the issued attempt; no replay and no finalization until exact positive commit evidence and resulting resource cleanup. |
| Committed Pod vanishes unclassified or admission strips its gate | No never-executable inference; physical-safety obligation remains unknown. |
| Lost ReadyToFinalize/Complete update returns unchanged receipt | Same identity is insufficient; require target state plus exact proofs before progressing. |
| Non-protocol binary, legacy parent or baseline mismatch | Production preflight stays blocked; no retroactive qualification or journal initialization over prior creates. |

The key safety counterexample to defeat is: observe child A, settle its operation, delete A, then a delayed replay creates child B. The transport evidence must exclude that second commit-capable transmission; a passing journal state-machine test alone does not.

## Delivery, baseline and qualification gates

1. Review and approve this written contract, then produce the implementation plan. No controller source/image/schema baseline changes at this stage.
2. Implement and review the upstream journal, protected transitions and dedicated transport in an isolated controller development checkout. Keep all published Symphony production allocation paths stopped. A source patch is not baseline approval.
3. Implement Symphony's acknowledgement consumer and recovery path behind the still-unconditional production stop. Update affected contract docs and behavioral tests. Exercise it through controlled test infrastructure, not a live-worker bypass flag.
4. Produce fault-injection evidence against the actual proposed controller/API-server/transport artifacts. Record unresolved cases as expected retention, never classify them as successful cleanup. Prove the stock replay counterexample is excluded and that physically delayed cleanup retains ownership.
5. Present an immutable candidate baseline for explicit approval: controller source commit, built image digest and provenance, generated CRD/schema hashes, guard schema, protocol version/limits, single-attempt helper binary/source, Go/SDK/transport/authentication configuration, supported API-server endpoint topology, writer-protection policy and linked failure-case evidence. Identify fork versus upstream delivery without relaxing any requirement. Do not populate this baseline with guessed future hashes.
6. Verify an isolated target with no legacy controller or unjournaled parent in scope. Approve and apply the reviewed baseline only there. A mixed-version rollout in an active ownership scope is prohibited; quiesce and prove existing ownership resolved, or use a fresh scope while retaining unresolved old ownership.
7. Only then perform approved live worker qualification of isolation, complete Linux/Docker workloads, stop/termination, storage deletion, recovery and the controller acknowledgement end to end. Qualify Symphony running in Kubernetes as well as its workers. Keep the VM operational and prevent concurrent orchestration of the same ticket scope.
8. Review the full evidence before a separate change lifts production allocation for that exact qualified baseline. Baseline mismatch always fails closed. Migration/cutover requires its own operational approval; rollback returns to the stopped profile without abandoning owned Kubernetes resources or disrupting the VM.

The controller source, schema and consumer form one protocol change, even if delivered in separate repositories. Upstream changes must cover every create, adoption, expiry, deletion and status-write path in the pinned controller source. Newly introduced child-create paths must use the same issuance boundary or invalidate qualification.

## Review and validation status

The architectural direction and indefinite-retention trade-off are approved, and the user has explicitly requested implementation. Candidate artifacts and operational baseline remain unapproved. Source audit and specification review are design evidence only; no real API-server fault-injection experiment or live worker qualification is claimed by this document.

Inline self-review verified local references and added durable post-parent recovery. The initial independent Codex review timed out at 120 seconds, and its fresh retry timed out at 600 seconds. Resuming the latter session produced one CRITICAL and two IMPORTANT findings: uncovered Symphony-issued POSTs, missing-Pod safety classification and insufficient lost-receipt-update postconditions. The revision added the retained pre-parent guard, shared single-attempt transport and explicit proof rules. A second review required explicit provider-object attribution; that correction was independently verified in iteration 3, which returned PASS with zero findings. These reviews authorize implementation planning, not qualification or deployment.
