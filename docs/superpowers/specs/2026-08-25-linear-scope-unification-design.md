# Linear scope unification: team, cycle, project, labels

Date: 2026-08-25
Status: design approved, awaiting implementation plan
Supersedes: `WMP-14` (cycle scoping, designed 2026-08-14) and the design on
`origin/feat/scope-tickets-by-tags` (team + tag scoping, designed 2026-08-20)

## Problem

The Linear adapter scopes every read to one project. `linear/client.ex` bakes
`project: {slugId: {eq: $projectSlug}}` into both GraphQL documents, and
`configured_tracker_for_read/0` (`client.ex:609-617`) refuses to read without a project slug.

Linear projects are epics: created and closed constantly. Pinning an instance to one forces a
choice nobody wants — either every new epic needs a Symphony config change and restart, or one
project is reserved permanently as "the Symphony queue" and projects stop being usable as epics.

Two selectors fix this, and they are not interchangeable:

* **Labels** are an explicit opt-in marker. A ticket joins the queue by carrying the right label in
  a listed team, whatever project it belongs to. Labels can partition several instances across one
  team; they cost per-ticket tagging.
* **The current cycle** is the team's existing sprint ritual. Nobody tags anything — the sprint *is*
  the queue. It cannot partition two instances on one team.

This design offers both, plus the existing project selector, as conjunctive scope keys.

## Relationship to the two prior designs

This work exists twice already, which is the reason for a third document rather than an increment.

`WMP-14` proposed team + current cycle, a pure `Linear.Scope` module, and the invariant that ID
refreshes must not be scope-filtered. It was never implemented; the branch it cites
(`adelrioj/feat-decouple-from-projects`, commit `180ac68`) no longer exists in this repository and
its spec file was never committed, so the ticket body is the only surviving copy.

`origin/feat/scope-tickets-by-tags` (25 commits, `+3644/-165`, zero commits behind `origin/main`)
implemented team + label scoping and independently arrived at three of the same structural moves:
the filter-as-one-variable rewrite, retiring `:missing_linear_project_slug` in favour of
`:missing_linear_scope`, and an optional `Tracker` callback. Its design doc explicitly rejected
cycle scoping on the grounds that cycles cannot partition two instances on one team — true, and
answering a different question than the one cycles are for.

What this design keeps from the branch, unchanged:

* the `$filter: IssueFilter!` rewrite of both documents and the shared `@issue_fields` selection set
* `provider.team_keys` as a list, and `tracker.any_labels` as core scheduler policy
* `:missing_linear_scope` replacing `:missing_linear_project_slug`
* `Tracker.preflight/1` and its two-request resolution of teams, states, and labels
* `Issue.routable?/2` taking a map rather than two positional label lists
* `eqIgnoreCase` everywhere, including for state names
* its live API findings and its `linear_scope_test.exs` table-driven filter tests

What this design changes about the branch, and why:

1. **ID refreshes stop being scope-filtered.** The branch calls
   `build_issue_filter(tracker, ids: batch_ids)` (`client.ex:303` on the branch), which ANDs every
   scope conjunct into the by-IDs read. This preserves the failure mode the whole feature needs
   eliminated, and it is worse under labels than under projects — see "The by-IDs invariant".
2. **Scope logic moves into a pure `Linear.Scope` module.** The branch put `build_issue_filter/2`
   inside `Linear.Client`, which is in `coverage_ignore_modules` (`mix.exs:47`) and absent from
   `review_coverage_modules/0`, so it is coverage-exempt in both modes. The branch's 506 lines of
   filter tests therefore measure nothing, and `CLAUDE.md:71` forbids resolving that by growing the
   ignore list.
3. **Provider-key validation moves out of core.** The branch validates `provider.team_keys` shape in
   `Config.Schema`. `SPEC.md:394-395` says core "MUST NOT prescribe one cross-provider credential or
   scope schema", so Linear provider keys are validated by the Linear adapter.
4. **The board label becomes `Scope:` unconditionally,** rendered through an optional
   `Tracker.scope_summary/1` callback rather than by pattern-matching Linear keys inside
   `status_dashboard.ex`. The branch kept a conditional `Project:` label to avoid regenerating ten
   snapshot fixtures; with four selectors a label whose meaning depends on which key is set is
   incoherent, and regeneration is one command.
5. **`current_cycle` is added** as a fourth selector.

## Goals

* Scope Linear reads by `team_keys`, `current_cycle`, `project_slug`, labels, or any conjunction.
* Keep every existing `project_slug`-only deployment working with no config edit.
* Stop a scope change — cycle rollover, or a label edited by hand — from killing in-flight agents.
* Keep provider-specific scope knowledge inside the Linear adapter.
* Make an unmatchable scope loud at boot instead of silently idle.

## Non-goals

* **Tag selects the workflow.** Per-tag prompts and agent policy. `Config.settings!()` is a global
  singleton read across many modules, several with no issue in scope. Per-tag config means splitting
  the schema into instance-scoped and workflow-scoped halves and turning `WorkflowStore` into a
  store of many workflows. Its own project.
* **Repo or other config read from the ticket.** `hooks.after_create` is arbitrary shell; sourcing a
  clone target from ticket text lets anyone with Linear write access choose what Symphony clones.
  Needs an allowlist design of its own.
* **Per-label backend and concurrency** (`WMP-14`'s deferred P3).
* **Stage routing by state and type label** (`WMP-14`'s deferred P2).
* Switching this repository's own `elixir/WORKFLOW.md` or the deploy templates to cycle scoping.
  They stay on `project_slug`; adopting a new selector is an operator action.

After this change one instance is still one repo and one `WORKFLOW.md`. What changes is that adding
a Linear project requires no Symphony config change.

## Verified provider facts

Every claim is load-bearing. Items 1-6 were verified against the live API on 2026-08-20 during the
branch's work; items 7-10 were verified on 2026-08-25 against
`packages/sdk/src/schema.graphql` in `linear/linear`
(`curl -sL https://raw.githubusercontent.com/linear/linear/master/packages/sdk/src/schema.graphql`).

1. **`StringComparator` has `in` but no `inIgnoreCase`.** Case-insensitive OR matching cannot be one
   `in` list; it must be an `or:` list of `eqIgnoreCase` clauses. Confirmed `eqIgnoreCase: "story"`
   matches the label `Story`.
2. **Top-level filter fields AND with `or:` / `and:` conjuncts.** `{team: …, state: …, or: […],
   and: […]}` evaluates as `team AND state AND (a OR b) AND (c)`. Confirmed by narrowing: team alone
   25 issues, team + `or(story|ci)` 19, plus `and(migrated)` 16. The whole filter passes as a single
   `$filter: IssueFilter!` JSON variable.
3. **`in` is case-sensitive, consistently, on both `teams` and `issues`.** They agree, which is what
   makes preflight validation sound rather than lucky.
4. **Labels are team-scoped, not global.** Two distinct labels named `Story` exist, one per team.
   Filtering by name across teams matches all of them — the desired behaviour — but an operator must
   create the label in every team they list.
5. **`WorkflowStateFilter` supports the same `or` + `eqIgnoreCase` shape.**
6. **Preflight costs two requests, not one per value.** `teams(filter: {key: {eqIgnoreCase: …}})
   { key states { nodes { name } } }` returns each team with its workflow states; one `issueLabels`
   query covers the labels.
7. **Query complexity is multiplicative with a ceiling of 10000.** Measured: `250x250` (69025) and
   `250x50` (14025) rejected, `100x50` accepted. Any nested connection added to a query must be
   budgeted.
8. **`IssueFilter` carries all four selectors as top-level ANDed fields:** `team: TeamFilter`
   (line 265 of the input), `cycle: NullableCycleFilter` (81), `project: NullableProjectFilter`
   (201), `labels: IssueLabelCollectionFilter` (169), `state: WorkflowStateFilter` (253),
   `id: IssueIDComparator` (165), plus `and:` (25) and `or:` (189).
9. **`NullableCycleFilter` has `isActive: BooleanComparator`** (schema line 28299), alongside
   `isNext`, `isPrevious`, `isFuture`, `isPast`, and `isInCooldown`. `isActive` is a property of the
   issue's own cycle, so `team_keys: [A, B]` AND `cycle.isActive` means "issues in A or B that sit in
   their own team's current cycle" — well defined for several teams.
   `IssueFilter.addedToCyclePeriod: CyclePeriodComparator` was considered and rejected:
   `enum CyclePeriod { after, before, during }` describes when an issue was added relative to a
   period, not "the current cycle".
10. **`type Team` exposes `activeCycle: Cycle`** (schema line 44788) as a plain object, not a
    connection — so preflight can select it in the `teams` query it already makes, at no extra
    request and with no effect on the complexity budget of item 7.
11. **`CycleCreateInput` requires exactly `teamId: String!`, `startsAt: DateTime!`,
    `endsAt: DateTime!`** (optional `name`, `description`, `completedAt`, `id`), which is what the
    live E2E cycle scenario needs.

## Design

### 1. Config surface

```yaml
tracker:
  kind: linear
  provider:
    team_keys: ["MDZ", "TRA"]     # optional; adapter-owned scope selector
    current_cycle: true           # optional; boolean only; requires non-empty team_keys
    project_slug: "acme-web"      # optional; unchanged semantics
  any_labels:                     # optional; core policy; at least one must match
    - feat-symphony
  required_labels: []             # existing; core policy; all must match
```

`team_keys`, `current_cycle`, and `project_slug` live under `provider` because `SPEC.md:391-397`
defines that object as "adapter-owned configuration such as endpoint, scope/project selector, and
credentials". `any_labels` is top-level beside `required_labels` because it is scheduler policy, not
Linear-specific: any adapter can implement it, and pushing it into a provider query is an
optimization, not the definition.

No new flat aliases. The flat `endpoint` / `api_key` / `project_slug` / `assignee` aliases
(`schema.ex:440-445`, `:477-486`) exist for backward compatibility and are kept exactly as they are;
a new key has no past to be compatible with.

`current_cycle: true` arrives as a real boolean. Front matter is parsed as YAML
(`workflow.ex:114`, `YamlElixir.read_from_string/1`), `provider` is `field(:provider, :map)`
(`schema.ex:56`), and `normalize_keys/1` (`schema.ex:502-509`) and `drop_nil_values/1`
(`schema.ex:519-528`) both have identity fallthrough clauses that touch keys only. Proven
end-to-end by `workspace_and_config_test.exs:1512-1528`, which round-trips `networkAccess: true`
through a real `WORKFLOW.md` and asserts the boolean survives. `current_cycle: false` survives too,
because `drop_nil_values` strips only `nil`.

### 2. Ownership boundary

| Owner | Responsibility |
| -- | -- |
| `Config.Schema` | `any_labels` only: trim, downcase, deduplicate, mirroring `required_labels`. |
| `SymphonyElixir.Linear.Scope` (new) | Everything under `tracker.provider`: `validate/1`, `filter/2`, `scope_summary/1`. |

`Linear.Scope` is pure over a tracker settings map, with no HTTP. One module owns validation, filter
shape, and the board text so the three cannot drift, it is testable without a network, and it keeps
`linear/client.ex` (729 lines) on transport and pagination.

| Function | Returns |
| -- | -- |
| `validate(tracker_settings)` | `:ok \| {:error, atom()}` |
| `filter(tracker_settings, opts)` | `map()` |
| `scope_summary(tracker_settings)` | `String.t()` |

Placing scope logic here rather than in `Linear.Client` is a coverage requirement, not a preference:
`SymphonyElixir.Linear.Client` sits in `coverage_ignore_modules` (`mix.exs:47`) and is absent from
`review_coverage_modules/0` (`mix.exs:80-89`), so it is exempt at both the default 100% threshold and
under `SYMPHONY_COVER_REVIEW_MODULES=1`. `Linear.Scope` is exempt from neither.

### 3. Validation

Presence is decided by **value**, never by key. `schema.ex:444` runs
`Map.put_new("project_slug", settings.tracker.project_slug)` *after* `drop_nil_values` has already
run at `schema.ex:333`, so the finalized provider map contains `"project_slug" => nil` even when
nothing was configured — confirmed by `workspace_and_config_test.exs:1235-1241`, which asserts a
surviving `"assignee" => nil`. A `Map.has_key?` check would treat project scope as always present and
never fire `:missing_linear_scope`. Blank and whitespace-only strings count as absent, matching the
existing `present_string?` discipline at `adapter.ex:120-121`.

`Scope.validate/1` enforces, in this order. Type checks come first so the presence rule cannot be
satisfied by a malformed value:

1. `team_keys` present but not a list of non-blank strings, else
   `{:error, :invalid_linear_team_keys}`. Strict, because a scalar would otherwise degrade silently
   to project-only scope.
2. `current_cycle` present but not a boolean, else `{:error, :invalid_linear_current_cycle}`. Strict
   so `filter/2` is total.
3. At least one **container** selector contributes a filter fragment — a non-empty `team_keys`, a
   present `project_slug`, or `current_cycle: true` — else `{:error, :missing_linear_scope}`.
4. `current_cycle: true` with an empty or absent `team_keys`, else
   `{:error, :missing_linear_team_keys}`. Rationale: unqualified `cycle: {isActive: {eq: true}}`
   matches the active cycle of *every* team the token can see, so the day a second team appears the
   instance would silently dispatch agents against another team's tickets.

Two consequences worth stating, because both are reachable by a plausible config and neither is
obvious from the rule list:

* **`current_cycle: false` does not satisfy rule 3.** It contributes no filter fragment — it means
  "not scoped by cycle", not "scoped to a non-active cycle" — so `current_cycle: false` with no other
  selector is `:missing_linear_scope`, not an unscoped read of the whole workspace. Rule 3 counts
  contributed fragments, never present keys, for exactly this reason.
* **Labels alone are not a scope.** `any_labels` and `required_labels` narrow a container; they do not
  define one. A labels-only config would filter the entire workspace by label, which is both a
  workspace-wide read and a scope no operator intends, so it is `:missing_linear_scope`. Note rules 3
  and 4 together make `current_cycle: true` imply `team_keys`, so cycle scoping is always
  team-qualified.

`:missing_linear_project_slug` is retired rather than kept as a special case: "project scope missing"
is the wrong diagnosis once four scope keys exist. Both gates delegate to `Scope.validate/1`, which
matters because they are independent today and disagree in style:

* `linear/adapter.ex:50-51` — config-time, `present_string?`-based.
* `linear/client.ex:613-614` — request-time, `is_nil`-based. Left alone, a cycle-only config would
  pass config validation and then be rejected at read time.
* `orchestrator.ex:271-273` — the error branch and its log message, which must name the new options
  or degrade to the generic catch-all at `orchestrator.ex:294-296`.

No `Config.Schema` change is needed for the retirement: that file contributes no Linear-specific
error atom and performs no provider validation, so `Schema.parse/1` accepts any provider shape
(`workspace_and_config_test.exs:1249-1281`).

### 4. Preflight

`Tracker.preflight/1` is kept as the branch built it: an optional callback listed in
`@optional_callbacks` and dispatched through the `Code.ensure_loaded?/1` plus `function_exported?/3`
guard already used at `tracker.ex:93`. The other five adapters need no change. It is called once at
CLI startup, not per tick, because it makes network calls while `Config.validate!/0` runs on every
poll.

`Linear.Adapter.preflight/1` resolves every value and reports all failures in one error rather than
failing on the first:

* each configured team key via `teams(filter: {key: {eqIgnoreCase: …}})` — the same comparator the
  read query uses, so validation and reads agree by construction (fact 3)
* `active_states` and `terminal_states` against those teams' workflow states, from the same query
  (fact 6), catching the `Merging` / `Rework` spelling trap the client README documents
* each `any_labels` and `required_labels` entry via one `issueLabels` query, grouped by `team { key }`
  because labels are team-scoped (fact 4); missing from one listed team is a warning, missing from
  all of them is an error

Extension for this design: the same `teams` query also selects `activeCycle { name endsAt }`, free per
fact 10.

**A team with no active cycle logs a warning naming that team and boots.** It is not a hard failure.
An absent active cycle is a normal Linear state during sprint cooldown, so refusing to start would
turn a routine condition into an outage — a container rebooting between sprints would not come up.
An unresolvable *team key* stays a hard failure, because that is a typo, not a state.

At runtime the poll simply returns zero issues and the instance idles. No per-tick
`team.activeCycle` probe: it would spend a query every poll and add a failure mode. No warning on
empty results: it would fire constantly during legitimate cycle end and cooldown. Whether a team
currently has an active cycle is a Linear-side fact; the boot warning is where it is reported.

`preflight/1` and `scope_summary/1` are complementary and coexist: one fails fast on an unresolvable
scope, the other renders the resolved one.

### 5. Query assembly

Both documents stop carrying a filter shape and take the whole filter as one variable:

```graphql
query SymphonyLinearPoll($filter: IssueFilter!, $first: Int!, $relationFirst: Int!, $attachmentFirst: Int!, $after: String) {
  issues(filter: $filter, first: $first, after: $after) { ... }
}
```

```graphql
query SymphonyLinearIssuesById($filter: IssueFilter!, $first: Int!, $relationFirst: Int!, $attachmentFirst: Int!) {
  issues(filter: $filter, first: $first) { ... }
}
```

The node selections are byte-identical on `main` and are collapsed into one `@issue_fields` attribute
interpolated into both. The `attachments(first: $attachmentFirst)` selection and `$attachmentFirst`
variable added by the attachments work are preserved in both documents; they are orthogonal to scope
and land in the same lines this change rewrites.

`Scope.filter/2` builds the map. Present conjuncts only; absent ones are omitted rather than emitted
as `[]`, and `and` is dropped entirely when its list is empty:

```elixir
%{
  "state" => %{"or" => [%{"name" => %{"eqIgnoreCase" => "todo"}}, ...]},
  "cycle" => %{"isActive" => %{"eq" => true}},
  "and" => [
    %{"or" => [%{"team" => %{"key" => %{"eqIgnoreCase" => "MDZ"}}}, ...]},
    %{"project" => %{"slugId" => %{"eq" => "acme-web"}}},
    %{"or" => [%{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "feat-symphony"}}}}, ...]},
    %{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "migrated"}}}}
  ]
}
```

`cycle` sits top-level because `IssueFilter.cycle` ANDs natively and needs no OR list (facts 8, 9).
Team keys, label names, and state names use `eqIgnoreCase` rather than `in`, costing one clause per
value, because fact 1 rules out `inIgnoreCase` and fact 3 makes bare `in` case-sensitive. That buys
immunity to `feat-Symphony` versus `feat-symphony` and to `To Do` versus `Todo`.

Moving state names to `eqIgnoreCase` changes behaviour for existing `project_slug`-only deploys:
state matching becomes case-insensitive where it was exact. This is a strict widening, it matches
what `SPEC.md` §5.3.1 already promises ("compared case-insensitively by the scheduler" — true
client-side today, false in the query), and it can only turn a silently-idle instance into a working
one. It goes in the changelog rather than behind a flag.

`fetch_issues_by_states/1` sends `Scope.filter/2` with the state names. `fetch_issues_by_ids/1`
builds `%{"id" => %{"in" => ids}}` inline and never calls `Scope.filter/2` at all — see section 6.
That asymmetry is deliberate: the by-IDs path holds no tracker settings and has no code path that
could reach a scope conjunct, so the invariant is structurally unrepresentable rather than merely
untested. This is the difference from the branch, where one builder served both call sites and a
single `ids:` option was all that separated a scoped read from an unscoped one.

Consequently `project_slug` stops being threaded through `do_fetch_by_states_page/5`; those functions
carry the tracker settings, and the `is_binary(project_slug)` guard at `client.ex:296-297` is removed.
Selection sets, `@issue_page_size 50`, `@attachment_page_size`, relation handling, assignee
filtering, and the empty-input short-circuits (`client.ex:126` for states, `client.ex:142` for IDs,
both required by `SPEC.md:1267` and `:1272`) are unchanged.

A `project_slug`-only config produces a semantically identical server-side filter, not identical wire
bytes, because the filter moves from the document into a variable.

### 6. The by-IDs invariant

`fetch_issues_by_ids/1` applies **no** scope filter.

> **Admission is scope-gated; continuation is state-gated.**

Linear issue IDs are workspace-unique UUIDs and the API token already bounds the query to one
workspace, so the read stays exact. This is the one place this design contradicts the branch, and it
matters more for the branch's own feature than for cycles: a label is mutable at any instant by
anyone with Linear write access, whereas a project churns monthly.

`fetch_issues_by_ids/1` has exactly five production consumers, and each treats an omitted ID as a
decision:

| Consumer | Omission means today |
| -- | -- |
| `orchestrator.ex:317` running reconcile, via `reconcile_missing_running_issue_ids/3` (`:478-496`) | `terminate_running_issue(state, id, false)` — kill the agent, no completion recorded, workspace retained |
| `orchestrator.ex:341` blocked reconcile (`:500-518`) | `release_issue_claim/2` — drop the block and the claim |
| `orchestrator.ex:927` `refresh_issue_for_dispatch/1` via `revalidate_issue_for_dispatch/3` (`:1038-1039`) | `{:skip, :missing}` — refuse to dispatch, swallowed by `dispatch_issue/4` |
| `orchestrator.ex:1115` `handle_retry_issue/4` via `handle_retry_issue_lookup/5` (`:1154-1157`) | the retry is dropped and the claim released, logged at `Logger.debug` only |
| `agent_runner.ex:133` via `continue_with_issue?/2` (`:233-234`) | `{:done, issue}` — end the multi-turn loop |

Because the by-IDs query is scope-filtered today, an issue that merely *leaves the configured scope*
is indistinguishable from a deleted one, and all five fire at once. Consumer 4 is the hottest path:
`handle_agent_down(:normal, …)` (`orchestrator.ex:198-213`) schedules a `:continuation` retry after
every clean agent exit, so a de-scoped issue loses its claim roughly one second after each successful
turn — and at `Logger.debug`, invisible at the default level. The failure semantics are also
asymmetric: a transport *error* is fail-safe at three of the five sites, but an empty-but-successful
result is destructive at all five. "Silently left the scope" is strictly worse than "Linear was down".

With no scope filter, a de-scoped issue is returned *with its state*, and `reconcile_issue_state/4`
(`orchestrator.ex:421-441`) decides on state through its four branches: terminal completes and removes
the workspace, non-routable stops the agent, active refreshes the cached issue and keeps running, and
the catch-all stops the agent while retaining the workspace. `reconcile_blocked_issue_state/4`
(`:456-475`) mirrors it with `release_issue_claim/2`.

Simplification: the by-IDs path stops needing tracker settings at all. The branch's threading of
`tracker` through `do_fetch_issue_states*` reverts, and `fetch_issues_by_ids_for_test/2` loses its
stub tracker — deleting both `main`'s hardcoded `"test-project"` slug (`client.ex:252`) and the
branch's inline `%{project_slug: "test-project", team_keys: [], any_labels: [], required_labels: []}`.

Accepted cost: `refresh_issue_for_dispatch/1` and `handle_retry_issue/4` are admission paths that
borrow the by-IDs read, so an issue polled earlier, deferred for retry, then moved out of scope can
still be re-dispatched while its state stays active. Accepted rather than fixed, because a retry is
continuation of work already admitted, and the operator's stop lever is unchanged and already
documented: move the issue to a non-active state and the last branch of `reconcile_issue_state/4`
stops the agent.

Rejected alternative: a second `Tracker` callback (`fetch_issues_by_ids_in_scope/1`) so continuation
is unscoped while admission stays scoped. It costs a callback implemented across six adapters and
duplicated by-IDs plumbing in each, for a race the state lever already covers.

### 7. SPEC.md amendment

`SPEC.md:1273-1274`, under §11.1 item 2, currently blesses the old behaviour:

> IDs no longer visible in the configured scope are omitted; the orchestrator treats omission as
> "no longer visible" rather than inventing a synthetic state.

Those two lines are replaced with:

1. `fetch_issues_by_ids` MUST NOT apply configured scope selection as a filter. An adapter whose IDs
   are only meaningful inside a container MAY remain container-bound — required for GitHub, where
   `github/client.ex:91-103` resolves IDs through the repository path because a GitHub ID is `#N`
   within a repository, and likewise for GitLab.
2. Omission MUST mean the ID is not retrievable — deleted, inaccessible, or foreign to the
   credential's workspace — never "outside the configured scope". The orchestrator still treats
   omission as "no longer visible" and invents no synthetic state.
3. Candidate admission is governed by `fetch_issues_by_states` and configured scope; lifecycle
   continuation is governed by issue state.

`SPEC.md:1289-1292` is preserved untouched: an ID refresh MUST still fail rather than silently omit a
*malformed* requested record. It shares a code path with the omission handling, so it needs explicit
care in implementation.

Matching edits, or the spec becomes internally inconsistent: §17.3 `:2191-2193` and `:2202-2203`, and
§5.3.1 for `any_labels`. Nothing enforces this mechanically — `mix specs.check` is a pure `@spec`
presence linter over `lib/` and never reads `SPEC.md`, and no test or CI step does either. The
amendment lands in this change or it never happens.

Jira and Asana IDs are already global and need no change.

### 8. Status board

Two defects in the current line, both blocking a scope-aware rendering:

* `status_dashboard.ex:397-400` pattern-matches `%{kind: "linear", project_slug: project_slug}` — a
  core rendering module branching on one provider's config keys, which `SPEC.md:1313-1314` forbids.
* `linear_project_url/1` (`:431`) builds `https://linear.app/project/#{slug}/issues`. Real Linear web
  URLs are workspace-prefixed and no workspace slug exists anywhere in config — the tracker schema
  (`schema.ex:50-61`) has no such field — so the line already emits a broken URL, and all ten
  snapshot fixtures embed it.

Add an optional callback, mirroring the `validate_config/1` precedent:

```elixir
@callback scope_summary(map()) :: String.t()
@optional_callbacks scope_summary: 1
```

`Tracker.scope_summary/1` takes a tracker settings map and MUST resolve the adapter through
`adapter_for_kind/1`, exactly as `Tracker.validate_config/1` does at `tracker.ex:91-98` — **not**
through `adapter/0`, which goes via `adapter_for_settings!/1` (`tracker.ex:115-118`) and raises
`MatchError` on an unknown kind. This matters because `format_project_link_lines/0` is called twice:
at `status_dashboard.ex:337` on the normal path and at `:386` on the degraded `:error` path, where
today it safely renders `n/a`. It guards with `Code.ensure_loaded?/1` plus `function_exported?/3` and
falls back to `"n/a"`; github, gitlab, jira, asana, and memory need no change and keep rendering
`n/a`.

`Linear.Adapter.scope_summary/1` delegates to `Linear.Scope.scope_summary/1`, so board text and query
cannot disagree. `Scope.scope_summary/1` renders in a fixed order — teams, cycle, project, labels —
joined with ` · `:

| Config | Summary |
| -- | -- |
| teams + cycle | `teams MDZ, TRA · current cycle` |
| teams only | `teams MDZ, TRA` |
| project only | `project acme-web` |
| teams + cycle + labels | `teams MDZ · current cycle · any labels feat-symphony` |

The board renders every 16 ms (`server.render_interval_ms`, `schema.ex:285`), so
`scope_summary/1` stays pure string assembly: no network, no config read beyond the settings map it
is handed.

The dashboard renders `│ Scope: ` in place of `│ Project: ` unconditionally, and
`linear_project_url/1` is deleted rather than patched. No URL is invented: the poll query already
selects `url` onto the `Issue` struct (`client.ex:27`), and per-issue links are where an operator
clicks. The `Dashboard:` line (`:408-414`), the `Next refresh:` line (`format_project_refresh_line/1`,
`:417-429`), the cyan value styling, and the gray `n/a` fallback are unchanged.

The board layout has no `SPEC.md` or README contract, and `SPEC.md:1484-1490` (§13.4) makes any
human-readable status surface OPTIONAL and implementation-defined, so no spec amendment is needed for
the rename — but `scope_summary/1` must stay genuinely optional at the behaviour level, or a REQUIRED
path would depend on an OPTIONAL feature.

The Phoenix LiveView dashboard and the JSON observability API are **not** a second render site:
`Presenter.state_payload/2` emits no project or scope field, `dashboard_live.ex` reads no tracker
config, and the only tracker-adjacent text is a per-issue aria-label. Adding a web-side scope display
would be new scope and is not part of this change.

## Testing

Coverage threshold is 100%, with `Linear.Client`, `StatusDashboard`, `Orchestrator`, `AgentRunner`,
and `Config` all in the ignore list (`mix.exs:38-79`). Of this change's surface the coverage-gated
modules are `Linear.Scope` (new), `Linear.Adapter`, `Tracker`, `Config.Schema`, and `Tracker.Issue`.
`Scope` is pure, so 100% is cheap and the ignore list does not grow — required, since `CLAUDE.md:71`
says to prefer tests over expanding it. Client and dashboard tests are justified by behaviour, not by
the coverage number.

### Seams

* `fetch_issues_by_ids_for_test/2` (`client.ex:240-254`) already injects a `graphql_fun/2`; used at
  `workspace_and_config_test.exs:536` and `:604`.
* **Add** `fetch_issues_by_states_for_test/2` with the same signature and the same `@doc false` plus
  `is_function(fun, 2)` convention. Without it the poll filter is only reachable over real HTTP, and
  no test asserts the poll request's variables today.
* Dashboard snapshots regenerate with
  `UPDATE_SNAPSHOTS=1 mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`
  (`snapshot_support.exs:31-34`, `:65-70`), which rewrites both `.snapshot.txt` and `.evidence.md`.

### Tests

`Linear.Scope` (new test file, no HTTP) — harvest the branch's `linear_scope_test.exs` and re-point it:

* `filter/2`: exact expected map, table-driven over teams only, cycle plus teams, project only,
  labels only, all four, and neither; plus the omitted-empty-conjunct cases and the `and`-dropped
  case.
* `validate/1`: `:missing_linear_scope`, `:invalid_linear_team_keys`,
  `:invalid_linear_current_cycle`, `:missing_linear_team_keys`, `current_cycle: false` contributing
  nothing, whitespace-only entries treated as absent, and the injected `"project_slug" => nil` case
  from section 3 that must not count as present.
* `scope_summary/1`: the four strings from section 8's table.

`Linear.Client` (behavioural, injected `graphql_fun`):

* Poll: `$filter` equals the scope map merged with the state clause, per scope combination.
* Poll pagination: the identical filter map is resent on page two with the cursor advanced.
* By-IDs: the outgoing `filter` **equals** `%{"id" => %{"in" => ids}}` by exact map comparison.
  This must be exact equality, not a subset pattern. Elixir map patterns are non-exact, which is
  exactly how the branch's `%{filter: %{id: %{in: ^first_batch_ids}}}` assertion passes while a
  project conjunct rides along in the same variable; and asserting on document text
  (`refute query =~ "$projectSlug"`) proves nothing once the filter is a variable, because the slug
  legitimately no longer appears there. This is the regression test for section 6.

`Issue.routable?/2`: OR semantics, AND semantics, both together, empty lists, the blank-label rule,
and `dispatchable: false` short-circuiting. Existing call sites in `workspace_and_config_test.exs`
move from a list to a map.

Continuation after a scope change (characterization; no orchestrator logic changes here):

* `AgentRunner.continue_with_issue_for_test/2` (`agent_runner.ex:17-20`) with an issue that left the
  scope but is still in an active state asserts `{:continue, _}`.
* `Orchestrator.revalidate_issue_for_dispatch_for_test/2` (`orchestrator.ex:393-396`) for the same
  input asserts the dispatch path is not skipped as `:missing`.

Config error migration:

* `core_test.exs:46,60,290,328` and `extensions_test.exs:139,142` move from
  `:missing_linear_project_slug` to `:missing_linear_scope`.
* The same files gain cases for `team_keys`-only config (valid), `current_cycle` without `team_keys`
  (`:missing_linear_team_keys`), and a non-boolean `current_cycle`
  (`:invalid_linear_current_cycle`).
* `test/support/test_support.exs` emits `project_slug` as a flat tracker key (`:191`) with a non-nil
  default (`:98`), so every config test travels the legacy alias path. It gains a provider-block
  option — the branch already added `tracker_provider:` and `tracker_any_labels:` knobs to harvest.

`Tracker` facade: both branches of the optional `scope_summary/1` dispatch — Linear delegates, memory
falls back to `"n/a"` — plus the unknown-kind path, which must return the fallback rather than raise.

`Linear.Adapter.preflight/1`: unknown team key, label absent from one listed team versus all listed
teams, unknown state name, a team with no active cycle producing a warning and `:ok`, and the
multiple-failures-in-one-error path.

Dashboard fixtures: all five pairs (`backoff_queue`, `credits_unlimited`, `idle`,
`idle_with_dashboard_url`, `super_busy`) change one line each — line 7 of `.snapshot.txt`, line 8 of
`.evidence.md` — from the broken project URL to the scope text, regenerated via `UPDATE_SNAPSHOTS=1`,
never hand-edited. Two code assertion sites move, not one: `orchestrator_status_test.exs:1183-1197`
(which also carries `refute rendered =~ "Dashboard:"` at `:1196`, a substring refute the scope text
must not trip) and `:1223-1226`. Rename the fixture slug from `project` to `acme-web` in the same
change so the artifacts stop reading as `project project`.

Live end-to-end (in scope, gated): `live_e2e_test.exs` is gated by `@moduletag :live_e2e` plus a
compile-time `@live_e2e_skip_reason` from `SYMPHONY_RUN_LIVE_E2E`, applied per test as `@tag skip:`,
and already resolves a team by key (`@default_team_key "SYME2E"`, `teams(filter: {key: {eq: $key}})`
at `:20-22`) and performs `projectCreate`, `issueCreate`, and `projectUpdate`. Extend it with one
scenario using `team_keys` plus `current_cycle` and no `project_slug`: create a cycle spanning now via
`cycleCreate(input: {teamId, startsAt, endsAt})` (fact 11), attach the seeded issue with
`issueUpdate(input: {cycleId: …})`, and assert the issue is dispatched. The existing flow dispatches
through `AgentRunner.run/3` directly and never exercises `fetch_issues_by_states`, so this scenario
must go through the scope query explicitly or it proves nothing about the filter.

This is worth the cost because a wrong reading of `cycle.isActive` fails silently as zero issues — the
worst failure mode in this change — and the scenario moves that assumption from "the schema says so"
to "observed against the real API". The branch's read-only `linear_scope_live_e2e_test.exs` is
harvested alongside it.

## Documentation

Same change, per `CLAUDE.md:72` and `elixir/AGENTS.md:70-77`:

* `SPEC.md` §11.1 item 2 (section 7 above), §17.3 `:2191-2193` and `:2202-2203`, §5.3.1 for
  `any_labels`, and the §11.2 adapter-profile obligation.
* `elixir/README.md:85-86` — an instance is scoped by teams, current cycle, project, labels, or a
  conjunction, not by a single project.
* `elixir/README.md:117` — the minimum edit for a new deployment.
* `elixir/README.md:229-231` — the provider-keys note and the legacy flat aliases.
* `elixir/README.md:346-397` — the Linear adapter profile: the new provider keys, the new error atoms,
  the retirement of `:missing_linear_project_slug`, the note at `:369` that scope governs scheduler
  reads and not raw tool calls, and critically `:354-356`, which currently states that ID refreshes
  are project-scoped.
* `elixir/README.md:380-388` (the flat error list) **and** `:390-394` (the portable error-category
  mapping required by `SPEC.md:1324-1325`). Both, not just the first.
* Root `README.md:31-32` — "one instance drives one project".
* `elixir/WORKFLOW.md` — mention the new keys; leave this repository's own configured scope on
  `project_slug`. Also `:109` and `:303-306`, which instruct agents that follow-up issues go "to the
  same project as the current issue" — unsatisfiable when no project is configured.
* `deploy/client-template/README.md:3` and `:31-38` — "one container, one project" becomes one
  container, one scope; the project-slug warning becomes a scope warning and can point at preflight
  instead of guesswork.
* `workflows/example.md:8` and `deploy/client-template/workflow.md:10-14` — keep `project_slug` as
  the default and add the new keys as commented alternatives.

The last three sit outside the documented Docs Update Policy, yet they are the files an operator
actually copies and the ones carrying the "silent failure, idle container" warnings.

## Risks

| Risk | Mitigation |
| -- | -- |
| `cycle.isActive` does not mean what the schema implies | Live E2E scenario above; the failure mode is loud there and silent in production |
| A team has no active cycle during cooldown | Boot warning names the team; the instance idles rather than crash-looping |
| Team key renamed mid-run | Preflight resolves keys at boot, so a rename stops matching until restart. Accepted: resolving to team IDs needs a cache invalidated on every `WorkflowStore` reload, more machinery than the failure justifies |
| Retry of an issue that left the scope | Accepted, section 6; the state lever stops it |
| Unscoped by-IDs read returns a foreign-workspace issue | Impossible with a workspace-bound API token |
| Preflight adds a boot-time network dependency | Accepted; a Linear outage at startup blocks boot where today it boots and polls unsuccessfully |
| Labels are team-scoped, so a label missing from one listed team narrows scope silently | Preflight warns per team, errors when missing from all |
| Wider scope means more issues fetched per tick | Paging already handles it; concurrency limits already bound dispatch |
| A future nested connection blows the complexity budget | Fact 7 documents the 10000 ceiling; `activeCycle` is a single object and cannot inflate it |
| Snapshot churn hides a real dashboard regression | Fixtures regenerated, never hand-edited; the diff is one line per pair |
| Sub-teams are not matched | `TeamFilter` exposes `parent` and `ancestors`; `team_keys` matches listed teams only. Deliberate — descending silently widens scope |

## Repo-state notes

The two prior designs cite line numbers from trees that have moved. Corrections that matter, verified
against `main` at `2100deb`:

* `linear/client.ex` is 729 lines, not 657; the attachments merge added `@attachment_page_size`, an
  `attachments(first: $attachmentFirst)` selection to both documents, `fetch_attachment/2`, and
  `extract_attachments/1`. It touched the same variable-declaration lines and variable maps this
  change rewrites, so the conflict surface is exactly the lines being changed — but the additions are
  orthogonal in meaning and compose mechanically with a `$filter` variable.
* The poll query attribute is `@query` (`client.ex:14-62`), not `@query_by_states`.
* Scope is not string-interpolated into the documents. Both are compile-time heredocs that hardcode
  the filter *shape* and pass only the slug as a `$projectSlug` variable. The structural problem is
  real; the "interpolation" framing in `WMP-14` is not.
* `SPEC.md` §11.1 item 2 is at `:1273-1274`, not `:1267-1268`.
* The "adapter owns its provider keys, core prescribes no cross-provider scope schema" rule is
  `SPEC.md:393-397` (§5.3.1), restated at `:1315-1325` (§11.2). It is **not** §13, which is Logging,
  Status, and Observability. `CLAUDE.md` does not contain this rule at all; the prohibition on core
  branching on provider semantics is `SPEC.md:1313-1314`.
* `Linear.Client` *is* in `coverage_ignore_modules` (`mix.exs:47`) and absent from
  `review_coverage_modules/0`, so it is exempt in both modes. `WMP-14`'s conclusion was right; its
  stated reason ("in neither list") was wrong.
* `present_string?` is at `adapter.ex:120-121`, not `:44-54`.
* The `is_binary(project_slug)` guard is at `client.ex:296-297` and guards the by-IDs path, not the
  by-states path.
* `revalidate_issue_for_dispatch/3`'s omission branch is at `orchestrator.ex:1038-1039` and
  `continue_with_issue?/2`'s at `agent_runner.ex:233-234`; both drifted one line.
* The Phoenix LiveView dashboard and JSON observability API are new since both designs and add no
  scope render site.
