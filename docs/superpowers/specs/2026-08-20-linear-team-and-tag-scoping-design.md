# Linear team + tag scoping

Date: 2026-08-20
Status: approved design, not yet implemented

## Problem

The Linear adapter scopes every read to one project. `linear/client.ex` embeds
`project: {slugId: {eq: $projectSlug}}` in both GraphQL queries, and
`configured_tracker_for_read/0` refuses to read without a project slug.

That forces a choice nobody wants. Either Linear projects are used as epics and every new
project needs a Symphony config change, or one project is reserved permanently as
"the Symphony queue" and projects stop being usable as epics at all.

Scoping by team plus a label removes the choice. A ticket joins an instance's queue by
carrying the right label in a listed team, whatever project it belongs to. Projects go
back to being epics and need no Symphony config at all.

An earlier proposal scoped by the team's current cycle
([WMP-14](https://linear.app/wmpayments/issue/WMP-14/linear-cycle-scoping-p1-scope-instances-by-team-current-cycle)).
Cycles are time-boxed and every team has exactly one current one, so cycle scoping cannot
express "this instance, not that one" between two instances on the same team. Labels can.

## Scope

In scope: the fetch scope selector and label matching.

Out of scope, deliberately, as separate follow-up work:

- **Tag selects the workflow** (`bug-symphony` and `feat-symphony` mapping to different
  prompts and agent policy). `Config.settings!()` is a global singleton read at 65 call
  sites across 14 modules, several with no issue in scope (`status_dashboard`,
  `http_server`, `Tracker` polling). Per-tag config means splitting the schema into
  instance-scoped and workflow-scoped halves, threading a resolved workflow into
  `PromptBuilder`, `Workspace`, and backend selection, and turning `WorkflowStore` into a
  store of many workflows. It is its own project.
- **Repo and other config read from the ticket.** `hooks.after_create` is arbitrary shell.
  Sourcing the clone target from ticket text means anyone with Linear write access chooses
  what Symphony clones and runs an agent inside. `path_safety.ex` guards the workspace
  path; nothing guards the clone source. This needs an allowlist design of its own.

After this change one Symphony instance still equals one repo and one `WORKFLOW.md`. What
changes is that adding a Linear project requires no Symphony config change.

`any_labels` is chosen over "one tag per instance" specifically so the follow-up work has
something to build on: the same list becomes the workflow keys when a tag selects a
workflow.

## Verified Linear API behavior

Every claim below was checked against the live API on 2026-08-20. They are load-bearing —
the design depends on all four.

1. **`StringComparator` has `in` but no `inIgnoreCase`.** Fields are `eq`, `neq`, `in`,
   `nin`, `eqIgnoreCase`, `neqIgnoreCase`, `startsWith`, `contains`, and variants.
   Case-insensitive OR matching therefore cannot be one `in` list; it must be an `or:` list
   of `eqIgnoreCase` clauses. Confirmed `eqIgnoreCase: "story"` matches the label `Story`.
2. **Top-level filter fields AND with `or:` / `and:` conjuncts.** `{team: …, state: …,
   or: […], and: […]}` evaluates as `team AND state AND (a OR b) AND (c)`. Confirmed by
   narrowing: team alone 25 issues, team + `or(story|ci)` 19, plus `and(migrated)` 16.
   Nested `or` inside an `and` list works, and the whole filter passes as a single
   `$filter: IssueFilter!` JSON variable.
3. **`in` is case-sensitive, consistently, on both `teams` and `issues`.**
   `teams(filter: {key: {in: ["mdz"]}})` returns nothing and
   `issues(filter: {team: {key: {in: ["mdz"]}}})` returns nothing. They agree, which is
   what makes preflight validation sound rather than lucky.
4. **Labels are team-scoped, not global.** The test workspace holds two distinct labels
   named `Migrated` and two named `Story`, one per team. Filtering by name across teams
   matches all of them, which is the behavior we want, but an operator must create the
   label in every team they list. Confirmed:
   `issueLabels(filter: {name: {eqIgnoreCase: "story"}})` returns one `Story` for `TRA` and
   one for `MDZ`.
5. **`WorkflowStateFilter` supports the same `or` + `eqIgnoreCase` shape.**
   `state: {or: [{name: {eqIgnoreCase: "to do"}}, …]}` matches the state spelled `To Do`.
6. **Preflight costs two requests, not one per value.**
   `teams(filter: {key: {eqIgnoreCase: …}}) { key states { nodes { name } } }` returns each
   team and its workflow states together, and one `issueLabels` query covers the labels.

A seventh observation drove section 5. A filter reading `state: {name: {in: ["Todo"]}}`
returned zero rows because the team's state is spelled `To Do`. A bogus team key does the
same: `team: {key: {in: ["NOPE"]}}` returns `{"data":{"issues":{"nodes":[]}}}` with no
error. This is the failure `deploy/client-template/README.md` already warns about — "Linear
simply returns zero issues, Symphony logs nothing, and the container sits idle forever with
clean logs and a working dashboard." Team scoping widens the surface that fails this way,
so the design makes it loud.

## Design

### 1. Config surface

```yaml
tracker:
  kind: linear
  provider:
    team_keys: ["MDZ", "TRA"]    # new, adapter-owned scope selector
    project_slug: "..."          # still honored, now optional
  any_labels:                    # new, core, at least one must match
    - bug-symphony
    - feat-symphony
  required_labels: []            # existing, core, all must match
```

`team_keys` belongs under `provider` because SPEC §5.3.1 already defines that object as
"adapter-owned configuration such as endpoint, scope/project selector, and credentials."

`any_labels` belongs top-level beside `required_labels` because it is scheduler policy, not
Linear-specific. Any adapter can implement it; adapters that can push it into their query
may, and that is an optimization, not the definition.

No flat `tracker.team_keys` alias. The flat `endpoint` / `api_key` / `project_slug` /
`assignee` aliases exist for backward compatibility; a new field has no past to be
compatible with.

Normalization mirrors `required_labels`: trim, downcase, deduplicate, in
`Config.Schema.Tracker.changeset/2`. Team keys are trimmed and deduplicated but **not**
case-folded in config, because they are matched with `eqIgnoreCase` at query time and
reported back to the operator verbatim in errors and on the status board.

### 2. Validation and backward compatibility

`Linear.Adapter.validate_config/1` requires at least one of `provider.team_keys` (a
non-empty list of non-blank strings) or `project_slug`. New error `:missing_linear_scope`
replaces `:missing_linear_project_slug`.

`Client.configured_tracker_for_read/0` applies the same rule.

`orchestrator.ex:271` matches `{:error, :missing_linear_project_slug}` today and logs
"Tracker project scope missing in WORKFLOW.md". It gets the new error atom and a message
naming both options.

Both set means AND: issues in that project and in one of those teams. Verified composable.
Existing deploys that set only `project_slug` behave exactly as before.

### 3. One filter builder, both queries collapsed

`linear/client.ex` carries two GraphQL literals, `@query` and `@query_by_ids`, whose node
selections are byte-identical and whose filters differ. Collapse them:

- one `@issue_fields` attribute holding the shared node selection, interpolated into both
- both queries take `$filter: IssueFilter!` and pass it straight to `issues(filter:)`
- one `build_issue_filter/2` builds the map in Elixir

```elixir
%{
  state: %{or: [%{name: %{eqIgnoreCase: "Todo"}}, ...]},
  and: [
    %{or: [%{team: %{key: %{eqIgnoreCase: "MDZ"}}}, ...]},          # team_keys
    %{project: %{slugId: %{eq: slug}}},                             # project_slug
    %{or: [%{labels: %{some: %{name: %{eqIgnoreCase: l}}}}, ...]},  # any_labels
    %{labels: %{some: %{name: %{eqIgnoreCase: l}}}}                 # one per required_label
  ]
}
```

Absent conjuncts are omitted from the list, not emitted as `[]`, and `and:` is omitted
entirely when the list is empty. The by-ids query adds `id: %{in: ids}` to the same map and
reuses the same builder.

The filter travels as a JSON variable. No GraphQL string interpolation, which is also how
it was verified.

`eqIgnoreCase` is used for team keys, label names, and state names rather than `in`. It
costs one clause per value instead of one list. It buys immunity to `feat-Symphony` versus
`feat-symphony` and to `To Do` versus `to do`, given findings 1 and 5. State names moving to
`eqIgnoreCase` also makes the query agree with SPEC §5.3.1, which already says state names
are "compared case-insensitively by the scheduler" — true client-side today, false in the
query.

Note that this changes existing behavior for deploys that only set `project_slug`: their
state matching becomes case-insensitive where it was exact. That is a strict widening, it
matches what SPEC §5.3.1 already promises, and it can only turn a silently-idle instance
into a working one. Call it out in the changelog rather than gating it behind a flag.

### 4. Label matching stays client-side as well

The server-side filter is a prefilter. `Issue.routable?/2` remains authoritative.

`agent_runner.ex:258` and `orchestrator.ex:873` both call `routable?` on issues already in
hand, for continuation and refresh checks where no query is involved. Both paths must agree
on the answer, so the predicate keeps both label rules and the GraphQL filter exists only
to avoid paging a whole team's active issues every `polling.interval_ms`.

Signature change: `routable?(t(), [String.t()])` becomes `routable?(t(), map())`, taking
any map with `:required_labels` and `:any_labels` keys. Both `lib` call sites already hold
`Config.settings!().tracker` and merely project one field off it, so each becomes a
one-word change, and tests can pass a bare two-key map without building a schema struct.
Two positional label lists were rejected as a transposition bug waiting to happen.

Semantics:

- `required_labels`: the issue carries every entry. Unchanged.
- `any_labels`: the issue carries at least one entry. An empty list imposes no constraint.
- Both compare after trim and downcase, consistent with existing label normalization.
- A blank configured label matches no issue, per SPEC §5.3.1. With `any_labels: [" "]` the
  constraint is unsatisfiable and nothing dispatches — the same fail-closed behavior
  `required_labels` already has.

### 5. Preflight

Add an optional `preflight/1` callback to the `Tracker` behaviour, listed in
`@optional_callbacks` and dispatched through the `Code.ensure_loaded?/1` plus
`function_exported?/3` guard that `Tracker.validate_config/1` already uses. The other five
adapters need no change.

Called once at CLI startup, not per tick: it makes network calls, and `Config.validate!/0`
runs on every poll.

`Linear.Adapter.preflight/1` resolves three things and reports every unresolved value in
one error rather than failing on the first:

- each configured team key via `teams(filter: {key: {eqIgnoreCase: …}})` — the same
  comparator the read query uses, so validation and reads agree by construction (finding 3)
- `active_states` and `terminal_states` against those teams' workflow states, which catches
  the `Merging` / `Rework` trap the client README documents; the states come back from the
  same `teams` query via `states { nodes { name } }` (finding 6)
- each `any_labels` and `required_labels` entry via one `issueLabels` query, grouped by the
  `team { key }` on each result, because labels are team-scoped (finding 4); a label missing
  from one listed team is a warning, missing from all of them is an error

Two requests total, regardless of how many teams, labels, or states are configured.

Outcome is a single startup error listing every unresolved team, label, and state, or `:ok`.
Failure prevents boot, because a Symphony that cannot match anything is worse than one that
refuses to start.

### 6. Status board

`status_dashboard.ex:395` hard-codes `format_project_link_lines/0` around a Linear project
URL.

The line keeps its `Project:` label and current content when only `project_slug` is set, and
becomes `Scope:` listing team keys and matched labels only when `team_keys` is set. An
unconditional rename would rewrite ten snapshot fixtures under
`test/fixtures/status_dashboard_snapshots/` — five `.snapshot.txt` plus five `.evidence.md`,
all generated with the default `project_slug: "project"` — for no gain in the project-only
case. Existing fixtures stay byte-identical and team scoping gets one new fixture.

## Testing

Coverage threshold is 100%.

- `build_issue_filter/2`, table-driven over config combinations: team keys only, project
  only, both, neither, with and without each label list, and the omitted-empty-conjunct
  cases. These assert the exact filter map, which is the contract that the live API checks
  above validated.
- `routable?/2`: OR semantics, AND semantics, both together, empty lists, the blank-label
  rule, and `dispatchable: false` short-circuiting. Seven existing call sites in
  `workspace_and_config_test.exs` move from a list to a map.
- `validate_config/1`: `:missing_linear_scope` for neither scope set, `:ok` for each of the
  three valid combinations.
- `preflight/1`: unknown team key, label absent from one listed team versus all listed
  teams, unknown state name, and the multiple-failures-in-one-error path.
- Config schema: `any_labels` normalization and `team_keys` trimming and deduplication.
- Existing Linear client tests that assert project-scoped query shapes are updated to the
  variable-based filter.

## Documentation

Same change, per the repo rule that behavior changes update docs alongside:

- `SPEC.md` §5.3.1 (`any_labels`), §6.4 cheat sheet, §8.2 candidate selection rules, and
  the Linear adapter profile scope paragraph
- `elixir/README.md`: Linear adapter profile and the config notes list
- `elixir/WORKFLOW.md`
- `workflows/example.md`
- `deploy/client-template/workflow.md` and `README.md`, where the project-slug warning
  becomes a scope warning and can now point at preflight instead of guesswork

## Risks

- **Team key rename.** Preflight resolves keys at boot, so a rename during a long run
  silently stops matching until restart. Accepted: resolving to team IDs instead would need
  a resolution cache invalidated on every `WorkflowStore` reload, which is more machinery
  than the failure justifies. Preflight catches it on the next restart.
- **Sub-teams.** `TeamFilter` exposes `parent` and `ancestors`; `team_keys` matches listed
  teams only and does not descend. Deliberate — descending silently widens scope.
- **Preflight adds boot-time network dependency.** A Linear outage at startup blocks boot
  where today it would boot and poll unsuccessfully. Accepted, and arguably better, but
  worth revisiting if it becomes annoying in practice.
- **Wider scope means more issues fetched per tick** even with the prefilter, if a team has
  many labeled active issues. Paging already handles it; concurrency limits already bound
  dispatch.
