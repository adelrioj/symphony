defmodule SymphonyElixir.LinearScopeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Scope

  # Mirrors a finalized tracker settings map: `provider` carries string keys because
  # `Config.Schema.normalize_keys/1` stringifies them, and `project_slug` is present as a
  # typed field because the schema mirrors it back out of the provider map.
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
      # The schema runs Map.put_new("project_slug", nil) AFTER drop_nil_values, so a finalized
      # provider map always has the key. Presence must be decided by value.
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

    test "a non-map provider is treated as carrying no scope keys" do
      assert Scope.validate(tracker(%{provider: nil})) == {:error, :missing_linear_scope}
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

    test "a non-map provider yields no team keys and no cycle" do
      settings = tracker(%{provider: nil})
      assert Scope.team_keys(settings) == []
      refute Scope.current_cycle?(settings)
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

    test "non-list label fields are treated as absent" do
      settings = tracker(%{project_slug: "acme-web", any_labels: nil, required_labels: nil})

      assert Scope.filter(settings, []) == %{and: [%{project: %{slugId: %{eq: "acme-web"}}}]}
    end

    test "a padded project_slug is trimmed before it reaches the filter" do
      # Presence is decided on the trimmed slug, so emitting the raw one would count as a
      # scope and then match no project at all.
      settings = tracker(%{project_slug: "  acme-web  "})

      assert Scope.filter(settings, []) == %{and: [%{project: %{slugId: %{eq: "acme-web"}}}]}
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

    test "opts default to no state names" do
      settings = tracker(%{project_slug: "acme-web"})
      assert Scope.filter(settings) == %{and: [%{project: %{slugId: %{eq: "acme-web"}}}]}
    end

    test "an id-bearing option is rejected rather than silently ignored" do
      # The by-ids read must not be reachable through this module at all: it applies no scope,
      # so an ID mode here is what would make a scoped ID read representable.
      settings = tracker(%{project_slug: "acme-web"})

      assert_raise ArgumentError, ~r/unknown keys \[:ids\]/, fn ->
        Scope.filter(settings, ids: ["issue-1"])
      end
    end

    test "filter never emits an id key on the state names path" do
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

    test "a padded project_slug is trimmed in the summary" do
      assert Scope.scope_summary(tracker(%{project_slug: "  acme-web  "})) == "project acme-web"
    end

    test "every selector renders in the fixed five-part order" do
      settings =
        tracker(%{
          project_slug: "acme-web",
          any_labels: ["feat-symphony"],
          required_labels: ["migrated"],
          provider: %{"team_keys" => ["MDZ", "TRA"], "current_cycle" => true}
        })

      assert Scope.scope_summary(settings) ==
               "teams MDZ, TRA · current cycle · project acme-web · any labels feat-symphony · required labels migrated"
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

    test "non-list label fields and a non-map provider degrade to n/a" do
      settings = tracker(%{provider: nil, any_labels: nil, required_labels: nil})
      assert Scope.scope_summary(settings) == "n/a"
    end
  end
end
