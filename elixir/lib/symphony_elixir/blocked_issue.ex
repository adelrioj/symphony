defmodule SymphonyElixir.BlockedIssue do
  @moduledoc """
  Parks a tracker work item that Symphony cannot make progress on: posts an explanatory
  comment, then moves the item to the configured `agent.blocked_state`.

  The comment is posted first on purpose. If the comment fails the state is left untouched
  so the next poll retries the whole park instead of silently hiding the work item.
  """

  require Logger
  alias SymphonyElixir.{Config, Tracker}

  @detail_limit 4_000

  @spec park(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def park(issue_id, identifier, detail, session_id)
      when is_binary(issue_id) and is_binary(identifier) and is_binary(detail) do
    case Tracker.create_comment(issue_id, comment_body(detail, session_id)) do
      :ok ->
        park_state(issue_id, identifier)

      {:error, reason} ->
        Logger.error("Blocked comment failed for #{issue_context(issue_id, identifier)}: #{inspect(reason)} (state NOT changed; will retry on next poll)")

        :ok
    end
  end

  defp park_state(issue_id, identifier) do
    blocked_state = Config.settings!().agent.blocked_state

    case Tracker.update_issue_state(issue_id, blocked_state) do
      :ok ->
        Logger.info("Parked blocked issue #{issue_context(issue_id, identifier)} state=#{blocked_state}")

      {:error, reason} ->
        Logger.error("Blocked state update failed for #{issue_context(issue_id, identifier)}: #{inspect(reason)} (comment posted; will retry on next poll)")
    end

    :ok
  end

  defp comment_body(detail, session_id) do
    truncated = String.slice(detail, 0, @detail_limit)
    suffix = if String.length(detail) > @detail_limit, do: "\n... (truncated)", else: ""

    """
    **Symphony: blocked**

    session_id: #{session_id || "unknown"}

    #{truncated}#{suffix}
    """
  end

  defp issue_context(issue_id, identifier), do: "issue_id=#{issue_id} issue_identifier=#{identifier}"
end
