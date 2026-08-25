defmodule SymphonyElixir.LiveE2ETest do
  use SymphonyElixir.TestSupport

  require Logger
  alias SymphonyElixir.Linear.Scope
  alias SymphonyElixir.SSH

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @default_team_key "SYME2E"
  @docker_worker_count 2
  @docker_support_dir Path.expand("../support/live_e2e_docker", __DIR__)
  @docker_compose_file Path.join(@docker_support_dir, "docker-compose.yml")
  @result_file "LIVE_E2E_RESULT.txt"
  @scope_read_deadline_ms 30_000
  @scope_read_poll_interval_ms 1_000
  # A borrowed future cycle must not be able to START during the run. `Cycle.isFuture` is evaluated
  # server-side at read time, but the decisive refute lands much later: after seeding, several round
  # trips, and up to @scope_read_deadline_ms of polling. A cycle that rolled over mid-run would become
  # the active cycle, its issue would appear in the scoped read, and the run would flunk with
  # "cycle.isActive matches cycle membership rather than the running cycle" — the exact wrong
  # conclusion this scenario exists to rule out. One hour is more than ten times the 300s moduletag
  # that hard-caps the whole test, and deliberately no larger: the window in which this refuses to
  # borrow is also the window in which it falls through to minting a cycle, and minting is what can
  # collide with a cadence team's already-scheduled next cycle.
  @future_cycle_start_margin_seconds 3_600
  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_LIVE_E2E=1 to enable the real Linear/Codex end-to-end test"
                        )

  @team_query """
  query SymphonyLiveE2ETeam($key: String!) {
    teams(filter: {key: {eq: $key}}, first: 1) {
      nodes {
        id
        key
        name
        states(first: 50) {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @create_project_mutation """
  mutation SymphonyLiveE2ECreateProject($name: String!, $teamIds: [String!]!) {
    projectCreate(input: {name: $name, teamIds: $teamIds}) {
      success
      project {
        id
        name
        slugId
        url
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyLiveE2ECreateIssue(
    $teamId: String!
    $projectId: String
    $title: String!
    $description: String!
    $stateId: String
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        title: $title
        description: $description
        stateId: $stateId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        url
        state {
          name
        }
      }
    }
  }
  """

  @project_statuses_query """
  query SymphonyLiveE2EProjectStatuses {
    projectStatuses(first: 50) {
      nodes {
        id
        name
        type
      }
    }
  }
  """

  @issue_details_query """
  query SymphonyLiveE2EIssueDetails($id: String!) {
    issue(id: $id) {
      id
      identifier
      state {
        name
        type
      }
      comments(first: 20) {
        nodes {
          body
        }
      }
    }
  }
  """

  @complete_project_mutation """
  mutation SymphonyLiveE2ECompleteProject($id: String!, $statusId: String!, $completedAt: DateTime!) {
    projectUpdate(id: $id, input: {statusId: $statusId, completedAt: $completedAt}) {
      success
    }
  }
  """

  @team_cycles_query """
  query SymphonyLiveE2ETeamCycles($id: String!, $futureCycleNotBefore: DateTimeOrDuration!) {
    team(id: $id) {
      id
      activeCycle {
        id
        name
        endsAt
      }
      cycles(filter: {isFuture: {eq: true}, startsAt: {gt: $futureCycleNotBefore}}, first: 1) {
        nodes {
          id
          name
          startsAt
          endsAt
        }
      }
    }
  }
  """

  @create_cycle_mutation """
  mutation SymphonyLiveE2ECreateCycle($teamId: String!, $startsAt: DateTime!, $endsAt: DateTime!, $name: String) {
    cycleCreate(input: {teamId: $teamId, startsAt: $startsAt, endsAt: $endsAt, name: $name}) {
      success
      cycle {
        id
        name
        endsAt
      }
    }
  }
  """

  @archive_cycle_mutation """
  mutation SymphonyLiveE2EArchiveCycle($id: String!) {
    cycleArchive(id: $id) {
      success
    }
  }
  """

  # `$cycleId` is nullable on purpose: passing it as nil clears the issue's cycle, which is how the
  # out-of-cycle issue is forced out of a team that auto-adds new issues to the running cycle.
  @set_issue_cycle_mutation """
  mutation SymphonyLiveE2ESetIssueCycle($id: String!, $cycleId: String) {
    issueUpdate(id: $id, input: {cycleId: $cycleId}) {
      success
      issue {
        id
      }
    }
  }
  """

  @archive_issue_mutation """
  mutation SymphonyLiveE2EArchiveIssue($id: String!) {
    issueArchive(id: $id) {
      success
    }
  }
  """

  @tag skip: @live_e2e_skip_reason
  test "creates a real Linear project and issue with a local worker" do
    run_live_issue_flow!(:local)
  end

  @tag skip: @live_e2e_skip_reason
  test "creates a real Linear project and issue with an ssh worker" do
    run_live_issue_flow!(:ssh)
  end

  @tag skip: @live_e2e_skip_reason
  test "a team plus current-cycle scope reads only the active cycle while the id refresh ignores scope" do
    run_live_cycle_scope_flow!()
  end

  defp run_live_cycle_scope_flow! do
    team_key = System.get_env("SYMPHONY_LIVE_LINEAR_TEAM_KEY") || @default_team_key
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    # Cleanup is on_exit/1 rather than try/after because ExUnit kills the test process when the 300s
    # moduletag expires, and an untrappable kill skips every `after` — which would strand up to five
    # real entities in a real workspace. ExUnit.OnExitHandler holds these outside the test process, so
    # they still run. Registered first means LIFO runs it last: every entity discard below still sees
    # the live token, and TestSupport's setup on_exit was registered earlier still, so it deletes the
    # workflow root after this one.
    on_exit(fn ->
      write_workflow_file!(Workflow.workflow_file_path())
      restart_agent_runtime_if_needed()
    end)

    # The Orchestrator under AgentRuntimeSupervisor re-reads the active workflow file on every tick,
    # and write_workflow_file!/2 forces a WorkflowStore reload, so the live scope written below would
    # make it poll the real workspace with the real token and dispatch Codex agents against every
    # dispatchable issue in the active cycle, not just the ones seeded here. Both neighbouring live
    # tests stop the runtime for exactly this reason.
    if is_pid(runtime_pid) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$LINEAR_API_KEY",
      tracker_project_slug: nil,
      tracker_provider: %{"team_keys" => [team_key], "current_cycle" => true},
      observability_enabled: false
    )

    assert_cycle_scope_loaded!(team_key)

    team = fetch_team!(team_key)
    active_state = active_state!(team)
    state_names = active_state_names(team)
    team_cycles = fetch_team_cycles!(team["id"])

    # Bound one at a time rather than inline in the map below: Elixir does not guarantee the evaluation
    # order of a map literal's values, and each of these registers its own discard as it is created, so
    # this order is what fixes the LIFO cleanup order.
    active_cycle = ensure_active_cycle!(team_cycles)
    future_cycle = ensure_future_cycle!(team_cycles, active_cycle)
    in_cycle_issue = create_scope_issue!(team, active_state, "in cycle")
    out_of_cycle_issue = create_scope_issue!(team, active_state, "out of cycle")
    future_cycle_issue = create_scope_issue!(team, active_state, "future cycle")

    fixtures = %{
      active_cycle: active_cycle,
      future_cycle: future_cycle,
      in_cycle_issue: in_cycle_issue,
      out_of_cycle_issue: out_of_cycle_issue,
      future_cycle_issue: future_cycle_issue
    }

    seed_cycle_membership!(fixtures)
    assert_cycle_scope!(fixtures, state_names)
  end

  # A provider map that stopped round-tripping through YAML would make Scope.filter/2 silently drop
  # the cycle key, and the run would then fail as "returned an issue that belongs to no cycle" — a
  # config bug wearing the costume of a Linear semantics bug, which is the misdiagnosis this scenario
  # exists to prevent. Prove the scope loaded before trusting any read built from it.
  defp assert_cycle_scope_loaded!(team_key) do
    tracker = Config.settings!().tracker
    filter = Scope.filter(tracker)

    assert match?(%{cycle: %{isActive: %{eq: true}}}, filter),
           "the workflow did not load as a current-cycle scope, so a scope failure below would be a config bug rather than a Linear one: #{inspect(filter)}"

    assert Scope.team_keys(tracker) == [team_key],
           "the workflow did not load tracker.provider.team_keys: #{inspect(Scope.team_keys(tracker))}"
  end

  # Seeding lives outside assert_cycle_scope!/2 on purpose: set_issue_cycle!/2 is strict, and a failed
  # attachment raising from inside a function named for assertions would read as a scope failure.
  defp seed_cycle_membership!(fixtures) do
    set_issue_cycle!(fixtures.in_cycle_issue.id, fixtures.active_cycle["id"])
    set_issue_cycle!(fixtures.future_cycle_issue.id, fixtures.future_cycle["id"])

    # Teams that auto-add new issues to the running cycle would otherwise put this issue in the cycle
    # too, and the no-cycle claim below would then hold for the wrong reason.
    set_issue_cycle!(fixtures.out_of_cycle_issue.id, nil)
  end

  defp assert_cycle_scope!(fixtures, state_names) do
    # The three cycle-scope claims are settled together by await_cycle_scope_claims!/2, which polls to
    # a deadline and flunks naming whichever one did not hold; unmet_cycle_scope_claim/2 states them.
    await_cycle_scope_claims!(fixtures, state_names)

    # Production-path guard: this is the only test in the suite that drives the real
    # fetch_issues_by_ids/1 wrapper, because the unit-level regression enters at the
    # fetch_issues_by_ids_for_test/2 seam instead. It catches a reintroduced cycle or foreign-project
    # conjunct. It does NOT catch a reintroduced team conjunct: this issue belongs to the scoped team,
    # so a team-filtered refresh would still return it. Admission is scope-gated; continuation is
    # state-gated, so an issue that left the cycle must still be refreshable by id.
    assert {:ok, refreshed} = Client.fetch_issues_by_ids([fixtures.out_of_cycle_issue.id])

    assert Enum.any?(refreshed, &(&1.id == fixtures.out_of_cycle_issue.id)),
           "the by-ids refresh dropped an out-of-scope issue, so it is applying the configured scope"
  end

  # Linear is not documented to reflect a cycle attachment in its issue index on the very next read,
  # and a cold miss would flunk as "cycle.isActive does not select the running cycle" — the exact
  # wrong conclusion, and the one this scenario exists to rule out. Poll to a deadline first, with the
  # same idiom as wait_for_ssh_host!/2.
  defp await_cycle_scope_claims!(fixtures, state_names) do
    await_cycle_scope_claims!(fixtures, state_names, System.monotonic_time(:millisecond) + @scope_read_deadline_ms)
  end

  defp await_cycle_scope_claims!(fixtures, state_names, deadline_ms) do
    assert {:ok, scoped_issues} = Client.fetch_issues_by_states(state_names)
    scoped_ids = MapSet.new(scoped_issues, & &1.id)

    case unmet_cycle_scope_claim(scoped_ids, fixtures) do
      nil ->
        :ok

      claim ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          Process.sleep(@scope_read_poll_interval_ms)
          await_cycle_scope_claims!(fixtures, state_names, deadline_ms)
        else
          flunk("#{claim} (still true after #{@scope_read_deadline_ms}ms of polling)")
        end
    end
  end

  # The three claims a team + current_cycle scope has to satisfy, in the order that makes a failure
  # readable. The future-cycle claim is the decisive one: without it the other two would still hold if
  # `cycle.isActive` merely meant "belongs to some cycle", because only that issue sits in a real,
  # non-overlapping cycle that has not started yet.
  defp unmet_cycle_scope_claim(scoped_ids, fixtures) do
    cond do
      not MapSet.member?(scoped_ids, fixtures.in_cycle_issue.id) ->
        "team + current_cycle did not return the issue seeded into the active cycle, so cycle.isActive does not select the running cycle"

      MapSet.member?(scoped_ids, fixtures.out_of_cycle_issue.id) ->
        "team + current_cycle returned an issue that belongs to no cycle"

      MapSet.member?(scoped_ids, fixtures.future_cycle_issue.id) ->
        "team + current_cycle returned an issue from a cycle that has not started, so cycle.isActive matches cycle membership rather than the running cycle"

      true ->
        nil
    end
  end

  # Registers its own archive the moment the issue exists, so a scope issue can never be created
  # without a discard attached to it.
  defp create_scope_issue!(team, state, label) do
    issue = create_issue!(team["id"], nil, state["id"], "Symphony live cycle scope #{label} #{System.unique_integer([:positive])}")

    on_exit(fn -> archive_issue(issue.id) end)

    issue
  end

  defp fetch_team!(team_key) do
    @team_query
    |> graphql_data!(%{key: team_key})
    |> get_in(["teams", "nodes"])
    |> case do
      [team | _] ->
        team

      _ ->
        flunk("expected Linear team #{inspect(team_key)} to exist")
    end
  end

  defp active_state!(%{"states" => %{"nodes" => states}}) when is_list(states) do
    Enum.find(states, &(&1["type"] == "started")) ||
      Enum.find(states, &(&1["type"] == "unstarted")) ||
      Enum.find(states, &(&1["type"] not in ["completed", "canceled"])) ||
      flunk("expected team to expose at least one non-terminal workflow state")
  end

  defp terminal_state_names(%{"states" => %{"nodes" => states}}) when is_list(states) do
    states
    |> Enum.filter(&(&1["type"] in ["completed", "canceled"]))
    |> Enum.map(& &1["name"])
    |> case do
      [] -> ["Done", "Canceled", "Cancelled"]
      names -> names
    end
  end

  defp active_state_names(%{"states" => %{"nodes" => states}}) when is_list(states) do
    states
    |> Enum.reject(&(&1["type"] in ["completed", "canceled"]))
    |> Enum.map(& &1["name"])
    |> case do
      [] -> ["Todo", "In Progress", "In Review"]
      names -> names
    end
  end

  defp completed_project_status! do
    @project_statuses_query
    |> graphql_data!(%{})
    |> get_in(["projectStatuses", "nodes"])
    |> case do
      statuses when is_list(statuses) ->
        Enum.find(statuses, &(&1["type"] == "completed")) ||
          flunk("expected workspace to expose a completed project status")

      payload ->
        flunk("expected project statuses list, got: #{inspect(payload)}")
    end
  end

  defp create_project!(team_id, name) do
    @create_project_mutation
    |> graphql_data!(%{teamIds: [team_id], name: name})
    |> fetch_successful_entity!("projectCreate", "project")
  end

  defp create_issue!(team_id, project_id, state_id, title) do
    variables =
      %{
        teamId: team_id,
        title: title,
        description: title,
        stateId: state_id
      }
      |> maybe_put_project_id(project_id)

    issue =
      @create_issue_mutation
      |> graphql_data!(variables)
      |> fetch_successful_entity!("issueCreate", "issue")

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      state: get_in(issue, ["state", "name"]),
      url: issue["url"],
      labels: [],
      blocked_by: []
    }
  end

  # A nil project id is dropped from the variables map rather than sent as an explicit null: a
  # GraphQL variable that is absent at runtime is omitted from the input object entirely, so Linear
  # sees an issueCreate with no projectId key at all.
  defp maybe_put_project_id(variables, project_id) when is_binary(project_id) do
    Map.put(variables, :projectId, project_id)
  end

  defp maybe_put_project_id(variables, nil), do: variables

  defp fetch_team_cycles!(team_id) when is_binary(team_id) do
    future_cycle_not_before =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(@future_cycle_start_margin_seconds, :second)
      |> DateTime.to_iso8601()

    @team_cycles_query
    |> graphql_data!(%{id: team_id, futureCycleNotBefore: future_cycle_not_before})
    |> get_in(["team"])
    |> case do
      %{"cycles" => %{"nodes" => nodes}} = team_cycles when is_list(nodes) -> team_cycles
      payload -> flunk("expected a team cycles payload for #{inspect(team_id)}, got: #{inspect(payload)}")
    end
  end

  # Borrows the team's own running cycle when it has one. Linear rejects cycles that overlap an
  # existing one, and a scenario that minted a cycle it did not need would leak one into a real
  # workspace on every run. Only a cycle this call creates gets an archive registered, so a borrowed
  # cycle — a real team's running sprint — is never archived.
  defp ensure_active_cycle!(team_cycles) do
    case team_cycles["activeCycle"] do
      %{"id" => cycle_id} = cycle when is_binary(cycle_id) ->
        cycle

      _no_active_cycle ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        create_and_discard_cycle!(team_cycles["id"], DateTime.add(now, -1, :day), DateTime.add(now, 13, :day), "active")
    end
  end

  # Same borrow-first rule, and it matters more here than for the active cycle. A team with a cycle
  # cadence — precisely the audience for a current_cycle selector — already has Linear's auto-scheduled
  # upcoming cycle sitting in the window just after the active one, so minting one there would be
  # rejected as an overlap and flunk at the very first fixture, before any assertion runs.
  defp ensure_future_cycle!(team_cycles, active_cycle) do
    case get_in(team_cycles, ["cycles", "nodes"]) do
      [%{"id" => cycle_id} = cycle | _rest] when is_binary(cycle_id) ->
        cycle

      _no_future_cycle ->
        # A full day after the active cycle ends, so the two windows cannot overlap. Reached only when
        # the team has no future cycle at all, so there is nothing else to collide with either.
        starts_at = active_cycle |> cycle_ends_at!() |> DateTime.add(1, :day)

        create_and_discard_cycle!(team_cycles["id"], starts_at, DateTime.add(starts_at, 14, :day), "future")
    end
  end

  defp create_and_discard_cycle!(team_id, %DateTime{} = starts_at, %DateTime{} = ends_at, label) do
    cycle = create_cycle!(team_id, starts_at, ends_at, label)

    on_exit(fn -> archive_cycle(cycle["id"]) end)

    cycle
  end

  defp create_cycle!(team_id, %DateTime{} = starts_at, %DateTime{} = ends_at, label) do
    @create_cycle_mutation
    |> graphql_data!(%{
      teamId: team_id,
      startsAt: DateTime.to_iso8601(starts_at),
      endsAt: DateTime.to_iso8601(ends_at),
      name: "symphony-live-#{label}-cycle-#{System.unique_integer([:positive])}"
    })
    |> fetch_successful_entity!("cycleCreate", "cycle")
  end

  defp cycle_ends_at!(%{"endsAt" => ends_at}) when is_binary(ends_at) do
    case DateTime.from_iso8601(ends_at) do
      {:ok, datetime, _utc_offset} -> DateTime.truncate(datetime, :second)
      {:error, reason} -> flunk("expected an ISO8601 endsAt on the active cycle, got #{inspect(ends_at)}: #{inspect(reason)}")
    end
  end

  defp cycle_ends_at!(cycle), do: flunk("expected the active cycle to expose endsAt, got: #{inspect(cycle)}")

  # Strict, unlike the cleanup mutations: a silently failed cycle attachment would surface as the
  # scope assertion failing, which reads as "cycle.isActive is broken" when it is not.
  defp set_issue_cycle!(issue_id, cycle_id) when is_binary(issue_id) and (is_binary(cycle_id) or is_nil(cycle_id)) do
    @set_issue_cycle_mutation
    |> graphql_data!(%{id: issue_id, cycleId: cycle_id})
    |> fetch_successful_entity!("issueUpdate", "issue")
  end

  defp archive_cycle(cycle_id) when is_binary(cycle_id) do
    update_entity(@archive_cycle_mutation, %{id: cycle_id}, "cycleArchive", "cycle")
  end

  defp archive_issue(issue_id) when is_binary(issue_id) do
    update_entity(@archive_issue_mutation, %{id: issue_id}, "issueArchive", "issue")
  end

  defp complete_project(project_id, completed_status_id)
       when is_binary(project_id) and is_binary(completed_status_id) do
    update_entity(
      @complete_project_mutation,
      %{
        id: project_id,
        statusId: completed_status_id,
        completedAt: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      },
      "projectUpdate",
      "project"
    )
  end

  defp fetch_issue_details!(issue_id) when is_binary(issue_id) do
    @issue_details_query
    |> graphql_data!(%{id: issue_id})
    |> get_in(["issue"])
    |> case do
      %{} = issue -> issue
      payload -> flunk("expected issue details payload, got: #{inspect(payload)}")
    end
  end

  defp issue_completed?(%{"state" => %{"type" => type}}), do: type in ["completed", "canceled"]
  defp issue_completed?(_issue), do: false

  defp issue_has_comment?(%{"comments" => %{"nodes" => comments}}, expected_body) when is_list(comments) do
    Enum.any?(comments, &(&1["body"] == expected_body))
  end

  defp issue_has_comment?(_issue, _expected_body), do: false

  defp update_entity(mutation, variables, mutation_name, entity_name) do
    case Client.graphql(mutation, variables) do
      {:ok, %{"data" => %{^mutation_name => %{"success" => true}}}} ->
        :ok

      {:ok, %{"errors" => errors}} ->
        Logger.warning("Live e2e finalization failed for #{entity_name}: #{inspect(errors)}")
        :ok

      {:ok, payload} ->
        Logger.warning("Live e2e finalization failed for #{entity_name}: #{inspect(payload)}")
        :ok

      {:error, reason} ->
        Logger.warning("Live e2e finalization failed for #{entity_name}: #{inspect(reason)}")
        :ok
    end
  end

  defp graphql_data!(query, variables) when is_binary(query) and is_map(variables) do
    case Client.graphql(query, variables) do
      {:ok, %{"data" => data, "errors" => errors}} when is_map(data) and is_list(errors) ->
        flunk("Linear GraphQL returned partial errors: #{inspect(errors)}")

      {:ok, %{"errors" => errors}} when is_list(errors) ->
        flunk("Linear GraphQL failed: #{inspect(errors)}")

      {:ok, %{"data" => data}} when is_map(data) ->
        data

      {:ok, payload} ->
        flunk("Linear GraphQL returned unexpected payload: #{inspect(payload)}")

      {:error, reason} ->
        flunk("Linear GraphQL request failed: #{inspect(reason)}")
    end
  end

  defp fetch_successful_entity!(data, mutation_name, entity_name)
       when is_map(data) and is_binary(mutation_name) and is_binary(entity_name) do
    case data do
      %{^mutation_name => %{"success" => true, ^entity_name => %{} = entity}} ->
        entity

      _ ->
        flunk("expected successful #{mutation_name} response, got: #{inspect(data)}")
    end
  end

  defp live_prompt(project_slug) do
    """
    You are running a real Symphony end-to-end test.

    The current working directory is the workspace root.

    Step 1:
    Create a file named #{@result_file} in the current working directory by running exactly:

    ```sh
    cat > #{@result_file} <<'EOF'
    identifier={{ issue.identifier }}
    project_slug=#{project_slug}
    EOF
    ```

    Then verify it by running:

    ```sh
    cat #{@result_file}
    ```

    The file content must be exactly:
    identifier={{ issue.identifier }}
    project_slug=#{project_slug}

    Step 2:
    You must use the `linear_graphql` tool to query the current issue by `{{ issue.id }}` and read:
    - existing comments
    - team workflow states

    A turn that only creates the file is incomplete. Do not stop after Step 1.

    If the exact comment body below is not already present, post exactly one comment on the current issue with this exact body:
    #{expected_comment("{{ issue.identifier }}", project_slug)}

    Use these exact GraphQL operations:

    ```graphql
    query IssueContext($id: String!) {
      issue(id: $id) {
        comments(first: 20) {
          nodes {
            body
          }
        }
        team {
          states(first: 50) {
            nodes {
              id
              name
              type
            }
          }
        }
      }
    }
    ```

    ```graphql
    mutation AddComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) {
        success
      }
    }
    ```

    Step 3:
    Use the same issue-context query result to choose a workflow state whose `type` is `completed`.
    Then move the current issue to that state with this exact mutation:

    ```graphql
    mutation CompleteIssue($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: {stateId: $stateId}) {
        success
      }
    }
    ```

    Step 4:
    Verify all outcomes with one final `linear_graphql` query against `{{ issue.id }}`:
    - the exact comment body is present
    - the issue state type is `completed`

    Do not ask for approval.
    Stop only after all three conditions are true:
    1. the file exists with the exact contents above
    2. the Linear comment exists with the exact body above
    3. the Linear issue is in a completed terminal state
    """
  end

  defp expected_result(issue_identifier, project_slug) do
    "identifier=#{issue_identifier}\nproject_slug=#{project_slug}\n"
  end

  defp expected_comment(issue_identifier, project_slug) do
    "Symphony live e2e comment\nidentifier=#{issue_identifier}\nproject_slug=#{project_slug}"
  end

  defp receive_runtime_info!(issue_id) do
    receive do
      {:worker_runtime_info, ^issue_id, %{workspace_path: workspace_path} = runtime_info}
      when is_binary(workspace_path) ->
        runtime_info

      {:codex_worker_update, ^issue_id, _message} ->
        receive_runtime_info!(issue_id)
    after
      5_000 ->
        flunk("timed out waiting for worker runtime info for #{inspect(issue_id)}")
    end
  end

  defp read_worker_result!(%{worker_host: nil, workspace_path: workspace_path}, result_file)
       when is_binary(workspace_path) and is_binary(result_file) do
    File.read!(Path.join(workspace_path, result_file))
  end

  defp read_worker_result!(%{worker_host: worker_host, workspace_path: workspace_path}, result_file)
       when is_binary(worker_host) and is_binary(workspace_path) and is_binary(result_file) do
    remote_result_path = Path.join(workspace_path, result_file)

    case SSH.run(worker_host, "cat #{shell_escape(remote_result_path)}", stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        output

      {:ok, {output, status}} ->
        flunk("failed to read remote result from #{worker_host}:#{remote_result_path} (status #{status}): #{inspect(output)}")

      {:error, reason} ->
        flunk("failed to read remote result from #{worker_host}:#{remote_result_path}: #{inspect(reason)}")
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp run_live_issue_flow!(backend) when backend in [:local, :ssh] do
    run_id = "symphony-live-e2e-#{backend}-#{System.unique_integer([:positive])}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    worker_setup = live_worker_setup!(backend, run_id, test_root)
    team_key = System.get_env("SYMPHONY_LIVE_LINEAR_TEAM_KEY") || @default_team_key
    original_workflow_path = Workflow.workflow_file_path()
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    File.mkdir_p!(workflow_root)

    try do
      if is_pid(runtime_pid) do
        assert :ok =
                 Supervisor.terminate_child(
                   SymphonyElixir.Supervisor,
                   SymphonyElixir.AgentRuntimeSupervisor
                 )
      end

      Workflow.set_workflow_file_path(workflow_file)

      write_workflow_file!(workflow_file,
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: "bootstrap",
        workspace_root: worker_setup.workspace_root,
        worker_ssh_hosts: worker_setup.ssh_worker_hosts,
        codex_command: worker_setup.codex_command,
        codex_approval_policy: "never",
        observability_enabled: false
      )

      team = fetch_team!(team_key)
      active_state = active_state!(team)
      completed_project_status = completed_project_status!()
      terminal_states = terminal_state_names(team)

      project =
        create_project!(
          team["id"],
          "Symphony Live E2E #{backend} #{System.unique_integer([:positive])}"
        )

      try do
        issue =
          create_issue!(
            team["id"],
            project["id"],
            active_state["id"],
            "Symphony live e2e #{backend} issue for #{project["name"]}"
          )

        write_workflow_file!(workflow_file,
          tracker_api_token: "$LINEAR_API_KEY",
          tracker_project_slug: project["slugId"],
          tracker_active_states: active_state_names(team),
          tracker_terminal_states: terminal_states,
          workspace_root: worker_setup.workspace_root,
          worker_ssh_hosts: worker_setup.ssh_worker_hosts,
          codex_command: worker_setup.codex_command,
          codex_approval_policy: "never",
          codex_turn_sandbox_policy: Map.get(worker_setup, :codex_turn_sandbox_policy),
          codex_read_timeout_ms: 60_000,
          codex_turn_timeout_ms: 600_000,
          codex_stall_timeout_ms: 600_000,
          observability_enabled: false,
          prompt: live_prompt(project["slugId"])
        )

        assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

        runtime_info = receive_runtime_info!(issue.id)

        assert read_worker_result!(runtime_info, @result_file) ==
                 expected_result(issue.identifier, project["slugId"])

        issue_snapshot = fetch_issue_details!(issue.id)
        assert issue_completed?(issue_snapshot)
        assert issue_has_comment?(issue_snapshot, expected_comment(issue.identifier, project["slugId"]))
      after
        assert :ok = complete_project(project["id"], completed_project_status["id"])
      end
    after
      restart_agent_runtime_if_needed()
      cleanup_live_worker_setup(worker_setup)
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
    end
  end

  defp live_worker_setup!(:local, _run_id, test_root) when is_binary(test_root) do
    codex_home = isolated_codex_home!(test_root)

    %{
      cleanup: fn -> :ok end,
      codex_command: "env CODEX_HOME=#{shell_escape(codex_home)} codex app-server",
      ssh_worker_hosts: [],
      workspace_root: Path.join(test_root, "workspaces")
    }
  end

  defp live_worker_setup!(:ssh, run_id, test_root) when is_binary(run_id) and is_binary(test_root) do
    case live_ssh_worker_hosts() do
      [] ->
        live_docker_worker_setup!(run_id, test_root)

      _hosts ->
        live_ssh_worker_setup!(run_id)
    end
  end

  defp isolated_codex_home!(test_root) when is_binary(test_root) do
    codex_home = Path.join(test_root, "codex-home")
    auth_json_path = Path.join(codex_home, "auth.json")

    File.mkdir_p!(codex_home)
    File.cp!(source_codex_auth_json!(), auth_json_path)
    File.chmod!(auth_json_path, 0o600)

    codex_home
  end

  defp source_codex_auth_json! do
    codex_home = System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
    auth_json_path = Path.join(codex_home, "auth.json")

    if File.regular?(auth_json_path) do
      auth_json_path
    else
      flunk("live e2e requires Codex auth at #{auth_json_path}")
    end
  end

  defp cleanup_live_worker_setup(%{cleanup: cleanup}) when is_function(cleanup, 0) do
    cleanup.()
  end

  defp cleanup_live_worker_setup(_worker_setup), do: :ok

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

  defp live_ssh_worker_setup!(run_id) when is_binary(run_id) do
    ssh_worker_hosts = live_ssh_worker_hosts()
    remote_test_root = Path.join(shared_remote_home!(ssh_worker_hosts), ".#{run_id}")
    remote_workspace_root = "~/.#{run_id}/workspaces"

    %{
      cleanup: fn -> cleanup_remote_test_root(remote_test_root, ssh_worker_hosts) end,
      codex_command: "codex app-server",
      ssh_worker_hosts: ssh_worker_hosts,
      workspace_root: remote_workspace_root
    }
  end

  defp live_docker_worker_setup!(run_id, test_root) when is_binary(run_id) and is_binary(test_root) do
    ssh_root = Path.join(test_root, "live-docker-ssh")
    key_path = Path.join(ssh_root, "id_ed25519")
    config_path = Path.join(ssh_root, "config")
    auth_json_path = source_codex_auth_json!()
    worker_ports = reserve_tcp_ports(@docker_worker_count)
    worker_hosts = Enum.map(worker_ports, &"localhost:#{&1}")
    project_name = docker_project_name(run_id)
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    base_cleanup = fn ->
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      docker_compose_down(project_name, docker_compose_env(worker_ports, auth_json_path, key_path <> ".pub"))
    end

    result =
      try do
        File.mkdir_p!(ssh_root)
        generate_ssh_keypair!(key_path)
        write_docker_ssh_config!(config_path, key_path)
        System.put_env("SYMPHONY_SSH_CONFIG", config_path)

        docker_compose_up!(project_name, docker_compose_env(worker_ports, auth_json_path, key_path <> ".pub"))
        wait_for_ssh_hosts!(worker_hosts)
        remote_test_root = Path.join(shared_remote_home!(worker_hosts), ".#{run_id}")
        remote_workspace_root = "~/.#{run_id}/workspaces"

        %{
          cleanup: fn ->
            cleanup_remote_test_root(remote_test_root, worker_hosts)
            base_cleanup.()
          end,
          codex_command: "codex app-server",
          codex_turn_sandbox_policy: %{type: "dangerFullAccess"},
          ssh_worker_hosts: worker_hosts,
          workspace_root: remote_workspace_root
        }
      rescue
        error ->
          {:error, error, __STACKTRACE__}
      catch
        kind, reason ->
          {:caught, kind, reason, __STACKTRACE__}
      end

    case result do
      %{ssh_worker_hosts: _hosts} = worker_setup ->
        worker_setup

      {:error, error, stacktrace} ->
        base_cleanup.()
        reraise(error, stacktrace)

      {:caught, kind, reason, stacktrace} ->
        base_cleanup.()
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp live_ssh_worker_hosts do
    System.get_env("SYMPHONY_LIVE_SSH_WORKER_HOSTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp cleanup_remote_test_root(test_root, ssh_worker_hosts)
       when is_binary(test_root) and is_list(ssh_worker_hosts) do
    Enum.each(ssh_worker_hosts, fn worker_host ->
      _ = SSH.run(worker_host, "rm -rf #{shell_escape(test_root)}", stderr_to_stdout: true)
    end)
  end

  defp shared_remote_home!([first_host | rest] = worker_hosts) when is_binary(first_host) and rest != [] do
    homes =
      worker_hosts
      |> Enum.map(fn worker_host -> {worker_host, remote_home!(worker_host)} end)

    [{_host, home} | _remaining] = homes

    if Enum.all?(homes, fn {_host, other_home} -> other_home == home end) do
      home
    else
      flunk("expected all live SSH workers to share one home directory, got: #{inspect(homes)}")
    end
  end

  defp shared_remote_home!([worker_host]) when is_binary(worker_host), do: remote_home!(worker_host)
  defp shared_remote_home!(_worker_hosts), do: flunk("expected at least one live SSH worker host")

  defp remote_home!(worker_host) when is_binary(worker_host) do
    case SSH.run(worker_host, "printf '%s\\n' \"$HOME\"", stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        output
        |> String.trim()
        |> case do
          "" -> flunk("expected non-empty remote home for #{worker_host}")
          home -> home
        end

      {:ok, {output, status}} ->
        flunk("failed to resolve remote home for #{worker_host} (status #{status}): #{inspect(output)}")

      {:error, reason} ->
        flunk("failed to resolve remote home for #{worker_host}: #{inspect(reason)}")
    end
  end

  defp reserve_tcp_ports(count) when is_integer(count) and count > 0 do
    reserve_tcp_ports(count, MapSet.new(), [])
  end

  defp reserve_tcp_ports(0, _seen, ports), do: Enum.reverse(ports)

  defp reserve_tcp_ports(remaining, seen, ports) do
    port = reserve_tcp_port!()

    if MapSet.member?(seen, port) do
      reserve_tcp_ports(remaining, seen, ports)
    else
      reserve_tcp_ports(remaining - 1, MapSet.put(seen, port), [port | ports])
    end
  end

  defp reserve_tcp_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp generate_ssh_keypair!(key_path) when is_binary(key_path) do
    case System.find_executable("ssh-keygen") do
      nil ->
        flunk("docker worker mode requires `ssh-keygen` on PATH")

      executable ->
        key_dir = Path.dirname(key_path)
        File.mkdir_p!(key_dir)
        File.rm_rf(key_path)
        File.rm_rf(key_path <> ".pub")

        case System.cmd(executable, ["-q", "-t", "ed25519", "-N", "", "-f", key_path], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> flunk("failed to generate live docker ssh key (status #{status}): #{inspect(output)}")
        end
    end
  end

  defp write_docker_ssh_config!(config_path, key_path)
       when is_binary(config_path) and is_binary(key_path) do
    config_contents = """
    Host localhost 127.0.0.1
      User root
      IdentityFile #{key_path}
      IdentitiesOnly yes
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
    """

    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, config_contents)
  end

  defp docker_project_name(run_id) when is_binary(run_id) do
    run_id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
  end

  defp docker_compose_env(worker_ports, auth_json_path, authorized_key_path)
       when is_list(worker_ports) and is_binary(auth_json_path) and is_binary(authorized_key_path) do
    [
      {"SYMPHONY_LIVE_DOCKER_AUTH_JSON", auth_json_path},
      {"SYMPHONY_LIVE_DOCKER_AUTHORIZED_KEY", authorized_key_path},
      {"SYMPHONY_LIVE_DOCKER_WORKER_1_PORT", Integer.to_string(Enum.at(worker_ports, 0))},
      {"SYMPHONY_LIVE_DOCKER_WORKER_2_PORT", Integer.to_string(Enum.at(worker_ports, 1))}
    ]
  end

  defp docker_compose_up!(project_name, env) when is_binary(project_name) and is_list(env) do
    args = ["compose", "-f", @docker_compose_file, "-p", project_name, "up", "-d", "--build"]

    case System.cmd("docker", args, cd: @docker_support_dir, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("failed to start live docker workers (status #{status}): #{inspect(output)}")
    end
  end

  defp docker_compose_down(project_name, env) when is_binary(project_name) and is_list(env) do
    _ =
      System.cmd(
        "docker",
        ["compose", "-f", @docker_compose_file, "-p", project_name, "down", "-v", "--remove-orphans"],
        cd: @docker_support_dir,
        env: env,
        stderr_to_stdout: true
      )

    :ok
  end

  defp wait_for_ssh_hosts!(worker_hosts) when is_list(worker_hosts) do
    deadline = System.monotonic_time(:millisecond) + 60_000

    Enum.each(worker_hosts, fn worker_host ->
      wait_for_ssh_host!(worker_host, deadline)
    end)
  end

  defp wait_for_ssh_host!(worker_host, deadline_ms) when is_binary(worker_host) do
    case SSH.run(worker_host, "printf ready", stderr_to_stdout: true) do
      {:ok, {"ready", 0}} ->
        :ok

      {:ok, {_output, _status}} ->
        retry_or_flunk_ssh_host(worker_host, deadline_ms)

      {:error, _reason} ->
        retry_or_flunk_ssh_host(worker_host, deadline_ms)
    end
  end

  defp retry_or_flunk_ssh_host(worker_host, deadline_ms) do
    if System.monotonic_time(:millisecond) < deadline_ms do
      Process.sleep(1_000)
      wait_for_ssh_host!(worker_host, deadline_ms)
    else
      flunk("timed out waiting for SSH worker #{worker_host} to accept connections")
    end
  end
end
