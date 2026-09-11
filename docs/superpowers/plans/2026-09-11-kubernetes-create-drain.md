# Kubernetes Create-Drain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement authoritative create-drain and recoverable cleanup across Agent Sandbox and Symphony without enabling production Kubernetes allocation.

**Architecture:** The controller journals Pod/PVC/Service issuance on the Sandbox and closes it by CAS. Symphony journals its parent/Secret issuance in a never-deleted pre-parent ConfigMap guard, consumes the controller acknowledgement, and retains independent physical/storage obligations until complete. Both issuers share an audited create-once Go transport; namespace-scoped admission policies protect attribution and writer ownership.

**Tech Stack:** Agent Sandbox at `3e77ccbac4db8a12b0157eafcad0d1ad5872f32a`, Go 1.26.4, controller-runtime v0.24.1, Kubernetes client-go v0.36.4; Symphony Elixir/OTP via mise.

**Spec:** `docs/superpowers/specs/2026-09-11-kubernetes-create-drain-design.md` (independent review iteration 3: PASS).

**Status:** Implemented and verified. Controller source `c30daee2b555a49cf4776863b1f12f41c0346a21`; Symphony implementation `0556e98`. Symphony `make all`: 905 tests, zero failures, 13 skipped, 100% configured coverage, clean lint/Dialyzer. Controller root-module race suite and isolated API-server tests passed; real Elixir-to-helper TLS smoke confirmed one POST per call. Both final independent re-reviews have no remaining findings. These are candidate source artifacts, not approved deployment/image pins or production qualification.

## Global Constraints

- Protocol is exactly `symphony-create-drain-v1`.
- Unknown outcomes retain ownership, potentially indefinitely; no timeout, negative lookup or process replacement settles an issued POST.
- Keep production `Kubernetes.preflight/2` returning `kubernetes_controller_cleanup_ordering_unproven`; do not change approved source/image/schema pins or add a bypass.
- No cluster deployment, live worker qualification, VM interruption, baseline approval or allocation enablement in this implementation run.
- Main owns integration, validation, generation and commits. Concurrent workers skip formatters, linters, builds and tests; they write regression cases and implement only their owned slice. Main runs the initial observable RED cases and final checks. No nested subagents.
- Controller checkout: `/Users/adelrioj/development/agent-sandbox-symphony`, branch `symphony-create-drain`. Symphony checkout: `/Users/adelrioj/development/symphony/.worktrees/symphony/remote-ticket-environments`.
- No Go or Elixir language server is configured; references must be mapped with repository searches and compiler checks.
- Public Elixir functions in lib require adjacent specs. Existing provider result/error shapes and provider-independent scheduler policy remain.

## Shared wire and source interfaces

Controller API structs use these exact JSON keys:

```json
{
  "spec": {"creationControl": {"protocol": "symphony-create-drain-v1", "closeRequestId": "cleanup-id"}},
  "status": {"creationJournal": {
    "parentUID": "sandbox-uid", "phase": "Drained", "revision": 4,
    "operations": [{"id":"attempt-id","issuerId":"process-id","group":"","resource":"pods","namespace":"test","name":"ticket","parentUID":"sandbox-uid","state":"Committed","objectUID":"pod-uid"}],
    "acknowledgement": {"protocol":"symphony-create-drain-v1","parentUID":"sandbox-uid","closeRequestId":"cleanup-id","revision":4,"operationCount":1}
  }}
}
```

`closeRequestId` absent before close; `acknowledgement` absent before Drained; `objectUID` absent while Issued. Operations serialize as an array including empty `[]`; identifiers never empty. Controller operation group is empty for the three core resources. Controller creation annotations: `agents.x-k8s.io/create-protocol`, `agents.x-k8s.io/create-parent-uid`, `agents.x-k8s.io/create-attempt-id`.

Provider object annotations: `symphony.dev/create-protocol`, `symphony.dev/create-guard-uid`, `symphony.dev/create-attempt-id`, plus `symphony.dev/create-parent-uid` on Secrets. All identity/evidence matching is exact; never settle by name alone.

Shared transport package, owned by Task 2:

```go
package createonce
func New(config *rest.Config) (*Client, error)
func (c *Client) Create(ctx context.Context, object client.Object) error
func (c *Client) Post(ctx context.Context, path string, body []byte) (int, []byte, error)
```

`Create` supports Pod/PVC/Service, fills the successful response into the passed object, and validates a nonempty UID and object identity. The journal additionally authenticates attribution. `Post` returns original status/body, including API errors; transport errors remain errors. The helper invokes `Post` once, with flags `--kubeconfig`, `--context`, `--path`, `--file`, `--timeout-ms`. It writes server JSON to stdout; transport/configuration diagnostics go to stderr with nonzero exit. No secret contents in diagnostics.

Task 1 adds `SandboxReconciler.APIReader client.Reader`, `CreateOnce interface { Create(context.Context, client.Object) error }`, and `CreationIssuerID string`. Manager wiring supplies `mgr.GetAPIReader()`, `createonce.New(restConfig)` and one random process ID. Missing dependencies fail closed for protocol-enabled parents, never use the cached/create-retrying client as fallback. Existing non-protocol upstream workloads retain their old behavior.

## Task 1: Controller journal, closure and schema

**Files:** Modify `api/v1beta1/sandbox_types.go`, `controllers/sandbox_controller.go`, `cmd/agent-sandbox-controller/main.go`; create `api/v1beta1/creation_control_types.go`, `controllers/creation_control.go`, `controllers/creation_control_test.go`. Generated deepcopy/CRDs in k8s, Helm and OLM are regenerated by Main after source changes. Own no transport-package or policy files.

**Consumes:** Task 2 createonce API above. **Produces:** wire contract above and production controller acknowledgement.

- [x] Write and have Main run a baseline regression through existing Reconcile, using JSON unmarshalling so the old types ignore the proposed fields rather than fail compilation:

```go
func TestCreationControlClosePreventsChildren(t *testing.T) {
    var sb sandboxv1beta1.Sandbox
    require.NoError(t, json.Unmarshal([]byte(`{"metadata":{"name":"closed","namespace":"test","uid":"parent","finalizers":["symphony.dev/environment-cleanup"]},"spec":{"creationControl":{"protocol":"symphony-create-drain-v1","closeRequestId":"close"},"service":true,"podTemplate":{"spec":{"containers":[{"name":"worker","image":"example.invalid/worker"}]}}}}`), &sb))
    c := newFakeClient(&sb)
    r := &SandboxReconciler{Client:c, Scheme:Scheme, Tracer:asmetrics.NewNoOp()}
    _, _ = r.Reconcile(t.Context(), ctrl.Request{NamespacedName:client.ObjectKeyFromObject(&sb)})
    var pods corev1.PodList
    require.NoError(t, c.List(t.Context(), &pods))
    require.Empty(t, pods.Items, "close must prevent all new child issuance")
}
```

Run `mise exec go@1.26.4 -- go test ./controllers -run TestCreationControlClosePreventsChildren -count=1`; expected before source change: child present, assertion failure.

- [x] Add API types and validation markers for immutable protocol request presence from parent creation, UID binding, append-only operations, monotonic outcomes/revisions/phases and frozen drained evidence. Bound operation count at 128 and serialized journal size at 128 KiB, reserving outcome/acknowledgement space; reject capacity before issuance, never prune.
- [x] Before deletion/expiry handling, authoritatively reconcile protocol state. Initialize only protocol-at-creation parents with finalizer; close freezes membership and returns without child reconciliation; settle only exact attributed positive observations; preserve unknown operations forever. A lost issuance CAS response cannot authorize a send. Use conditional status update, not optimistic-lock-free merge for journal writers. A final status update must not overwrite intermediate journal writes.
- [x] Route all three create sites through `createChildOnce(ctx, sandbox, object) error`; protocol parents use the journal and one sender, legacy parents use the existing behavior. Reject adoption/unattributed existing children for protocol parents. Preserve reserved annotations in Pod metadata updates. Apply UID-preconditioned deletes. Preserve journal across expiry and deletionTimestamp, watch PVCs, and ensure no stale status writer erases/reopens it.
- [x] Wire manager dependencies. Add deterministic regressions for concurrent close/issuance, delayed POST, lost create/issuance responses, controller replacement, same-name wrong attribution, full journal and expiry/status reset. Tests assert observed child creations and durable acknowledgement/retention, not source text.

## Task 2: Shared single-attempt transport and CLI

**Files:** Create `internal/createonce/client.go`, `internal/createonce/client_test.go`, `cmd/symphony-kubernetes-create/main.go`, `cmd/symphony-kubernetes-create/main_test.go`; modify `Makefile` only to add/build the helper target. Own no controller/types/policy/Symphony files.

**Consumes:** Go rest.Config and explicit helper argv. **Produces:** package and CLI interfaces above.

- [x] Write real TLS HTTP-server tests that count received POSTs for 429/Retry-After, 503/Retry-After, 307/308 redirects, connection loss after reading the body and success with UID. A redirect target must receive zero requests. Auth configuration/wrappers unsupported by the proof must fail before any send.

```go
var received atomic.Int32
server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    received.Add(1)
    w.Header().Set("Retry-After", "0")
    w.WriteHeader(http.StatusServiceUnavailable)
    _, _ = w.Write([]byte(`{"kind":"Status","code":503}`))
}))
// Build rest.Config trusting server.Certificate(); Post once; assert status 503
// and received.Load()==1, including after the caller's context has expired.
```

- [x] Implement dedicated HTTP/1.1 TLS transport: fresh connection per request, no proxies, redirects, HTTP/2, GetBody, idempotency headers or application retries. Reject custom transport/wrap/dial/proxy/exec/auth-provider configuration rather than accidentally importing a retry layer. Support directly loaded CA/client certificate and static bearer/bearer-token-file/basic authentication without request retry. Require verified HTTPS. Read bounded responses and honor context deadlines.
- [x] Implement helper config parsing with `clientcmd`, explicit current-context override and required private input file/API path. No new provider-specific scheduler logic. CLI call emits machine-readable API JSON for both successful and structured rejection responses; missing/malformed config, TLS or transport failure produces no synthetic success.
- [x] Cover actual CLI execution against TLS test server with a temporary kubeconfig. Integrator builds helper and invokes it directly for smoke evidence; no live worker is launched.

## Task 3: Symphony guard and acknowledgement consumer

**Files:** Modify `elixir/lib/symphony_elixir/execution_environment/kubernetes.ex`, `elixir/lib/symphony_elixir/execution_environment/kubernetes/client.ex`, `elixir/test/symphony_elixir/kubernetes_environment_test.exs`; create focused modules/tests under existing `execution_environment/kubernetes/` only where separation improves maintainability. Own no upstream files and no other Symphony docs.

**Consumes:** exact controller wire schema, helper argv and protected attribution. **Produces:** real `ensure`, discovery, start/stop and destroy/recovery integration; same existing provider result shapes.

- [x] Main adds and runs an existing-API regression before edits:

```elixir
test "cleanup retains storage before authoritative create-drain acknowledgement" do
  {config, record, opts} = api_fixture()
  assert {:ok, created} = Kubernetes.ensure(config, record, opts)
  assert {:error, _, _} = Kubernetes.destroy(config, created, opts)
  assert Map.has_key?(api_state()["persistentvolumeclaims"], "workspace-se-ticket")
end
```

Expected before source change: cleanup deletes the PVC, then returns ordering-unproven; the retention assertion fails.

- [x] Replace all production POST transport with helper invocation; preserve GET/patch/delete/watch client behavior. Keep fake external command injection for deterministic API tests, not a production qualification override. Tests must model the new helper argv explicitly.
- [x] Before Sandbox creation, create/observe the versioned, deterministic, never-deleted guard. Store `protocol`, `identity`, `phase`, `operations`, nullable `parentUID`/`closeRequestId`, `record` and `evidence` in `data["guard.json"]`. Bind guard UID via metadata and attempts. Journal Sandbox/Secret issuance by CAS, annotate bodies exactly, settle only matching positive observations. No replay after a lost append or restart. No reuse of completed guard identities; no recreation of missing guards for owned resources.
- [x] Close provider issuance on cleanup intent. Account for every earlier provider attempt, then request controller close by same UID/request ID and validate the full drained journal/ack. Preserve desired-absent state across stop/inspect and prohibit new credentials or parent creation after close. A missing parent is not success except with complete durable proof; denied/ambiguous initial POST now retains its guard.
- [x] Collect durable safety classification for every committed Pod and storage obligation for every committed PVC. Never classify a vanished unobserved Pod as safe; never infer backing deletion from PVC absence. Keep prior termination/CSI semantics and conservative errors.
- [x] Store/read back ReadyToFinalize including exact proofs, then remove only Symphony's cleanup finalizer by UID/resourceVersion CAS on unchanged drained parent. Confirm exact parent absence, CAS/read back Complete, return absent. Discovery inventories guards and reconciles exact identities without order-dependent overwrite. Complete tombstones survive parent deletion, block stale incarnation reuse and do not consume compute capacity. Unknown version/content remains blocking.
- [x] Add observable tests for successful cleanup and restart after parent disappearance, lost ReadyToFinalize/Complete update with unchanged state, wrong acknowledgement, outstanding controller/provider attempts, forged/same-name attribution, missing Pod/PVC evidence and unchanged production preflight stop. Update old tests whose contract intentionally changes; do not disable assertions or add bypass flags.

## Task 4: Admission protections and integration proof

**Files:** Create upstream `k8s/symphony-create-drain-policy.yaml` and `controllers/creation_policy_test.go`; integration tests may add `controllers/creation_control_envtest_test.go`. Main owns Symphony SPEC/README updates, generated files and cross-project evidence packaging. No deployment manifests are applied to a real cluster.

**Consumes:** exact field/annotation names above. **Produces:** usable candidate admission policy and real isolated API-server proof where binaries are available.

- [x] Scope policy/binding to namespaces labeled `symphony.dev/create-drain=symphony-create-drain-v1`. Namespace annotations `symphony.dev/creation-controller` and `symphony.dev/creation-provider` contain exact service-account usernames, set by the operator; missing annotations fail closed. Usernames contain colons, which are invalid in label values. Use Kubernetes ValidatingAdmissionPolicy v1, not a webhook that pretends to fence commits.
- [x] Protect protocol Sandbox creation/status/close/finalizer ownership; immutable per-attempt annotations on Sandbox/Secret/Pod/PVC/Service; controller-only child creation and provider-only parent/Secret creation; guard deletion forbidden. Require original attribution; no copying/adoption. Preserve legitimate API-server/system status operations and namespace isolation. Scheduling-gate removal is provider-only; binding an ungated Pod follows existing scheduler behavior.
- [x] Validate policy CEL and CRD transition rules against isolated envtest apiserver. Exercise writer impersonation, status CAS conflicts, stale issuer/close races and lost/delayed commits using the actual controller/transport where supported. Missing binary capability is reported precisely and cannot be represented as passing qualification.
- [x] Main runs formatters once, Go controller/transport/policy tests plus build, Symphony focused tests then its full `make all` gate with GNU realpath. Run real helper smoke and cross-project wire decoding. Fix new errors at source and obtain independent code/wiring review.
- [x] Update implemented contract docs, leaving baseline/production allocation prohibition explicit. Record actual source commits and generated schema hashes as candidate artifacts only; never invent an image digest or qualification result. Commit source changes in each checkout and provide transportable source evidence for the Kubernetes session.
