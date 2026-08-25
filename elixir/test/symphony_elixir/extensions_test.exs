defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(issue_ids) do
      send(self(), {:fetch_issues_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule PreflightClient do
    # SML lacks "In Progress", so a state can be present in one listed team and absent from
    # another. BIG fills the 50-state page the nested `states` connection cannot filter, so its
    # workflow states are truncated and absence cannot be proven for it.
    @teams [
      %{
        "key" => "MDZ",
        "activeCycle" => %{"id" => "cycle-1"},
        "states" => %{"nodes" => [%{"name" => "Todo"}, %{"name" => "In Progress"}, %{"name" => "Done"}]}
      },
      %{
        "key" => "TRA",
        "activeCycle" => nil,
        "states" => %{"nodes" => [%{"name" => "Todo"}, %{"name" => "In Progress"}, %{"name" => "Done"}]}
      },
      %{
        "key" => "SML",
        "activeCycle" => %{"id" => "cycle-2"},
        "states" => %{"nodes" => [%{"name" => "Todo"}, %{"name" => "Done"}]}
      },
      %{
        "key" => "BIG",
        "activeCycle" => %{"id" => "cycle-3"},
        "states" => %{"nodes" => Enum.map(1..50, &%{"name" => "State #{&1}"})}
      }
    ]

    # `feat-symphony` exists on MDZ only: labels are team-scoped in Linear, so this fixture is
    # what distinguishes "absent from one listed team" (a warning) from "absent everywhere".
    # `crowded-label` exists on 250 unlisted teams, filling the 250-label page the `issueLabels`
    # connection cannot paginate, so a listed team's copy of it could sit beyond the cap.
    @labels [%{"name" => "feat-symphony", "team" => %{"key" => "MDZ"}}] ++
              Enum.map(1..250, &%{"name" => "crowded-label", "team" => %{"key" => "OTH#{&1}"}})

    def graphql(query, variables) do
      send(self(), {:preflight_query, query, variables})

      cond do
        query =~ "SymphonyPreflightTeams" ->
          {:ok, %{"data" => %{"teams" => %{"nodes" => matching(@teams, variables, :key, "key")}}}}

        query =~ "SymphonyPreflightLabels" ->
          {:ok, %{"data" => %{"issueLabels" => %{"nodes" => matching(@labels, variables, :name, "name")}}}}
      end
    end

    # Applies the filter the way Linear does, so preflight only ever sees the nodes its own
    # filter selects. `Map.fetch!(:eqIgnoreCase)` is load-bearing: a filter built with any other
    # comparator raises here instead of silently matching, which is how the tests pin preflight
    # to the same case-insensitive comparator the read query uses.
    defp matching(nodes, %{filter: %{or: clauses}}, filter_key, node_key) do
      wanted =
        Enum.map(clauses, fn clause ->
          clause |> Map.fetch!(filter_key) |> Map.fetch!(:eqIgnoreCase) |> String.downcase()
        end)

      Enum.filter(nodes, &(String.downcase(&1[node_key]) in wanted))
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Second prompt",
      poll_interval_ms: 45_000
    )

    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    good_settings = Config.settings!()
    assert good_settings.polling.interval_ms == 45_000

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    File.write!(
      Workflow.workflow_file_path(),
      "---\npolling:\n  interval_ms: nope\n---\nTyped-invalid prompt\n"
    )

    assert {:error, {:invalid_workflow_config, message}} = WorkflowStore.force_reload()
    assert message =~ "polling.interval_ms"
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil,
      prompt: "Semantic-invalid prompt"
    )

    assert {:error, :missing_linear_scope} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, :missing_linear_scope} = Config.validate!()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert {:ok, settings} = WorkflowStore.settings()
    assert settings.polling.interval_ms == 30_000
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.settings()

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    assert :ok = GenServer.stop(manual_pid)

    Workflow.set_workflow_file_path(existing_path)

    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    assert :ok = WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_ids(["issue-1"])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    binding = SymphonyElixir.Tracker.bind_agent_tools()
    assert binding.adapter == Memory
    assert binding.tool_specs == []
    assert binding.secret_environment_names == []

    assert SymphonyElixir.Tracker.execute_bound_agent_tool(binding, "not_a_memory_tool", %{})[
             "success"
           ] == false

    assert {:error, {:unsupported_tracker_kind, "future-tracker"}} =
             SymphonyElixir.Tracker.adapter_for_kind("future-tracker")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
    assert SymphonyElixir.Tracker.bind_agent_tools().secret_environment_names == ["LINEAR_API_KEY"]
  end

  test "linear adapter delegates reads and advertises its native agent tool" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issues_by_ids(["issue-1"])
    assert_receive {:fetch_issues_by_ids_called, ["issue-1"]}

    assert [%{"name" => "linear_graphql"}, %{"name" => "linear_fetch_attachment"}] =
             Adapter.agent_tool_specs()
  end

  test "linear adapter validates blocked comment and state update responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    for {result, expected} <- [
          {{:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}, {:error, :comment_create_failed}},
          {{:error, :boom}, {:error, :boom}},
          {{:ok, %{"data" => %{}}}, {:error, :comment_create_failed}},
          {:unexpected, {:error, :comment_create_failed}}
        ] do
      Process.put({FakeLinearClient, :graphql_result}, result)
      assert Adapter.create_comment("issue-1", "failed") == expected
    end

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        state_lookup_result("state-1"),
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"
    assert_receive {:graphql_called, update_query, %{issueId: "issue-1", stateId: "state-1"}}
    assert update_query =~ "issueUpdate"

    for {results, expected} <- [
          {[state_lookup_result("state-1"), {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}], {:error, :issue_update_failed}},
          {[{:error, :boom}], {:error, :boom}},
          {[{:ok, %{"data" => %{}}}], {:error, :state_not_found}},
          {[state_lookup_result("state-1"), {:ok, %{"data" => %{}}}], {:error, :issue_update_failed}},
          {[state_lookup_result("state-1"), :unexpected], {:error, :issue_update_failed}}
        ] do
      Process.put({FakeLinearClient, :graphql_results}, results)
      assert Adapter.update_issue_state("issue-1", "Failed") == expected
    end
  end

  test "preflight resolves known team keys, states and labels" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings =
      preflight_settings(
        provider: %{"team_keys" => ["MDZ"]},
        any_labels: ["feat-symphony"],
        active_states: ["Todo", "In Progress"]
      )

    assert :ok = Adapter.preflight(settings)

    assert_received {:preflight_query, teams_query, %{filter: %{or: [%{key: %{eqIgnoreCase: "MDZ"}}]}}}
    assert teams_query =~ "SymphonyPreflightTeams"
    assert teams_query =~ "activeCycle"
    assert teams_query =~ "teams(filter: $filter, first: 100)"
    assert teams_query =~ "states(first: 50)"

    assert_received {:preflight_query, labels_query, %{filter: %{or: [%{name: %{eqIgnoreCase: "feat-symphony"}}]}}}
    assert labels_query =~ "SymphonyPreflightLabels"
    assert labels_query =~ "issueLabels(filter: $filter, first: 250)"
  end

  test "preflight reports an unknown team key" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{"team_keys" => ["NOPE"]})

    assert {:error, {:linear_preflight_failed, reasons}} = Adapter.preflight(settings)
    assert reasons == ["unknown Linear team key \"NOPE\""]
  end

  test "preflight reports a state that no listed team defines" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{"team_keys" => ["mdz"]}, active_states: ["Merging"])

    assert {:error, {:linear_preflight_failed, reasons}} = Adapter.preflight(settings)
    assert reasons == ["state \"Merging\" does not exist in any listed Linear team"]
  end

  test "preflight warns rather than fails when a state is absent from only some listed teams" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    # Lowercase on purpose: the configured keys must resolve case-insensitively AND the warning
    # must name Linear's own spelling of the team, not the operator's.
    settings = preflight_settings(provider: %{"team_keys" => ["mdz", "sml"]}, active_states: ["In Progress"])

    log = capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    assert log =~ "Linear state \"In Progress\" is absent from team(s) [\"SML\"]"
  end

  test "preflight treats a full workflow state page as unprovable rather than absent" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{"team_keys" => ["BIG"]}, active_states: ["Todo"], terminal_states: ["State 1"])

    log = capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    assert log =~ "Linear state \"Todo\" was not found, and team(s) [\"BIG\"] returned a full page of 50 workflow states, so its absence cannot be proven"
    refute log =~ "\"State 1\""
  end

  test "preflight reports every failure in one error" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings =
      preflight_settings(
        provider: %{"team_keys" => ["MDZ", "NOPE"]},
        any_labels: ["absent-label"],
        required_labels: ["also-absent"],
        active_states: ["Merging"]
      )

    assert {:error, {:linear_preflight_failed, reasons}} = Adapter.preflight(settings)

    assert reasons == [
             "unknown Linear team key \"NOPE\"",
             "state \"Merging\" does not exist in any listed Linear team",
             "label \"absent-label\" does not exist in any listed Linear team",
             "label \"also-absent\" does not exist in any listed Linear team"
           ]

    # Two selector kinds across four values still cost exactly two requests, not one per value.
    assert_received {:preflight_query, _teams_query, _teams_variables}
    assert_received {:preflight_query, _labels_query, _labels_variables}
    refute_received {:preflight_query, _query, _variables}
  end

  test "preflight surfaces graphql errors, unknown payloads and transport failures" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    settings = preflight_settings(provider: %{"team_keys" => ["MDZ"]})

    for {result, expected} <- [
          {{:ok, %{"errors" => [%{"message" => "complexity"}]}}, {:error, {:linear_graphql_errors, [%{"message" => "complexity"}]}}},
          {{:ok, %{"data" => %{"teams" => %{}}}}, {:error, :linear_unknown_payload}},
          {{:error, :timeout}, {:error, :timeout}}
        ] do
      Process.put({FakeLinearClient, :graphql_result}, result)
      assert Adapter.preflight(settings) == expected
    end
  end

  test "preflight warns rather than fails when a listed team has no active cycle" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{"team_keys" => ["TRA"], "current_cycle" => true})

    log = capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    assert log =~ "no active cycle"
    assert log =~ "TRA"
  end

  test "preflight does not check cycles when current_cycle is not configured" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{"team_keys" => ["TRA"]})

    log = capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    refute log =~ "no active cycle"
  end

  test "preflight warns rather than fails when a label is absent from only some listed teams" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    # Lowercase on purpose, as in the state warning above: this is the assertion that pins
    # `resolved_team_keys/1` to Linear's spelling rather than the operator's.
    settings = preflight_settings(provider: %{"team_keys" => ["mdz", "tra"]}, any_labels: ["feat-symphony"])

    log = capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    assert log =~ "Linear label \"feat-symphony\" is absent from team(s) [\"TRA\"]"
  end

  test "preflight names the list a partly absent label came from" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{"team_keys" => ["MDZ", "TRA"]}, required_labels: ["feat-symphony"])

    log = capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    assert log =~ "Linear required label \"feat-symphony\" is absent from team(s) [\"TRA\"]; those teams will contribute no issues at all"
  end

  test "preflight treats a full label page as unprovable rather than absent" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{"team_keys" => ["MDZ"]}, any_labels: ["crowded-label"])

    log = capture_log(fn -> assert :ok = Adapter.preflight(settings) end)

    assert log =~ "Linear label \"crowded-label\" was not found, and the label query returned a full page of 250 labels, so its absence cannot be proven"
  end

  test "preflight never names an unresolvable team key as missing a label" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{"team_keys" => ["MDZ", "NOPE"]}, any_labels: ["feat-symphony"])

    {result, log} = with_log(fn -> Adapter.preflight(settings) end)

    assert result == {:error, {:linear_preflight_failed, ["unknown Linear team key \"NOPE\""]}}
    refute log =~ "absent from team(s)"
  end

  test "preflight is a no-op without team keys" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    settings = preflight_settings(provider: %{}, project_slug: "acme-web")

    assert :ok = Adapter.preflight(settings)
    refute_received {:preflight_query, _query, _variables}
  end

  test "the tracker facade dispatches preflight to the adapter and falls back to ok" do
    Application.put_env(:symphony_elixir, :linear_client_module, PreflightClient)

    assert :ok = SymphonyElixir.Tracker.preflight(preflight_settings(provider: %{"team_keys" => ["MDZ"]}))
    assert_received {:preflight_query, _query, _variables}

    assert :ok = SymphonyElixir.Tracker.preflight(%{kind: "memory"})
  end

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
    # format_scope_and_dashboard_lines/0 also runs on the dashboard's degraded :error path.
    assert SymphonyElixir.Tracker.scope_summary(%{kind: "nope"}) == "n/a"
  end

  test "tracker reports an explicit error when an adapter does not support blocked writes" do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: owner/repo
        token: token
      active_states: [open]
      terminal_states: [closed]
    ---
    body
    """)

    assert :ok = WorkflowStore.force_reload()

    assert {:error, {:unsupported_tracker_operation, :create_comment}} =
             SymphonyElixir.Tracker.create_comment("1", "blocked")

    assert {:error, {:unsupported_tracker_operation, :update_issue_state}} =
             SymphonyElixir.Tracker.update_issue_state("1", "closed")
  end

  defp state_lookup_result(state_id) do
    {:ok,
     %{
       "data" => %{
         "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => state_id}]}}}
       }
     }}
  end

  # Only the keys a given preflight case turns on are stated at the call site; the rest are the
  # resolvable defaults, so each test reads as the one thing it is about.
  defp preflight_settings(overrides) do
    Map.merge(
      %{
        kind: "linear",
        provider: %{},
        project_slug: nil,
        any_labels: [],
        required_labels: [],
        active_states: ["Todo"],
        terminal_states: ["Done"]
      },
      Map.new(overrides)
    )
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "blocked" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "issue_url" => "https://example.org/issues/MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "issue_url" => "https://example.org/issues/MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "issue_url" => "https://example.org/issues/MT-BLOCKED",
                 "state" => "In Progress",
                 "error" => "codex turn requires operator input",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "session_id" => "thread-blocked",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "codex turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "error" => "codex turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~r|/dashboard\.css\?v=[0-9a-f]{12}|

    assert html =~
             ~r|<link rel="icon" type="image/png" sizes="128x128" href="/favicon\.png\?v=[0-9a-f]{12}">|

    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "text-decoration-thickness: 1px"

    favicon_conn = get(build_conn(), "/favicon.png")
    assert response(favicon_conn, 200) == File.read!("priv/static/favicon.png")
    assert Plug.Conn.get_resp_header(favicon_conn, "content-type") == ["image/png; charset=utf-8"]

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ ~s(href="https://example.org/issues/MT-HTTP")
    assert html =~ ~s(href="https://example.org/issues/MT-RETRY")
    assert html =~ ~s(href="https://example.org/issues/MT-BLOCKED")
    assert html =~ ~s(aria-label="Open MT-HTTP in the issue tracker")
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "javascript:alert('nope')",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)

    refute render(view) =~ "javascript:alert"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "blocked" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          issue_url: "https://example.org/issues/MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          issue_url: "https://example.org/issues/MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_codex_timestamp: DateTime.utc_now()
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
