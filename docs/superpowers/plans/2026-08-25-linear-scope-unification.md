# Linear Scope Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one Symphony instance scope its Linear reads by team keys, the team's current cycle, a project slug, labels, or any conjunction of those, and stop a scope change from killing in-flight agents.

**Architecture:** A new pure module `SymphonyElixir.Linear.Scope` owns Linear scope validation, `IssueFilter` construction, and the status-board summary. Both GraphQL documents stop hardcoding a filter shape and take the whole filter as one `$filter: IssueFilter!` variable. The candidate-poll read is scope-filtered; the by-IDs refresh read is not, and cannot be, because it never touches `Scope` at all. A new optional `Tracker.scope_summary/1` callback lets the status board render scope without core knowing any Linear config key.

**Tech Stack:** Elixir 1.19.x / OTP 28 via `mise`, Ecto changesets for config schema, `YamlElixir` for `WORKFLOW.md` front matter, ExUnit, Linear GraphQL API.

**Spec:** `docs/superpowers/specs/2026-08-25-linear-scope-unification-design.md`

## Global Constraints

- Run every `mix` command from the `elixir/` directory. Prefix with `mise exec --` outside a mise-activated shell.
- Every public `def` in `lib/` needs an adjacent `@spec`. `defp` and `@impl` callbacks are exempt. Enforced by `mix specs.check`.
- Coverage threshold is 100%. `mix.exs:38-79` lists ignored modules; **do not add to that list** (`CLAUDE.md:71`). `SymphonyElixir.Linear.Client`, `StatusDashboard`, `Orchestrator`, `AgentRunner`, and `Config` are already ignored. `SymphonyElixir.Linear.Scope` will NOT be ignored and must reach 100%.
- Formatter line length is 200 (`mix format`).
- Add tracker capabilities through the `Tracker` behaviour, never by branching in `AgentRunner` or calling an adapter directly (`CLAUDE.md:62`).
- All config access goes through `SymphonyElixir.Config`, never ad-hoc env reads (`CLAUDE.md:63`).
- Preserve orchestrator retry, reconciliation, and cleanup semantics (`CLAUDE.md:64`).
- `SPEC.md` is the source of truth; the implementation may be a superset but must never conflict. Behaviour changes update `SPEC.md` in the same change (`CLAUDE.md:9-10`).
- Provider config keys are string-keyed. `normalize_keys/1` (`config/schema.ex:502-509`) stringifies keys only and leaves values untouched, so a YAML boolean arrives as a real boolean.
- Linear provider scope keys live under `tracker.provider`; core MUST NOT gain typed fields for them (`SPEC.md:394-395`). The existing typed `project_slug` field is legacy leakage and is not extended.
- Team keys, label names, and state names are matched with `eqIgnoreCase`. Linear's `StringComparator` has `in` but no `inIgnoreCase`, and bare `in` is case-sensitive.
- Linear query complexity is MULTIPLICATIVE across nested connections with a ceiling of 10000. Measured: `250x250` and `250x50` rejected, `100x50` accepted. Do not raise a nested page size without re-measuring.
- Full gate before handoff: `make all` (from `elixir/`).

---

### Task 1: `SymphonyElixir.Linear.Scope`

The pure core of the change: one module owning validation, filter construction, and the board summary, so the query, the config error, and the board text cannot disagree. Nothing depends on it yet, so it lands and is tested on its own.

It lives in its own module rather than in `Linear.Client` for a mechanical reason: `SymphonyElixir.Linear.Client` is in `coverage_ignore_modules` (`mix.exs:47`) and absent from `review_coverage_modules/0` (`mix.exs:80-89`), so it is coverage-exempt in both modes. Filter logic placed there would be measured at 0%.

**Files:**
- Create: `elixir/lib/symphony_elixir/linear/scope.ex`
- Test: `elixir/test/symphony_elixir/linear_scope_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `SymphonyElixir.Linear.Scope.validate(tracker_settings :: map()) :: :ok | {:error, atom()}`
  - `SymphonyElixir.Linear.Scope.filter(tracker_settings :: map(), opts :: keyword()) :: map()` — `opts` accepts only `:state_names` (a list of strings). There is deliberately no `:ids` option; see Task 4.
  - `SymphonyElixir.Linear.Scope.scope_summary(tracker_settings :: map()) :: String.t()`
  - `SymphonyElixir.Linear.Scope.team_keys(tracker_settings :: map()) :: [String.t()]`
  - `SymphonyElixir.Linear.Scope.current_cycle?(tracker_settings :: map()) :: boolean()`

`team_keys/1` and `current_cycle?/1` are public beyond the spec's three functions so that preflight (Task 6) and any other caller never re-read a provider key name. This module is the only place that knows those names.

- [ ] **Step 1: Write the failing tests**

Create `elixir/test/symphony_elixir/linear_scope_test.exs`:

```elixir
defmodule SymphonyElixir.LinearScopeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Scope

  # Mirrors a finalized tracker settings map: `provider` carries string keys because
  # `Config.Schema.normalize_keys/1` stringifies them, and `project_slug` is present as a
  # typed field because `config/schema.ex:480` mirrors it back out of the provider map.
  defp tracker(overrides) do
    Map.merge(
      %{
        kind: "linear",
        project_slug: nil,
        any_labels: [],
        required_labels: [],
        provider: %{}
      },
      overrides
    )
  end

  defp provider(overrides), do: tracker(%{provider: overrides})

  describe "validate/1" do
    test "no scope selector at all is a missing scope" do
      assert Scope.validate(tracker(%{})) == {:error, :missing_linear_scope}
    end

    test "an injected nil project_slug does not count as a scope" do
      # `config/schema.ex:444` runs Map.put_new("project_slug", nil) AFTER drop_nil_values,
      # so a finalized provider map always has the key. Presence must be by value.
      settings = tracker(%{provider: %{"project_slug" => nil}})
      assert Scope.validate(settings) == {:error, :missing_linear_scope}
    end

    test "a blank project_slug does not count as a scope" do
      assert Scope.validate(tracker(%{project_slug: "   "})) == {:error, :missing_linear_scope}
    end

    test "labels alone are not a scope" do
      settings = tracker(%{any_labels: ["feat-symphony"], required_labels: ["migrated"]})
      assert Scope.validate(settings) == {:error, :missing_linear_scope}
    end

    test "current_cycle false is not a scope" do
      assert Scope.validate(provider(%{"current_cycle" => false})) == {:error, :missing_linear_scope}
    end

    test "project_slug alone is valid" do
      assert Scope.validate(tracker(%{project_slug: "acme-web"})) == :ok
    end

    test "team_keys alone is valid" do
      assert Scope.validate(provider(%{"team_keys" => ["MDZ"]})) == :ok
    end

    test "team_keys plus current_cycle is valid" do
      assert Scope.validate(provider(%{"team_keys" => ["MDZ"], "current_cycle" => true})) == :ok
    end

    test "current_cycle without team_keys is rejected" do
      assert Scope.validate(provider(%{"current_cycle" => true})) == {:error, :missing_linear_team_keys}
    end

    test "current_cycle with only blank team_keys is rejected" do
      settings = provider(%{"current_cycle" => true, "team_keys" => ["  "]})
      assert Scope.validate(settings) == {:error, :invalid_linear_team_keys}
    end

    test "a scalar team_keys is rejected rather than silently ignored" do
      assert Scope.validate(provider(%{"team_keys" => "MDZ"})) == {:error, :invalid_linear_team_keys}
    end

    test "a non-string team key is rejected" do
      assert Scope.validate(provider(%{"team_keys" => ["MDZ", 7]})) == {:error, :invalid_linear_team_keys}
    end

    test "a non-boolean current_cycle is rejected" do
      settings = provider(%{"team_keys" => ["MDZ"], "current_cycle" => "true"})
      assert Scope.validate(settings) == {:error, :invalid_linear_current_cycle}
    end

    test "type errors are reported before the presence error" do
      # Otherwise a malformed value could satisfy "at least one selector present".
      assert Scope.validate(provider(%{"team_keys" => "MDZ"})) == {:error, :invalid_linear_team_keys}
    end
  end

  describe "team_keys/1 and current_cycle?/1" do
    test "team keys are trimmed, blank-rejected and deduplicated but not case-folded" do
      settings = provider(%{"team_keys" => [" MDZ ", "mdz", "MDZ", "  ", "TRA"]})
      assert Scope.team_keys(settings) == ["MDZ", "mdz", "TRA"]
    end

    test "absent team_keys is an empty list" do
      assert Scope.team_keys(tracker(%{})) == []
    end

    test "current_cycle? is false when absent or false" do
      refute Scope.current_cycle?(tracker(%{}))
      refute Scope.current_cycle?(provider(%{"current_cycle" => false}))
    end

    test "current_cycle? is true only for the boolean true" do
      assert Scope.current_cycle?(provider(%{"current_cycle" => true}))
    end
  end

  describe "filter/2" do
    test "project only, with state names" do
      settings = tracker(%{project_slug: "acme-web"})

      assert Scope.filter(settings, state_names: ["Todo", "In Progress"]) == %{
               state: %{or: [%{name: %{eqIgnoreCase: "Todo"}}, %{name: %{eqIgnoreCase: "In Progress"}}]},
               and: [%{project: %{slugId: %{eq: "acme-web"}}}]
             }
    end

    test "teams only" do
      settings = provider(%{"team_keys" => ["MDZ", "TRA"]})

      assert Scope.filter(settings, []) == %{
               and: [
                 %{
                   or: [
                     %{team: %{key: %{eqIgnoreCase: "MDZ"}}},
                     %{team: %{key: %{eqIgnoreCase: "TRA"}}}
                   ]
                 }
               ]
             }
    end

    test "teams plus current cycle puts cycle at the top level" do
      settings = provider(%{"team_keys" => ["MDZ"], "current_cycle" => true})

      assert Scope.filter(settings, []) == %{
               cycle: %{isActive: %{eq: true}},
               and: [%{or: [%{team: %{key: %{eqIgnoreCase: "MDZ"}}}]}]
             }
    end

    test "current_cycle false contributes no cycle fragment" do
      settings = provider(%{"team_keys" => ["MDZ"], "current_cycle" => false})
      refute Map.has_key?(Scope.filter(settings, []), :cycle)
    end

    test "all four selectors plus labels" do
      settings =
        tracker(%{
          project_slug: "acme-web",
          any_labels: ["feat-symphony", "bug-symphony"],
          required_labels: ["migrated"],
          provider: %{"team_keys" => ["MDZ"], "current_cycle" => true}
        })

      assert Scope.filter(settings, state_names: ["Todo"]) == %{
               state: %{or: [%{name: %{eqIgnoreCase: "Todo"}}]},
               cycle: %{isActive: %{eq: true}},
               and: [
                 %{or: [%{team: %{key: %{eqIgnoreCase: "MDZ"}}}]},
                 %{project: %{slugId: %{eq: "acme-web"}}},
                 %{
                   or: [
                     %{labels: %{some: %{name: %{eqIgnoreCase: "feat-symphony"}}}},
                     %{labels: %{some: %{name: %{eqIgnoreCase: "bug-symphony"}}}}
                   ]
                 },
                 %{labels: %{some: %{name: %{eqIgnoreCase: "migrated"}}}}
               ]
             }
    end

    test "each required label becomes its own AND conjunct" do
      settings = tracker(%{project_slug: "acme-web", required_labels: ["a", "b"]})

      assert Scope.filter(settings, []) == %{
               and: [
                 %{project: %{slugId: %{eq: "acme-web"}}},
                 %{labels: %{some: %{name: %{eqIgnoreCase: "a"}}}},
                 %{labels: %{some: %{name: %{eqIgnoreCase: "b"}}}}
               ]
             }
    end

    test "an empty conjunct list omits the and key entirely" do
      assert Scope.filter(tracker(%{}), state_names: ["Todo"]) == %{
               state: %{or: [%{name: %{eqIgnoreCase: "Todo"}}]}
             }
    end

    test "empty state names omit the state key" do
      settings = tracker(%{project_slug: "acme-web"})
      refute Map.has_key?(Scope.filter(settings, state_names: []), :state)
      refute Map.has_key?(Scope.filter(settings, []), :state)
    end

    test "filter never emits an id key" do
      # The by-ids read must not be reachable through this module at all.
      settings = tracker(%{project_slug: "acme-web"})
      refute Map.has_key?(Scope.filter(settings, state_names: ["Todo"]), :id)
    end
  end

  describe "scope_summary/1" do
    test "teams and cycle" do
      settings = provider(%{"team_keys" => ["MDZ", "TRA"], "current_cycle" => true})
      assert Scope.scope_summary(settings) == "teams MDZ, TRA · current cycle"
    end

    test "teams only" do
      assert Scope.scope_summary(provider(%{"team_keys" => ["MDZ", "TRA"]})) == "teams MDZ, TRA"
    end

    test "project only" do
      assert Scope.scope_summary(tracker(%{project_slug: "acme-web"})) == "project acme-web"
    end

    test "teams, cycle and labels in fixed order" do
      settings =
        tracker(%{
          any_labels: ["feat-symphony"],
          required_labels: ["migrated"],
          provider: %{"team_keys" => ["MDZ"], "current_cycle" => true}
        })

      assert Scope.scope_summary(settings) ==
               "teams MDZ · current cycle · any labels feat-symphony · required labels migrated"
    end

    test "an unscoped settings map renders n/a rather than an empty string" do
      assert Scope.scope_summary(tracker(%{})) == "n/a"
    end

    test "the summary never contains the word Dashboard" do
      # orchestrator_status_test.exs:1196 refutes "Dashboard:" as a substring of the whole board.
      settings = provider(%{"team_keys" => ["MDZ"], "current_cycle" => true})
      refute Scope.scope_summary(settings) =~ "Dashboard"
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/symphony_elixir/linear_scope_test.exs`
Expected: FAIL — `** (UndefinedFunctionError) function SymphonyElixir.Linear.Scope.validate/1 is undefined (module SymphonyElixir.Linear.Scope is not available)`

- [ ] **Step 3: Write the implementation**

Create `elixir/lib/symphony_elixir/linear/scope.ex`:

```elixir
defmodule SymphonyElixir.Linear.Scope do
  @moduledoc """
  Owns the Linear read scope: validation, `IssueFilter` construction, and the
  human-readable summary the status board renders.

  Scope keys live under `tracker.provider` because `SPEC.md` §5.3.1 makes that
  object adapter-owned and forbids core from prescribing a cross-provider scope
  schema. This module is the only place that knows their names.

  One module owns all three concerns so the query, the config error, and the
  board text cannot drift apart.

  Team keys, label names, and state names are matched with `eqIgnoreCase`
  because Linear's `StringComparator` offers `in` but no `inIgnoreCase`, so a
  case-insensitive set match has to be an `or` list of single comparisons.

  Top-level `IssueFilter` keys AND with the `and` conjunct list, so a filter
  reads as `state AND cycle AND (team ...) AND project AND (any label ...) AND
  required label ...`.
  """

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(tracker_settings) when is_map(tracker_settings) do
    provider = provider_map(tracker_settings)

    # Type checks run first so a malformed value can never satisfy the presence rule.
    with :ok <- validate_team_keys_shape(provider),
         :ok <- validate_current_cycle_shape(provider),
         :ok <- validate_scope_present(tracker_settings, provider) do
      validate_cycle_is_team_qualified(tracker_settings, provider)
    end
  end

  @doc """
  Builds the Linear `IssueFilter` map for the configured scope.

  `opts` accepts `:state_names` only. There is deliberately no `:ids` option:
  the by-IDs refresh read applies no scope, and giving this function an ID mode
  is what would make a scoped ID read representable.
  """
  @spec filter(map(), keyword()) :: map()
  def filter(tracker_settings, opts \\ []) when is_map(tracker_settings) and is_list(opts) do
    conjuncts =
      [
        team_conjunct(team_keys(tracker_settings)),
        project_conjunct(project_slug(tracker_settings)),
        any_labels_conjunct(label_list(tracker_settings, :any_labels))
      ] ++ required_label_conjuncts(label_list(tracker_settings, :required_labels))

    %{}
    |> maybe_put_state(Keyword.get(opts, :state_names))
    |> maybe_put_cycle(current_cycle?(tracker_settings))
    |> maybe_put_conjuncts(Enum.reject(conjuncts, &is_nil/1))
  end

  @spec scope_summary(map()) :: String.t()
  def scope_summary(tracker_settings) when is_map(tracker_settings) do
    parts =
      [
        teams_summary(team_keys(tracker_settings)),
        cycle_summary(current_cycle?(tracker_settings)),
        project_summary(project_slug(tracker_settings)),
        labels_summary("any labels", label_list(tracker_settings, :any_labels)),
        labels_summary("required labels", label_list(tracker_settings, :required_labels))
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "n/a"
      parts -> Enum.join(parts, " · ")
    end
  end

  @doc """
  The configured team keys, trimmed and deduplicated.

  Keys are not case-folded: they are matched with `eqIgnoreCase` at query time
  and reported back to the operator verbatim in errors and on the status board.
  """
  @spec team_keys(map()) :: [String.t()]
  def team_keys(tracker_settings) when is_map(tracker_settings) do
    tracker_settings
    |> provider_map()
    |> Map.get("team_keys")
    |> normalize_team_keys()
  end

  @spec current_cycle?(map()) :: boolean()
  def current_cycle?(tracker_settings) when is_map(tracker_settings) do
    Map.get(provider_map(tracker_settings), "current_cycle") == true
  end

  defp provider_map(tracker_settings) do
    case Map.get(tracker_settings, :provider) do
      provider when is_map(provider) -> provider
      _ -> %{}
    end
  end

  # `project_slug` is read from the typed field because `config/schema.ex:480` mirrors the
  # provider value onto it, and every existing Linear call site already reads it there.
  defp project_slug(tracker_settings), do: Map.get(tracker_settings, :project_slug)

  defp label_list(tracker_settings, key) do
    case Map.get(tracker_settings, key) do
      labels when is_list(labels) -> labels
      _ -> []
    end
  end

  defp validate_team_keys_shape(provider) do
    case Map.get(provider, "team_keys") do
      nil -> :ok
      keys when is_list(keys) -> validate_team_key_entries(keys)
      _other -> {:error, :invalid_linear_team_keys}
    end
  end

  defp validate_team_key_entries(keys) do
    if Enum.all?(keys, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :invalid_linear_team_keys}
    end
  end

  defp validate_current_cycle_shape(provider) do
    case Map.get(provider, "current_cycle") do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _other -> {:error, :invalid_linear_current_cycle}
    end
  end

  # Counts contributed filter fragments, never present keys: `current_cycle: false` and an
  # injected `"project_slug" => nil` are both present-but-empty. Labels narrow a container,
  # they do not define one, so they are not counted here.
  defp validate_scope_present(tracker_settings, provider) do
    scoped? =
      team_keys(tracker_settings) != [] or
        present_string?(project_slug(tracker_settings)) or
        Map.get(provider, "current_cycle") == true

    if scoped?, do: :ok, else: {:error, :missing_linear_scope}
  end

  # An unqualified `cycle: {isActive: {eq: true}}` matches the active cycle of every team the
  # token can see, so the day a second team is added the instance would silently dispatch
  # agents against another team's tickets.
  defp validate_cycle_is_team_qualified(tracker_settings, provider) do
    if Map.get(provider, "current_cycle") == true and team_keys(tracker_settings) == [] do
      {:error, :missing_linear_team_keys}
    else
      :ok
    end
  end

  defp normalize_team_keys(keys) when is_list(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_team_keys(_keys), do: []

  defp team_conjunct([]), do: nil
  defp team_conjunct(keys), do: %{or: Enum.map(keys, &%{team: %{key: %{eqIgnoreCase: &1}}})}

  defp project_conjunct(slug) do
    if present_string?(slug), do: %{project: %{slugId: %{eq: slug}}}, else: nil
  end

  defp any_labels_conjunct([]), do: nil
  defp any_labels_conjunct(labels), do: %{or: Enum.map(labels, &label_clause/1)}

  defp required_label_conjuncts(labels), do: Enum.map(labels, &label_clause/1)

  defp label_clause(label), do: %{labels: %{some: %{name: %{eqIgnoreCase: label}}}}

  defp maybe_put_state(filter, state_names) when is_list(state_names) and state_names != [] do
    Map.put(filter, :state, %{or: Enum.map(state_names, &%{name: %{eqIgnoreCase: &1}})})
  end

  defp maybe_put_state(filter, _state_names), do: filter

  defp maybe_put_cycle(filter, true), do: Map.put(filter, :cycle, %{isActive: %{eq: true}})
  defp maybe_put_cycle(filter, _current_cycle?), do: filter

  defp maybe_put_conjuncts(filter, []), do: filter
  defp maybe_put_conjuncts(filter, conjuncts), do: Map.put(filter, :and, conjuncts)

  defp teams_summary([]), do: nil
  defp teams_summary(keys), do: "teams " <> Enum.join(keys, ", ")

  defp cycle_summary(true), do: "current cycle"
  defp cycle_summary(_current_cycle?), do: nil

  defp project_summary(slug) do
    if present_string?(slug), do: "project " <> slug, else: nil
  end

  defp labels_summary(_label, []), do: nil
  defp labels_summary(label, labels), do: label <> " " <> Enum.join(labels, ", ")

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/linear_scope_test.exs`
Expected: PASS, all tests.

- [ ] **Step 5: Verify the new module is fully covered**

Run: `mix test --cover test/symphony_elixir/linear_scope_test.exs 2>&1 | grep -i "linear.scope"`
Expected: `SymphonyElixir.Linear.Scope` at 100.0%. If a line is uncovered, add the missing case to the test file — do not add the module to `mix.exs` ignore list.

- [ ] **Step 6: Check formatting and specs**

Run: `mix format && mix specs.check`
Expected: no output from `specs.check` (all five public functions have adjacent `@spec`s).

- [ ] **Step 7: Commit**

```bash
git add lib/symphony_elixir/linear/scope.ex test/symphony_elixir/linear_scope_test.exs
git commit -m "feat: add Linear.Scope owning scope validation, filter and summary"
```

---

### Task 2: Core `any_labels` policy and `Issue.routable?/2`

`any_labels` is scheduler policy, not Linear-specific, so it is a core top-level field beside `required_labels`. `Issue.routable?/2` stays authoritative for label matching — the GraphQL filter is only a prefilter that avoids paging a whole team every tick, and two call sites check routability on issues already in hand where no query is involved.

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex:56` (add field), `:75` (cast list), `:81-85` (normalization)
- Modify: `elixir/lib/symphony_elixir/tracker/issue.ex:58-65`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex:872-874`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex:257-259`
- Modify: `elixir/test/support/test_support.exs` (emit `any_labels` and a `provider` block)
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs` (existing `routable?/2` call sites)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `tracker.any_labels :: [String.t()]` on the settings struct, trimmed, downcased, deduplicated, default `[]`.
  - `SymphonyElixir.Tracker.Issue.routable?(issue :: t(), label_policy :: map()) :: boolean()` — `label_policy` is any map with optional `:required_labels` and `:any_labels` keys.
  - `SymphonyElixir.TestSupport.write_workflow_file!/2` gains options `tracker_any_labels :: [String.t()]` and `tracker_provider :: map()`.

- [ ] **Step 1: Write the failing tests**

Add to `elixir/test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
  test "any_labels is normalized like required_labels" do
    write_workflow_file!(tracker_any_labels: ["  Feat-Symphony ", "feat-symphony", "BUG-Symphony"])

    assert {:ok, settings} = SymphonyElixir.Config.settings()
    assert settings.tracker.any_labels == ["feat-symphony", "bug-symphony"]
  end

  test "any_labels defaults to an empty list" do
    write_workflow_file!([])

    assert {:ok, settings} = SymphonyElixir.Config.settings()
    assert settings.tracker.any_labels == []
  end

  test "routable? requires every required label" do
    issue = %SymphonyElixir.Tracker.Issue{dispatchable: true, labels: ["Migrated"]}

    assert SymphonyElixir.Tracker.Issue.routable?(issue, %{required_labels: ["migrated"]})
    refute SymphonyElixir.Tracker.Issue.routable?(issue, %{required_labels: ["migrated", "ci"]})
  end

  test "routable? requires at least one any_label when any are configured" do
    issue = %SymphonyElixir.Tracker.Issue{dispatchable: true, labels: ["Feat-Symphony"]}

    assert SymphonyElixir.Tracker.Issue.routable?(issue, %{any_labels: ["feat-symphony", "bug-symphony"]})
    refute SymphonyElixir.Tracker.Issue.routable?(issue, %{any_labels: ["bug-symphony"]})
  end

  test "routable? treats an empty any_labels list as no constraint" do
    issue = %SymphonyElixir.Tracker.Issue{dispatchable: true, labels: []}

    assert SymphonyElixir.Tracker.Issue.routable?(issue, %{any_labels: [], required_labels: []})
    assert SymphonyElixir.Tracker.Issue.routable?(issue, %{})
  end

  test "routable? applies required and any label rules together" do
    issue = %SymphonyElixir.Tracker.Issue{dispatchable: true, labels: ["migrated", "feat-symphony"]}

    assert SymphonyElixir.Tracker.Issue.routable?(issue, %{
             required_labels: ["migrated"],
             any_labels: ["feat-symphony", "bug-symphony"]
           })

    refute SymphonyElixir.Tracker.Issue.routable?(issue, %{
             required_labels: ["migrated"],
             any_labels: ["bug-symphony"]
           })
  end

  test "routable? is false for a non-dispatchable issue regardless of labels" do
    issue = %SymphonyElixir.Tracker.Issue{dispatchable: false, labels: ["migrated"]}

    refute SymphonyElixir.Tracker.Issue.routable?(issue, %{required_labels: ["migrated"]})
  end

  test "routable? treats a blank configured label as unsatisfiable" do
    issue = %SymphonyElixir.Tracker.Issue{dispatchable: true, labels: ["migrated"]}

    refute SymphonyElixir.Tracker.Issue.routable?(issue, %{any_labels: ["   "]})
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs -k "any_labels"`
Expected: FAIL — `write_workflow_file!/1` does not accept `tracker_any_labels`, and `routable?/2` raises `FunctionClauseError` because it still guards `is_list(required_labels)`.

- [ ] **Step 3: Add the config field and normalization**

In `elixir/lib/symphony_elixir/config/schema.ex`, add the field after `:required_labels` (line 56):

```elixir
      field(:any_labels, {:array, :string}, default: [])
```

Add `:any_labels` to the cast list after `:required_labels` (line 75):

```elixir
          :required_labels,
          :any_labels,
```

Add the normalization after the existing `:required_labels` block (after line 85):

```elixir
      |> update_change(:any_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
```

- [ ] **Step 4: Change `Issue.routable?/2` to take a label policy map**

Replace `elixir/lib/symphony_elixir/tracker/issue.ex:58-65` with:

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

A map rather than two positional lists: two same-typed positional list arguments are a transposition bug waiting to happen, and both `lib` call sites already hold the tracker settings map.

- [ ] **Step 5: Update both `routable?` call sites**

In `elixir/lib/symphony_elixir/orchestrator.ex`, replace `issue_routable?/1` (lines 872-874):

```elixir
  defp issue_routable?(%Issue{} = issue) do
    # Only the label fields: the tracker struct also carries the resolved Linear API token,
    # which a FunctionClauseError on this hot path would inspect/1 into the log file.
    Issue.routable?(issue, Map.take(Config.settings!().tracker, [:required_labels, :any_labels]))
  end
```

In `elixir/lib/symphony_elixir/agent_runner.ex`, replace `issue_routable?/1` (lines 257-259) with the same body:

```elixir
  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Map.take(Config.settings!().tracker, [:required_labels, :any_labels]))
  end
```

- [ ] **Step 6: Teach the test helper to emit the new keys**

In `elixir/test/support/test_support.exs`, add defaults alongside `tracker_project_slug` (near line 98):

```elixir
      tracker_any_labels: [],
      tracker_provider: %{},
```

Read them alongside the other options (near line 144) and emit them in the tracker block of the generated `WORKFLOW.md` (near line 191). `any_labels` is a top-level tracker key; `tracker_provider` entries go under a `provider:` block. Emit each only when non-empty so existing fixtures stay byte-identical:

```elixir
  defp tracker_any_labels_yaml([]), do: ""

  defp tracker_any_labels_yaml(labels) do
    "  any_labels:\n" <> Enum.map_join(labels, "", &"    - #{&1}\n")
  end

  defp tracker_provider_yaml(provider) when map_size(provider) == 0, do: ""

  defp tracker_provider_yaml(provider) do
    "  provider:\n" <> Enum.map_join(provider, "", fn {key, value} -> "    #{key}: #{provider_value_yaml(value)}\n" end)
  end

  defp provider_value_yaml(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &inspect/1) <> "]"
  defp provider_value_yaml(value) when is_binary(value), do: inspect(value)
  defp provider_value_yaml(value), do: to_string(value)
```

- [ ] **Step 7: Migrate the existing `routable?/2` call sites in tests**

Run: `grep -rn "routable?" test/`
For each call passing a bare list, wrap it: `routable?(issue, ["migrated"])` becomes `routable?(issue, %{required_labels: ["migrated"]})`.

- [ ] **Step 8: Run the affected tests**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs`
Expected: PASS.

- [ ] **Step 9: Run the full suite to catch other `routable?` callers**

Run: `mix test`
Expected: PASS. A `FunctionClauseError` mentioning `routable?/2` means a call site still passes a list.

- [ ] **Step 10: Commit**

```bash
git add lib/symphony_elixir/config/schema.ex lib/symphony_elixir/tracker/issue.ex \
        lib/symphony_elixir/orchestrator.ex lib/symphony_elixir/agent_runner.ex \
        test/support/test_support.exs test/symphony_elixir/workspace_and_config_test.exs
git commit -m "feat: add tracker.any_labels and match it in Issue.routable?/2"
```

---

### Task 3: Both queries take one `$filter` variable

Collapse the two byte-identical node selections into one attribute and pass the whole filter as a GraphQL variable. This task keeps the by-IDs read scope-filtered so it is a pure refactor of *how* the filter travels; Task 4 changes *what* the by-IDs filter contains. Splitting them this way keeps each commit's behaviour change reviewable on its own.

A `project_slug`-only config produces a semantically identical server-side filter, not identical wire bytes. One behaviour change does land here: state names move from `in` to `eqIgnoreCase`, which makes the query agree with `SPEC.md` §5.3.1's promise that state names are compared case-insensitively — true client-side today, false in the query. That is a strict widening and can only turn a silently-idle instance into a working one.

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/client.ex:14-110` (documents), `:120-150` (fetch entry points), `:240-254` (seam), `:256-336` (pagination)
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs:590-626`

**Interfaces:**
- Consumes: `SymphonyElixir.Linear.Scope.filter/2` from Task 1.
- Produces:
  - `SymphonyElixir.Linear.Client.fetch_issues_by_states_for_test(state_names :: [String.t()], graphql_fun :: (String.t(), map() -> {:ok, map()} | {:error, term()})) :: {:ok, [Issue.t()]} | {:error, term()}`
  - Both documents accept `$filter: IssueFilter!` and no `$projectSlug` / `$stateNames` / `$ids` variables.

- [ ] **Step 1: Write the failing tests**

Add to `elixir/test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
  test "linear poll sends the configured scope as one filter variable" do
    write_workflow_file!(tracker_project_slug: "acme-web")

    graphql_fun = fn query, variables ->
      send(self(), {:poll_page, query, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}
    end

    assert {:ok, []} = SymphonyElixir.Linear.Client.fetch_issues_by_states_for_test(["Todo", "In Progress"], graphql_fun)

    assert_receive {:poll_page, query, variables}

    assert variables.filter == %{
             state: %{or: [%{name: %{eqIgnoreCase: "Todo"}}, %{name: %{eqIgnoreCase: "In Progress"}}]},
             and: [%{project: %{slugId: %{eq: "acme-web"}}}]
           }

    assert query =~ "SymphonyLinearPoll"
    assert query =~ "$filter: IssueFilter!"
    refute query =~ "$projectSlug"
    refute query =~ "$stateNames"
  end

  test "linear poll resends the identical filter on the next page with the cursor advanced" do
    write_workflow_file!(tracker_project_slug: "acme-web")

    graphql_fun = fn query, variables ->
      send(self(), {:poll_page, query, variables})

      page_info =
        case variables.after do
          nil -> %{"hasNextPage" => true, "endCursor" => "cursor-1"}
          "cursor-1" -> %{"hasNextPage" => false, "endCursor" => nil}
        end

      {:ok, %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => page_info}}}}
    end

    assert {:ok, []} = SymphonyElixir.Linear.Client.fetch_issues_by_states_for_test(["Todo"], graphql_fun)

    assert_receive {:poll_page, _query, %{filter: first_filter, after: nil}}
    assert_receive {:poll_page, _query, %{filter: second_filter, after: "cursor-1"}}
    assert first_filter == second_filter
  end
```

Replace the filter assertions in the existing test at `:590-626` ("linear client paginates issue state fetches by id beyond one page") so they read the new variable shape. Keep the scope conjunct in the expectation for now — Task 4 removes it:

```elixir
    assert_receive {:fetch_issue_states_page, query, variables}

    assert variables.filter == %{
             id: %{in: first_batch_ids},
             and: [%{project: %{slugId: %{eq: "test-project"}}}]
           }

    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ "$filter: IssueFilter!"
```

Update the stubbed response builder in that test to read the new variable shape: `Enum.map(variables.filter.id.in, raw_issue)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs -k "filter variable"`
Expected: FAIL — `fetch_issues_by_states_for_test/2` is undefined.

- [ ] **Step 3: Extract the shared selection set and rewrite both documents**

In `elixir/lib/symphony_elixir/linear/client.ex`, replace lines 14-110 (`@query` and `@query_by_ids`) with:

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

The `attachments(first: $attachmentFirst)` selection and the `$attachmentFirst` declaration are preserved in both documents — they are orthogonal to scope but occupy the same lines.

- [ ] **Step 4: Thread the tracker settings instead of the slug**

Add the alias near the top of the module, beside the existing ones:

```elixir
  alias SymphonyElixir.Linear.Scope
```

Change `fetch_issues_by_states/1` (line 131) to pass the whole tracker:

```elixir
          do_fetch_by_states(tracker, states, assignee_filter)
```

Change `fetch_issues_by_ids/1` (line 147) the same way:

```elixir
          do_fetch_issue_states(ids, tracker, assignee_filter)
```

Replace the poll pagination (lines 256-284):

```elixir
  defp do_fetch_by_states(tracker, state_names, assignee_filter) do
    do_fetch_by_states_page(tracker, state_names, assignee_filter, nil, [], &graphql/2)
  end

  defp do_fetch_by_states_page(tracker, state_names, assignee_filter, after_cursor, acc_issues, graphql_fun) do
    with {:ok, body} <-
           graphql_fun.(@query, %{
             filter: Scope.filter(tracker, state_names: state_names),
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             attachmentFirst: @attachment_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(tracker, state_names, assignee_filter, next_cursor, updated_acc, graphql_fun)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
```

Replace the by-IDs pagination (lines 292-336), still scope-filtered at this step:

```elixir
  defp do_fetch_issue_states(ids, tracker, assignee_filter) do
    do_fetch_issue_states(ids, tracker, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, tracker, assignee_filter, graphql_fun)
       when is_list(ids) and is_map(tracker) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, tracker, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _tracker, _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, tracker, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           filter: Map.put(Scope.filter(tracker, []), :id, %{in: batch_ids}),
           first: length(batch_ids),
           relationFirst: @issue_page_size,
           attachmentFirst: @attachment_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response_strict(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(rest_ids, tracker, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
```

Note the `is_binary(project_slug)` guard is gone, replaced by `is_map(tracker)`.

- [ ] **Step 5: Add the poll test seam and update the by-IDs seam**

Replace `fetch_issues_by_ids_for_test/2` (lines 240-254) and add the poll seam beside it:

```elixir
  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, %{project_slug: "test-project", provider: %{}, any_labels: [], required_labels: []}, nil, graphql_fun)
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, graphql_fun)
      when is_list(state_names) and is_function(graphql_fun, 2) do
    normalized_states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    case normalized_states do
      [] ->
        {:ok, []}

      states ->
        with {:ok, tracker} <- configured_tracker_for_read() do
          do_fetch_by_states_page(tracker, states, nil, nil, [], graphql_fun)
        end
    end
  end
```

The poll seam reads real configured settings rather than a stub, because the poll filter is exactly what the test needs to observe.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/symphony_elixir/linear/client.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "refactor: pass a built IssueFilter variable to both Linear queries"
```

---

### Task 4: ID refreshes stop being scope-filtered

The load-bearing behaviour change. `fetch_issues_by_ids/1` builds an ID-only filter inline and never calls `Scope.filter/2`, so the by-IDs path holds no tracker settings and has no code path that could reach a scope conjunct. The invariant becomes structurally unrepresentable rather than merely tested.

> **Admission is scope-gated; continuation is state-gated.**

Because the by-IDs query is scope-filtered before this task, an issue that merely leaves the configured scope is indistinguishable from a deleted one, and all five omission consumers fire at once: kill the agent with no completion (`orchestrator.ex:478-496`), release the block and claim (`:500-518`), refuse to dispatch (`:1038-1039`), drop the retry (`:1154-1157`, logged at `Logger.debug` only), and end the multi-turn loop (`agent_runner.ex:233-234`). `handle_agent_down(:normal, …)` (`orchestrator.ex:198-213`) schedules a continuation retry after every clean agent exit, so the fourth consumer fires roughly one second after every successful turn.

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/client.ex` (by-IDs entry point, pagination, seam)
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs:590-626`

**Interfaces:**
- Consumes: `Scope.filter/2` remains used by the poll path only.
- Produces: `fetch_issues_by_ids_for_test/2` keeps its arity-2 signature but no longer accepts or fabricates tracker settings.

- [ ] **Step 1: Write the failing test**

Replace the filter assertions in "linear client paginates issue state fetches by id beyond one page" in `elixir/test/symphony_elixir/workspace_and_config_test.exs` with exact map equality, and add a dedicated regression test beside it:

```elixir
    assert_receive {:fetch_issue_states_page, query, variables}

    # Exact equality, not a subset pattern. Elixir map patterns are non-exact, so
    # `%{filter: %{id: %{in: ids}}}` also matches a filter carrying `and: [project…]`,
    # and asserting on document text proves nothing once the filter is a variable.
    assert variables.filter == %{id: %{in: first_batch_ids}}

    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ "$filter: IssueFilter!"
  end

  test "linear id refresh applies no scope filter even when scope is configured" do
    write_workflow_file!(
      tracker_project_slug: "acme-web",
      tracker_any_labels: ["feat-symphony"],
      tracker_provider: %{"team_keys" => ["MDZ"], "current_cycle" => true}
    )

    graphql_fun = fn _query, variables ->
      send(self(), {:by_ids, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    assert {:ok, []} = SymphonyElixir.Linear.Client.fetch_issues_by_ids_for_test(["issue-1"], graphql_fun)

    assert_receive {:by_ids, variables}
    assert variables.filter == %{id: %{in: ["issue-1"]}}
    assert Map.keys(variables.filter) == [:id]
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs -k "no scope filter"`
Expected: FAIL — the filter still carries `and: [%{project: …}]` and `cycle:`, so the exact-equality assertion fails with a map diff.

- [ ] **Step 3: Remove scope from the by-IDs path**

In `elixir/lib/symphony_elixir/linear/client.ex`, change `fetch_issues_by_ids/1` to stop resolving tracker settings for scope. It still calls `configured_tracker_for_read/0` for the API-token check and the assignee filter, but passes neither into the fetch:

```elixir
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, _tracker} <- configured_tracker_for_read(),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end
```

Replace the by-IDs pagination so no tracker travels with it:

```elixir
  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  # SPEC 11.1: an ID refresh applies no configured scope selection. Linear issue IDs are
  # workspace-unique UUIDs and the API token already bounds the query to one workspace, so
  # the read stays exact. Admission is scope-gated; continuation is state-gated.
  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           filter: %{id: %{in: batch_ids}},
           first: length(batch_ids),
           relationFirst: @issue_page_size,
           attachmentFirst: @attachment_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response_strict(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
```

`decode_linear_response_strict/2` is unchanged: `SPEC.md:1289-1292` requires an ID refresh to fail rather than silently omit a *malformed* record, and that is a different concern from scope.

- [ ] **Step 4: Simplify the seam**

Replace `fetch_issues_by_ids_for_test/2` so it fabricates no tracker settings at all:

```elixir
  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end
```

The `"test-project"` literal is gone. There is no longer any tracker argument on this path to carry a scope.

- [ ] **Step 5: Add the continuation characterization tests**

Add to `elixir/test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
  test "an issue that left the scope but is still active continues its turn loop" do
    write_workflow_file!([])

    issue = %SymphonyElixir.Tracker.Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "Still running",
      state: "In Progress",
      labels: [],
      dispatchable: true
    }

    fetcher = fn ["issue-1"] -> {:ok, [issue]} end

    assert {:continue, _issue} = SymphonyElixir.AgentRunner.continue_with_issue_for_test(issue, fetcher)
  end

  test "an issue that left the scope but is still active is not skipped as missing" do
    write_workflow_file!([])

    issue = %SymphonyElixir.Tracker.Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "Still dispatchable",
      state: "Todo",
      labels: [],
      dispatchable: true
    }

    fetcher = fn ["issue-1"] -> {:ok, [issue]} end

    refute SymphonyElixir.Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetcher) == {:skip, :missing}
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/symphony_elixir/linear/client.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "fix: stop scope-filtering Linear ID refreshes

An issue that merely leaves the configured scope was indistinguishable
from a deleted one, so all five omission consumers fired at once: agent
killed with no completion, claim released, dispatch refused, retry
dropped, turn loop ended. Admission is scope-gated; continuation is
state-gated."
```

---

### Task 5: Validation cutover

With the query able to honour every selector, open the config surface. `:missing_linear_project_slug` is retired rather than kept as a special case — "project scope missing" is the wrong diagnosis once four selectors exist.

Two independent gates exist and disagree in style: `linear/adapter.ex:50-51` is config-time and `present_string?`-based, `linear/client.ex:613-614` is request-time and `is_nil`-based. Both must delegate to `Scope.validate/1`, or a cycle-only config passes config validation and is then rejected at read time.

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex:41-58`
- Modify: `elixir/lib/symphony_elixir/linear/client.ex:609-617`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex:271-273`
- Test: `elixir/test/symphony_elixir/core_test.exs:46,60,290,328`
- Test: `elixir/test/symphony_elixir/extensions_test.exs:139,142`

**Interfaces:**
- Consumes: `Scope.validate/1` from Task 1.
- Produces: error atoms `:missing_linear_scope`, `:invalid_linear_team_keys`, `:invalid_linear_current_cycle`, `:missing_linear_team_keys`. `:missing_linear_project_slug` no longer exists anywhere.

- [ ] **Step 1: Write the failing tests**

In `elixir/test/symphony_elixir/core_test.exs` and `extensions_test.exs`, change every `:missing_linear_project_slug` assertion to `:missing_linear_scope`. Then add to `core_test.exs`:

```elixir
  test "a team_keys-only linear config is valid" do
    write_workflow_file!(tracker_project_slug: nil, tracker_provider: %{"team_keys" => ["MDZ"]})

    assert :ok = SymphonyElixir.Config.validate!()
  end

  test "a team_keys plus current_cycle config is valid" do
    write_workflow_file!(
      tracker_project_slug: nil,
      tracker_provider: %{"team_keys" => ["MDZ"], "current_cycle" => true}
    )

    assert :ok = SymphonyElixir.Config.validate!()
  end

  test "current_cycle without team_keys is rejected" do
    write_workflow_file!(tracker_project_slug: nil, tracker_provider: %{"current_cycle" => true})

    assert {:error, :missing_linear_team_keys} = SymphonyElixir.Config.settings() |> validate_tracker()
  end

  test "a non-boolean current_cycle is rejected" do
    write_workflow_file!(
      tracker_project_slug: nil,
      tracker_provider: %{"team_keys" => ["MDZ"], "current_cycle" => "yes"}
    )

    assert {:error, :invalid_linear_current_cycle} = SymphonyElixir.Config.settings() |> validate_tracker()
  end

  test "a scalar team_keys is rejected" do
    write_workflow_file!(tracker_project_slug: nil, tracker_provider: %{"team_keys" => "MDZ"})

    assert {:error, :invalid_linear_team_keys} = SymphonyElixir.Config.settings() |> validate_tracker()
  end

  defp validate_tracker({:ok, settings}), do: SymphonyElixir.Tracker.validate_config(settings.tracker)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs`
Expected: FAIL — the adapter still returns `:missing_linear_project_slug` and rejects team-only configs.

- [ ] **Step 3: Delegate config-time validation to `Scope`**

In `elixir/lib/symphony_elixir/linear/adapter.ex`, add the alias to the existing `alias SymphonyElixir.Linear.{AgentTool, Client}` line:

```elixir
  alias SymphonyElixir.Linear.{AgentTool, Client, Scope}
```

Replace the `project_slug` branch of `validate_config/1` (lines 50-51) with a delegation, keeping the other three branches and their order:

```elixir
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    cond do
      not present_string?(tracker_settings.endpoint) ->
        {:error, :invalid_linear_endpoint}

      not present_string?(tracker_settings.api_key) ->
        {:error, :missing_linear_api_token}

      not is_nil(tracker_settings.assignee) and not present_string?(tracker_settings.assignee) ->
        {:error, :invalid_linear_assignee}

      true ->
        Scope.validate(tracker_settings)
    end
  end
```

The assignee check moves above the scope delegation so the `cond` ends on the delegating clause rather than a bare `true -> :ok`.

- [ ] **Step 4: Delegate request-time validation to `Scope`**

In `elixir/lib/symphony_elixir/linear/client.ex`, replace `configured_tracker_for_read/0` (lines 609-617):

```elixir
  defp configured_tracker_for_read do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      true ->
        with :ok <- Scope.validate(tracker), do: {:ok, tracker}
    end
  end
```

- [ ] **Step 5: Update the orchestrator error branch**

In `elixir/lib/symphony_elixir/orchestrator.ex`, replace lines 271-273:

```elixir
      {:error, :missing_linear_scope} ->
        Logger.error(
          "Tracker scope missing in WORKFLOW.md: set tracker.provider.team_keys, tracker.provider.current_cycle, or tracker.provider.project_slug"
        )

        state

      {:error, :missing_linear_team_keys} ->
        Logger.error("Tracker scope invalid in WORKFLOW.md: tracker.provider.current_cycle requires tracker.provider.team_keys")
        state
```

The other two new atoms are config-shape errors surfaced at startup by `Config.validate!/0`; they fall through to the existing generic `{:error, reason}` clause at `:294-296`, which is correct for a malformed value.

- [ ] **Step 6: Verify the retired atom is gone**

Run: `grep -rn "missing_linear_project_slug" lib/ test/ ../SPEC.md ../README.md README.md WORKFLOW.md ../deploy ../workflows`
Expected: only hits in `elixir/README.md` (fixed in Task 8). Any hit in `lib/` or `test/` is a miss.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs`
Expected: PASS.

- [ ] **Step 8: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/symphony_elixir/linear/adapter.ex lib/symphony_elixir/linear/client.ex \
        lib/symphony_elixir/orchestrator.ex test/symphony_elixir/core_test.exs \
        test/symphony_elixir/extensions_test.exs
git commit -m "feat: accept team keys, current cycle or project slug as the Linear read scope"
```

---

### Task 6: `Tracker.preflight/1` and Linear scope resolution

A scope selector that does not exist returns zero issues rather than an error, which leaves the process running with nothing to do — the failure `deploy/client-template/README.md` already warns about ("Linear simply returns zero issues, Symphony logs nothing, and the container sits idle forever with clean logs and a working dashboard"). Four selectors widen that surface, so resolution happens once at startup and reports every unresolved value in one error.

A team with **no active cycle** is a warning, not an error: an absent active cycle is normal during sprint cooldown, so failing boot would turn a routine Linear state into an outage for a container that restarts between sprints. An unresolvable team *key* stays a hard failure, because that is a typo.

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex:22-35` (callback), `:100` (dispatcher)
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex` (preflight queries and resolution)
- Modify: `elixir/lib/symphony_elixir/cli.ex` (run preflight before the supervision tree)
- Test: `elixir/test/symphony_elixir/extensions_test.exs` (adapter preflight), `elixir/test/symphony_elixir/cli_test.exs` (wiring)

**Interfaces:**
- Consumes: `Scope.team_keys/1` from Task 1.
- Produces:
  - `SymphonyElixir.Tracker.preflight(tracker_settings :: map()) :: :ok | {:error, term()}` — optional callback, `:ok` fallback for adapters that do not implement it.
  - `SymphonyElixir.Linear.Adapter.preflight/1` returning `{:error, {:linear_preflight_failed, reasons :: [String.t()]}}` on failure.
  - `SymphonyElixir.CLI` deps map gains `optional(:preflight) => (-> :ok | {:error, term()})`.

- [ ] **Step 1: Write the failing tests**

Add to `elixir/test/symphony_elixir/extensions_test.exs`, following the `FakeLinearClient` pattern
already in that file. **Every preflight test below must start with**
`Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)` — that is how the
adapter's `client_module/0` (`adapter.ex:104-106`) is stubbed, and the `setup` block at
`extensions_test.exs:75-85` already restores the key on exit. The `settings` maps below carry no
client key; the adapter resolves its client from app env, not from tracker settings.

```elixir
  defmodule PreflightClient do
    def graphql(query, variables) do
      send(self(), {:preflight_query, query, variables})

      cond do
        query =~ "SymphonyPreflightTeams" ->
          {:ok, %{"data" => %{"teams" => %{"nodes" => teams()}}}}

        query =~ "SymphonyPreflightLabels" ->
          {:ok, %{"data" => %{"issueLabels" => %{"nodes" => labels()}}}}
      end
    end

    defp teams do
      [
        %{
          "key" => "MDZ",
          "activeCycle" => %{"name" => "Sprint 12", "endsAt" => "2026-09-01T00:00:00Z"},
          "states" => %{"nodes" => [%{"name" => "Todo"}, %{"name" => "In Progress"}, %{"name" => "Done"}]}
        },
        %{
          "key" => "TRA",
          "activeCycle" => nil,
          "states" => %{"nodes" => [%{"name" => "Todo"}, %{"name" => "In Progress"}, %{"name" => "Done"}]}
        }
      ]
    end

    defp labels do
      [%{"name" => "feat-symphony", "team" => %{"key" => "MDZ"}}]
    end
  end

  test "preflight resolves known team keys, states and labels" do
    settings = %{
      kind: "linear",
      provider: %{"team_keys" => ["MDZ"]},
      project_slug: nil,
      any_labels: ["feat-symphony"],
      required_labels: [],
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"]
    }

    assert :ok = Adapter.preflight(settings)
  end

  test "preflight reports an unknown team key" do
    settings = %{
      kind: "linear",
      provider: %{"team_keys" => ["NOPE"]},
      project_slug: nil,
      any_labels: [],
      required_labels: [],
      active_states: ["Todo"],
      terminal_states: ["Done"]
    }

    assert {:error, {:linear_preflight_failed, reasons}} = Adapter.preflight(settings)
    assert Enum.any?(reasons, &(&1 =~ "unknown Linear team key"))
  end

  test "preflight reports an unknown state name" do
    settings = %{
      kind: "linear",
      provider: %{"team_keys" => ["MDZ"]},
      project_slug: nil,
      any_labels: [],
      required_labels: [],
      active_states: ["Merging"],
      terminal_states: ["Done"]
    }

    assert {:error, {:linear_preflight_failed, reasons}} = Adapter.preflight(settings)
    assert Enum.any?(reasons, &(&1 =~ "Merging"))
  end

  test "preflight reports every failure in one error" do
    settings = %{
      kind: "linear",
      provider: %{"team_keys" => ["NOPE"]},
      project_slug: nil,
      any_labels: ["absent-label"],
      required_labels: [],
      active_states: ["Merging"],
      terminal_states: ["Done"]
    }

    assert {:error, {:linear_preflight_failed, reasons}} = Adapter.preflight(settings)
    assert length(reasons) >= 3
  end

  test "preflight warns rather than fails when a listed team has no active cycle" do
    settings = %{
      kind: "linear",
      provider: %{"team_keys" => ["TRA"], "current_cycle" => true},
      project_slug: nil,
      any_labels: [],
      required_labels: [],
      active_states: ["Todo"],
      terminal_states: ["Done"]
    }

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    assert log =~ "no active cycle"
    assert log =~ "TRA"
  end

  test "preflight does not check cycles when current_cycle is not configured" do
    settings = %{
      kind: "linear",
      provider: %{"team_keys" => ["TRA"]},
      project_slug: nil,
      any_labels: [],
      required_labels: [],
      active_states: ["Todo"],
      terminal_states: ["Done"]
    }

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    refute log =~ "no active cycle"
  end

  test "preflight is a no-op without team keys" do
    settings = %{
      kind: "linear",
      provider: %{},
      project_slug: "acme-web",
      any_labels: [],
      required_labels: [],
      active_states: ["Todo"],
      terminal_states: ["Done"]
    }

    assert :ok = Adapter.preflight(settings)
    refute_received {:preflight_query, _query, _variables}
  end

  test "the tracker facade falls back to ok for adapters without preflight" do
    assert :ok = SymphonyElixir.Tracker.preflight(%{kind: "memory"})
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/symphony_elixir/extensions_test.exs -k "preflight"`
Expected: FAIL — `Adapter.preflight/1` and `Tracker.preflight/1` are undefined.

- [ ] **Step 3: Add the optional callback to the behaviour**

In `elixir/lib/symphony_elixir/tracker.ex`, add the callback after `validate_config` (line 27):

```elixir
  @callback preflight(map()) :: :ok | {:error, term()}
```

Add it to `@optional_callbacks` (after line 33):

```elixir
                      preflight: 1,
```

Add the dispatcher after `validate_config/1` (after line 98):

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

- [ ] **Step 4: Implement `Linear.Adapter.preflight/1`**

Add the two query attributes to `elixir/lib/symphony_elixir/linear/adapter.ex`, after `@state_lookup_query`. `activeCycle` is a single object, not a connection, so it does not multiply the complexity budget:

```elixir
  # Neither query paginates; both cap every connection well below Linear's maximum because
  # query complexity is MULTIPLICATIVE across nested connections with a ceiling of 10000.
  # Measured against the live API: 250x250 = 69025 and 250x50 = 14025 both rejected, 100x50
  # accepted. Raising either teams number means re-measuring, not just doubling it.
  # `activeCycle` is a single object rather than a connection, so it costs nothing here.
  @teams_preflight_query """
  query SymphonyPreflightTeams($filter: TeamFilter!) {
    teams(filter: $filter, first: 100) {
      nodes {
        key
        activeCycle {
          name
          endsAt
        }
        states(first: 50) {
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
    issueLabels(filter: $filter, first: 250) {
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

Add the callback and its helpers:

```elixir
  @spec preflight(map()) :: :ok | {:error, term()}
  def preflight(tracker_settings) do
    case Scope.team_keys(tracker_settings) do
      [] ->
        :ok

      team_keys ->
        with {:ok, teams} <- fetch_preflight_teams(team_keys),
             {:ok, labels} <- fetch_preflight_labels(preflight_label_names(tracker_settings)) do
          warn_missing_active_cycles(tracker_settings, teams)
          report_preflight(tracker_settings, team_keys, teams, labels)
        end
    end
  end

  defp preflight_label_names(tracker_settings) do
    ((Map.get(tracker_settings, :any_labels) || []) ++ (Map.get(tracker_settings, :required_labels) || []))
    |> Enum.uniq()
  end

  defp fetch_preflight_teams(team_keys) do
    filter = %{or: Enum.map(team_keys, &%{key: %{eqIgnoreCase: &1}})}
    preflight_nodes(@teams_preflight_query, filter, "teams")
  end

  defp fetch_preflight_labels([]), do: {:ok, []}

  defp fetch_preflight_labels(label_names) do
    filter = %{or: Enum.map(label_names, &%{name: %{eqIgnoreCase: &1}})}
    preflight_nodes(@labels_preflight_query, filter, "issueLabels")
  end

  defp preflight_nodes(query, filter, root_key) do
    case client_module().graphql(query, %{filter: filter}) do
      {:ok, %{"data" => %{^root_key => %{"nodes" => nodes}}}} when is_list(nodes) -> {:ok, nodes}
      {:ok, %{"errors" => errors}} -> {:error, {:linear_graphql_errors, errors}}
      {:ok, _body} -> {:error, :linear_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  # A team legitimately has no active cycle during sprint cooldown, so this is a warning and
  # not a boot failure: refusing to start would turn a routine Linear state into an outage for
  # a container that restarts between sprints. At runtime the poll simply returns zero issues.
  defp warn_missing_active_cycles(tracker_settings, teams) do
    if Scope.current_cycle?(tracker_settings) do
      teams
      |> Enum.filter(&is_nil(&1["activeCycle"]))
      |> Enum.each(fn team ->
        Logger.warning(
          "Linear team #{inspect(team["key"])} has no active cycle; scope current_cycle will match nothing until a cycle starts"
        )
      end)
    end

    :ok
  end

  defp report_preflight(tracker_settings, team_keys, teams, labels) do
    reasons =
      unknown_team_keys(team_keys, teams) ++
        unknown_state_names(tracker_settings, teams) ++
        unknown_label_names(tracker_settings, team_keys, labels)

    case reasons do
      [] -> :ok
      reasons -> {:error, {:linear_preflight_failed, reasons}}
    end
  end

  defp unknown_team_keys(team_keys, teams) do
    resolved_keys = MapSet.new(teams, &String.downcase(&1["key"] || ""))

    team_keys
    |> Enum.reject(&MapSet.member?(resolved_keys, String.downcase(&1)))
    |> Enum.map(&"unknown Linear team key #{inspect(&1)}")
  end

  defp unknown_state_names(tracker_settings, teams) do
    configured =
      ((Map.get(tracker_settings, :active_states) || []) ++ (Map.get(tracker_settings, :terminal_states) || []))
      |> Enum.uniq()

    Enum.flat_map(teams, fn team ->
      known =
        team
        |> get_in(["states", "nodes"])
        |> Kernel.||([])
        |> MapSet.new(&String.downcase(&1["name"] || ""))

      configured
      |> Enum.reject(&MapSet.member?(known, String.downcase(&1)))
      |> Enum.map(&"state #{inspect(&1)} does not exist in Linear team #{inspect(team["key"])}")
    end)
  end

  defp unknown_label_names(tracker_settings, team_keys, labels) do
    labels_by_team =
      Enum.group_by(
        labels,
        &String.downcase(get_in(&1, ["team", "key"]) || ""),
        &String.downcase(&1["name"] || "")
      )

    Enum.flat_map(preflight_label_names(tracker_settings), fn label ->
      teams_with_label =
        Enum.filter(team_keys, fn key ->
          labels_by_team
          |> Map.get(String.downcase(key), [])
          |> Enum.member?(String.downcase(label))
        end)

      label_reason(label, teams_with_label, team_keys)
    end)
  end

  # Labels are team-scoped in Linear, so the same name exists once per team. Missing from one
  # listed team narrows the scope silently and is a warning; missing from all of them means
  # nothing can ever match and is an error.
  defp label_reason(label, [], _team_keys), do: ["label #{inspect(label)} does not exist in any listed Linear team"]

  defp label_reason(label, teams_with_label, team_keys) do
    case team_keys -- teams_with_label do
      [] ->
        []

      missing ->
        Logger.warning("Linear label #{inspect(label)} is absent from team(s) #{inspect(missing)}; those teams will match nothing for it")
        []
    end
  end
```

Add `Scope` to the alias line. Do **not** add a new client-injection mechanism: the adapter already resolves its client through `client_module/0` (`adapter.ex:104-106`, `Application.get_env(:symphony_elixir, :linear_client_module, Client)`), and `extensions_test.exs` already stubs it that way with a `setup` block that saves and restores the env key. Reuse both.

```elixir
  alias SymphonyElixir.Linear.{AgentTool, Client, Scope}
```

In the preflight tests, inject the stub the same way the existing adapter tests do, relying on the `setup` block at `extensions_test.exs:75-85` to restore it:

```elixir
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)
```

- [ ] **Step 5: Run preflight before the supervision tree starts**

In `elixir/lib/symphony_elixir/cli.ex`, add `optional(:preflight) => (-> :ok | {:error, term()})` to the deps type, wire `preflight: &run_tracker_preflight/0` into the default deps map, and gate application start on it:

```elixir
      # Validate the scope before starting the scheduling loop, otherwise a bad scope
      # dispatches work (workspace, clone, agent) before preflight can halt the VM.
      with :ok <- handle_preflight(expanded_path, deps), do: start_application(expanded_path, deps)
```

```elixir
  defp start_application(expanded_path, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
    end
  end

  defp handle_preflight(expanded_path, deps) do
    case run_preflight(deps) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Tracker preflight failed for workflow #{expanded_path}: #{format_preflight_error(reason)}"}
    end
  end

  defp run_preflight(deps) do
    deps
    |> Map.get(:preflight, fn -> :ok end)
    |> then(& &1.())
  end

  # Runs before the supervision tree, so it starts only the HTTP client it needs. An unloadable
  # workflow is left to application start, which reports it with its own message.
  defp run_tracker_preflight do
    case SymphonyElixir.Config.settings() do
      {:ok, settings} ->
        with {:ok, _started_apps} <- Application.ensure_all_started(:req) do
          SymphonyElixir.Tracker.preflight(settings.tracker)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp format_preflight_error({:linear_preflight_failed, reasons}) when is_list(reasons) do
    Enum.join(reasons, "; ")
  end

  defp format_preflight_error(reason), do: inspect(reason)
```

- [ ] **Step 6: Add the CLI wiring test**

Add to `elixir/test/symphony_elixir/cli_test.exs`:

```elixir
  test "a failing preflight prevents the supervision tree from starting" do
    workflow = write_workflow_file!([])

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      ensure_all_started: fn -> flunk("application must not start when preflight fails") end,
      preflight: fn -> {:error, {:linear_preflight_failed, ["unknown Linear team key \"NOPE\""]}} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, workflow], deps)
    assert message =~ "Tracker preflight failed"
    assert message =~ "NOPE"
  end

  test "a passing preflight starts the supervision tree" do
    workflow = write_workflow_file!([])

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, []} end,
      preflight: fn -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow], deps)
  end
```

`CLI.evaluate/2` is the existing entry point (`cli.ex:52`) and `@ack_flag` is already defined at `cli_test.exs:8`. No new test seam is needed.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/cli_test.exs`
Expected: PASS.

- [ ] **Step 8: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/symphony_elixir/tracker.ex lib/symphony_elixir/linear/adapter.ex lib/symphony_elixir/cli.ex \
        test/symphony_elixir/extensions_test.exs test/symphony_elixir/cli_test.exs
git commit -m "feat: resolve the Linear scope at startup via an optional Tracker.preflight callback"
```

---

### Task 7: `Tracker.scope_summary/1` and the status board

The board currently pattern-matches `%{kind: "linear", project_slug: project_slug}` — a core rendering module branching on one provider's config keys, which `SPEC.md:1313-1314` forbids. And `linear_project_url/1` builds `https://linear.app/project/#{slug}/issues` while real Linear URLs are workspace-prefixed; no workspace slug exists anywhere in config, so the line has been emitting a broken URL into all ten snapshot fixtures.

Two non-obvious constraints. The wrapper MUST resolve through `adapter_for_kind/1` as `Tracker.validate_config/1` does at `tracker.ex:91-98`, **not** through `adapter/0` → `adapter_for_settings!/1`, which raises `MatchError` on an unknown kind — because `format_project_link_lines/0` is also called on the degraded `:error` path at `status_dashboard.ex:386` where today it safely renders `n/a`. And the board re-renders every 16 ms (`server.render_interval_ms`, `config/schema.ex:285`), so `scope_summary/1` stays pure string assembly.

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex` (callback, `@optional_callbacks`, dispatcher)
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex` (delegate to `Scope`)
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex:395-415`, delete `:431`
- Modify: `elixir/test/support/test_support.exs:98` (fixture slug `project` → `acme-web`)
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs:1183-1197`, `:1223-1226`
- Modify: all ten files under `elixir/test/fixtures/status_dashboard_snapshots/`

**Interfaces:**
- Consumes: `Scope.scope_summary/1` from Task 1.
- Produces: `SymphonyElixir.Tracker.scope_summary(tracker_settings :: map()) :: String.t()` — optional callback, `"n/a"` fallback.

- [ ] **Step 1: Write the failing tests**

Add to `elixir/test/symphony_elixir/extensions_test.exs`:

```elixir
  test "the tracker facade delegates scope_summary to the linear adapter" do
    settings = %{
      kind: "linear",
      provider: %{"team_keys" => ["MDZ"], "current_cycle" => true},
      project_slug: nil,
      any_labels: [],
      required_labels: []
    }

    assert SymphonyElixir.Tracker.scope_summary(settings) == "teams MDZ · current cycle"
  end

  test "the tracker facade falls back to n/a for adapters without scope_summary" do
    assert SymphonyElixir.Tracker.scope_summary(%{kind: "memory"}) == "n/a"
  end

  test "the tracker facade returns n/a rather than raising for an unknown kind" do
    # format_project_link_lines/0 also runs on the dashboard's degraded :error path.
    assert SymphonyElixir.Tracker.scope_summary(%{kind: "nope"}) == "n/a"
  end
```

Replace the two assertion sites in `elixir/test/symphony_elixir/orchestrator_status_test.exs`. At `:1183-1197`:

```elixir
    assert rendered =~ "│ Scope:"
    assert rendered =~ "project acme-web"
    refute rendered =~ "linear.app"
    refute rendered =~ "Dashboard:"
```

At `:1223-1226`:

```elixir
    assert rendered =~ "│ Scope:"
    assert rendered =~ "project acme-web"
    assert rendered =~ "│ Dashboard:"
    assert rendered =~ "http://127.0.0.1:4000/"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/orchestrator_status_test.exs`
Expected: FAIL — `Tracker.scope_summary/1` is undefined and the board still renders `│ Project:` with the broken URL.

- [ ] **Step 3: Add the optional callback**

In `elixir/lib/symphony_elixir/tracker.ex`, add the callback beside `preflight`:

```elixir
  @callback scope_summary(map()) :: String.t()
```

Add to `@optional_callbacks`:

```elixir
                      scope_summary: 1,
```

Add the dispatcher, resolving through `adapter_for_kind/1` and swallowing an unknown kind so the degraded render path cannot crash:

```elixir
  @doc """
  A short human-readable description of the adapter's configured read scope.

  Rendered on the status board. Resolves through `adapter_for_kind/1` rather
  than `adapter/0` because the board also renders this on its degraded path,
  where the configured kind may not resolve at all.
  """
  @spec scope_summary(map()) :: String.t()
  def scope_summary(%{kind: kind} = tracker_settings) do
    case adapter_for_kind(kind) do
      {:ok, adapter} ->
        if Code.ensure_loaded?(adapter) and function_exported?(adapter, :scope_summary, 1) do
          adapter.scope_summary(tracker_settings)
        else
          "n/a"
        end

      {:error, _reason} ->
        "n/a"
    end
  end

  def scope_summary(_tracker_settings), do: "n/a"
```

- [ ] **Step 4: Delegate from the Linear adapter**

In `elixir/lib/symphony_elixir/linear/adapter.ex`:

```elixir
  @spec scope_summary(map()) :: String.t()
  def scope_summary(tracker_settings), do: Scope.scope_summary(tracker_settings)
```

- [ ] **Step 5: Render the scope line and delete the broken URL builder**

In `elixir/lib/symphony_elixir/status_dashboard.ex`, replace `format_project_link_lines/0` (lines 395-415):

```elixir
  defp format_project_link_lines do
    scope_part =
      case Tracker.scope_summary(Config.settings!().tracker) do
        "n/a" -> colorize("n/a", @ansi_gray)
        summary -> colorize(summary, @ansi_cyan)
      end

    scope_line = colorize("│ Scope: ", @ansi_bold) <> scope_part

    case dashboard_url() do
      url when is_binary(url) ->
        [scope_line, colorize("│ Dashboard: ", @ansi_bold) <> colorize(url, @ansi_cyan)]

      _ ->
        [scope_line]
    end
  end
```

Delete `linear_project_url/1` entirely (line 431). No URL is invented: the poll query already selects `url` onto the `Issue` struct (`client.ex:27`), and per-issue links are where an operator clicks.

Add the alias if the module does not already have it:

```elixir
  alias SymphonyElixir.Tracker
```

- [ ] **Step 6: Rename the fixture slug**

In `elixir/test/support/test_support.exs:98`, change the default:

```elixir
      tracker_project_slug: "acme-web",
```

This stops the artifacts reading as `project project`.

- [ ] **Step 7: Regenerate the snapshot fixtures**

Run: `UPDATE_SNAPSHOTS=1 mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`
Then inspect the diff: `git diff test/fixtures/status_dashboard_snapshots/`
Expected: exactly one changed line per file across all ten files — line 7 of each `.snapshot.txt` and line 8 of each `.evidence.md` — going from `│ Project: https://linear.app/project/project/issues` to `│ Scope: project acme-web`. Never hand-edit these files. Any other changed line means the render changed more than intended; stop and investigate.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs`
Expected: PASS.

- [ ] **Step 9: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/symphony_elixir/tracker.ex lib/symphony_elixir/linear/adapter.ex \
        lib/symphony_elixir/status_dashboard.ex test/support/test_support.exs \
        test/symphony_elixir/extensions_test.exs test/symphony_elixir/orchestrator_status_test.exs \
        test/fixtures/status_dashboard_snapshots/
git commit -m "feat: render the tracker scope on the status board via an optional callback"
```

---

### Task 8: `SPEC.md` and documentation

`SPEC.md` is the source of truth and nothing enforces it mechanically: `mix specs.check` is a pure `@spec` presence linter over `lib/` that never reads Markdown, and no test or CI step parses `SPEC.md`. The amendment lands here or it never happens.

The "one instance, one project" assertion is duplicated across five tiers and every tier must move together. Three of the files are operator-facing templates that sit outside the documented Docs Update Policy yet are what a customer actually copies.

**Files:**
- Modify: `SPEC.md` §11.1 item 2 (`:1273-1274`), §5.3.1, §17.3 (`:2191-2193`, `:2202-2203`)
- Modify: `README.md:31-32`
- Modify: `elixir/README.md:85-86`, `:117`, `:229-231`, `:346-397` (profile, especially `:354-356`), `:380-388`, `:390-394`
- Modify: `elixir/WORKFLOW.md` front matter and `:109`, `:303-306`
- Modify: `workflows/example.md:8`
- Modify: `deploy/client-template/README.md:3`, `:31-38`
- Modify: `deploy/client-template/workflow.md:10-14`

**Interfaces:**
- Consumes: the final error-atom set and config surface from Tasks 5 and 6.
- Produces: documentation only.

- [ ] **Step 1: Amend `SPEC.md` §11.1 item 2**

Replace the two lines at `SPEC.md:1273-1274`:

```markdown
   - `fetch_issues_by_ids` MUST NOT apply configured scope selection as a filter. An adapter
     whose IDs are only meaningful inside a container MAY remain container-bound; this is
     REQUIRED for GitHub and GitLab, where an ID is `#N` within a repository.
   - Omission MUST mean the ID is not retrievable — deleted, inaccessible, or foreign to the
     credential's workspace — never "outside the configured scope". The orchestrator still
     treats omission as "no longer visible" and invents no synthetic state.
   - Candidate admission is governed by `fetch_issues_by_states` and configured scope;
     lifecycle continuation is governed by issue state.
```

Leave `SPEC.md:1289-1292` untouched: an ID refresh MUST still fail rather than silently omit a malformed record.

- [ ] **Step 2: Add `any_labels` to `SPEC.md` §5.3.1 and update §17.3**

Document `any_labels` beside `required_labels` in §5.3.1: an array of label names, default `[]`, where an issue must carry at least one entry to be a candidate, compared case-insensitively after trimming, and an empty list imposes no constraint.

In §17.3, adjust `:2191-2193` and `:2202-2203` so the checklist matches the new §11.1 — candidate admission applies scope, ID refresh does not.

- [ ] **Step 3: Verify no spec/implementation conflict remains**

Run: `grep -n "configured scope" ../SPEC.md`
Expected: no remaining sentence claiming an ID refresh is scope-filtered.

- [ ] **Step 4: Update the concept and run docs**

`README.md:31-32`: one instance drives one repo; its Linear queue is selected by team, current cycle, project, labels, or a conjunction, so adding a Linear project needs no Symphony config change.

`elixir/README.md:85-86`: replace "scoped to a **single** project" with the four selectors and note that at least one container selector is required.

`elixir/README.md:117`: the minimum edit for a new deployment is a scope selector plus the `hooks.after_create` clone URL.

`elixir/README.md:229-231`: keep the note that adapter-owned endpoint, scope, and auth settings belong under `tracker.provider` and that the flat aliases remain for compatibility; add that `team_keys` and `current_cycle` have no flat aliases.

- [ ] **Step 5: Rewrite the Linear adapter profile**

In `elixir/README.md:346-397`:
- Config bullet (`:348-353`): `provider.team_keys` (list), `provider.current_cycle` (boolean, requires `team_keys`), `provider.project_slug`, plus core `any_labels` / `required_labels`. At least one of the three container selectors is required.
- Scope and paging (`:354-356`): **this is the sentence that currently states ID refreshes are project-scoped.** Replace with: candidate reads filter the configured scope and requested state names, following Linear pages of 50; ID refreshes apply no scope and batch up to 50 IDs; empty state/ID lists return `{:ok, []}` without a Linear request. Add that team keys, label names, and state names match case-insensitively.
- `:369`: keep the note that scope governs scheduler reads and not raw tool calls.
- Error list (`:380-388`): remove `:missing_linear_project_slug`; add `:missing_linear_scope`, `:missing_linear_team_keys`, `:invalid_linear_team_keys`, `:invalid_linear_current_cycle`, and `{:linear_preflight_failed, reasons}`.
- Portable-category mapping (`:390-394`): map the four new config atoms to `tracker_config`. This table exists to satisfy `SPEC.md:1324-1325` and is easy to miss.
- Add a preflight paragraph: two requests at startup resolve team keys, workflow state names, and label names; a team with no active cycle is a warning, an unresolved team key or a label absent from every listed team is a boot failure.
- Add the no-active-cycle runtime note: the poll returns zero issues and the instance idles; no per-tick probe is spent and no warning is emitted, because cycles legitimately end. Operator visibility is the boot warning and the board's `Scope:` line.

- [ ] **Step 6: Update the config contract and operator templates**

`elixir/WORKFLOW.md`: leave this repository's own scope on `project_slug`; document the new keys. Fix `:109` and `:303-306`, which instruct agents that follow-up issues go "to the same project as the current issue" — unsatisfiable when no project is configured. Reword to place follow-ups in the same scope as the current issue, naming the project only when one is configured.

`workflows/example.md:8` and `deploy/client-template/workflow.md:10-14`: keep `project_slug` as the default and add the new keys as commented alternatives, for example:

```yaml
    project_slug: "REPLACE-with-your-linear-project-slug"
    # Or scope by team instead, so epics can come and go without a config change:
    # team_keys: ["REPLACE-with-your-team-key"]
    # current_cycle: true          # requires team_keys; the team's sprint becomes the queue
```

`deploy/client-template/README.md:3`: "One container, one project" becomes one container, one scope — a single repo plus a Linear scope selected by team, cycle, project, or labels.

`deploy/client-template/README.md:31-38`: the project-slug explainer becomes a scope explainer. Keep the silent-failure warning, and point it at preflight: an unknown team key or label now fails at startup with a named error instead of idling silently. Note that a `project_slug` typo still fails silently, because Linear returns zero issues for an unknown slug and preflight does not resolve project slugs.

- [ ] **Step 7: Verify the retired atom is gone from the docs**

Run: `grep -rn "missing_linear_project_slug" . --include=*.md`
Expected: no matches anywhere in the repository.

- [ ] **Step 8: Verify no stale "one project" claim remains**

Run: `grep -rn "one project" README.md elixir/README.md deploy/ workflows/`
Expected: only sentences that are still true (for example, guidance that you may still run one container per project if you want isolation).

- [ ] **Step 9: Commit**

```bash
git add ../SPEC.md ../README.md README.md WORKFLOW.md ../workflows/example.md ../deploy/client-template/
git commit -m "docs: document team, cycle, project and label scoping and the unscoped ID refresh"
```

---

### Task 9: Live end-to-end cycle scenario

A wrong reading of `cycle.isActive` fails silently as zero issues, which is the worst failure mode in this change. This scenario moves that assumption from "the schema says so" to "observed against the real API".

`live_e2e_test.exs` already resolves a team by key and performs `projectCreate`, `issueCreate`, and `projectUpdate`, and has reusable `graphql_data!/2`, `fetch_successful_entity!/3`, and `update_entity/4` helpers. It has no cycle machinery. Critically, its existing flow dispatches through `AgentRunner.run/3` directly and never exercises `fetch_issues_by_states`, so this scenario must call the poll path explicitly or it proves nothing about the filter.

**Files:**
- Modify: `elixir/test/symphony_elixir/live_e2e_test.exs`

**Interfaces:**
- Consumes: `SymphonyElixir.Linear.Client.fetch_issues_by_states/1` and the `provider.team_keys` / `provider.current_cycle` config surface.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the cycle mutations**

Add module attributes beside the existing mutations. `CycleCreateInput` requires exactly `teamId`, `startsAt`, and `endsAt`:

```elixir
  @cycle_create_mutation """
  mutation SymphonyLiveCycleCreate($teamId: String!, $startsAt: DateTime!, $endsAt: DateTime!, $name: String) {
    cycleCreate(input: {teamId: $teamId, startsAt: $startsAt, endsAt: $endsAt, name: $name}) {
      success
      cycle {
        id
        name
      }
    }
  }
  """

  @issue_cycle_mutation """
  mutation SymphonyLiveIssueCycle($issueId: String!, $cycleId: String!) {
    issueUpdate(id: $issueId, input: {cycleId: $cycleId}) {
      success
    }
  }
  """
```

- [ ] **Step 2: Write the scenario**

Add the test, gated the same way as the existing ones with `@tag skip: @live_e2e_skip_reason`:

```elixir
  @tag skip: @live_e2e_skip_reason
  test "a team plus current cycle scope dispatches an issue with no project configured" do
    team_key = System.get_env("SYMPHONY_LIVE_LINEAR_TEAM_KEY") || @default_team_key
    team = fetch_team!(team_key)
    state = active_state!(team)

    now = DateTime.utc_now()
    starts_at = DateTime.add(now, -1, :day)
    ends_at = DateTime.add(now, 13, :day)

    cycle =
      fetch_successful_entity!(
        @cycle_create_mutation,
        %{
          teamId: team["id"],
          startsAt: DateTime.to_iso8601(starts_at),
          endsAt: DateTime.to_iso8601(ends_at),
          name: "symphony-live-#{System.unique_integer([:positive])}"
        },
        ["cycleCreate", "cycle"]
      )

    issue = create_issue!(team, nil, state, "symphony live cycle scope")

    :ok = update_entity(@issue_cycle_mutation, %{issueId: issue["id"], cycleId: cycle["id"]}, ["issueUpdate"], "attach cycle")

    # Scope by team + current cycle with NO project_slug, then read through the poll path
    # itself rather than dispatching directly, because the poll path is what carries the filter.
    write_live_workflow!(
      tracker_project_slug: nil,
      tracker_provider: %{"team_keys" => [team_key], "current_cycle" => true}
    )

    assert {:ok, issues} = SymphonyElixir.Linear.Client.fetch_issues_by_states(active_state_names(team))
    assert Enum.any?(issues, &(&1.id == issue["id"])), "the cycle-scoped poll did not return the seeded issue"

    # And the same scope must NOT return an issue outside the cycle.
    other_issue = create_issue!(team, nil, state, "symphony live outside cycle")

    assert {:ok, scoped_issues} = SymphonyElixir.Linear.Client.fetch_issues_by_states(active_state_names(team))
    refute Enum.any?(scoped_issues, &(&1.id == other_issue["id"])), "cycle scoping returned an issue with no cycle"

    # The ID refresh must find the out-of-cycle issue anyway: continuation is state-gated.
    assert {:ok, refreshed} = SymphonyElixir.Linear.Client.fetch_issues_by_ids([other_issue["id"]])
    assert Enum.any?(refreshed, &(&1.id == other_issue["id"])), "an unscoped ID refresh failed to return an out-of-scope issue"
  end
```

Reuse the existing helpers for team resolution, state selection, issue creation, and workflow rewriting; match their current names in the file rather than inventing new ones. `create_issue!` takes a project in the existing flow — pass `nil` so no project is set, and adjust the helper to omit `projectId` when it is `nil`.

- [ ] **Step 3: Verify the scenario is skipped by default**

Run: `mix test test/symphony_elixir/live_e2e_test.exs`
Expected: all live tests reported as skipped, no network calls.

- [ ] **Step 4: Run the scenario against the real API**

Run: `SYMPHONY_RUN_LIVE_E2E=1 mix test test/symphony_elixir/live_e2e_test.exs -k "current cycle scope"`
Expected: PASS. A failure asserting the seeded issue was not returned means `cycle.isActive` does not mean what the schema implies — stop and re-verify against the live API before proceeding.

- [ ] **Step 5: Commit**

```bash
git add test/symphony_elixir/live_e2e_test.exs
git commit -m "test: live e2e coverage for team plus current-cycle scoping"
```

---

### Task 10: Full gate

- [ ] **Step 1: Run the complete quality gate**

Run: `make all`
Expected: PASS — setup, build, format check, lint (`specs.check` + `credo --strict`), coverage at 100%, dialyzer.

- [ ] **Step 2: Confirm the new module is coverage-measured and the ignore list did not grow**

Run: `git diff origin/main -- mix.exs`
Expected: no change to `coverage_ignore_modules/0`. If `SymphonyElixir.Linear.Scope` was added there, remove it and cover the missing branches instead (`CLAUDE.md:71`).

- [ ] **Step 3: Confirm backward compatibility by hand**

Run: `grep -n "project_slug" WORKFLOW.md`
Expected: this repository's own scope is still `tracker.provider.project_slug`, unchanged. Start the service against it and confirm the board's `Scope:` line reads `project <slug>` and that polling still dispatches.

- [ ] **Step 4: Commit any gate fixes**

```bash
git add -A
git commit -m "chore: quality gate"
```

---

## Self-Review

**Spec coverage.** Every design section maps to a task: config surface → Tasks 2 and 5; ownership boundary → Task 1; validation → Tasks 1 and 5; preflight → Task 6; query assembly → Task 3; the by-IDs invariant → Task 4; the `SPEC.md` amendment → Task 8; the status board → Task 7; testing → distributed across every task plus Task 9; documentation → Task 8; risks → mitigated in Tasks 6 (no-active-cycle warning), 8 (silent `project_slug` typo documented), and 9 (`cycle.isActive` verified live).

Two spec items deliberately not implemented as separate tasks because they are properties of other tasks rather than work of their own: "presence is value-based, never key-based" is enforced by `validate_scope_present/2` in Task 1 and tested by the injected-nil case; "both gates delegate to `Scope.validate/1`" is Task 5 steps 3 and 4.

**Two refinements over the committed spec, both noted where they occur.** The spec's filter examples use string keys; the plan uses atom keys throughout, because the existing variable maps in `client.ex` use atoms and `Jason` encodes atom keys as JSON strings, so the wire format is identical. And the spec lists three public functions on `Linear.Scope`; the plan adds `team_keys/1` and `current_cycle?/1` so preflight and the board never re-read a provider key name, which strengthens rather than weakens the "one module knows the key names" invariant.

**Type consistency.** `Scope.filter/2` is `filter(map(), keyword()) :: map()` everywhere it appears (Tasks 1, 3). `Scope.validate/1` returns `:ok | {:error, atom()}` and is consumed as such by `Adapter.validate_config/1` and `configured_tracker_for_read/0` (Task 5). `Issue.routable?/2` takes a map in Task 2 and every call site is updated in the same task. `Tracker.preflight/1` and `Tracker.scope_summary/1` match their `@callback` declarations. `fetch_issues_by_ids_for_test/2` keeps arity 2 across Tasks 3 and 4 while its internals lose the tracker argument.

**Ordering.** Task 3 rewrites how the filter travels while keeping the by-IDs read scoped; Task 4 then changes what that filter contains; Task 5 only opens the config surface once the query can honour it. Every commit leaves the tree shippable, and a `project_slug`-only deployment behaves identically until Task 7 changes the board label.
