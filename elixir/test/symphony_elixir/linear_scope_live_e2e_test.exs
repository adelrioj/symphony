defmodule SymphonyElixir.LinearScopeLiveE2ETest do
  @moduledoc """
  Read-only live checks for the Linear team/label scope path.

  These exist because the scope queries can be perfectly valid GraphQL, shaped exactly as the unit
  tests assert, and still be rejected by the live API. Linear scores query complexity
  multiplicatively across nested connections, so a page size that looks harmless in isolation can
  push a nested query over the budget. That failure is invisible to every stub-based test: the
  stub answers whatever it is handed, so the suite stays green while every real preflight call
  400s and no team-scoped deployment can boot.

  Unlike `live_e2e_test.exs`, nothing here creates a project, an issue, or an agent session. Every
  test is a read.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter

  @moduletag :live_e2e
  @moduletag timeout: 120_000

  @skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1",
                 do: "set SYMPHONY_RUN_LIVE_E2E=1 to enable the live Linear scope checks"
               )

  # A label name no workspace will contain, so the labels query is always issued (an empty label
  # list short-circuits it) and always fails to resolve — which is the deterministic outcome we
  # want when the point is to prove the query itself was accepted.
  @unresolvable_label "symphony-live-e2e-label-that-does-not-exist"

  @teams_discovery_query """
  query SymphonyLiveScopeTeams {
    teams(first: 1) {
      nodes {
        key
        states(first: 50) {
          nodes {
            name
          }
        }
      }
    }
  }
  """

  @labels_discovery_query """
  query SymphonyLiveScopeLabels {
    issueLabels(first: 100) {
      nodes {
        name
        team {
          key
        }
      }
    }
  }
  """

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$LINEAR_API_KEY",
      tracker_project_slug: "live-scope-bootstrap",
      observability_enabled: false
    )

    :ok
  end

  @tag skip: @skip_reason
  test "preflight issues both queries without tripping Linear's query-complexity budget" do
    team = discover_team!()

    result =
      Adapter.preflight(
        live_settings(%{
          team_keys: [team.key],
          any_labels: [@unresolvable_label],
          active_states: [],
          terminal_states: []
        })
      )

    # The distinction that matters: a `:linear_preflight_failed` means both queries were accepted
    # and Linear answered — the label simply did not resolve, which is what we asked for. A status
    # or GraphQL error means the query itself was rejected, which is the regression this guards.
    case result do
      {:error, {:linear_preflight_failed, reasons}} ->
        assert Enum.any?(reasons, &(&1 =~ @unresolvable_label)),
               "expected the unresolvable label to be reported, got: #{inspect(reasons)}"

      {:error, {:linear_api_status, status}} ->
        flunk("""
        Linear rejected a preflight query with HTTP #{status}.

        The usual cause is query complexity: it is multiplicative across nested connections, so the
        `first:` on the teams query multiplies with the `first:` on its nested states. Measured
        against the live API, teams 250 x states 250 scored 69025 and 250 x 50 scored 14025 against
        a maximum of 10000, while 100 x 50 was accepted. Re-measure before raising either number.
        """)

      other ->
        flunk("expected the queries to be accepted by Linear, got: #{inspect(other)}")
    end
  end

  @tag skip: @skip_reason
  test "a real team, state and label resolve at preflight" do
    team = discover_team!()
    state = List.first(team.states)

    result =
      Adapter.preflight(
        live_settings(%{
          team_keys: [team.key],
          any_labels: List.wrap(discover_label(team.key)),
          active_states: List.wrap(state),
          terminal_states: []
        })
      )

    assert result == :ok, "expected a real team/state/label to resolve, got: #{inspect(result)}"
  end

  @tag skip: @skip_reason
  test "a misspelled team key is reported by name rather than resolving silently" do
    team = discover_team!()
    misspelled = team.key <> "XX"

    assert {:error, {:linear_preflight_failed, reasons}} =
             Adapter.preflight(
               live_settings(%{
                 team_keys: [misspelled],
                 any_labels: [],
                 active_states: [],
                 terminal_states: []
               })
             )

    assert Enum.any?(reasons, &(&1 =~ misspelled)),
           "expected the unknown team key to be named, got: #{inspect(reasons)}"
  end

  @tag skip: @skip_reason
  test "the poll filter is accepted for a team-scoped read" do
    team = discover_team!()
    state = List.first(team.states)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$LINEAR_API_KEY",
      tracker_project_slug: nil,
      tracker_provider: %{"team_keys" => [team.key]},
      tracker_active_states: [state],
      observability_enabled: false
    )

    assert {:ok, issues} = Tracker.fetch_issues_by_states([state]),
           "the built IssueFilter was rejected for a team-scoped read"

    assert is_list(issues)
  end

  defp live_settings(overrides) do
    Map.merge(
      %{
        kind: "linear",
        team_keys: [],
        project_slug: nil,
        any_labels: [],
        required_labels: [],
        active_states: [],
        terminal_states: []
      },
      overrides
    )
  end

  defp discover_team! do
    %{"teams" => %{"nodes" => nodes}} = graphql_data!(@teams_discovery_query)

    case nodes do
      [%{"key" => key, "states" => %{"nodes" => states}} | _] ->
        %{key: key, states: Enum.map(states, & &1["name"])}

      [] ->
        flunk("the Linear workspace behind LINEAR_API_KEY has no teams to scope against")
    end
  end

  # A label in the given team, else a workspace-level label (which belongs to every team), else
  # nil so the caller simply omits labels.
  defp discover_label(team_key) do
    %{"issueLabels" => %{"nodes" => nodes}} = graphql_data!(@labels_discovery_query)
    downcased = String.downcase(team_key)

    nodes
    |> Enum.filter(&label_applies_to_team?(&1, downcased))
    |> Enum.map(& &1["name"])
    |> List.first()
  end

  defp label_applies_to_team?(node, downcased_team_key) do
    case get_in(node, ["team", "key"]) do
      # A workspace-level label belongs to no team and therefore applies to every team.
      nil -> true
      key -> String.downcase(key) == downcased_team_key
    end
  end

  defp graphql_data!(query) do
    case Client.graphql(query, %{}) do
      {:ok, %{"data" => data}} when is_map(data) -> data
      {:ok, payload} -> flunk("Linear discovery query returned an unexpected payload: #{inspect(payload)}")
      {:error, reason} -> flunk("Linear discovery query failed: #{inspect(reason)}")
    end
  end
end
