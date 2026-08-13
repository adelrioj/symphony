defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Tracker.Issue

  @calls_key {__MODULE__, :calls}
  @failures_key {__MODULE__, :failures}

  @type operation :: :create_comment | :update_issue_state

  @impl true
  @spec validate_config(map()) :: :ok
  def validate_config(_tracker_settings), do: :ok

  @spec calls() :: [tuple()]
  def calls do
    @calls_key
    |> Process.get([])
    |> Enum.reverse()
  end

  @spec reset() :: :ok
  def reset do
    Process.delete(@calls_key)
    Process.delete(@failures_key)
    :ok
  end

  @spec fail(operation()) :: :ok
  def fail(operation) when operation in [:create_comment, :update_issue_state] do
    failures = Process.get(@failures_key, MapSet.new())
    Process.put(@failures_key, MapSet.put(failures, operation))
    :ok
  end

  @impl true
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @impl true
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @impl true
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    record_call({:create_comment, issue_id})

    if failed?(:create_comment) do
      {:error, {:memory_tracker_failed, :create_comment}}
    else
      send_event({:memory_tracker_comment, issue_id, body})
      :ok
    end
  end

  @impl true
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    record_call({:update_issue_state, issue_id, state_name})

    if failed?(:update_issue_state) do
      {:error, {:memory_tracker_failed, :update_issue_state}}
    else
      send_event({:memory_tracker_state_update, issue_id, state_name})
      :ok
    end
  end

  @impl true
  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp record_call(call) do
    calls = Process.get(@calls_key, [])
    Process.put(@calls_key, [call | calls])
    :ok
  end

  defp failed?(operation) do
    @failures_key
    |> Process.get(MapSet.new())
    |> MapSet.member?(operation)
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
