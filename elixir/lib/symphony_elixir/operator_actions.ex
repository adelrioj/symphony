defmodule SymphonyElixir.OperatorActions do
  @moduledoc """
  Operator controls for one lane's tickets. Stop and retry act on the lane orchestrator. Resuming a
  blocked ticket goes through the `Tracker` behaviour, so the normal blocked-issue reconcile releases it
  and a new attempt starts. Callers must already be in the lane's `LaneContext`.
  """

  alias SymphonyElixir.{Config, Orchestrator, Tracker}

  @spec stop(GenServer.server(), String.t()) :: :ok | {:error, :not_running | :unavailable}
  def stop(orchestrator, issue_id) when is_binary(issue_id), do: call(orchestrator, {:operator_stop, issue_id})

  @spec retry_now(GenServer.server(), String.t()) :: :ok | {:error, :not_retrying | :unavailable}
  def retry_now(orchestrator, issue_id) when is_binary(issue_id), do: call(orchestrator, {:operator_retry_now, issue_id})

  @spec resume(GenServer.server(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def resume(orchestrator, issue_id, message) when is_binary(issue_id) do
    with {:ok, target} <- resume_state(),
         :ok <- comment(issue_id, message),
         :ok <- Tracker.update_issue_state(issue_id, target) do
      _ = Orchestrator.request_refresh(orchestrator)
      :ok
    end
  end

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
