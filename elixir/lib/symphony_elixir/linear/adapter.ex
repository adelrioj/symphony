defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Linear.{AgentTool, Client, Scope}
  alias SymphonyElixir.Tracker.Issue

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  # Neither preflight query paginates, and both cap every connection well below Linear's
  # maximum because query complexity is MULTIPLICATIVE across nested connections with a ceiling
  # of 10000. Measured against the live API: 250x250 and 250x50 are both rejected, 100x50 is
  # accepted. Raising either teams number means re-measuring, not just doubling it.
  @teams_page_size 100
  @team_states_page_size 50
  @labels_page_size 250

  # `activeCycle` is a single object rather than a connection, so selecting it costs nothing
  # against the budget above. Only `id` is read, and only for presence.
  @teams_preflight_query """
  query SymphonyPreflightTeams($filter: TeamFilter!) {
    teams(filter: $filter, first: #{@teams_page_size}) {
      nodes {
        key
        activeCycle {
          id
        }
        states(first: #{@team_states_page_size}) {
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
    issueLabels(filter: $filter, first: #{@labels_page_size}) {
      nodes {
        name
        team {
          key
        }
      }
    }
  }
  """

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

  @doc """
  Resolves the configured Linear scope against the workspace once at startup.

  Every unresolved selector is reported together, because fixing them one boot
  at a time is what an operator with four mistyped selectors would otherwise do.
  """
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

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts) do
    AgentTool.execute(tool, arguments, opts)
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: tracker_settings.secret_environment_names

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp preflight_label_names(tracker_settings) do
    ((Map.get(tracker_settings, :any_labels) || []) ++ (Map.get(tracker_settings, :required_labels) || []))
    |> Enum.uniq()
  end

  # Two requests resolve every selector, not one per value: the teams query carries each team's
  # workflow states and active cycle, and labels are filtered by name in a single second read.
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
        Logger.warning("Linear team #{inspect(team["key"])} has no active cycle; scope current_cycle will match nothing until a cycle starts")
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

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
