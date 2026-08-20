defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

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

  # Neither query paginates or sets `first:` — both rely on Linear's default page size.
  # Truncation here would drop resolved values and fail preflight on values that actually
  # exist (a false positive, not the silent-idle failure this function exists to catch).
  # Unlikely in practice: the teams query is filtered to the configured keys, and a
  # workspace rarely has enough matching labels or workflow states per team to hit a
  # default page limit. Left undocumented pagination handling as a known limitation.
  @teams_preflight_query """
  query SymphonyPreflightTeams($filter: TeamFilter!) {
    teams(filter: $filter) {
      nodes {
        key
        states {
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
    issueLabels(filter: $filter) {
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

  defp preflight_label_names(tracker_settings) do
    ((Map.get(tracker_settings, :any_labels) || []) ++ (Map.get(tracker_settings, :required_labels) || []))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.uniq()
  end

  defp fetch_preflight_teams(team_keys) do
    filter = %{or: Enum.map(team_keys, &%{key: %{eqIgnoreCase: &1}})}

    case client_module().graphql(@teams_preflight_query, %{filter: filter}) do
      {:ok, %{"data" => %{"teams" => %{"nodes" => nodes}}}} when is_list(nodes) -> {:ok, nodes}
      {:ok, _body} -> {:error, :linear_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_preflight_labels([]), do: {:ok, []}

  defp fetch_preflight_labels(label_names) do
    filter = %{or: Enum.map(label_names, &%{name: %{eqIgnoreCase: &1}})}

    case client_module().graphql(@labels_preflight_query, %{filter: filter}) do
      {:ok, %{"data" => %{"issueLabels" => %{"nodes" => nodes}}}} when is_list(nodes) -> {:ok, nodes}
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
    known_states =
      teams
      |> Enum.flat_map(fn team -> get_in(team, ["states", "nodes"]) || [] end)
      |> MapSet.new(&String.downcase(&1["name"] || ""))

    configured_states =
      ((Map.get(tracker_settings, :active_states) || []) ++ (Map.get(tracker_settings, :terminal_states) || []))
      |> Enum.uniq()

    configured_states
    |> Enum.reject(&MapSet.member?(known_states, String.downcase(&1)))
    |> Enum.map(&"state name #{inspect(&1)} does not exist in any listed team")
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
    |> Enum.reject(&label_in_listed_teams?(label_teams, listed_team_keys, &1))
    |> Enum.map(&"label #{inspect(&1)} does not exist in any listed team")
  end

  # A label with no `team` key (a workspace-level label) is normalized to team key ""
  # above, and counts as present in every listed team, not absent from all of them.
  defp label_in_listed_teams?(label_teams, listed_team_keys, label_name) do
    case Map.fetch(label_teams, String.downcase(label_name)) do
      {:ok, teams} -> MapSet.member?(teams, "") or not MapSet.disjoint?(teams, listed_team_keys)
      :error -> false
    end
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
