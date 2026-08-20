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

  test "a blank project slug produces no project conjunct" do
    filter = Client.build_issue_filter(tracker(%{project_slug: "   ", team_keys: ["MDZ"]}), state_names: ["Todo"])

    refute Enum.any?(filter.and, &Map.has_key?(&1, :project))
  end
end
