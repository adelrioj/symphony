defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with the selected agent backend.
  """

  require Logger
  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil
  @blocked_comment_detail_limit 4_000

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          outcome =
            with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
              run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end

          handle_run_outcome(outcome, issue)
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_run_outcome({:blocked, result}, issue), do: post_blocked_state(issue, result)
  defp handle_run_outcome(other, _issue), do: other

  defp post_blocked_state(%Issue{} = issue, result) do
    body = blocked_comment_body(issue, result)

    case Tracker.create_comment(issue.id, body) do
      :ok ->
        blocked_state = Config.settings!().agent.blocked_state

        case Tracker.update_issue_state(issue.id, blocked_state) do
          :ok ->
            Logger.info("Parked blocked issue #{issue_context(issue)} state=#{blocked_state}")

          {:error, reason} ->
            Logger.error("Blocked state update failed for #{issue_context(issue)}: #{inspect(reason)} (comment posted; will retry on next poll)")
        end

      {:error, reason} ->
        Logger.error("Blocked comment failed for #{issue_context(issue)}: #{inspect(reason)} (state NOT changed; will retry on next poll)")
    end

    :ok
  end

  defp blocked_comment_body(%Issue{} = _issue, result) do
    detail = result.blocked_action || result.summary || "No blocked action detail was provided."
    truncated = String.slice(detail, 0, @blocked_comment_detail_limit)
    suffix = if String.length(detail) > @blocked_comment_detail_limit, do: "\n... (truncated)", else: ""

    """
    **Symphony: blocked**

    session_id: #{result.session_id || "unknown"}

    #{truncated}#{suffix}
    """
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    backend = Keyword.get(opts, :backend_module, SymphonyElixir.Agent.Codex)

    session_opts = Keyword.put(opts, :worker_host, worker_host)

    with {:ok, session} <- backend.start_session(workspace, session_opts) do
      turn_context = %{
        backend: backend,
        session: session,
        workspace: workspace,
        issue: issue,
        recipient: codex_update_recipient,
        opts: opts,
        issue_state_fetcher: issue_state_fetcher,
        max_turns: max_turns
      }

      try do
        do_run_agent_turns(turn_context, 1)
      after
        backend.stop_session(session)
      end
    end
  end

  defp do_run_agent_turns(%{issue: issue, opts: opts, max_turns: max_turns} = context, turn_number) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns, context.backend)

    turn_opts = Keyword.put(opts, :on_message, agent_message_handler(context.recipient, issue))

    with {:ok, %Result{} = result} <- context.backend.run_turn(context.session, prompt, issue, turn_opts) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{result.session_id} workspace=#{context.workspace} turn=#{turn_number}/#{max_turns}")

      handle_turn_result(context, result, turn_number)
    end
  end

  defp handle_turn_result(%{issue: issue, issue_state_fetcher: fetcher, max_turns: max_turns} = context, %Result{status: :done}, turn_number) do
    case continue_with_issue?(issue, fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_agent_turns(%{context | issue: refreshed_issue}, turn_number + 1)

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_turn_result(_context, %Result{status: :blocked} = result, _turn_number), do: {:blocked, result}

  defp build_turn_prompt(issue, opts, 1, _max_turns, _backend), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(issue, opts, turn_number, max_turns, SymphonyElixir.Agent.Claude) do
    original_prompt = PromptBuilder.build_prompt(issue, opts)

    """
    #{original_prompt}

    Continuation guidance:

    - The previous Claude turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The full issue instructions are included above because Claude runs each turn in a fresh process.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, _backend) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if same_issue_state?(issue.state, refreshed_issue.state) and active_issue_state?(refreshed_issue.state) and
             issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp same_issue_state?(current_state, refreshed_state) when is_binary(current_state) and is_binary(refreshed_state) do
    normalize_issue_state(current_state) == normalize_issue_state(refreshed_state)
  end

  defp same_issue_state?(_current_state, _refreshed_state), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Map.take(Config.settings!().tracker, [:required_labels, :any_labels]))
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
