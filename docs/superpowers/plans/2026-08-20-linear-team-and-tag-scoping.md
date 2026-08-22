# Linear Team + Tag Scoping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Linear tracker adapter scope issue reads by team keys plus label matching instead of a single project, so Linear projects are free to act as epics and adding one needs no Symphony config change.

**Architecture:** Add `provider.team_keys` (adapter-owned scope) and `tracker.any_labels` (core, OR-matching) to the config schema. Replace the two hard-coded project-scoped GraphQL query literals in `linear/client.ex` with one shared node selection plus a pure `build_issue_filter/2` that assembles a `IssueFilter` map, passed as a JSON variable. Keep `Issue.routable?/2` authoritative for label matching (the server filter is only a prefilter). Add an optional `preflight/1` callback to the `Tracker` behaviour so unknown team keys, labels, and state names fail at CLI startup instead of leaving the process silently idle.

**Tech Stack:** Elixir 1.19.x / OTP 28 (pinned via `mise`), Ecto embedded schemas for config, `Req` for HTTP, ExUnit, Linear GraphQL API.

**Spec:** `docs/superpowers/specs/2026-08-20-linear-team-and-tag-scoping-design.md`

## Global Constraints

- Run all `mix` commands from `elixir/`. Prefix with `mise exec --` outside a mise-activated shell.
- Every public function (`def`) in `lib/` needs an adjacent `@spec`. `defp` and `@impl` callbacks are exempt. Enforced by `mix specs.check`.
- Coverage threshold is **100%** (`mix test --cover`). Prefer adding tests over expanding the ignore list in `mix.exs`.
- Formatting: `line_length: 200`. Run `mix format` before every commit.
- Full gate before handoff: `make all` from `elixir/` (setup, build, fmt-check, lint, coverage, dialyzer).
- Add tracker capabilities through the `Tracker` behaviour only — never by branching in `AgentRunner` or calling an adapter directly (`CLAUDE.md` non-negotiable).
- All config access goes through `SymphonyElixir.Config` — never ad-hoc env reads.
- `SPEC.md` at the repo root is the source of truth. When implementation changes intended behavior, update `SPEC.md` in the same change.
- Linear filter comparators: use `eqIgnoreCase` for team keys, label names, and state names. `StringComparator` has `in` but **no** `inIgnoreCase`.
- Exact config field names: `tracker.provider.team_keys`, `tracker.any_labels`, `tracker.required_labels`, `tracker.provider.project_slug`.
- Exact new error atom: `:missing_linear_scope`.
- Test name filtering uses `-n "<pattern>"` (`--name-pattern`, Elixir 1.19+). There is no pytest-style `-k`.

## Baseline

Verified on this branch before any task ran: `mix test` → **391 tests, 1 failure, 6 skipped**.

That one failure is environmental, not a defect. `test/symphony_elixir/agent/claude_test.exs:33`
asserts the generated MCP config carries the literal string `"LINEAR_API_KEY"` as a secret
reference; when a real `LINEAR_API_KEY` is exported in the shell, the config carries the
resolved value instead and the assertion fails. Confirmed by
`env -u LINEAR_API_KEY mix test test/symphony_elixir/agent/claude_test.exs` → 24 tests, 0 failures.

**Run the suite with `env -u LINEAR_API_KEY` prefixed, or unset the variable in your shell.**
Otherwise you will chase a phantom failure through every task. Note also that the failure
diff prints the resolved key to the terminal, so avoid pasting that output anywhere.

Every "Expected: PASS" below means "green apart from this known baseline failure."

---

## File Structure

**Modified:**
- `elixir/lib/symphony_elixir/config/schema.ex` — add `any_labels` field + normalization; surface `team_keys` from the provider map in `finalize_settings/1`.
- `elixir/lib/symphony_elixir/tracker/issue.ex` — `routable?/2` takes a label-policy map.
- `elixir/lib/symphony_elixir/agent_runner.ex:258` — one-line caller update.
- `elixir/lib/symphony_elixir/orchestrator.ex:873` — one-line caller update; `:271` error clause.
- `elixir/lib/symphony_elixir/linear/client.ex` — collapse two query literals into one shared selection; add `build_issue_filter/2`; scope check.
- `elixir/lib/symphony_elixir/linear/adapter.ex` — `validate_config/1` scope rule; new `preflight/1`.
- `elixir/lib/symphony_elixir/tracker.ex` — optional `preflight/1` callback + dispatch.
- `elixir/lib/symphony_elixir/cli.ex` — call preflight after `ensure_all_started`.
- `elixir/lib/symphony_elixir/status_dashboard.ex:395` — scope line.
- `elixir/test/support/test_support.exs` — **must gain a `provider:` block writer** (it currently only writes flat tracker keys); no team-scoping test can be written before this.
- Docs: root `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, `workflows/example.md`, `deploy/client-template/workflow.md`, `deploy/client-template/README.md`.

**Created:**
- `elixir/test/symphony_elixir/linear_scope_test.exs` — filter builder, scope validation, preflight.

Task 1 exists solely because the test helper can't express a `provider:` block. Every later task's tests depend on it.

---

### Task 1: Teach the test helper to write a `provider:` block

**Files:**
- Modify: `elixir/test/support/test_support.exs:98` (defaults list), `:144` (extraction), `:191` (YAML emission)

**Interfaces:**
- Consumes: nothing.
- Produces: `write_workflow_file!(path, tracker_provider: %{"team_keys" => ["MDZ"]})` emits a nested `provider:` block under `tracker:`. Also `tracker_any_labels: ["bug-symphony"]` emits `any_labels:`. Default for both is `nil`, meaning the key is omitted entirely so all existing tests keep their current output byte-for-byte.

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
test "test helper emits a tracker provider block and any_labels" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_project_slug: nil,
    tracker_provider: %{"team_keys" => ["MDZ", "TRA"]},
    tracker_any_labels: ["bug-symphony", "feat-symphony"]
  )

  content = File.read!(Workflow.workflow_file_path())

  assert content =~ "  provider:"
  assert content =~ "    team_keys: [\"MDZ\", \"TRA\"]"
  assert content =~ "  any_labels: [\"bug-symphony\", \"feat-symphony\"]"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs -n "test helper emits a tracker provider block"`
Expected: FAIL — `write_workflow_file!` ignores the unknown `:tracker_provider` key, so `content =~ "  provider:"` is false.

- [ ] **Step 3: Add the defaults**

In `elixir/test/support/test_support.exs`, in the `Keyword.merge` defaults list (near `tracker_required_labels: []` at line ~100), add:

```elixir
          tracker_provider: nil,
          tracker_any_labels: nil,
```

- [ ] **Step 4: Extract the new values**

Next to `tracker_required_labels = Keyword.get(config, :tracker_required_labels)` (line ~146), add:

```elixir
    tracker_provider = Keyword.get(config, :tracker_provider)
    tracker_any_labels = Keyword.get(config, :tracker_any_labels)
```

- [ ] **Step 5: Emit the YAML**

In the `sections` list, replace the single `required_labels` line with the provider block, the optional `any_labels` line, and `required_labels`:

```elixir
        tracker_provider_yaml(tracker_provider),
        optional_tracker_line("any_labels", tracker_any_labels),
        "  required_labels: #{yaml_value(tracker_required_labels)}",
```

The `sections` list already ends with `|> Enum.reject(&(&1 in [nil, ""]))`, so returning `nil` omits a line.

Add these two private helpers next to `hooks_yaml/5`:

```elixir
  defp tracker_provider_yaml(nil), do: nil
  defp tracker_provider_yaml(provider) when provider == %{}, do: nil

  defp tracker_provider_yaml(provider) when is_map(provider) do
    entries =
      Enum.map(provider, fn {key, value} ->
        "    #{key}: #{yaml_value(value)}"
      end)

    Enum.join(["  provider:" | entries], "\n")
  end

  defp optional_tracker_line(_key, nil), do: nil
  defp optional_tracker_line(key, value), do: "  #{key}: #{yaml_value(value)}"
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs -n "test helper emits a tracker provider block"`
Expected: PASS

- [ ] **Step 7: Verify no existing test regressed**

Run: `mix test`
Expected: PASS — the new keys default to `nil` and are rejected from `sections`, so every existing workflow file is byte-identical.

- [ ] **Step 8: Format and commit**

```bash
mix format
git add test/support/test_support.exs test/symphony_elixir/workspace_and_config_test.exs
git commit -m "test: let the workflow helper write a tracker provider block and any_labels"
```

---

### Task 2: Config schema — `any_labels` and `team_keys`

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex:58` (field), `:75` (cast list), `:81` (normalization), `:444` (linear provider defaults), `:480` (tracker struct)
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- Consumes: Task 1's `tracker_provider:` / `tracker_any_labels:` helper keys.
- Produces: `Config.settings!().tracker.any_labels` is a `[String.t()]`, trimmed/downcased/deduped exactly like `required_labels`, default `[]`. `Config.settings!().tracker.team_keys` is a `[String.t()]`, trimmed and deduped but **not** case-folded, default `[]`, read from `provider["team_keys"]`.

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
test "any_labels normalizes like required_labels and team_keys come from the provider map" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_project_slug: nil,
    tracker_provider: %{"team_keys" => [" MDZ ", "MDZ", "TRA"]},
    tracker_any_labels: [" Bug-Symphony ", "BUG-SYMPHONY", "Feat-Symphony"]
  )

  tracker = Config.settings!().tracker

  assert tracker.any_labels == ["bug-symphony", "feat-symphony"]
  assert tracker.team_keys == ["MDZ", "TRA"]
end

test "any_labels and team_keys default to empty lists" do
  write_workflow_file!(Workflow.workflow_file_path())

  tracker = Config.settings!().tracker

  assert tracker.any_labels == []
  assert tracker.team_keys == []
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs -n "any_labels"`
Expected: FAIL with `KeyError` — `:any_labels` is not a key of the `Tracker` struct.

- [ ] **Step 3: Add both fields to the embedded schema**

In `elixir/lib/symphony_elixir/config/schema.ex`, inside `defmodule Tracker`, after `field(:required_labels, {:array, :string}, default: [])`:

```elixir
      field(:any_labels, {:array, :string}, default: [])
      field(:team_keys, {:array, :string}, default: [])
```

- [ ] **Step 4: Cast and normalize them**

In `Tracker.changeset/2`, add `:any_labels` to the cast field list (after `:required_labels`). Do **not** add `:team_keys` to the cast list — it is derived from the provider map in `finalize_settings/1`, not accepted as a top-level key.

Then add normalization after the existing `update_change(:required_labels, ...)` block:

```elixir
      |> update_change(:any_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
```

The existing `required_labels` normalizer is the model to match exactly: trim, downcase, `Enum.uniq/1`, and a blank entry normalizes to `""` (which `routable?` then matches against nothing). Do not add rejection of blanks — `SPEC.md` §5.3.1 specifies that a blank configured label matches no issue, and `workspace_and_config_test.exs:1067` asserts `[" "] -> [""]`.

- [ ] **Step 5: Derive `team_keys` from the provider map**

In `finalize_settings/1`, in the `"linear"` branch that builds `linear_provider` (around line 444), the provider map already carries `team_keys` verbatim from YAML — no `Map.put_new` needed, because there is no flat alias to fall back to.

In the `tracker = %{settings.tracker | ...}` struct update (around line 480), add:

```elixir
        team_keys: normalize_team_keys(Map.get(provider, "team_keys")),
```

Add this private helper alongside `normalize_optional_map/1`:

```elixir
  defp normalize_team_keys(keys) when is_list(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_team_keys(_keys), do: []
```

Blank team keys are rejected here rather than preserved, unlike labels: a blank label has defined "matches nothing" semantics in the spec, whereas a blank team key would just produce a junk `eqIgnoreCase: ""` clause.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs -n "any_labels"`
Expected: PASS (both tests)

- [ ] **Step 7: Format, lint, commit**

```bash
mix format
mix lint
git add lib/symphony_elixir/config/schema.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "feat: add tracker.any_labels and provider.team_keys config fields"
```

---

### Task 3: `routable?/2` takes a label policy map

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker/issue.ex:58-65`, `elixir/lib/symphony_elixir/agent_runner.ex:258`, `elixir/lib/symphony_elixir/orchestrator.ex:873`
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs` (7 existing call sites)

**Interfaces:**
- Consumes: `tracker.any_labels` and `tracker.required_labels` from Task 2.
- Produces: `Issue.routable?(issue, policy)` where `policy` is any map with `:required_labels` and `:any_labels` keys (the `Schema.Tracker` struct satisfies this). Returns `false` when `dispatchable` is false. Semantics: every `required_labels` entry present AND at least one `any_labels` entry present; an empty `any_labels` imposes no constraint.

- [ ] **Step 1: Write the failing tests**

Add to `elixir/test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
test "routable? requires all required_labels and at least one any_label" do
  issue = %Issue{
    id: "i-1",
    identifier: "MT-1",
    title: "Scoped",
    state: "Todo",
    labels: ["bug-symphony", "backend"],
    dispatchable: true
  }

  # any_labels: at least one match is enough
  assert Issue.routable?(issue, %{required_labels: [], any_labels: ["bug-symphony", "feat-symphony"]})

  # any_labels: no match rejects
  refute Issue.routable?(issue, %{required_labels: [], any_labels: ["feat-symphony"]})

  # empty any_labels imposes no constraint
  assert Issue.routable?(issue, %{required_labels: [], any_labels: []})

  # required_labels still ANDs
  assert Issue.routable?(issue, %{required_labels: ["backend"], any_labels: ["bug-symphony"]})
  refute Issue.routable?(issue, %{required_labels: ["frontend"], any_labels: ["bug-symphony"]})

  # both must hold together
  refute Issue.routable?(issue, %{required_labels: ["backend"], any_labels: ["feat-symphony"]})

  # case and whitespace insensitive on both lists
  assert Issue.routable?(issue, %{required_labels: [" BACKEND "], any_labels: [" Bug-Symphony "]})

  # a blank configured label matches nothing (SPEC 5.3.1)
  refute Issue.routable?(issue, %{required_labels: [""], any_labels: []})
  refute Issue.routable?(issue, %{required_labels: [], any_labels: [""]})

  # dispatchable: false always rejects
  refute Issue.routable?(%{issue | dispatchable: false}, %{required_labels: [], any_labels: []})
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs -n "routable? requires all required_labels"`
Expected: FAIL — `routable?/2` has a `when is_list(required_labels)` guard, so a map argument falls through to the `def routable?(%__MODULE__{}, _required_labels), do: false` clause and the first assertion fails.

- [ ] **Step 3: Implement the new predicate**

Replace the `routable?/2` clauses in `elixir/lib/symphony_elixir/tracker/issue.ex`:

```elixir
  @spec routable?(t(), map()) :: boolean()
  def routable?(%__MODULE__{dispatchable: true, labels: labels}, label_policy)
      when is_list(labels) and is_map(label_policy) do
    issue_labels = MapSet.new(labels, &normalize_label/1)

    required_labels = Map.get(label_policy, :required_labels) || []
    any_labels = Map.get(label_policy, :any_labels) || []

    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1))) and
      any_label_satisfied?(any_labels, issue_labels)
  end

  def routable?(%__MODULE__{}, _label_policy), do: false

  defp any_label_satisfied?([], _issue_labels), do: true

  defp any_label_satisfied?(any_labels, issue_labels) when is_list(any_labels) do
    Enum.any?(any_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end
```

`Map.get(..) || []` tolerates a policy map with the key present but `nil`, which a hand-built map in a test can easily produce.

- [ ] **Step 4: Update both `lib` call sites**

In `elixir/lib/symphony_elixir/agent_runner.ex` (~line 258) and `elixir/lib/symphony_elixir/orchestrator.ex` (~line 873), both read identically today:

```elixir
  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end
```

Change each to:

```elixir
  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker)
  end
```

The `Schema.Tracker` struct has both `:required_labels` and `:any_labels` keys after Task 2, so it satisfies the policy contract directly.

- [ ] **Step 5: Update the 7 existing test call sites**

In `elixir/test/symphony_elixir/workspace_and_config_test.exs`, rewrite each list argument as a policy map:

```elixir
Issue.routable?(issue, [])                          -> Issue.routable?(issue, %{required_labels: [], any_labels: []})
Issue.routable?(issue, ["symphony"])                -> Issue.routable?(issue, %{required_labels: ["symphony"], any_labels: []})
Issue.routable?(issue, ["SYMPHONY", "javascript"])  -> Issue.routable?(issue, %{required_labels: ["SYMPHONY", "javascript"], any_labels: []})
Issue.routable?(issue, ["symph"])                   -> Issue.routable?(issue, %{required_labels: ["symph"], any_labels: []})
Issue.routable?(issue, [" "])                       -> Issue.routable?(issue, %{required_labels: [" "], any_labels: []})
Issue.routable?(issue, ["symphony", "security"])    -> Issue.routable?(issue, %{required_labels: ["symphony", "security"], any_labels: []})
Issue.routable?(%{issue | dispatchable: false}, ["symphony"])
  -> Issue.routable?(%{issue | dispatchable: false}, %{required_labels: ["symphony"], any_labels: []})
```

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS. If a test outside `workspace_and_config_test.exs` fails on `routable?`, it is a call site this plan missed — fix it the same way.

- [ ] **Step 7: Format, lint, commit**

```bash
mix format
mix lint
git add lib/symphony_elixir/tracker/issue.ex lib/symphony_elixir/agent_runner.ex lib/symphony_elixir/orchestrator.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "feat: match any_labels alongside required_labels in Issue.routable?"
```

---

### Task 4: `build_issue_filter/2`

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/client.ex`
- Test: `elixir/test/symphony_elixir/linear_scope_test.exs` (create)

**Interfaces:**
- Consumes: `tracker.team_keys`, `tracker.any_labels`, `tracker.required_labels` from Task 2.
- Produces: `SymphonyElixir.Linear.Client.build_issue_filter(tracker_settings, opts)` where `opts` is a keyword list accepting `:state_names` (list of strings) and `:ids` (list of strings). Returns a map ready to serialize as a Linear `IssueFilter` JSON variable. Keys are atoms; `Jason` encodes them as the camelCase strings Linear expects because they are already written in camelCase (`slugId`, `eqIgnoreCase`).

This is a public function with a real `@spec` and `@doc` rather than a `_for_test` seam, because it is a pure transformation that both queries consume and it is the contract the live-API checks in the spec validated.

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/linear_scope_test.exs`:

```elixir
defmodule SymphonyElixir.LinearScopeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

  defp tracker(overrides) do
    Map.merge(
      %{
        kind: "linear",
        team_keys: [],
        project_slug: nil,
        any_labels: [],
        required_labels: []
      },
      overrides
    )
  end

  test "state names become a case-insensitive or clause" do
    filter = Client.build_issue_filter(tracker(%{project_slug: "p-1"}), state_names: ["Todo", "In Progress"])

    assert filter.state == %{
             or: [
               %{name: %{eqIgnoreCase: "Todo"}},
               %{name: %{eqIgnoreCase: "In Progress"}}
             ]
           }
  end

  test "team keys become a nested or conjunct" do
    filter = Client.build_issue_filter(tracker(%{team_keys: ["MDZ", "TRA"]}), state_names: ["Todo"])

    assert %{or: [%{team: %{key: %{eqIgnoreCase: "MDZ"}}}, %{team: %{key: %{eqIgnoreCase: "TRA"}}}]} in filter.and
  end

  test "project slug becomes a conjunct" do
    filter = Client.build_issue_filter(tracker(%{project_slug: "p-1"}), state_names: ["Todo"])

    assert %{project: %{slugId: %{eq: "p-1"}}} in filter.and
  end

  test "team keys and project slug are ANDed when both are set" do
    filter =
      Client.build_issue_filter(
        tracker(%{team_keys: ["MDZ"], project_slug: "p-1"}),
        state_names: ["Todo"]
      )

    assert %{or: [%{team: %{key: %{eqIgnoreCase: "MDZ"}}}]} in filter.and
    assert %{project: %{slugId: %{eq: "p-1"}}} in filter.and
  end

  test "any_labels become one or conjunct and required_labels one conjunct each" do
    filter =
      Client.build_issue_filter(
        tracker(%{
          team_keys: ["MDZ"],
          any_labels: ["bug-symphony", "feat-symphony"],
          required_labels: ["backend", "reviewed"]
        }),
        state_names: ["Todo"]
      )

    assert %{
             or: [
               %{labels: %{some: %{name: %{eqIgnoreCase: "bug-symphony"}}}},
               %{labels: %{some: %{name: %{eqIgnoreCase: "feat-symphony"}}}}
             ]
           } in filter.and

    assert %{labels: %{some: %{name: %{eqIgnoreCase: "backend"}}}} in filter.and
    assert %{labels: %{some: %{name: %{eqIgnoreCase: "reviewed"}}}} in filter.and
  end

  test "empty conjunct list omits the and key entirely" do
    filter = Client.build_issue_filter(tracker(%{}), state_names: ["Todo"])

    refute Map.has_key?(filter, :and)
    assert Map.has_key?(filter, :state)
  end

  test "ids are added for the by-ids query and state is omitted when absent" do
    filter = Client.build_issue_filter(tracker(%{project_slug: "p-1"}), ids: ["a", "b"])

    assert filter.id == %{in: ["a", "b"]}
    refute Map.has_key?(filter, :state)
    assert %{project: %{slugId: %{eq: "p-1"}}} in filter.and
  end

  test "the filter serializes to the JSON shape Linear accepts" do
    filter =
      Client.build_issue_filter(
        tracker(%{team_keys: ["MDZ"], any_labels: ["story"]}),
        state_names: ["To Do"]
      )

    decoded = filter |> Jason.encode!() |> Jason.decode!()

    assert decoded == %{
             "state" => %{"or" => [%{"name" => %{"eqIgnoreCase" => "To Do"}}]},
             "and" => [
               %{"or" => [%{"team" => %{"key" => %{"eqIgnoreCase" => "MDZ"}}}]},
               %{"or" => [%{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "story"}}}}]}
             ]
           }
  end
end
```

The last test is the important one: it asserts the exact JSON that was verified against the live Linear API, so a refactor that changes the shape fails loudly instead of returning zero issues.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/linear_scope_test.exs`
Expected: FAIL — `Client.build_issue_filter/2` is undefined.

- [ ] **Step 3: Implement the builder**

In `elixir/lib/symphony_elixir/linear/client.ex`, add:

```elixir
  @doc """
  Builds a Linear `IssueFilter` map for the configured scope.

  Team keys, label names, and state names are matched with `eqIgnoreCase`
  because Linear's `StringComparator` offers `in` but no `inIgnoreCase`, so a
  case-insensitive set match has to be an `or` list of single comparisons.

  Top-level keys AND with the `and` conjunct list, so the result reads as
  `state AND (team ...) AND project AND (any label ...) AND required label ...`.
  """
  @spec build_issue_filter(map(), keyword()) :: map()
  def build_issue_filter(tracker_settings, opts) when is_map(tracker_settings) and is_list(opts) do
    conjuncts =
      [
        team_conjunct(Map.get(tracker_settings, :team_keys) || []),
        project_conjunct(tracker_settings.project_slug),
        any_labels_conjunct(Map.get(tracker_settings, :any_labels) || [])
      ] ++ required_label_conjuncts(Map.get(tracker_settings, :required_labels) || [])

    %{}
    |> maybe_put_state(Keyword.get(opts, :state_names))
    |> maybe_put_ids(Keyword.get(opts, :ids))
    |> maybe_put_conjuncts(Enum.reject(conjuncts, &is_nil/1))
  end

  defp team_conjunct([]), do: nil

  defp team_conjunct(team_keys) do
    %{or: Enum.map(team_keys, &%{team: %{key: %{eqIgnoreCase: &1}}})}
  end

  defp project_conjunct(project_slug) when is_binary(project_slug) do
    if String.trim(project_slug) == "", do: nil, else: %{project: %{slugId: %{eq: project_slug}}}
  end

  defp project_conjunct(_project_slug), do: nil

  defp any_labels_conjunct([]), do: nil

  defp any_labels_conjunct(any_labels) do
    %{or: Enum.map(any_labels, &label_clause/1)}
  end

  defp required_label_conjuncts(required_labels), do: Enum.map(required_labels, &label_clause/1)

  defp label_clause(label), do: %{labels: %{some: %{name: %{eqIgnoreCase: label}}}}

  defp maybe_put_state(filter, state_names) when is_list(state_names) and state_names != [] do
    Map.put(filter, :state, %{or: Enum.map(state_names, &%{name: %{eqIgnoreCase: &1}})})
  end

  defp maybe_put_state(filter, _state_names), do: filter

  defp maybe_put_ids(filter, ids) when is_list(ids) and ids != [] do
    Map.put(filter, :id, %{in: ids})
  end

  defp maybe_put_ids(filter, _ids), do: filter

  defp maybe_put_conjuncts(filter, []), do: filter
  defp maybe_put_conjuncts(filter, conjuncts), do: Map.put(filter, :and, conjuncts)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/linear_scope_test.exs`
Expected: PASS (8 tests)

- [ ] **Step 5: Format, lint, commit**

```bash
mix format
mix lint
git add lib/symphony_elixir/linear/client.ex test/symphony_elixir/linear_scope_test.exs
git commit -m "feat: build Linear IssueFilter maps for team and label scoping"
```

---

### Task 5: Wire the builder into both queries

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/client.ex` (`@query`, `@query_by_ids`, `do_fetch_by_states_page/5`, `do_fetch_issue_states_page/6`, `configured_tracker_for_read/0`, `fetch_issues_by_ids_for_test/2`)
- Test: `elixir/test/symphony_elixir/linear_scope_test.exs`

**Interfaces:**
- Consumes: `build_issue_filter/2` from Task 4.
- Produces: both GraphQL operations take `$filter: IssueFilter!`. `configured_tracker_for_read/0` returns `{:error, :missing_linear_scope}` when neither `team_keys` nor `project_slug` is configured. `fetch_issues_by_ids_for_test/2` keeps its arity and its `graphql_fun` seam.

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/linear_scope_test.exs`:

```elixir
  test "the by-ids query passes a filter variable carrying the requested ids" do
    parent = self()

    graphql_fun = fn query, variables ->
      send(parent, {:graphql, query, variables})

      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_ids_for_test(["id-1", "id-2"], graphql_fun)

    assert_receive {:graphql, query, variables}
    assert query =~ "$filter: IssueFilter!"
    refute query =~ "$projectSlug"
    assert variables.filter.id == %{in: ["id-1", "id-2"]}
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/linear_scope_test.exs -n "by-ids query passes a filter variable"`
Expected: FAIL — the current query declares `$projectSlug: String!` and the variables map has a `:projectSlug` key, not `:filter`.

- [ ] **Step 3: Extract the shared node selection**

In `elixir/lib/symphony_elixir/linear/client.ex`, replace the two `@query` / `@query_by_ids` attributes with one shared selection plus two thin operations. The node selection below is copied verbatim from the existing `@query`:

```elixir
  @issue_fields """
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        attachments(first: $attachmentFirst) {
          nodes {
            title
            url
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
  """

  @query """
  query SymphonyLinearPoll($filter: IssueFilter!, $first: Int!, $relationFirst: Int!, $attachmentFirst: Int!, $after: String) {
    issues(filter: $filter, first: $first, after: $after) {
  #{@issue_fields}
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($filter: IssueFilter!, $first: Int!, $relationFirst: Int!, $attachmentFirst: Int!) {
    issues(filter: $filter, first: $first) {
  #{@issue_fields}
    }
  }
  """
```

- [ ] **Step 4: Pass the filter instead of the slug**

Replace the `graphql/2` call inside `do_fetch_by_states_page/5`:

```elixir
    with {:ok, body} <-
           graphql(@query, %{
             filter: build_issue_filter(tracker, state_names: state_names),
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             attachmentFirst: @attachment_page_size,
             after: after_cursor
           }),
```

and inside `do_fetch_issue_states_page/6`:

```elixir
    case graphql_fun.(@query_by_ids, %{
           filter: build_issue_filter(tracker, ids: batch_ids),
           first: length(batch_ids),
           relationFirst: @issue_page_size,
           attachmentFirst: @attachment_page_size
         }) do
```

Both private functions currently thread a `project_slug` string. Change that parameter to the whole `tracker` map in each function head and recursive call — `do_fetch_by_states/3`, `do_fetch_by_states_page/5`, `do_fetch_issue_states/3`, `do_fetch_issue_states/4`, `do_fetch_issue_states_page/6` — and update `fetch_issues_by_states/1` and `fetch_issues_by_ids/1` to pass `tracker` instead of `tracker.project_slug`. Drop the `when is_binary(project_slug)` guard on `do_fetch_issue_states/4`.

In `fetch_issues_by_ids_for_test/2`, replace the `"test-project"` literal with a minimal tracker map so the seam keeps working:

```elixir
        do_fetch_issue_states(ids, %{project_slug: "test-project", team_keys: [], any_labels: [], required_labels: []}, nil, graphql_fun)
```

- [ ] **Step 5: Accept either scope in the read guard**

Replace `configured_tracker_for_read/0`:

```elixir
  defp configured_tracker_for_read do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_linear_api_token}
      not scoped?(tracker) -> {:error, :missing_linear_scope}
      true -> {:ok, tracker}
    end
  end

  defp scoped?(%{team_keys: team_keys}) when is_list(team_keys) and team_keys != [], do: true
  defp scoped?(%{project_slug: project_slug}) when is_binary(project_slug), do: String.trim(project_slug) != ""
  defp scoped?(_tracker), do: false
```

- [ ] **Step 6: Run the new test, then the full suite**

Run: `mix test test/symphony_elixir/linear_scope_test.exs`
Expected: PASS

Run: `mix test`
Expected: FAIL in `core_test.exs` at the four `:missing_linear_project_slug` assertions (lines ~46, ~60, ~290, ~328). That is expected — Task 6 owns those, because the atom is also matched in `adapter.ex` and `orchestrator.ex`. Do not fix them here.

- [ ] **Step 7: Commit the working slice**

```bash
mix format
git add lib/symphony_elixir/linear/client.ex test/symphony_elixir/linear_scope_test.exs
git commit -m "refactor: pass a built IssueFilter variable to both Linear queries"
```

---

### Task 6: `:missing_linear_scope` end to end

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex:48-52`, `elixir/lib/symphony_elixir/orchestrator.ex:270-273`
- Test: `elixir/test/symphony_elixir/linear_scope_test.exs`, `elixir/test/symphony_elixir/core_test.exs` (4 assertions)

**Interfaces:**
- Consumes: `tracker.team_keys` from Task 2, `scoped?/1` semantics from Task 5.
- Produces: `Linear.Adapter.validate_config/1` returns `{:error, :missing_linear_scope}` when neither scope is set, and `:ok` when either or both are. `:missing_linear_project_slug` no longer exists anywhere in `lib/`.

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/linear_scope_test.exs`:

```elixir
  describe "validate_config scope rules" do
    alias SymphonyElixir.Linear.Adapter

    defp settings(overrides) do
      Map.merge(
        %{
          endpoint: "https://api.linear.app/graphql",
          api_key: "token",
          project_slug: nil,
          team_keys: [],
          assignee: nil,
          any_labels: [],
          required_labels: [],
          secret_environment_names: []
        },
        overrides
      )
    end

    test "neither scope is an error" do
      assert {:error, :missing_linear_scope} = Adapter.validate_config(settings(%{}))
    end

    test "a blank project slug with no team keys is an error" do
      assert {:error, :missing_linear_scope} = Adapter.validate_config(settings(%{project_slug: "  "}))
    end

    test "project slug alone is valid" do
      assert :ok = Adapter.validate_config(settings(%{project_slug: "p-1"}))
    end

    test "team keys alone are valid" do
      assert :ok = Adapter.validate_config(settings(%{team_keys: ["MDZ"]}))
    end

    test "both together are valid" do
      assert :ok = Adapter.validate_config(settings(%{team_keys: ["MDZ"], project_slug: "p-1"}))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/linear_scope_test.exs -n "validate_config scope rules"`
Expected: FAIL — `validate_config/1` returns `{:error, :missing_linear_project_slug}` for the first two and `{:error, :missing_linear_project_slug}` for "team keys alone".

- [ ] **Step 3: Change the adapter guard**

In `elixir/lib/symphony_elixir/linear/adapter.ex`, replace this clause of the `cond` in `validate_config/1`:

```elixir
      not present_string?(tracker_settings.project_slug) ->
        {:error, :missing_linear_project_slug}
```

with:

```elixir
      not scoped?(tracker_settings) ->
        {:error, :missing_linear_scope}
```

and add the private helper next to `present_string?/1`:

```elixir
  defp scoped?(%{team_keys: team_keys}) when is_list(team_keys) and team_keys != [], do: true
  defp scoped?(%{project_slug: project_slug}), do: present_string?(project_slug)
  defp scoped?(_tracker_settings), do: false
```

Elixir tries the clauses in order, so a settings map with a non-empty `team_keys` matches the first clause and one with only a slug falls to the second.

- [ ] **Step 4: Update the orchestrator log clause**

In `elixir/lib/symphony_elixir/orchestrator.ex` (~line 270), replace:

```elixir
      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        state
```

with:

```elixir
      {:error, :missing_linear_scope} ->
        Logger.error("Tracker scope missing in WORKFLOW.md: set tracker.provider.team_keys or tracker.provider.project_slug")
        state
```

- [ ] **Step 5: Update the four `core_test.exs` assertions**

Change `:missing_linear_project_slug` to `:missing_linear_scope` at `core_test.exs` lines ~46, ~60, ~290, and ~328. Confirm none remain:

Run: `grep -rn "missing_linear_project_slug" lib/ test/`
Expected: no output.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS

- [ ] **Step 7: Format, lint, commit**

```bash
mix format
mix lint
git add lib/symphony_elixir/linear/adapter.ex lib/symphony_elixir/orchestrator.ex test/symphony_elixir/linear_scope_test.exs test/symphony_elixir/core_test.exs
git commit -m "feat: accept team keys or project slug as the Linear read scope"
```

---

### Task 7: `Tracker.preflight/1` behaviour callback

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `SymphonyElixir.Tracker.preflight(tracker_settings)` returns `:ok` when the selected adapter does not export `preflight/1`, otherwise the adapter's result. Callback signature `@callback preflight(map()) :: :ok | {:error, term()}`, listed in `@optional_callbacks`.

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/extensions_test.exs`:

```elixir
  test "Tracker.preflight is a no-op for adapters that do not implement it" do
    # the memory adapter does not export preflight/1
    assert :ok = SymphonyElixir.Tracker.preflight(%{kind: "memory"})
  end

  test "Tracker.preflight delegates to an adapter that implements it" do
    assert :ok = SymphonyElixir.Tracker.preflight(%{kind: "linear", team_keys: [], project_slug: "p-1"})
  end
```

The second test passes trivially once `Linear.Adapter.preflight/1` exists (Task 8) and short-circuits with no team keys; keep it here so the dispatch path is covered by both branches.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/extensions_test.exs -n "Tracker.preflight"`
Expected: FAIL — `SymphonyElixir.Tracker.preflight/1` is undefined.

- [ ] **Step 3: Add the callback and dispatch**

In `elixir/lib/symphony_elixir/tracker.ex`, add the callback next to `validate_config`:

```elixir
  @callback preflight(map()) :: :ok | {:error, term()}
```

Add `preflight: 1` to `@optional_callbacks`:

```elixir
  @optional_callbacks agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      validate_config: 1,
                      preflight: 1,
                      create_comment: 2,
                      update_issue_state: 2
```

Add the dispatch function, mirroring `validate_config/1` immediately above it:

```elixir
  @doc """
  Resolves adapter-side configuration against the live tracker once at startup.

  Scope selectors that do not exist usually produce an empty result set rather
  than an error, which leaves the process running with nothing to do. Adapters
  that can detect that implement this callback; others inherit the `:ok` default.
  """
  @spec preflight(map()) :: :ok | {:error, term()}
  def preflight(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :preflight, 1) do
        adapter.preflight(tracker_settings)
      else
        :ok
      end
    end
  end
```

- [ ] **Step 4: Add a temporary stub so the second test passes**

Add to `elixir/lib/symphony_elixir/linear/adapter.ex` (Task 8 replaces the body):

```elixir
  @spec preflight(map()) :: :ok | {:error, term()}
  def preflight(_tracker_settings), do: :ok
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/extensions_test.exs -n "Tracker.preflight"`
Expected: PASS (both)

- [ ] **Step 6: Format, lint, commit**

```bash
mix format
mix lint
git add lib/symphony_elixir/tracker.ex lib/symphony_elixir/linear/adapter.ex test/symphony_elixir/extensions_test.exs
git commit -m "feat: add an optional Tracker.preflight callback"
```

---

### Task 8: Linear preflight resolves teams, states, and labels

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Test: `elixir/test/symphony_elixir/linear_scope_test.exs`

**Interfaces:**
- Consumes: `Tracker.preflight/1` dispatch from Task 7; `client_module().graphql/2` (already the adapter's injection seam via `Application.get_env(:symphony_elixir, :linear_client_module, Client)`).
- Produces: `Linear.Adapter.preflight/1` returns `:ok`, or `{:error, {:linear_preflight_failed, [String.t()]}}` where the list holds one human-readable line per unresolved value. Returns `:ok` immediately when `team_keys` is empty (project-only deploys keep their current startup behavior).

Two GraphQL requests regardless of how many teams, labels, or states are configured.

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/linear_scope_test.exs`:

```elixir
  describe "preflight" do
    alias SymphonyElixir.Linear.Adapter

    defmodule StubClient do
      @moduledoc false

      @spec graphql(String.t(), map()) :: {:ok, map()} | {:error, term()}
      def graphql(query, _variables) do
        responses = Process.get(:preflight_responses, %{})

        cond do
          query =~ "teams(" -> Map.fetch!(responses, :teams)
          query =~ "issueLabels(" -> Map.fetch!(responses, :labels)
        end
      end
    end

    setup do
      previous = Application.get_env(:symphony_elixir, :linear_client_module)
      Application.put_env(:symphony_elixir, :linear_client_module, StubClient)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:symphony_elixir, :linear_client_module)
        else
          Application.put_env(:symphony_elixir, :linear_client_module, previous)
        end
      end)

      :ok
    end

    defp stub(teams, labels) do
      Process.put(:preflight_responses, %{teams: {:ok, teams}, labels: {:ok, labels}})
    end

    defp teams_response(teams) do
      %{
        "data" => %{
          "teams" => %{
            "nodes" =>
              Enum.map(teams, fn {key, states} ->
                %{"key" => key, "states" => %{"nodes" => Enum.map(states, &%{"name" => &1})}}
              end)
          }
        }
      }
    end

    defp labels_response(pairs) do
      %{
        "data" => %{
          "issueLabels" => %{
            "nodes" => Enum.map(pairs, fn {name, team} -> %{"name" => name, "team" => %{"key" => team}} end)
          }
        }
      }
    end

    defp scoped_settings(overrides) do
      Map.merge(
        %{
          endpoint: "https://api.linear.app/graphql",
          api_key: "token",
          project_slug: nil,
          team_keys: ["MDZ"],
          any_labels: ["bug-symphony"],
          required_labels: [],
          active_states: ["To Do"],
          terminal_states: ["Done"]
        },
        overrides
      )
    end

    test "everything resolving is ok" do
      stub(teams_response([{"MDZ", ["To Do", "Done"]}]), labels_response([{"bug-symphony", "MDZ"}]))

      assert :ok = Adapter.preflight(scoped_settings(%{}))
    end

    test "no team keys short-circuits without a request" do
      # StubClient would raise KeyError if called, since no responses are stubbed
      assert :ok = Adapter.preflight(scoped_settings(%{team_keys: [], project_slug: "p-1"}))
    end

    test "an unknown team key is reported" do
      stub(teams_response([]), labels_response([]))

      assert {:error, {:linear_preflight_failed, reasons}} =
               Adapter.preflight(scoped_settings(%{team_keys: ["NOPE"]}))

      assert Enum.any?(reasons, &(&1 =~ "team key" and &1 =~ "NOPE"))
    end

    test "an unknown state name is reported" do
      stub(teams_response([{"MDZ", ["To Do"]}]), labels_response([{"bug-symphony", "MDZ"}]))

      assert {:error, {:linear_preflight_failed, reasons}} =
               Adapter.preflight(scoped_settings(%{active_states: ["Todo"]}))

      assert Enum.any?(reasons, &(&1 =~ "state" and &1 =~ "Todo"))
    end

    test "a label missing from every listed team is an error" do
      stub(teams_response([{"MDZ", ["To Do", "Done"]}]), labels_response([]))

      assert {:error, {:linear_preflight_failed, reasons}} =
               Adapter.preflight(scoped_settings(%{}))

      assert Enum.any?(reasons, &(&1 =~ "bug-symphony"))
    end

    test "a label present in one of two listed teams is not an error" do
      stub(
        teams_response([{"MDZ", ["To Do", "Done"]}, {"TRA", ["To Do", "Done"]}]),
        labels_response([{"bug-symphony", "MDZ"}])
      )

      assert :ok = Adapter.preflight(scoped_settings(%{team_keys: ["MDZ", "TRA"]}))
    end

    test "every unresolved value is reported in one error" do
      stub(teams_response([{"MDZ", ["To Do"]}]), labels_response([]))

      assert {:error, {:linear_preflight_failed, reasons}} =
               Adapter.preflight(
                 scoped_settings(%{team_keys: ["MDZ", "NOPE"], active_states: ["Todo"], any_labels: ["bug-symphony"]})
               )

      assert length(reasons) >= 3
    end

    test "a transport error propagates unchanged" do
      Process.put(:preflight_responses, %{teams: {:error, :timeout}, labels: {:ok, labels_response([])}})

      assert {:error, :timeout} = Adapter.preflight(scoped_settings(%{}))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/linear_scope_test.exs -n "preflight"`
Expected: FAIL — the Task 7 stub returns `:ok` unconditionally, so every error-case test fails.

- [ ] **Step 3: Implement preflight**

In `elixir/lib/symphony_elixir/linear/adapter.ex`, add the two queries next to the existing module attributes:

```elixir
  @teams_preflight_query """
  query SymphonyPreflightTeams($filter: TeamFilter!) {
    teams(filter: $filter) {
      nodes {
        key
        states {
          nodes {
            name
          }
        }
      }
    }
  }
  """

  @labels_preflight_query """
  query SymphonyPreflightLabels($filter: IssueLabelFilter!) {
    issueLabels(filter: $filter) {
      nodes {
        name
        team {
          key
        }
      }
    }
  }
  """
```

Replace the Task 7 stub with:

```elixir
  @spec preflight(map()) :: :ok | {:error, term()}
  def preflight(tracker_settings) do
    case Map.get(tracker_settings, :team_keys) || [] do
      [] ->
        :ok

      team_keys ->
        with {:ok, teams} <- fetch_preflight_teams(team_keys),
             {:ok, labels} <- fetch_preflight_labels(preflight_label_names(tracker_settings)) do
          report_preflight(team_keys, teams, labels, tracker_settings)
        end
    end
  end

  defp preflight_label_names(tracker_settings) do
    ((Map.get(tracker_settings, :any_labels) || []) ++ (Map.get(tracker_settings, :required_labels) || []))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.uniq()
  end

  defp fetch_preflight_teams(team_keys) do
    filter = %{or: Enum.map(team_keys, &%{key: %{eqIgnoreCase: &1}})}

    case client_module().graphql(@teams_preflight_query, %{filter: filter}) do
      {:ok, %{"data" => %{"teams" => %{"nodes" => nodes}}}} when is_list(nodes) -> {:ok, nodes}
      {:ok, _body} -> {:error, :linear_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_preflight_labels([]), do: {:ok, []}

  defp fetch_preflight_labels(label_names) do
    filter = %{or: Enum.map(label_names, &%{name: %{eqIgnoreCase: &1}})}

    case client_module().graphql(@labels_preflight_query, %{filter: filter}) do
      {:ok, %{"data" => %{"issueLabels" => %{"nodes" => nodes}}}} when is_list(nodes) -> {:ok, nodes}
      {:ok, _body} -> {:error, :linear_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp report_preflight(team_keys, teams, labels, tracker_settings) do
    resolved_keys = MapSet.new(teams, &String.downcase(&1["key"] || ""))

    unknown_teams =
      team_keys
      |> Enum.reject(&MapSet.member?(resolved_keys, String.downcase(&1)))
      |> Enum.map(&"unknown Linear team key #{inspect(&1)}")

    known_states =
      teams
      |> Enum.flat_map(fn team -> get_in(team, ["states", "nodes"]) || [] end)
      |> MapSet.new(&String.downcase(&1["name"] || ""))

    configured_states =
      ((Map.get(tracker_settings, :active_states) || []) ++ (Map.get(tracker_settings, :terminal_states) || []))
      |> Enum.uniq()

    unknown_states =
      configured_states
      |> Enum.reject(&MapSet.member?(known_states, String.downcase(&1)))
      |> Enum.map(&"state name #{inspect(&1)} does not exist in any listed team")

    label_teams =
      Enum.reduce(labels, %{}, fn label, acc ->
        name = String.downcase(label["name"] || "")
        team_key = String.downcase(get_in(label, ["team", "key"]) || "")

        Map.update(acc, name, MapSet.new([team_key]), &MapSet.put(&1, team_key))
      end)

    unknown_labels =
      tracker_settings
      |> preflight_label_names()
      |> Enum.reject(&Map.has_key?(label_teams, String.downcase(&1)))
      |> Enum.map(&"label #{inspect(&1)} does not exist in any listed team")

    case unknown_teams ++ unknown_states ++ unknown_labels do
      [] -> :ok
      reasons -> {:error, {:linear_preflight_failed, reasons}}
    end
  end
```

A label present in some but not all listed teams resolves to `:ok` because `unknown_labels` only rejects names absent from `label_teams` entirely — matching the spec's "missing from one listed team is a warning, missing from all of them is an error."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/linear_scope_test.exs -n "preflight"`
Expected: PASS (8 tests)

- [ ] **Step 5: Format, lint, commit**

```bash
mix format
mix lint
git add lib/symphony_elixir/linear/adapter.ex test/symphony_elixir/linear_scope_test.exs
git commit -m "feat: resolve Linear teams, states, and labels at preflight"
```

---

### Task 9: Call preflight at CLI startup

**Files:**
- Modify: `elixir/lib/symphony_elixir/cli.ex:80-96` (`run/2`), `:20-30` (`deps` type), `:105-115` (`runtime_deps/1`)
- Test: `elixir/test/symphony_elixir/cli_test.exs`

**Interfaces:**
- Consumes: `Tracker.preflight/1` from Task 7.
- Produces: `CLI.run/2` returns `{:error, message}` when preflight fails, after `ensure_all_started` succeeds. New injectable dep key `:preflight` defaulting to a closure over `SymphonyElixir.Tracker.preflight/1` with the current settings.

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/cli_test.exs`:

```elixir
  test "run reports a preflight failure instead of starting silently idle" do
    workflow_path = Path.join(System.tmp_dir!(), "cli_preflight_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n---\nprompt\n")
    on_exit(fn -> File.rm(workflow_path) end)

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, []} end,
      preflight: fn -> {:error, {:linear_preflight_failed, ["unknown Linear team key \"NOPE\""]}} end
    }

    assert {:error, message} = SymphonyElixir.CLI.run(workflow_path, deps)
    assert message =~ "NOPE"
  end

  test "run succeeds when preflight passes" do
    workflow_path = Path.join(System.tmp_dir!(), "cli_preflight_ok_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n---\nprompt\n")
    on_exit(fn -> File.rm(workflow_path) end)

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, []} end,
      preflight: fn -> :ok end
    }

    assert :ok = SymphonyElixir.CLI.run(workflow_path, deps)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/cli_test.exs -n "preflight"`
Expected: FAIL — `run/2` ignores the `:preflight` dep and returns `:ok` for both.

- [ ] **Step 3: Call preflight in `run/2`**

In `elixir/lib/symphony_elixir/cli.ex`, replace the `case deps.ensure_all_started.() do` block inside `run/2`:

```elixir
      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          case run_preflight(deps) do
            :ok ->
              :ok

            {:error, reason} ->
              {:error, "Tracker preflight failed for workflow #{expanded_path}: #{format_preflight_error(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
```

Add the two private helpers next to `ensure_linear_mcp_started/1`:

```elixir
  defp run_preflight(deps) do
    deps
    |> Map.get(:preflight, fn -> :ok end)
    |> then(& &1.())
  end

  defp format_preflight_error({:linear_preflight_failed, reasons}) when is_list(reasons) do
    Enum.join(reasons, "; ")
  end

  defp format_preflight_error(reason), do: inspect(reason)
```

`Map.get/3` with a default mirrors how `ensure_linear_mcp_started/1` already tolerates a deps map without that key, so existing `cli_test.exs` deps maps keep working untouched.

- [ ] **Step 4: Add the dep to the type and to `runtime_deps/1`**

In the `@type deps` map, add:

```elixir
          optional(:preflight) => (-> :ok | {:error, term()}),
```

In `runtime_deps/1`, add:

```elixir
      preflight: fn -> SymphonyElixir.Tracker.preflight(SymphonyElixir.Config.settings!().tracker) end,
```

- [ ] **Step 5: Run the tests, then the full suite**

Run: `mix test test/symphony_elixir/cli_test.exs`
Expected: PASS

Run: `mix test`
Expected: PASS

- [ ] **Step 6: Format, lint, commit**

```bash
mix format
mix lint
git add lib/symphony_elixir/cli.ex test/symphony_elixir/cli_test.exs
git commit -m "feat: fail startup when tracker preflight cannot resolve the scope"
```

---

### Task 10: Status board scope line

**Files:**
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex:395-415`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs:1223`

**Interfaces:**
- Consumes: `tracker.team_keys`, `tracker.any_labels`, `tracker.required_labels` from Task 2.
- Produces: the line keeps its `│ Project: <url>` form when `team_keys` is empty (existing snapshot fixtures stay byte-identical) and becomes `│ Scope: <team keys> · <labels>` when `team_keys` is set.

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/orchestrator_status_test.exs`, next to the existing `assert rendered =~ "│ Project:"` assertion:

```elixir
  test "status board shows team scope when team keys are configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_provider: %{"team_keys" => ["MDZ", "TRA"]},
      tracker_any_labels: ["bug-symphony"]
    )

    rendered = StatusDashboard.format_project_link_lines_for_test()

    assert rendered =~ "Scope:"
    assert rendered =~ "MDZ, TRA"
    assert rendered =~ "bug-symphony"
    refute rendered =~ "linear.app/project"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/orchestrator_status_test.exs -n "status board shows team scope"`
Expected: FAIL — `format_project_link_lines_for_test/0` is undefined.

- [ ] **Step 3: Add the team-scoped branch**

In `elixir/lib/symphony_elixir/status_dashboard.ex`, replace `format_project_link_lines/0`'s scope computation:

```elixir
  defp format_project_link_lines do
    {label, scope_part} =
      case Config.settings!().tracker do
        %{kind: "linear", team_keys: team_keys} = tracker when is_list(team_keys) and team_keys != [] ->
          {"Scope", colorize(format_team_scope(tracker), @ansi_cyan)}

        %{kind: "linear", project_slug: project_slug}
        when is_binary(project_slug) and project_slug != "" ->
          {"Project", colorize(linear_project_url(project_slug), @ansi_cyan)}

        _ ->
          {"Project", colorize("n/a", @ansi_gray)}
      end

    project_line = colorize("│ #{label}: ", @ansi_bold) <> scope_part

    case dashboard_url() do
      url when is_binary(url) ->
        [project_line, colorize("│ Dashboard: ", @ansi_bold) <> colorize(url, @ansi_cyan)]

      _ ->
        [project_line]
    end
  end

  defp format_team_scope(tracker) do
    labels = (Map.get(tracker, :any_labels) || []) ++ (Map.get(tracker, :required_labels) || [])

    case labels do
      [] -> Enum.join(tracker.team_keys, ", ")
      labels -> Enum.join(tracker.team_keys, ", ") <> " · " <> Enum.join(labels, ", ")
    end
  end
```

Add the test seam alongside the file's other `_for_test` functions:

```elixir
  @doc false
  @spec format_project_link_lines_for_test() :: String.t()
  def format_project_link_lines_for_test, do: Enum.join(format_project_link_lines(), "\n")
```

- [ ] **Step 4: Run the test, then the snapshot suite**

Run: `mix test test/symphony_elixir/orchestrator_status_test.exs -n "status board shows team scope"`
Expected: PASS

Run: `mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`
Expected: PASS with **zero** fixture changes. The five snapshots all use the default `project_slug: "project"` and no team keys, so they take the `Project` branch unchanged. If any snapshot diff appears, the first clause is matching when it should not.

- [ ] **Step 5: Format, lint, commit**

```bash
mix format
mix lint
git add lib/symphony_elixir/status_dashboard.ex test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat: show team and label scope on the status board"
```

---

### Task 11: Documentation

**Files:**
- Modify: `SPEC.md` (§5.3.1 ~line 397, §6.4 ~line 666, §8.2 ~line 822, Linear adapter profile), `elixir/README.md` (~line 232 notes, ~line 350 adapter profile), `elixir/WORKFLOW.md` (~line 5), `workflows/example.md` (~line 8), `deploy/client-template/workflow.md` (~line 14), `deploy/client-template/README.md` (~line 31)

**Interfaces:**
- Consumes: the final behavior from Tasks 2–10.
- Produces: no code. `SPEC.md` is the source of truth and must not contradict the implementation.

- [ ] **Step 1: `SPEC.md` §5.3.1 — add `any_labels`**

After the `required_labels` bullet list, add:

```markdown
- `any_labels` (list of strings)
  - Default: `[]`.
  - When non-empty, an issue MUST contain at least one configured label to dispatch or
    continue. An empty list imposes no constraint.
  - Matching ignores case and surrounding whitespace.
  - A blank configured label matches no issue.
  - Composes with `required_labels` as a conjunction: all of `required_labels` AND at least
    one of `any_labels`.
```

- [ ] **Step 2: `SPEC.md` §6.4 — cheat sheet**

After the `tracker.required_labels` line, add:

```markdown
- `tracker.any_labels`: list of strings, default `[]`
```

- [ ] **Step 3: `SPEC.md` §8.2 — candidate selection**

Change the bullet `- It contains every label in `tracker.required_labels`.` to two bullets:

```markdown
- It contains every label in `tracker.required_labels`.
- If `tracker.any_labels` is non-empty, it contains at least one of those labels.
```

And in the paragraph below, change "all `tracker.required_labels` match" to "all `tracker.required_labels` and, when non-empty, at least one `tracker.any_labels` match".

- [ ] **Step 4: `SPEC.md` Linear adapter profile — scope paragraph**

Replace the "Scope and paging" bullet's project-only wording with:

```markdown
- Scope and paging: candidate reads filter the configured scope and requested state names,
  following Linear pages of 50. Scope is `provider.team_keys`, `provider.project_slug`, or
  both; at least one is REQUIRED, and both together are a conjunction. Team keys, label
  names, and state names are compared case-insensitively. ID refreshes apply the same scope
  and batch up to 50 IDs. Empty state/ID lists return `{:ok, []}` without a Linear request.
- Preflight: at startup the adapter resolves configured team keys, `active_states`,
  `terminal_states`, and label names against Linear and fails startup listing every value
  that does not resolve. This exists because an unknown scope selector returns an empty
  result set rather than an error.
```

- [ ] **Step 5: `elixir/README.md` — notes list**

After the `tracker.required_labels` note (~line 232), add:

```markdown
- `tracker.any_labels` is optional. When set, an issue must have at least one of the
  configured labels to dispatch or continue running. It composes with `required_labels` as
  a conjunction: all required labels AND at least one of these. Matching ignores case and
  surrounding whitespace.
```

- [ ] **Step 6: `elixir/README.md` — Linear adapter profile**

Change the config bullet's `required project_slug` to:

```markdown
- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), a scope — `team_keys` (list of Linear team keys such as `["MDZ"]`),
  `project_slug`, or both, at least one required — and optional `assignee` (a Linear user
  ID or `me`, defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases
  remain supported; `team_keys` is provider-only. `required_labels`, `any_labels`,
  `active_states`, and `terminal_states` stay under `tracker`.
```

Add a note that startup now fails on an unresolvable team key, label, or state name.

- [ ] **Step 7: `elixir/WORKFLOW.md`**

Leave `project_slug` in place (it is this repo's own working config) and add a commented alternative under `tracker:`:

```yaml
tracker:
  kind: linear
  provider:
    project_slug: "symphony-0c79b11b75ea"
    # Or scope by team and let any project's tickets qualify:
    # team_keys: ["SYM"]
  # any_labels:
  #   - bug-symphony
  #   - feat-symphony
  required_labels: []
```

- [ ] **Step 8: `workflows/example.md` and `deploy/client-template/workflow.md`**

Add the same commented `team_keys` / `any_labels` alternative next to the existing `project_slug` placeholder in both files.

- [ ] **Step 9: `deploy/client-template/README.md`**

The step-3 bullet currently spends a paragraph warning that a wrong `project_slug` fails silently. Rewrite it to present both scoping options and point at preflight:

```markdown
   - **Scope** — either `tracker.provider.project_slug` (the `<project-name>-<id>` segment
     of the project URL, not the display name) or `tracker.provider.team_keys` (a list of
     Linear team keys, the prefix in issue identifiers such as `WMP` in `WMP-14`). Team
     scoping plus `tracker.any_labels` lets tickets in any project qualify by carrying a
     label, so adding a project needs no config change here.
     Symphony resolves these at startup and refuses to boot if a team key, label, or state
     name does not exist in your workspace, naming each one — so a typo is a startup error,
     not a silently idle container.
```

Keep the `active_states` / `terminal_states` bullet but note preflight now catches those too.

- [ ] **Step 10: Verify no doc contradicts the code**

Run: `grep -rn "required project_slug\|project_slug.*REQUIRED" SPEC.md elixir/README.md deploy/`
Expected: no output — no doc still claims the slug is mandatory.

- [ ] **Step 11: Commit**

```bash
git add SPEC.md elixir/README.md elixir/WORKFLOW.md workflows/example.md deploy/client-template/workflow.md deploy/client-template/README.md
git commit -m "docs: document Linear team scoping, any_labels, and preflight"
```

---

### Task 12: Full quality gate

**Files:**
- Modify: whatever the gate flags.

**Interfaces:**
- Consumes: Tasks 1–11.
- Produces: a branch that passes `make all`.

- [ ] **Step 1: Run the whole suite with coverage**

Run: `mix test --cover`
Expected: PASS at 100%. If a new function is uncovered, the likely gaps are `format_preflight_error/1`'s fallback clause (add a test passing a bare atom reason), `project_conjunct/1`'s blank-string branch, `fetch_preflight_labels/1`'s empty-list clause, and `format_team_scope/1`'s no-labels branch. Add a test per gap rather than extending the ignore list in `mix.exs`.

- [ ] **Step 2: Confirm every public function has a spec**

Run: `mix specs.check`
Expected: PASS. New public functions needing specs: `Client.build_issue_filter/2`, `Tracker.preflight/1`, `Linear.Adapter.preflight/1`, `StatusDashboard.format_project_link_lines_for_test/0`.

- [ ] **Step 3: Lint and format check**

Run: `mix lint && mix format --check-formatted`
Expected: PASS

- [ ] **Step 4: Dialyzer**

Run: `mix dialyzer`
Expected: PASS. `routable?/2`'s spec changed from `[String.t()]` to `map()`, so a stale call site would surface here.

- [ ] **Step 5: The whole gate**

Run: `make all`
Expected: PASS

- [ ] **Step 6: Manual smoke against real Linear (optional but recommended)**

With `LINEAR_API_KEY` exported, point a scratch workflow at a real team and confirm the process picks up a labeled ticket, then confirm a deliberately misspelled team key fails at startup with a named error rather than idling:

```bash
./bin/symphony /tmp/scratch-WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

- [ ] **Step 7: Commit any gate fixes**

```bash
mix format
git add -A
git commit -m "chore: satisfy the full quality gate for Linear team scoping"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 Config surface (`team_keys`, `any_labels`) | 2 (helper prerequisite: 1) |
| §2 Validation and backward compatibility (`:missing_linear_scope`) | 6 |
| §3 One filter builder, both queries collapsed | 4 (builder), 5 (wiring) |
| §4 Label matching stays client-side (`routable?/2`) | 3 |
| §5 Preflight | 7 (behaviour), 8 (Linear impl), 9 (CLI) |
| §6 Status board | 10 |
| Testing section | folded into each task, gaps closed in 12 |
| Documentation section | 11 |
| Risk: state matching becomes case-insensitive for project-only deploys | 5 (Step 3 `maybe_put_state`), documented in 11 |

No spec section is unimplemented.

**Type consistency check:** `build_issue_filter/2` takes `(map(), keyword())` in Tasks 4 and 5. `routable?/2` takes `(t(), map())` in Task 3 and both call sites pass `Config.settings!().tracker`. `preflight/1` takes `map()` and returns `:ok | {:error, term()}` in Tasks 7, 8, and 9, and Task 9's `format_preflight_error/1` matches the `{:linear_preflight_failed, reasons}` shape Task 8 produces. `scoped?/1` appears in both `client.ex` (Task 5) and `adapter.ex` (Task 6) as separate private functions — deliberate, since neither module should depend on the other's internals, and both are covered by tests.

**Known ordering constraint:** Task 5 Step 6 leaves the suite red on four `core_test.exs` assertions; Task 6 fixes them. A reviewer gating Task 5 on a green full suite will be surprised, which is why Step 6 says so explicitly. The alternative — merging Tasks 5 and 6 — would put a query refactor and an error-atom rename in one reviewable unit, which is worse.
