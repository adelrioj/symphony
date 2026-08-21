defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Linear.{AgentTool, Client}
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

  # Neither query paginates; both cap every connection at Linear's maximum page size of 250
  # instead of relying on the default (50). The labels query matches by name across every team
  # in the workspace, so a large workspace where many teams carry the same label name could
  # otherwise page the listed team's row off the end and refuse to boot a valid deployment.
  # Truncation would still fail preflight on values that actually exist (a false positive, not the
  # silent-idle failure this function exists to catch).
  #
  # The page sizes are capped by Linear's query-complexity budget (max 10000), and complexity is
  # MULTIPLICATIVE across nested connections, so teams x states is the binding constraint rather
  # than either number alone. Measured against the live API: 250x250 = 69025 and 250x50 = 14025 both
  # rejected; 100x50 accepted. The single-level labels query is cheap, and 250 is accepted there.
  # Raising either teams number means re-measuring, not just doubling it.
  @teams_preflight_query """
  query SymphonyPreflightTeams($filter: TeamFilter!) {
    teams(filter: $filter, first: 100) {
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

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    cond do
      not present_string?(tracker_settings.endpoint) ->
        {:error, :invalid_linear_endpoint}

      not present_string?(tracker_settings.api_key) ->
        {:error, :missing_linear_api_token}

      not scoped?(tracker_settings) ->
        {:error, :missing_linear_scope}

      not is_nil(tracker_settings.assignee) and not present_string?(tracker_settings.assignee) ->
        {:error, :invalid_linear_assignee}

      true ->
        :ok
    end
  end

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

  # Blank labels are deliberately kept: `Issue.routable?/2` can never satisfy one, so a config
  # that normalizes a label to "" dispatches nothing. Letting it miss the label query turns that
  # into a loud preflight failure instead of a permanently idle boot.
  defp preflight_label_names(tracker_settings) do
    ((Map.get(tracker_settings, :any_labels) || []) ++ (Map.get(tracker_settings, :required_labels) || []))
    |> Enum.uniq()
  end

  defp fetch_preflight_teams(team_keys) do
    filter = %{or: Enum.map(team_keys, &%{key: %{eqIgnoreCase: &1}})}

    case client_module().graphql(@teams_preflight_query, %{filter: filter}) do
      {:ok, %{"data" => %{"teams" => %{"nodes" => nodes}}}} when is_list(nodes) -> {:ok, nodes}
      {:ok, %{"errors" => errors}} -> {:error, {:linear_graphql_errors, errors}}
      {:ok, _body} -> {:error, :linear_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_preflight_labels([]), do: {:ok, []}

  defp fetch_preflight_labels(label_names) do
    filter = %{or: Enum.map(label_names, &%{name: %{eqIgnoreCase: &1}})}

    case client_module().graphql(@labels_preflight_query, %{filter: filter}) do
      {:ok, %{"data" => %{"issueLabels" => %{"nodes" => nodes}}}} when is_list(nodes) -> {:ok, nodes}
      {:ok, %{"errors" => errors}} -> {:error, {:linear_graphql_errors, errors}}
      {:ok, _body} -> {:error, :linear_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp report_preflight(team_keys, teams, labels, tracker_settings) do
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
    states_by_team =
      Map.new(teams, fn team ->
        states = MapSet.new(get_in(team, ["states", "nodes"]) || [], &String.downcase(&1["name"] || ""))
        {team["key"] || "", states}
      end)

    known_states = states_by_team |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    ((Map.get(tracker_settings, :active_states) || []) ++ (Map.get(tracker_settings, :terminal_states) || []))
    |> Enum.uniq()
    |> Enum.flat_map(fn state ->
      if MapSet.member?(known_states, String.downcase(state)) do
        warn_partial_scope("state", state, teams_missing_state(states_by_team, state))
        []
      else
        ["state name #{inspect(state)} does not exist in any listed team"]
      end
    end)
  end

  defp unknown_label_names(tracker_settings, team_keys, labels) do
    listed_team_keys = MapSet.new(team_keys, &String.downcase/1)

    label_teams =
      Enum.reduce(labels, %{}, fn label, acc ->
        name = String.downcase(label["name"] || "")
        team_key = String.downcase(get_in(label, ["team", "key"]) || "")

        Map.update(acc, name, MapSet.new([team_key]), &MapSet.put(&1, team_key))
      end)

    tracker_settings
    |> preflight_label_names()
    |> Enum.flat_map(fn label ->
      if label_in_listed_teams?(label_teams, listed_team_keys, label) do
        warn_partial_scope("label", label, teams_missing_label(label_teams, listed_team_keys, label))
        []
      else
        ["label #{inspect(label)} does not exist in any listed team"]
      end
    end)
  end

  # A label with no `team` key (a workspace-level label) is normalized to team key ""
  # above, and counts as present in every listed team, not absent from all of them.
  defp label_in_listed_teams?(label_teams, listed_team_keys, label_name) do
    case Map.fetch(label_teams, String.downcase(label_name)) do
      {:ok, teams} -> MapSet.member?(teams, "") or not MapSet.disjoint?(teams, listed_team_keys)
      :error -> false
    end
  end

  defp teams_missing_state(states_by_team, state) do
    downcased = String.downcase(state)

    states_by_team
    |> Enum.reject(fn {_key, states} -> MapSet.member?(states, downcased) end)
    |> Enum.map(fn {key, _states} -> key end)
    |> Enum.sort()
  end

  defp teams_missing_label(label_teams, listed_team_keys, label_name) do
    teams = Map.fetch!(label_teams, String.downcase(label_name))

    if MapSet.member?(teams, "") do
      []
    else
      listed_team_keys |> MapSet.difference(teams) |> Enum.sort()
    end
  end

  # Design §5: absent from every listed team is an error; absent from only some is a warning —
  # the configured scope still resolves, but no issue in the named teams can ever match.
  defp warn_partial_scope(_kind, _name, []), do: :ok

  defp warn_partial_scope(kind, name, missing_team_keys) do
    Logger.warning(
      "Linear preflight #{kind} missing from some listed teams " <>
        "#{kind}=#{name} missing_team_keys=#{Enum.join(missing_team_keys, ",")} outcome=issues_in_those_teams_never_match"
    )
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

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp scoped?(%{team_keys: team_keys}) when is_list(team_keys) and team_keys != [], do: true
  defp scoped?(%{project_slug: project_slug}), do: present_string?(project_slug)
  defp scoped?(_tracker_settings), do: false
end
