defmodule SymphonyElixir.OperatorActions do
  @moduledoc """
  Operator controls for one lane's tickets. Stop and retry act on the lane orchestrator. Resuming applies
  only to a blocked ticket (held by the orchestrator, or in `agent.blocked_state` in the tracker): it moves
  the ticket through the `Tracker` behaviour, then releases the orchestrator's block so the next poll
  starts a new attempt. Callers must already be in the lane's `LaneContext`.
  """

  alias SymphonyElixir.{Config, Orchestrator, Tracker}

  @spec stop(GenServer.server(), String.t()) :: :ok | {:error, :not_running | :unavailable}
  def stop(orchestrator, issue_id) when is_binary(issue_id), do: call(orchestrator, {:operator_stop, issue_id})

  @spec retry_now(GenServer.server(), String.t()) :: :ok | {:error, :not_retrying | :unavailable}
  def retry_now(orchestrator, issue_id) when is_binary(issue_id),
    do: call(orchestrator, {:operator_retry_now, issue_id})

  @spec resume(GenServer.server(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def resume(orchestrator, issue_id, message) when is_binary(issue_id) do
    with {:ok, target} <- resume_state(),
         :ok <- ensure_blocked(orchestrator, issue_id),
         :ok <- comment(issue_id, message),
         :ok <- Tracker.update_issue_state(issue_id, target) do
      # The ticket has moved; an unavailable lane has no block left to release.
      _ = call(orchestrator, {:operator_release_blocked, issue_id})
      _ = Orchestrator.request_refresh(orchestrator)
      :ok
    end
  end

  defp ensure_blocked(orchestrator, issue_id) do
    if call(orchestrator, {:operator_blocked?, issue_id}) == true, do: :ok, else: blocked_in_tracker(issue_id)
  end

  defp blocked_in_tracker(issue_id) do
    blocked_state = Config.settings!().agent.blocked_state

    with {:ok, issues} <- Tracker.fetch_issues_by_ids([issue_id]) do
      if Enum.any?(issues, &same_state?(&1.state, blocked_state)), do: :ok, else: {:error, :not_blocked}
    end
  end

  defp same_state?(a, b) when is_binary(a) and is_binary(b), do: normalize_state(a) == normalize_state(b)
  defp same_state?(_a, _b), do: false

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp resume_state do
    settings = Config.settings!()

    case Enum.reject(settings.tracker.active_states, &(&1 == settings.agent.blocked_state)) do
      [target | _] -> {:ok, target}
      [] -> {:error, :no_active_state}
    end
  end

  defp comment(issue_id, message) when is_binary(message) do
    case String.trim(message) do
      "" -> :ok
      body -> Tracker.create_comment(issue_id, body)
    end
  end

  defp comment(_issue_id, nil), do: :ok

  defp call(orchestrator, message) do
    GenServer.call(orchestrator, message)
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
