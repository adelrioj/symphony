# Structured Lane CRUD and Execution Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace YAML-first lane editing with structured lane configuration and reusable mutable execution profiles, including atomic propagation, safe migration and lossless import/export.

**Architecture:** Preserve `LaneStore` as the single serialized live mutation authority and `LaneContext` as the immutable attempt configuration boundary. Persist profile-owned raw configuration separately from lane-owned workflow versions, compose them through the existing `Config.Schema`, and publish every affected lane entry in one ETS insertion after a successful database transaction. Reuse Phoenix LiveView, the authenticated browser/API pipelines, existing runtime fencing, and existing tracker/agent/provider behaviours.

**Tech Stack:** Elixir 1.19 / OTP 28, Ecto/SQLite, Phoenix LiveView, ExUnit, existing vanilla CSS and JavaScript.

**Spec:** `docs/superpowers/specs/2026-09-20-lane-crud-execution-profiles-design.md`

## Global Constraints

- Profiles are mutable; no revisions, pinning, adoption actions or profile rollback.
- Profiles own worker configuration, execution credential references and workspace base; lanes own tracker, prompt, hooks, backend and limits.
- All lanes, including disabled lanes, participate in profile validation. Soft-deleted lane references still prevent profile deletion.
- Attempts and immediate cleanup retain their dispatch snapshot. Retries dispatched later capture current settings.
- Shared profiles do not create a global scheduling pool. Per-lane and per-host limit semantics are unchanged.
- New lanes are disabled. Slugs are immutable after creation. Existing enable/disable actions remain explicit.
- No profile save provisions infrastructure. Existing managed-provider qualification and safety restrictions remain enforced.
- Never resolve credentials into persisted configuration, API summaries, previews, exports or error messages. Preserve reference syntax.
- Workspace safety is mandatory for local, SSH and managed execution; unavailable inventory is not proof that resources are absent.
- `SPEC.md` is the language-agnostic source of truth. Update it and the existing root/Elixir READMEs, WORKFLOW and API/configuration documentation.
- Migration must preserve local relative-root semantics using `Config.data_root()` (`Config.local_workspace_root/0`), while SSH/managed roots retain target-side semantics. Distinguish absent legacy settings with defined defaults from invalid supplied values.
- Add adjacent `@spec` to every new public `def` under `lib/`; callbacks with `@impl` are exempt. Use existing module conventions.
- Do not commit runtime data, screenshots, browser scripts, `.dex` scratch reports or pipeline contracts.
- No compatibility shim for the old live YAML payload; migrate every caller. WORKFLOW files remain supported as the explicit flattened interchange format.
- Tests defend observable behavior, boundaries, destructive safety or concurrency; do not pin new markup wording, implementation plumbing or source text.
- Run commands from `elixir/`, prefixed with `mise exec --` when needed. Run the full `mise exec -- make all` gate once after integration, not for each task.
- Upstream Codex spec review timed out twice without a verdict. This plan must not claim adversarial approval.

## File structure and implementation contracts

Keep existing `Lanes` as the lane domain API and `LaneStore` as the mutation owner. Introduce only three focused domain pieces: `ExecutionProfiles` (profile domain API and query operations), `ExecutionProfiles.Profile` (Ecto schema), and `ExecutionProfiles.Configuration` (raw ownership split/composition and identity/path checks independent of persistence). Add web form helpers only for reusable input conversion and schema-driven field metadata; do not introduce a second validation engine.

Canonical profile API attributes:

```elixir
%{
  "name" => "Shared local workers",
  "description" => nil,
  "workspace_base" => "/srv/symphony/workspaces",
  "worker" => %{}
}
```

Canonical lane API attributes:

```elixir
%{
  "name" => "Features",
  "slug" => "features",
  "execution_profile_id" => 1,
  "workspace_subdir" => "features",
  "config" => %{"tracker" => %{"kind" => "memory"}},
  "prompt" => "Complete the issue.",
  "note" => nil
}
```

`config` is a JSON-compatible string-keyed map containing only lane-owned values. An update replaces the supplied configuration map; omitted configuration preserves the stored map. The form owns a full original map and patches only submitted controls, preserving unrendered nested values. Never rebuild persisted configuration from finalized `Config.Schema` structs, which contain resolved secrets and drop unknown imported values.

Public contracts introduced by this plan:

```elixir
ExecutionProfiles.list() :: [Profile.t()]
ExecutionProfiles.get(term()) :: Profile.t() | nil
ExecutionProfiles.linked_lanes(Profile.t()) :: [Lane.t()]
ExecutionProfiles.create(map()) :: {:ok, Profile.t()} | {:error, [Lanes.error()]}
ExecutionProfiles.update(Profile.t(), map()) :: {:ok, Profile.t()} | {:error, [Lanes.error()]}
ExecutionProfiles.delete(Profile.t()) :: :ok | {:error, [Lanes.error()]}
ExecutionProfiles.Configuration.split(map()) :: {map(), map()}
ExecutionProfiles.Configuration.resolve(map(), map(), String.t(), String.t()) ::
  {:ok, Lanes.validated()} | {:error, [Lanes.error()]}
Workflow.encode_config(map()) :: String.t()
```

`split/1` returns `{profile_attrs, lane_config}` from flattened raw configuration. It extracts `worker` and `workspace.root`, preserving all other keys. `resolve/4` receives raw profile attrs, raw lane config, subdirectory and prompt, validates ownership/path containment, composes effective config, and invokes existing schema/config validation. `Workflow.encode_config/1` uses JSON encoding as valid YAML rather than adding a YAML encoder dependency; exports remain valid `WORKFLOW.md` files.

Retain original historical front matter for inspection. New lane versions can store canonical lane-owned front matter through the same version storage; history inspection parses it as raw configuration. On rollback strip infrastructure from historical full YAML and resolve lane-owned values against the currently selected profile and subdirectory. Export and `Workflow.current_content/0` render the effective flattened raw configuration, not the historical lane-only text.

The identity subdirectory is `"."` for migrated/imported lanes whose effective path must stay exact. New normal creation defaults to slug. Reject absolute subdirectories and any `..` segment even when normalization would remain inside the base. Remote paths must be validated on the remote target, not canonicalized against the daemon filesystem.

## Task dependency order

1. Raw ownership, composition and path validation.
2. Persistence/migration plus serialized lane/profile mutation.
3. Dispatch/retained-resource safety and snapshot lifecycle.
4. Import/export, CLI, API and caller clean cutover.
5. Execution-profile LiveView CRUD and reusable structured fields.
6. Four-section lane editor with in-place profile creation and history integration.
7. End-to-end acceptance, docs and repository quality gate.

### Task 1: Raw configuration ownership and lossless composition

**Files:**
- Create: `elixir/lib/symphony_elixir/execution_profiles/configuration.ex`
- Modify: `elixir/lib/symphony_elixir/workflow.ex`
- Modify: `elixir/lib/symphony_elixir/path_safety.ex`
- Modify: `elixir/lib/symphony_elixir/config/schema.ex` only to reuse existing validation/default metadata where necessary
- Test: `elixir/test/symphony_elixir/execution_profiles_test.exs`
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- Consumes: `Workflow.parse_parts/2`, `Config.Schema.parse/2`, `Config.validate_settings/1`, `PathSafety.canonicalize/1`.
- Produces: `Configuration.split/1`, `Configuration.resolve/4`, `Workflow.encode_config/1` as defined above, plus narrowly scoped shared path helpers needed for containment and overlap checks.

- [x] **Step 1: Add boundary regression tests.** Use real temporary directories for local symlink containment. This is the core resolution contract:

```elixir
alias SymphonyElixir.ExecutionProfiles.Configuration

@tag :tmp_dir
test "profile infrastructure cannot be shadowed and nested lane values survive", %{tmp_dir: root} do
  profile = %{"name" => "Local", "workspace_base" => root, "worker" => %{}}
  config = %{"tracker" => %{"kind" => "memory"}, "extension" => %{"nested" => [1, true]}}
  assert {:ok, value} = Configuration.resolve(profile, config, "features", "Do work")
  assert value.settings.workspace.root == Path.join(root, "features")
  assert value.workflow.config["extension"] == %{"nested" => [1, true]}
  assert {:error, errors} = Configuration.resolve(profile, Map.put(config, "worker", %{}), "features", "Do work")
  assert Enum.any?(errors, &(&1.path == "config.worker"))
  assert {:error, _} = Configuration.resolve(profile, config, "../outside", "Do work")
end
```

Add distinct tests for an absolute subdirectory, a symlink pointing outside the base, identity `"."`, lossless nested split/merge, and secret-reference preservation in encoded/exported raw configuration. Avoid duplicate same-path rows.

- [x] **Step 2: Run the focused tests before implementation.** Run: `mise exec -- mix test test/symphony_elixir/execution_profiles_test.exs`. Expected: failure because the new composition functions are absent.
- [x] **Step 3: Implement the raw codec and resolver.** `split/1` removes only profile-owned infrastructure and leaves every other unknown or nested value intact. Distinguish absence from invalid supplied values. `resolve/4` rejects infrastructure keys in new lane maps with field-specific errors; it never silently drops them. Compose `%{"worker" => profile["worker"], "workspace" => %{"root" => effective_root}}` into the lane map before schema validation. Preserve prompt normalization via `Workflow.parse_parts/2`. Add:

```elixir
@spec encode_config(map()) :: String.t()
def encode_config(config) when is_map(config), do: Jason.encode!(config, pretty: true)
```

Reuse Ecto embedded worker/environment validation and schema defaults rather than inventing a parallel model. Profile-only structural validation must not require fake tracker credentials or invent a runnable tracker. Preserve existing provider qualification checks when validating effective lane settings. Implement containment by canonical path components in `PathSafety`; no naive prefix tests. Do not treat the daemon's local filesystem as the SSH filesystem.
- [x] **Step 4: Verify focused observable behavior.** Run: `mise exec -- mix test test/symphony_elixir/execution_profiles_test.exs test/symphony_elixir/workspace_and_config_test.exs`. Expected: ownership, round-trip and safety boundaries pass without changing legacy WORKFLOW parsing semantics.
- [x] **Step 5: Commit this testable configuration boundary.** Stage only the listed files and commit `feat: define execution profile configuration ownership`.

### Task 2: Persist profiles and atomically publish linked lanes

**Files:**
- Create: `elixir/lib/symphony_elixir/execution_profiles.ex`
- Create: `elixir/lib/symphony_elixir/execution_profiles/profile.ex`
- Modify: `elixir/lib/symphony_elixir/repo/migrations.ex`
- Modify: `elixir/lib/symphony_elixir/repo.ex`
- Modify: `elixir/lib/symphony_elixir/lanes/lane.ex`
- Modify: `elixir/lib/symphony_elixir/lanes.ex`
- Modify: `elixir/lib/symphony_elixir/lane_store.ex`
- Modify: `elixir/test/support/test_support.exs`
- Test: `elixir/test/symphony_elixir/repo_test.exs`
- Test: `elixir/test/symphony_elixir/lanes_test.exs`
- Test: `elixir/test/symphony_elixir/lane_store_test.exs`
- Test: `elixir/test/symphony_elixir/execution_profiles_test.exs`

**Interfaces:**
- Consumes: Task 1 composition/codec; existing `LaneStore` transaction, monitor, preflight and restart semantics.
- Produces: profile CRUD signatures above; lane `execution_profile_id` and `workspace_subdir`; extended `LaneStore.Entry` with profile ID/name and immutable effective workflow/settings. Existing `Lanes.create/update/activate_version/set_enabled/delete` remain the domain entry points but consume the new lane attributes.

- [x] **Step 1: Add transactional and migration regressions.** Extend existing real-Repo tests rather than introducing a second harness. Assert successful shared edits update the effective settings of two linked lanes, disabled lanes participate, and any invalid lane causes database and all entries to remain unchanged:

```elixir
@tag :tmp_dir
test "shared profile validation is all or nothing", %{tmp_dir: root} do
  {:ok, profile} = ExecutionProfiles.create(%{name: "Shared", workspace_base: root, worker: %{}})
  {:ok, first} = Lanes.create(%{slug: "first", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
  {:ok, second} = Lanes.create(%{slug: "second", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
  {:ok, before_first} = LaneStore.lookup(first.id)
  {:ok, before_second} = LaneStore.lookup(second.id)
  assert {:error, errors} = ExecutionProfiles.update(profile, %{worker: %{"max_concurrent_agents_per_host" => -1}})
  assert errors != []
  assert ExecutionProfiles.get(profile.id).worker == profile.worker
  assert {:ok, ^before_first} = LaneStore.lookup(first.id)
  assert {:ok, ^before_second} = LaneStore.lookup(second.id)
end
```

Use a pre-migration database populated through the original migration, not current schemas, to cover enabled, disabled, deleted, malformed-YAML, missing-version and managed rows plus existing runs/events. Assert exact effective paths and historical IDs/content survive. Test duplicate/nonblank names, required FK enforcement and referenced deletion including soft-deleted lanes.
- [x] **Step 2: Run the focused tests to expose the absent domain behavior.** Run: `mise exec -- mix test test/symphony_elixir/execution_profiles_test.exs test/symphony_elixir/repo_test.exs`. Expected: failures in profile persistence/migration behavior.
- [x] **Step 3: Implement migration and the single publication authority.** Add a compiled migration registered after `CreateHostLossAlarms`. Persist profile name, nullable description, raw worker map, workspace base and an explicit repair error for malformed legacy infrastructure. Backfill one unique dedicated profile per lane, including soft-deleted lanes; no deduplication. Preserve existing canonical effective path as base with subdir `"."`; never call finalized-schema serialization that writes resolved credentials. Malformed rows retain their original historical data and visible repair error, stay non-runnable, and gain no invented operational defaults. The required FK must be enforced in SQLite, not only by changesets; handle SQLite table rebuilding/constraints without cascaded deletion of versions/runs/events. Run `PRAGMA foreign_key_check` in the migration regression. Do not modify the already-released first migration.

Replace per-lane publication preparation with one common serialized mutation path used by both domain APIs. A mutation loads fresh rows within the authority, applies a single transaction, resolves all affected lanes and rejects any invalid candidate before commit. It must never call `GenServer.call(LaneStore, ...)` recursively from inside the authority. Prepare every entry before commit, then perform one insertion:

```elixir
true = :ets.insert(@table, Enum.map(entries, &{&1.lane_id, &1}))
```

Only after this insertion broadcast affected lanes/profile views and refresh runtimes. Existing attempts are not stopped for configuration-only edits. Profile update success is returned only after publication. No `keep_last_known_good` path may turn a rejected candidate or partial profile publication into reported success. Preserve intentional disable/repair behavior for invalid persisted lanes without making profile edits bypass full validation.

Crash between commit and publication must take the authority through the existing fenced restart path: restore every persisted effective entry before new dispatch. Maintain monitor/preflight generation checks. Reject unsafe identity changes through existing guards; Task 3 extends unmanaged ownership safety before feature completion. Profile deletion shares this serialization boundary and refuses references or outstanding ownership; never cascade-delete infrastructure.

Make lane slugs immutable on update and create new lanes disabled regardless of supplied `enabled`; enabling remains a subsequent explicit action. Reject legacy live `front_matter`, `executor` and infrastructure overrides rather than accepting them silently. Preserve historical front matter, but resolve rollback through current selected profile/subdirectory.
- [x] **Step 4: Migrate the common test harness and existing domain fixtures, then verify.** Update `TestSupport.reset_lanes!/0` to remove profiles only after lane/version/run cleanup; update its workflow writer to split infrastructure and mutate through the new domain boundary. File-mode entry 0 remains the agent-side workflow path, not a second live lane API. Run: `mise exec -- mix test test/symphony_elixir/repo_test.exs test/symphony_elixir/lanes_test.exs test/symphony_elixir/lane_store_test.exs test/symphony_elixir/execution_profiles_test.exs`. Expected: FK, atomicity, rollback and startup recovery pass; repair entries remain visible.
- [x] **Step 5: Commit the complete persistence/authority cutover.** Commit `feat: persist execution profiles and atomically refresh linked lanes`.

### Task 3: Fence dispatch and retained execution resources

**Files:**
- Modify: `elixir/lib/symphony_elixir/lane_store.ex`
- Modify: `elixir/lib/symphony_elixir/lane_context.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Modify: `elixir/lib/symphony_elixir/execution_profiles/configuration.ex`
- Modify: `elixir/lib/symphony_elixir/execution_environment/config.ex` only if shared identity extraction is needed
- Test: `elixir/test/symphony_elixir/multi_lane_test.exs`
- Test: `elixir/test/symphony_elixir/lane_store_test.exs`
- Test: `elixir/test/symphony_elixir/lane_context_test.exs`
- Test: `elixir/test/symphony_elixir/execution_profiles_test.exs`
- Test: existing orchestrator/workspace regression modules covering dispatch and cleanup

**Interfaces:**
- Consumes: Task 2 batch mutation/publication and immutable entries.
- Produces: serialized dispatch reservation/capture coupled to location identity; identity-change checks covering active attempts, pending dispatches, local/SSH retained workspaces and existing managed inventories. Keep the exact new reservation helper private where possible; consumers continue reading effective settings through `Config` and `LaneContext`.

- [x] **Step 1: Add synchronization-based regression cases.** Use messages/barriers, not sleeps, to pause a real runner around dispatch and completion. One process installs the old snapshot, profile non-location settings change, a second dispatch observes the new profile, and the first runner plus after-run cleanup still observe the old values. Assert an identity change is rejected while a dispatch is reserved, while running, and while a retained local workspace exists after completion. Removing the workspace safely then permits the change. Exercise an inaccessible SSH target as a rejected/unverifiable location change, never an empty inventory. Concurrent profile update/relink/delete must produce either a complete valid result or field errors, never partial DB/ETS state.

```elixir
LaneContext.put(lane.id)
{:ok, old_snapshot} = LaneContext.capture()
{:ok, _profile} = ExecutionProfiles.update(profile, %{description: "Updated"})
LaneContext.install(old_snapshot)
assert {:ok, ^old_snapshot} = LaneContext.capture()
```

The above only establishes snapshot pinning; keep the real running-attempt/cleanup scenario as the regression against the dispatch race.
- [x] **Step 2: Run these focused tests before fixing the race.** Run: `mise exec -- mix test test/symphony_elixir/multi_lane_test.exs test/symphony_elixir/execution_profiles_test.exs`. Expected: the new location/reservation cases expose the gaps in unmanaged guards.
- [x] **Step 3: Close ownership races without broadening the architecture.** Existing `EnvironmentConfig.identity/1` returns nil for unmanaged workers, so it is not an adequate location guard. Derive local/SSH target identity from canonical root and execution target(s), and retain the existing managed identity/qualification logic. A profile with overlapping SSH host sets may collide even when the host lists are not identical. Compare effective roots on the same target; use component containment checks and remote canonicalization where needed. Include disabled lanes and retained references in overlap/ownership decisions; legacy collisions become visible non-runnable repair conditions, not silently moved paths.

Reserve the chosen snapshot/location under the same `LaneStore` serialization boundary as mutations before a new task can create a workspace. Release failed spawn reservations and attempt reservations only after immediate cleanup; handle owner death through existing runtime fencing so no orphan task can write after the guard is dropped. Avoid authority-to-orchestrator synchronous calls while an orchestrator can be waiting on the authority. Inspect retained local/SSH roots conservatively before allowing location changes; read-only inventory failure blocks changes and identifies the affected lane/target. Do not provision a provider or invent a remote cleanup operation during save.

Reuse the current captured `ExecutionContext` for cleanup, including recorded paths. Keep retries capturing the current effective entry after ownership checks. Reconciliation currently groups snapshots by `version_id` in two locations in `orchestrator.ex`; profile edits need a full immutable generation/config identity so different profile settings sharing one lane version cannot be reconciled under the wrong snapshot. Fix both groups and preserve the existing before/after-run hook snapshot behavior.
- [x] **Step 4: Verify the safety matrix.** Run: `mise exec -- mix test test/symphony_elixir/lane_store_test.exs test/symphony_elixir/lane_context_test.exs test/symphony_elixir/multi_lane_test.exs test/symphony_elixir/execution_profiles_test.exs test/symphony_elixir/workspace_and_config_test.exs`. Expected: profile edit cannot redirect retained-resource cleanup or race a dispatch; non-location updates remain possible.
- [x] **Step 5: Commit.** Commit `fix: preserve execution identity across profile updates and dispatch`.

### Task 4: Clean-cutover API, offline interchange and remaining callers

**Files:**
- Modify: `elixir/lib/symphony_elixir/lanes.ex`
- Modify: `elixir/lib/symphony_elixir/cli.ex`
- Modify: `elixir/lib/symphony_elixir/workflow.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/lanes_api_controller.ex`
- Create: `elixir/lib/symphony_elixir_web/controllers/execution_profiles_api_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/test/symphony_elixir_web/auth_test.exs` and its CSRF lane-creation payload
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: all remaining direct lane create/update fixtures/callers discovered by symbol/text search
- Test: `elixir/test/symphony_elixir_web/lanes_api_test.exs`
- Create: `elixir/test/symphony_elixir_web/execution_profiles_api_test.exs`
- Test: existing CLI/import/export tests and `elixir/test/symphony_elixir/lanes_test.exs`

**Interfaces:**
- Consumes: profile CRUD and canonical lane attributes.
- Produces: authenticated `/api/v1/execution-profiles` CRUD matching the existing lane API status/error conventions; lane responses with profile ID/name/subdir; same domain validation for every UI/API mutation. Preserve the existing `Lanes.import_file/2` return shape `{:ok, lane, warnings}` and add the generated profile name to import output/warnings.

- [x] **Step 1: Add API and interchange regressions.** Assert unauthorized profile requests fail through the same auth plug as lanes; successful create/update returns persisted profile configuration without resolved secrets; duplicate names/infrastructure overrides return 422 field errors. Deleting referenced profiles is rejected without changing lanes. Flattened export/import must round-trip semantic lane and worker configuration while a re-import creates a new dedicated profile and changes only the targeted lane. A failed import leaves neither profile nor lane/version changes.

```elixir
assert {:ok, exported} = Lanes.export(lane)
assert {:ok, parsed} = Workflow.parse(exported)
assert parsed.config["workspace"]["root"] == effective_root
assert parsed.config["tracker"]["api_key"] == "$LINEAR_API_KEY"
refute exported =~ System.fetch_env!("LINEAR_API_KEY")
```

Use the existing test environment's distinct test token for that assertion, never a real credential.
- [x] **Step 2: Run focused tests.** Run: `mise exec -- mix test test/symphony_elixir_web/lanes_api_test.exs test/symphony_elixir_web/execution_profiles_api_test.exs test/symphony_elixir/lanes_test.exs`. Expected: absent routes and old request/serialization assumptions fail before implementation.
- [x] **Step 3: Implement the adapters, not another authority.** Controllers translate request/response shape and call domain APIs; no controller writes Repo directly. Restrict profile routes to authenticated API scope. Validate bounded IDs using existing controller conventions. Preserve 404/422 semantics and expose lane-identified rejected-save errors. Add profile links/identity to existing presenter output without secret values.

Offline import parses the flattened raw map, allocates a collision-safe dedicated profile name, and creates/relinks the lane plus profile in one existing mutation transaction. Preserve exact imported effective root with identity subdir. Re-import never edits an existing shared profile. Existing CLI data-root and offline locking restrictions stay intact. Export reads the currently selected profile and lane configuration consistently and serializes raw merged data, not finalized settings. Update `Workflow.current_content/0` so an attempt gets its captured effective flattened configuration, including MCP/agent consumers.

Search all `Lanes.create`, `Lanes.update`, `validate_version`, lane fixtures and API examples; migrate them. Do not leave a branch accepting legacy front matter in the live API. Historical/file-mode parsing is explicitly not such a shim. Existing tests asserting the former supported contract should move to the new observable contract; delete tests that merely pin source/markup wording instead of rewriting strings.
- [x] **Step 4: Verify.** Run the three focused modules above plus actual CLI import/export against a fresh throwaway data root. Expected: existing exported WORKFLOW files import, generated profile names are shown, default disabled status and profile references survive export/reimport, API authentication and field errors work.
- [x] **Step 5: Commit.** Commit `feat: expose execution profile API and profile-aware workflow interchange`.

### Task 5: Execution-profile LiveView CRUD

**Files:**
- Create: `elixir/lib/symphony_elixir_web/live/execution_profiles_live.ex`
- Create: `elixir/lib/symphony_elixir_web/live/execution_profile_live.ex`
- Create: `elixir/lib/symphony_elixir_web/live/execution_profile_editor_live.ex`
- Create: `elixir/lib/symphony_elixir_web/components/configuration_fields.ex` only for fields reused by both profile/lane forms
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/lib/symphony_elixir_web/components/layouts.ex`
- Modify: `elixir/priv/static/dashboard.css`
- Modify: `elixir/lib/symphony_elixir_web/observability_pubsub.ex`
- Test: `elixir/test/symphony_elixir_web/execution_profiles_live_test.exs`

**Interfaces:**
- Consumes: profile domain API; current authenticated LiveView/layout conventions.
- Produces: `/execution-profiles`, `/execution-profiles/new`, `/execution-profiles/:id`, `/execution-profiles/:id/edit`; reusable form fields/conversion with no persistence authority. Profile fields remain reusable inside the lane editor for Task 6's inline create flow.

- [x] **Step 1: Extend behavior tests only for risky transitions.** Assert delete rejection leaves the page/data intact, changing a referenced profile reports affected lane errors, and submitted nested worker maps survive an unrelated name edit. Use normal authenticated LiveView mounts, not a separate app harness. Do not add tests pinning every label or CSS class.
- [x] **Step 2: Implement actual CRUD views.** Use existing layouts, tables/panels, button and flash conventions. The list links to detail/create; detail shows safe environment summary plus all linked lanes and affected count; edit explains automatic application to future runs and aggregate shared-machine load. Inline all save errors in an error summary plus associated labeled controls. Link rejected identity errors to affected lanes/resources. Delete requires a clear destructive-action confirmation and never cascades.

Provide structured fields for local, static SSH and existing managed configurations, with credential references and environment-specific controls. Do not imply unavailable providers are enabled. Ordinary profile creation requires no YAML; uncommon provider nested fields may use a JSON object editor with field-level parse errors. Preserve unexposed nested keys on unrelated edits. Defaults come from existing schema definitions, never the HTML mockup. Do not expose resolved credential values.

Reusable numeric duration conversion must preserve integer milliseconds exactly. Use decimal parsing/formatting rather than float multiply/round; display milliseconds or an exact decimal second value when not divisible by 1000. Booleans, arrays and optional/null values must preserve types.
- [x] **Step 3: Run focused regressions.** Run: `mise exec -- mix test test/symphony_elixir_web/execution_profiles_live_test.exs test/symphony_elixir_web/execution_profiles_api_test.exs`. Expected: domain errors remain visible without navigation/data loss.
- [ ] **Step 4: Exercise the real profile UI.** Start a local server using the existing CLI in a throwaway data root and operator token; wait for the HTTP port. Log in through the actual `/login` page. Create, inspect, edit and delete a resource-free profile; verify the referenced-delete message on a linked profile. Check narrow-screen layout, keyboard focus, labels and screenshots using browser automation. Save proof outside the repo and stop only the server you started. This is runtime verification, not a `[manual]` checkbox that may be ticked without proof. Blocked: host Accessibility/Screen Recording permissions prevented browser automation; only HTTP login/protected-route smoke checks ran.
- [x] **Step 5: Commit.** Commit `feat: add execution profile management views`.

### Task 6: Four-section lane editor and profile creation return flow

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/live/lane_editor_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/lanes_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/lane_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/lane_versions_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/components/configuration_fields.ex` if introduced in Task 5
- Modify: `elixir/priv/static/dashboard.css`
- Test: `elixir/test/symphony_elixir_web/lane_editor_live_test.exs`
- Test: `elixir/test/symphony_elixir_web/lane_versions_live_test.exs`
- Test: existing lane list/detail tests affected by the new contract

**Interfaces:**
- Consumes: canonical lane config/profile domain APIs and reusable profile form fields.
- Produces: lossless structured lane creation/editing, linked profile visibility, current-profile rollback messaging, and inline profile creation returning to the untouched lane draft.

- [x] **Step 1: Add lossless-edit and return-flow regressions.** Mount the lane editor, populate an unsaved prompt/provider scope/nested override, open profile creation inline, create a profile, and assert the lane draft retains every value with the new profile selected. Repeat cancel without creating a profile. Editing a name must preserve unknown imported nested config and raw secret references; malformed advanced JSON must not save or discard the draft. Assert slug mutation is rejected by the domain, not merely hidden by the UI.
- [x] **Step 2: Replace the raw YAML editor with the specified four sections.** Keep the server-side lane draft in the same LiveView while showing an inline profile-create panel, avoiding secrets in URLs, localStorage or an unprotected draft persistence endpoint. The empty-profile state opens that same create panel. Reuse profile form fields/domain API, and on success select the new ID without resetting lane fields. Cancel returns focus to the opener and preserves draft data.

The four sections are Work selection, Execution, Workflow and Limits. Work selection includes name, creation-only slug preview/editor, all supported tracker adapter scopes, label filters and states. Execution includes profile select/create/link, safe read-only target summary, effective workspace path and advanced subdir. Workflow includes backend/prompt/setup hooks, all lifecycle hooks/timeouts and backend-specific settings/permissions/state overrides. Limits includes concurrency, polling, turn/retry/exhaustion/state limits and observability. Remove the executor selector and raw-YAML-first interaction. Create stays disabled; notes belong to edit/history.

Use `Config.Schema` and tracker adapter validation as the authoritative field inventory: `Tracker` common fields/provider map, Polling, Agent, Codex, Claude, Hooks and Observability must all be represented or preserved in a named advanced structured object control. Unknown imported keys stay in the draft's original raw map; unsupported/uneditable values must be reported, not dropped. Do not use a generic JSON textarea as the ordinary creation experience. Known common tracker scopes must be first-class controls; uncommon nested structures may be JSON.

Lane list/detail show selected profile and link. Existing runtime actions remain wired. History still displays existing records; before activation explain that historical lane settings will use the currently selected profile and will not roll back infrastructure. Ensure history actions invoke the new domain resolution contract.
- [x] **Step 3: Run focused behavior regressions.** Run: `mise exec -- mix test test/symphony_elixir_web/lane_editor_live_test.exs test/symphony_elixir_web/lane_versions_live_test.exs test/symphony_elixir_web/lanes_live_test.exs test/symphony_elixir_web/lane_live_test.exs`. Expected: no field loss, no profile content mutation from lane edit, no history infrastructure rollback.
- [ ] **Step 4: Exercise the real lane UI.** In the same supported temporary-server setup, create a profile and two lanes without entering YAML. Verify distinct effective workspace paths. Edit the shared profile, inspect both lanes, and verify pending form state through profile create/cancel. Exercise keyboard-only select/save/error navigation and narrow mobile viewport. Capture actual screenshots outside the repo. Confirm errors are associated with inputs, focus is visible, and destructive actions explain affected entities. Partial: keyboard navigation, focus return, save/error flows, links, and a screenshot ran; narrow-viewport verification was unavailable.
- [x] **Step 5: Commit.** Commit `feat: replace YAML-first lane editing with structured configuration`.

### Task 7: Integrated acceptance, documentation and quality gate

**Files:**
- Modify: `SPEC.md`
- Modify: `README.md`
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md`
- Modify: `.claude/docs/configuration.md`
- Modify: existing API/configuration guidance located by references to lane payloads
- Modify: affected focused regression modules only where integrated behavior requires it
- Modify: `.claude/docs/deployment.md` (existing front-matter API recipes) and `docs/operations.md`

**Interfaces:**
- Consumes: all preceding tasks.
- Produces: verified full spec behavior, accurate operational/API documentation and a handoff with actual command/browser outcomes.

- [x] **Step 1: Run an end-to-end throwaway runtime scenario.** Use two linked lanes and a controlled runner so an attempt pauses, a profile non-location edit succeeds, a later dispatch uses new settings, and the paused attempt/cleanup retain the old snapshot. Attempt a prohibited location change with retained workspace state, verify rejection without persistence/publication drift, safely clear ownership using supported operations, then verify the edit is allowed. Stop/restart the temporary installation and verify profile resolution before dispatch. Exercise migration against an old-schema fixture with real version/run/resource identity data. Record results outside the repo; no fabricated acceptance based on compilation alone.
- [x] **Step 2: Update existing documentation after behavior is proven.** Document profile ownership, aggregate shared capacity, automatic future-run propagation, immutable attempts, identity-change rejection/repair, deletion restrictions, structured UI, changed lane API payload, profile routes and offline import-generated profile names. Explain rollback's current-profile semantics, no infrastructure provisioning, no profile history and secret-reference-only exports. Keep flattened WORKFLOW examples importable; no new runtime watched-file configuration. Update migration/recovery guidance for invalid or overlapping legacy lanes and disabled states.
- [ ] **Step 3: Run project formatter and the full quality gate once.** Run: `mise exec -- mix format`, then `mise exec -- make all`. Expected: build, formatting, specs/Credo, coverage (both configured passes) and Dialyzer complete successfully. Fix real integrated defects, not suppression/ignore-list expansion. Report external failures exactly; do not claim a green gate if it did not run or failed. Re-run only the failed relevant gate after fixes unless integrated changes require the full sequence. Incomplete: format/spec checks passed, but the full suite had failures and `make all` stopped at strict Credo before coverage and Dialyzer.
- [x] **Step 4: Remove only throwaway artifacts created by this implementation.** Keep screenshots, smoke scripts/logs and test databases outside the repo. Remove temporary implementation scripts after runtime proof. Confirm every named acceptance bullet in the spec has runtime/regression evidence and every affected caller uses the new authority. No unfinished scaffolding, no compatibility aliases, no unimplemented routes.
- [x] **Step 5: Commit the integrated docs and fixes.** Commit `docs: document structured lanes and execution profile lifecycle`. Hand back exact tests, browser scenarios, remaining failures and changed files for dex review and PR creation.

## Self-review and acceptance mapping

- Profile ownership/resolution and raw-secret safety: Tasks 1–2 and 4.
- All-or-nothing publication, concurrent edits/relink/delete and crash recovery: Tasks 2–3 and 7.
- Active snapshot, retry capture and unmanaged/managed retained identity: Task 3 and runtime proof in Task 7.
- Required FK, dedicated migration profiles, invalid-row repair, no activation/path drift: Task 2 and Task 7.
- Profile CRUD/API, referenced-delete constraints and affected-lane messaging: Tasks 2, 4–5.
- Ordinary no-YAML lane creation, all adapter/backend advanced fields, lossless edits: Task 6.
- Profile-create draft return, keyboard/mobile/errors/destructive messaging: Tasks 5–6 real browser runs.
- Atomic offline import/re-import, flattened export and current-profile rollback: Tasks 2, 4 and 6.
- SPEC/README/WORKFLOW/API/config docs and full repository gate: Task 7.

Concrete remaining fixture/caller inventory: `test/support/kubernetes_candidate_runner.exs`, `test/symphony_elixir/core_test.exs`, `cli_test.exs`, `lane_supervisor_test.exs`, `kubernetes_environment_test.exs`, `runs_test.exs`, `test/mix/tasks/symphony_task_test.exs`, and `test/symphony_elixir_web/run_live_test.exs`, in addition to the task-listed modules. Prefix these paths with `elixir/`. Keep `RunLive`'s historical `run.executor` meaningful; do not replace recorded attempt identity with today's mutable profile. Existing split/render byte-roundtrip tests in `workflow_test.exs` remain valid even though profile-composed export comparisons become semantic.

Route and asset evidence: profile API routes must precede the existing issue-identifier/wildcard fallbacks in `router.ex`; retain bearer authentication, cookie CSRF protection and positive bounded path-ID parsing. `StaticAssets` embeds `dashboard.css` at compilation, so the browser verification must run rebuilt code. Existing global PubSub is sufficient for profile lists/details if used consistently; introduce no redundant notification bus.

Execution is owned by the enclosing ship-it conductor through `plan-to-dex`. Do not execute this plan during the writing-plans step and do not re-interview the user.
