defmodule SymphonyElixir.LinearScopeLiveE2ETest do
  @moduledoc """
  Read-only live checks for the Linear scope path.

  These exist because the scope queries can be perfectly valid GraphQL, shaped exactly as the unit
  tests assert, and still be rejected by the live API. Linear scores query complexity
  multiplicatively across nested connections, so a page size that looks harmless in isolation can
  push a nested query over the budget. That failure is invisible to every stub-based test: the
  stub answers whatever it is handed, so the suite stays green while every real preflight call
  400s and no team-scoped deployment can boot.

  Unlike `live_e2e_test.exs`, nothing here creates a cycle, a project, an issue, or an agent
  session. Every test is a read, so this file is safe to run against a real workspace on every
  change to `Linear.Scope` or the preflight queries.
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
  # want when the point is to prove the query itself was accepted. Filtering by this one name also
  # guarantees a non-full label page, so the miss is reported as absent rather than unprovable.
  @unresolvable_label "symphony-live-e2e-label-that-does-not-exist"

  # A slug no workspace will contain. The bootstrap config needs some scope to satisfy
  # `Scope.validate/1`, and a project that cannot resolve means a poll leaking from a concurrently
  # running Orchestrator matches nothing rather than dispatching against a real team.
  @bootstrap_project_slug "symphony-live-e2e-scope-bootstrap"

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
      tracker_project_slug: @bootstrap_project_slug,
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
          provider: %{"team_keys" => [team.key]},
          any_labels: [@unresolvable_label]
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
        against the live API, teams 250 x states 250 and 250 x 50 are both rejected against a
        maximum of 10000, while 100 x 50 is accepted. Re-measure before raising either number.
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
          provider: %{"team_keys" => [team.key]},
          any_labels: List.wrap(discover_label(team.key)),
          active_states: List.wrap(state)
        })
      )

    assert result == :ok, "expected a real team/state/label to resolve, got: #{inspect(result)}"
  end

  @tag skip: @skip_reason
  test "a current-cycle scope resolves against a real team" do
    team = discover_team!()

    # `activeCycle` is selected by the same teams query, so this proves the cycle arm of preflight
    # against the live schema without creating a cycle. A team in sprint cooldown warns rather than
    # failing, so the assertion is on the result, not on the log.
    result =
      Adapter.preflight(
        live_settings(%{
          provider: %{"team_keys" => [team.key], "current_cycle" => true}
        })
      )

    assert result == :ok, "expected a current-cycle scope to resolve, got: #{inspect(result)}"
  end

  @tag skip: @skip_reason
  test "a misspelled team key is reported by name rather than resolving silently" do
    team = discover_team!()
    misspelled = team.key <> "XX"

    assert {:error, {:linear_preflight_failed, reasons}} =
             Adapter.preflight(live_settings(%{provider: %{"team_keys" => [misspelled]}}))

    assert Enum.any?(reasons, &(&1 =~ misspelled)),
           "expected the unknown team key to be named, got: #{inspect(reasons)}"
  end

  @tag skip: @skip_reason
  test "the poll filter is accepted for a team scope and for a team plus current-cycle scope" do
    team = discover_team!()
    state = List.first(team.states)

    stop_agent_runtime!()

    assert_poll_filter_accepted!(%{"team_keys" => [team.key]}, state)
    assert_poll_filter_accepted!(%{"team_keys" => [team.key], "current_cycle" => true}, state)
  end

  # The read below goes through the production entry point, so it reads the scope from the loaded
  # workflow rather than from an argument. Writing a live team scope to the active workflow file is
  # what a running Orchestrator would poll with the real token, dispatching real agents against
  # every dispatchable issue in that team, so the runtime is stopped first and the bootstrap scope
  # restored after — the same guard the mutating cycle scenario in `live_e2e_test.exs` uses.
  defp stop_agent_runtime! do
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    on_exit(fn ->
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: @bootstrap_project_slug,
        observability_enabled: false
      )

      restart_agent_runtime_if_needed()
    end)

    if is_pid(runtime_pid) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    :ok
  end

  defp restart_agent_runtime_if_needed do
    if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
      case Supervisor.restart_child(
             SymphonyElixir.Supervisor,
             SymphonyElixir.AgentRuntimeSupervisor
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp assert_poll_filter_accepted!(provider, state) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$LINEAR_API_KEY",
      tracker_project_slug: nil,
      tracker_provider: provider,
      tracker_active_states: [state],
      observability_enabled: false
    )

    assert {:ok, issues} = Tracker.fetch_issues_by_states([state]),
           "the built IssueFilter was rejected for scope #{inspect(provider)}"

    assert is_list(issues)
  end

  defp live_settings(overrides) do
    Map.merge(
      %{
        kind: "linear",
        provider: %{},
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
