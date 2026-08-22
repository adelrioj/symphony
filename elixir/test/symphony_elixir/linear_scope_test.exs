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

    test "a settings map carrying neither scope key is an error" do
      dropped = Map.drop(settings(%{}), [:project_slug, :team_keys])
      assert {:error, :missing_linear_scope} = Adapter.validate_config(dropped)
    end
  end

  describe "preflight" do
    import ExUnit.CaptureLog

    alias SymphonyElixir.Linear.Adapter

    defmodule StubClient do
      @moduledoc false

      @spec graphql(String.t(), map()) :: {:ok, map()} | {:error, term()}
      def graphql(query, _variables) do
        responses = Process.get(:preflight_responses, %{})
        Process.put(:preflight_queries, [query | Process.get(:preflight_queries, [])])

        case Process.get(:preflight_request_counter) do
          nil -> :ok
          pid -> send(pid, :preflight_request)
        end

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
            "nodes" =>
              Enum.map(pairs, fn
                {name, nil} -> %{"name" => name, "team" => nil}
                {name, team} -> %{"name" => name, "team" => %{"key" => team}}
              end)
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
      # terminal_states (default ["Done"]) is not stubbed as a known state either, so it
      # must be reported too — proves terminal_states is actually validated, not just active_states.
      assert Enum.any?(reasons, &(&1 =~ "state" and &1 =~ "Done"))
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

    test "a label that exists only in a team that is not listed is an error" do
      # The label resolves fine against the workspace (it exists, in team ZED), but ZED is
      # not one of the listed team_keys, so the poll filter (team AND label) would never
      # match anything. Reverting the team-scoping check to a bare Map.has_key? on label
      # name alone would make this test fail to raise an error and assert :ok instead.
      stub(
        teams_response([{"MDZ", ["To Do", "Done"]}]),
        labels_response([{"bug-symphony", "ZED"}])
      )

      assert {:error, {:linear_preflight_failed, reasons}} =
               Adapter.preflight(scoped_settings(%{team_keys: ["MDZ"]}))

      assert Enum.any?(reasons, &(&1 =~ "bug-symphony"))
    end

    test "a workspace-level label with no team applies to every listed team" do
      stub(
        teams_response([{"MDZ", ["To Do", "Done"]}]),
        labels_response([{"bug-symphony", nil}])
      )

      assert :ok = Adapter.preflight(scoped_settings(%{team_keys: ["MDZ"]}))
    end

    test "team key comparison is case-insensitive" do
      stub(teams_response([{"MDZ", ["To Do", "Done"]}]), labels_response([{"bug-symphony", "MDZ"}]))

      assert :ok = Adapter.preflight(scoped_settings(%{team_keys: ["mdz"]}))
    end

    test "state name comparison is case-insensitive" do
      stub(teams_response([{"MDZ", ["TO DO", "DONE"]}]), labels_response([{"bug-symphony", "MDZ"}]))

      assert :ok = Adapter.preflight(scoped_settings(%{}))
    end

    test "exactly two requests are made regardless of team, state, or label count" do
      parent = self()

      Process.put(:preflight_responses, %{
        teams: {:ok, teams_response([{"MDZ", ["To Do", "Done"]}, {"TRA", ["To Do", "Done"]}])},
        labels: {:ok, labels_response([{"bug-symphony", "MDZ"}, {"feat-symphony", "TRA"}, {"backend", "MDZ"}])}
      })

      Process.put(:preflight_request_counter, parent)

      settings =
        scoped_settings(%{
          team_keys: ["MDZ", "TRA"],
          any_labels: ["bug-symphony", "feat-symphony"],
          required_labels: ["backend"],
          active_states: ["To Do"],
          terminal_states: ["Done"]
        })

      assert :ok = Adapter.preflight(settings)
      assert_receive :preflight_request, 0
      assert_receive :preflight_request, 0
      refute_receive :preflight_request, 0
    end

    test "every unresolved value is reported in one error" do
      stub(teams_response([{"MDZ", ["To Do"]}]), labels_response([]))

      assert {:error, {:linear_preflight_failed, reasons}} =
               Adapter.preflight(scoped_settings(%{team_keys: ["MDZ", "NOPE"], active_states: ["Todo"], any_labels: ["bug-symphony"]}))

      # One reason per category, not just a headcount, so this fails if any one category
      # stops accumulating (three state-only errors could otherwise satisfy a bare length check).
      assert Enum.any?(reasons, &(&1 =~ "team key" and &1 =~ "NOPE"))
      assert Enum.any?(reasons, &(&1 =~ "state" and &1 =~ "Todo"))
      assert Enum.any?(reasons, &(&1 =~ "bug-symphony"))
    end

    test "a transport error propagates unchanged" do
      Process.put(:preflight_responses, %{teams: {:error, :timeout}, labels: {:ok, labels_response([])}})

      assert {:error, :timeout} = Adapter.preflight(scoped_settings(%{}))
    end

    test "a labels transport error propagates unchanged" do
      Process.put(:preflight_responses, %{
        teams: {:ok, teams_response([{"MDZ", ["To Do", "Done"]}])},
        labels: {:error, :timeout}
      })

      assert {:error, :timeout} = Adapter.preflight(scoped_settings(%{}))
    end

    test "a malformed teams payload is reported as an unknown payload" do
      Process.put(:preflight_responses, %{teams: {:ok, %{"data" => %{}}}, labels: {:ok, labels_response([])}})

      assert {:error, :linear_unknown_payload} = Adapter.preflight(scoped_settings(%{}))
    end

    test "a malformed labels payload is reported as an unknown payload" do
      Process.put(:preflight_responses, %{
        teams: {:ok, teams_response([{"MDZ", ["To Do", "Done"]}])},
        labels: {:ok, %{"data" => %{}}}
      })

      assert {:error, :linear_unknown_payload} = Adapter.preflight(scoped_settings(%{}))
    end

    test "a label present in only some listed teams warns without failing startup" do
      stub(
        teams_response([{"MDZ", ["To Do", "Done"]}, {"TRA", ["To Do", "Done"]}]),
        labels_response([{"bug-symphony", "MDZ"}])
      )

      log =
        capture_log(fn ->
          assert :ok = Adapter.preflight(scoped_settings(%{team_keys: ["MDZ", "TRA"]}))
        end)

      assert log =~ "label=bug-symphony"
      assert log =~ "missing_team_keys=tra"
    end

    test "a state present in only some listed teams warns without failing startup" do
      stub(
        teams_response([{"MDZ", ["To Do", "Done"]}, {"TRA", ["Done"]}]),
        labels_response([{"bug-symphony", nil}])
      )

      log =
        capture_log(fn ->
          assert :ok = Adapter.preflight(scoped_settings(%{team_keys: ["MDZ", "TRA"]}))
        end)

      assert log =~ "state=To Do"
      assert log =~ "missing_team_keys=TRA"
    end

    test "a label that normalizes to blank is reported rather than dropped" do
      # Config.Schema trims and downcases labels but does not drop blanks, so `any_labels: ["  "]`
      # reaches the tracker as [""] — which Issue.routable?/2 can never satisfy. Preflight must
      # say so instead of booting a deployment that will never dispatch anything.
      stub(teams_response([{"MDZ", ["To Do", "Done"]}]), labels_response([]))

      assert {:error, {:linear_preflight_failed, reasons}} =
               Adapter.preflight(scoped_settings(%{any_labels: [""]}))

      assert Enum.any?(reasons, &(&1 == ~s(label "" does not exist in any listed team)))
    end

    test "a GraphQL error body on the teams query carries Linear's own message" do
      Process.put(:preflight_responses, %{
        teams: {:ok, %{"data" => nil, "errors" => [%{"message" => "Authentication required"}]}},
        labels: {:ok, labels_response([])}
      })

      assert {:error, {:linear_graphql_errors, [%{"message" => "Authentication required"}]}} =
               Adapter.preflight(scoped_settings(%{}))
    end

    test "a GraphQL error body on the labels query carries Linear's own message" do
      Process.put(:preflight_responses, %{
        teams: {:ok, teams_response([{"MDZ", ["To Do", "Done"]}])},
        labels: {:ok, %{"data" => nil, "errors" => [%{"message" => "Query too complex"}]}}
      })

      assert {:error, {:linear_graphql_errors, [%{"message" => "Query too complex"}]}} =
               Adapter.preflight(scoped_settings(%{}))
    end

    test "both preflight queries keep their page sizes within Linear's complexity budget" do
      # These numbers are not free choices and not "Linear's maximum page size" — they are capped by
      # Linear's query-complexity budget (max 10000), which is MULTIPLICATIVE across nested
      # connections. Measured against the live API: teams 250 x states 250 scored 69025 and
      # 250 x 50 scored 14025, both rejected; 100 x 50 was accepted. The single-level labels query is
      # cheap and accepts 250. An earlier version of this test asserted 250 x 250 and passed happily
      # against the stub while every real preflight call 400'd, so if you change a number here,
      # re-measure against the API rather than trusting this test.
      stub(teams_response([{"MDZ", ["To Do", "Done"]}]), labels_response([{"bug-symphony", "MDZ"}]))

      assert :ok = Adapter.preflight(scoped_settings(%{}))

      queries = Process.get(:preflight_queries, [])

      assert Enum.any?(queries, &(&1 =~ "teams(filter: $filter, first: 100)" and &1 =~ "states(first: 50)"))
      assert Enum.any?(queries, &(&1 =~ "issueLabels(filter: $filter, first: 250)"))
    end

    test "no configured labels skips the labels request" do
      # No :labels key is stubbed at all, so if fetch_preflight_labels([]) did not
      # short-circuit and instead issued a request, StubClient would raise KeyError.
      Process.put(:preflight_responses, %{teams: {:ok, teams_response([{"MDZ", ["To Do", "Done"]}])}})

      assert :ok = Adapter.preflight(scoped_settings(%{any_labels: [], required_labels: []}))
    end
  end
end
