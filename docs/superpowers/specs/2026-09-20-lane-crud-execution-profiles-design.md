# Structured lane CRUD and reusable execution profiles

Date: 2026-09-20
Status: design direction approved; written specification awaiting review

## Goal and approved decisions

Replace the YAML-first lane editor with structured configuration and reusable execution profiles from the outset. Profiles are mutable: a successful save automatically applies to newly dispatched attempts of every linked lane. There are no profile revisions, pinning, adoption actions, or profile rollback. Existing lane workflow history remains supported but does not restore historical profile contents.

The HTML concept at `/tmp/symphony-lane-create.html` establishes the four-section layout, not complete field coverage or production defaults. Implement using the existing Phoenix LiveView stack and visual conventions, not a new frontend framework.

## Ownership

Execution profiles own name, optional description, worker configuration (unmanaged local, static SSH, or existing managed-provider configuration), execution credential references, and workspace base directory. Profiles do not provision infrastructure merely by being saved. Existing provider qualification and safety restrictions remain enforced; configuration support is not authorization to enable unavailable providers.

Lanes own name, immutable slug, enabled status, profile reference, workspace subdirectory, tracker configuration and secrets references, polling, agent/backend settings, prompt, repository-specific lifecycle hooks, concurrency, turn/retry limits, and lane observability configuration. Repository setup is a lane concern even when machines are shared.

The current single-option `executor` selector disappears from the form. This feature does not invent a second execution dispatch mechanism: profiles resolve into the existing worker configuration and agent behaviours.

## Data and configuration resolution

Add an execution_profiles table and a required foreign key from lanes. Store structured profile configuration using repository-supported persistence conventions. A profile ID is stable; its name is editable. Profile names are nonblank and unique. Foreign keys prevent deletion while referenced, including by soft-deleted lanes unless their references are explicitly removed as part of safe cleanup.

Profile infrastructure fields have one authority. New lane payloads cannot shadow worker or workspace-base settings. A lane workspace is the profile base plus a validated relative lane subdirectory (new lanes default to their immutable slug). Reject absolute subdirectories, traversal, symlink escapes, and overlapping effective workspace roots where they would share issue directories on the same execution target. Continue using PathSafety rather than introducing string-prefix checks.

Resolve lane-owned configuration plus profile-owned configuration into the existing Config.Schema. Preserve Config and LaneContext as consumers' access path. Backend processes must not query mutable profile rows during an attempt. Extend LaneStore.Entry with the profile identity needed for refresh and diagnostics, retaining its fully resolved immutable settings.

Existing lane version history remains lane-owned. Rollback resolves historical lane settings against the currently selected profile; it never restores obsolete infrastructure embedded in historical YAML. The UI must state this limitation before rollback.

## Runtime update contract

LaneStore remains the serialized runtime configuration authority. Profile saves, lane relinking, lane edits, and deletion must share a serialization boundary; do not implement propagation as independent per-lane saves.

For a profile mutation:

1. Resolve all linked lanes, including disabled lanes, against the proposed profile.
2. Validate every effective configuration, workspace-isolation constraint, and execution resource-identity guard.
3. If any lane fails, reject the complete mutation and return lane-identified errors. Do not update the database or publish any candidate settings.
4. Commit the profile in one database transaction and publish the prepared lane entries as a single ETS batch. Dispatch captures an entry before or after publication, never a mixture of configuration fields. Cross-lane scheduling is not a transaction.
5. Refresh lane runtime configuration and broadcast affected views without terminating existing attempts. Report success only after publication is complete.

A run dispatched after a successful save uses current settings. An already dispatched attempt, including its immediate cleanup, retains its snapshot. A retry dispatched later captures the then-current configuration, subject to resource-location constraints.

Changing execution location is not an implicit migration. Host/provider/root changes must be rejected while attempts or retained resources require the previous identity. Existing managed-resource guards are necessary but not sufficient: unmanaged local/SSH workspace reuse and cleanup must also be protected. If an old workspace would be abandoned or cleanup redirected, reject the change until it is safely removed or otherwise resolved through existing supported operations. Keep non-location settings editable when safe.

Database commit and ETS publication cannot be made one storage transaction. If the authority fails in this interval, recovery rebuilds effective entries from the database before permitting new dispatch. Existing runtime fencing/restart semantics remain authoritative; do not claim uninterrupted process survival across daemon failure. No silent last-known-good fallback may report a profile update successful while some lanes retain old settings.

Sharing a profile does not create a global scheduling pool. Lane concurrency remains per lane; existing per-host limit semantics are unchanged. The UI explains that several lanes can place aggregate load on the same machines.

## User interface

### Lanes

Retain the lane list and existing detail/runtime actions. Show each lane's execution profile and link to it. Creation and editing use:

1. **Work selection:** name, slug preview (editable only on creation), provider-specific tracker scope, labels, active and terminal states.
2. **Execution:** profile selector, create-profile action, read-only environment summary, effective workspace path, and advanced workspace subdirectory control.
3. **Workflow:** agent backend, prompt, workspace setup; advanced backend-specific commands, permissions, state overrides, all lifecycle hooks and hook timeout.
4. **Limits:** concurrency plus advanced polling, turn, retry, state-specific limits, and other supported lane settings.

New lanes are created disabled. Existing enable/disable semantics remain explicit. Editing a lane changes its profile selection, not the shared profile's contents. Change notes belong to edit/history rather than a prominent creation control.

Use accessible labels and field-level errors plus an error summary. Present human units for intervals and convert without precision loss. Populate actual schema defaults, not the mockup's example values. All supported tracker adapters and configuration fields must be accounted for; uncommon nested values may use advanced structured editors, but ordinary creation must not require YAML. Preserve unexposed imported configuration on unrelated form edits and report unsupported configuration rather than silently discarding it. Secrets remain references and must not be exposed in summaries or previews.

### Execution profiles

Provide list, create, detail, edit, and delete views under `/execution-profiles`. Detail shows environment configuration and linked lanes. Editing shows the number and names of affected lanes and explains that changes apply automatically to future runs. Display rejected-save reasons with links to affected lanes/resources. Deletion is blocked by lane references and outstanding resource ownership. Do not cascade-delete lanes, workspaces, or provider resources.

Creating a profile from the lane form must preserve the unfinished lane form and return with the new profile selected. Empty-profile state leads directly to profile creation.

## API, import/export, and migration

Expose authenticated profile CRUD alongside the existing lane API. Lane API writes select a profile and provide lane-owned configuration; supplying infrastructure overrides returns a field-specific error. Apply the same validation and serialization to UI and API writes. Update every existing create/update/rollback/import/export caller; no alternate authority or compatibility shim remains.

Keep WORKFLOW.md as a portable flattened import/export format. Export resolves current profile settings and includes the effective workspace root, without embedding resolved secrets. Import creates a dedicated profile from the infrastructure portion and a lane from the remainder; it never silently edits a shared profile. Re-import into an existing lane creates a replacement dedicated profile and relinks only that lane, subject to ownership guards. The import is atomic and remains offline-only where currently required. Profile names generated during import must be collision-safe and shown in the result.

Migration runs before lane runtime startup and creates one dedicated profile per existing lane. Do not deduplicate: reuse is an explicit operator choice. Preserve each existing effective workspace path exactly by using that path as its dedicated profile base and the identity subdirectory. New profiles default to slug-isolated subdirectories. Migration must handle disabled lanes and invalid configuration without activating them or inventing runnable defaults; surface invalid profiles/lanes for repair. Preserve historical records, but remove their ability to override current profile infrastructure. Validate migration against real existing rows and retained-resource identities before shipping.

Existing exported files must remain importable. The redesigned live API is a clean cutover, with its consumers and documentation updated in the same change.

## Verification and acceptance

- Create a profile and two lanes through the actual UI without YAML; both display correct independent workspace roots.
- Edit a shared profile; future dispatches on both lanes use the new resolved settings without adoption clicks or profile versions.
- An attempt already executing retains its original settings through completion and cleanup.
- Invalid shared edits leave profile persistence and all published lane settings unchanged.
- Concurrent profile edits, relinking, dispatch, and deletion cannot bypass validation or expose partially composed settings.
- Unsafe identity changes are rejected for running attempts and retained resources, including unmanaged workspaces.
- Referenced profiles cannot be deleted; unreferenced resource-free profiles can.
- Restart and publication-failure recovery resolve persisted profiles before new dispatch, with no stale-success claims.
- Existing installations migrate without changing paths, enabling disabled lanes, or losing lane-owned settings.
- Import/export and lane rollback follow the current-profile contract; secrets are not rendered in output.
- Advanced fields and all supported provider/backend configurations survive unrelated edits.
- Keyboard operation, mobile layout, field errors, profile creation return flow, and destructive-action messaging are verified in the real UI.

Keep focused regression tests for concurrency, snapshot isolation, destructive safety, migration, and lossless edits. Exercise UI behavior in the browser and run the repository quality gate once integrated. Update SPEC.md, root and Elixir READMEs, WORKFLOW.md, API documentation, and relevant configuration guidance in the implementation change.

## Implementation boundaries and evidence

Current entry points: `elixir/lib/symphony_elixir_web/live/lane_editor_live.ex`, `lanes.ex`, `lanes/lane.ex`, `lanes/lane_version.ex`, `config/schema.ex`, `lane_store.ex`, `lane_context.ex`, `execution_environment/config.ex`, and `repo/migrations.ex`.

Observed existing constraints: the editor exposes raw YAML and Markdown; LaneStore publishes per-lane entries containing resolved settings; LaneContext installs immutable attempt snapshots; current mutations enforce managed identity checks before publication. Multi-lane mutation, unmanaged location guards, profile persistence, and structured UI are new work, not existing capabilities.

Non-goals: profile history, profile rollout controls, infrastructure provisioning, global capacity scheduling, new tracker/agent/provider adapters, and weakening existing provider restrictions.
