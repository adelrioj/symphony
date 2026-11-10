defmodule SymphonyElixir.WorkspaceDiscard do
  @moduledoc """
  Leaves a record when a workspace is discarded because its issue carries an excluded label.

  Exclusion releases the issue's workspace through the ordinary cleanup path, so work that was
  never pushed is lost with it. Symphony does not push it: the workspace is agent-controlled, and
  publishing its contents with the lane's credentials is a decision for the operator's
  `hooks.before_remove`, which still runs afterwards. What Symphony guarantees instead is that the
  loss is never silent: the branch, last pushed commit, local HEAD and unpushed/uncommitted counts
  are logged and, when the tracker supports comments, posted on the issue. Reading or posting may
  fail; that is recorded too and never holds the exclusion back.
  """

  require Logger

  alias SymphonyElixir.{Tracker, Workspace}

  @spec notify(map(), String.t(), {:ok, Workspace.discard_report()} | {:error, term()}) :: :ok
  def notify(issue, label, report) when is_map(issue) and is_binary(label) do
    issue_id = Map.get(issue, :id) || Map.get(issue, :issue_id)
    identifier = Map.get(issue, :identifier) || Map.get(issue, :issue_identifier) || issue_id

    Logger.warning(
      "Discarding workspace of excluded issue issue_id=#{issue_id} issue_identifier=#{identifier} " <>
        "label=#{label} #{log_fields(report)}"
    )

    comment(issue_id, identifier, body(label, report))
  end

  @doc false
  @spec body(String.t(), {:ok, Workspace.discard_report()} | {:error, term()}) :: String.t()
  def body(label, {:ok, report}) do
    """
    Symphony removed this issue from its lane because it carries the `#{label}` label, and is discarding its workspace.

    - Branch: #{value(report.branch, "(detached or unknown)")}
    - Last pushed commit: #{pushed(report)}
    - Local HEAD: #{value(report.head, "unknown")}
    - Unpushed commits: #{count(report.unpushed)}
    - Uncommitted paths: #{count(report.dirty)}

    Commits that were not pushed and uncommitted changes are lost with the workspace. Removing the label makes the issue eligible again; it then starts from a fresh workspace.
    """
  end

  def body(label, {:error, _reason}) do
    """
    Symphony removed this issue from its lane because it carries the `#{label}` label, and is discarding its workspace.

    The workspace's Git state could not be read, so its branch and last pushed commit are unknown. Anything that was not pushed is lost with the workspace. Removing the label makes the issue eligible again; it then starts from a fresh workspace.
    """
  end

  defp comment(issue_id, identifier, body) when is_binary(issue_id) do
    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not comment on discarded workspace issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{reason_code(reason)}"
        )
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "Could not comment on discarded workspace issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(error.__struct__)}"
      )

      :ok
  end

  defp comment(_issue_id, _identifier, _body), do: :ok

  defp log_fields({:ok, report}) do
    "branch=#{value(report.branch, "unknown")} upstream=#{value(report.upstream, "none")} " <>
      "pushed=#{value(report.pushed, "unknown")} head=#{value(report.head, "unknown")} " <>
      "unpushed=#{count(report.unpushed)} dirty=#{count(report.dirty)}"
  end

  defp log_fields({:error, reason}), do: "workspace_state=unreadable reason=#{reason_code(reason)}"

  defp pushed(%{pushed: sha, upstream: upstream}) when is_binary(sha), do: "#{sha} (#{value(upstream, "upstream")})"
  defp pushed(_report), do: "none known (no upstream branch)"

  defp value(value, _fallback) when is_binary(value), do: value
  defp value(_value, fallback), do: fallback

  defp count(value) when is_integer(value), do: Integer.to_string(value)
  defp count(_value), do: "unknown"

  # Tracker and transport failures can carry response bodies; log only their shape.
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_code(_reason), do: "error"
end
