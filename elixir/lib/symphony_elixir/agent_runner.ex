defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with the selected agent backend.
  """

  require Logger
  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{BlockedIssue, Config, ExecutionContext, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | {:error, term()} | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    with {:ok, context} <- execution_context(Config.settings!(), opts) do
      opts = Keyword.put_new_lazy(opts, :attempt_id, &new_attempt_id/0)
      Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(context.worker_host)}")

      case run_on_worker_host(issue, codex_update_recipient, opts, context) do
        :ok ->
          :ok

        {:error, {:managed_execution_unknown, _detail} = reason} ->
          exit(reason)

        {:error, reason} ->
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
      end
    end
  end

  defp new_attempt_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp execution_context(settings, opts) do
    case {Map.get(settings.worker, :environment), Keyword.get(opts, :execution_context)} do
      {%{}, %ExecutionContext{mode: :managed} = context} -> {:ok, context}
      {%{}, _} -> {:error, :managed_context_required}
      {nil, %ExecutionContext{} = context} -> {:ok, context}
      {nil, _} -> {:error, :execution_context_required}
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host.worker_host)}")
    on_hook = agent_message_handler(codex_update_recipient, issue, opts[:attempt_id])

    case Workspace.create_for_issue(issue, worker_host, on_hook) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, opts[:attempt_id])

        run_with_workspace_hooks(workspace, issue, codex_update_recipient, opts, worker_host, on_hook)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_with_workspace_hooks(workspace, issue, recipient, opts, %ExecutionContext{mode: :managed} = context, on_hook) do
    outcome =
      try do
        with :ok <- Workspace.run_before_run_hook(workspace, issue, context, on_hook) do
          run_agent_turns(workspace, issue, recipient, opts, context)
        end
      catch
        :exit, {:managed_execution_unknown, _detail} = reason ->
          :erlang.raise(:exit, reason, __STACKTRACE__)

        kind, reason ->
          propagate_run_failure(workspace, issue, context, on_hook, {kind, reason, __STACKTRACE__})
      end

    case outcome do
      {:error, {:managed_execution_unknown, _detail}} = unknown ->
        unknown

      _ ->
        with :ok <- Workspace.run_after_run_hook(workspace, issue, context, on_hook) do
          handle_run_outcome(outcome, issue)
        end
    end
  end

  defp run_with_workspace_hooks(workspace, issue, recipient, opts, context, on_hook) do
    outcome =
      with :ok <- Workspace.run_before_run_hook(workspace, issue, context, on_hook) do
        run_agent_turns(workspace, issue, recipient, opts, context)
      end

    handle_run_outcome(outcome, issue)
  after
    Workspace.run_after_run_hook(workspace, issue, context, on_hook)
  end

  @spec propagate_run_failure(
          Path.t(),
          Issue.t(),
          ExecutionContext.t(),
          Workspace.hook_observer(),
          {atom(), term(), list()}
        ) :: no_return()
  defp propagate_run_failure(workspace, issue, context, on_hook, {kind, reason, stacktrace}) do
    Workspace.run_after_run_hook(workspace, issue, context, on_hook)
  after
    :erlang.raise(kind, reason, stacktrace)
  end

  defp handle_run_outcome({:blocked, result}, issue), do: post_blocked_state(issue, result)
  defp handle_run_outcome(other, _issue), do: other

  defp post_blocked_state(%Issue{} = issue, result) do
    BlockedIssue.park(issue.id, issue.identifier, blocked_detail(result), result.session_id)
  end

  defp blocked_detail(result), do: result.blocked_action || result.summary || "No blocked action detail was provided."

  defp agent_message_handler(recipient, issue, attempt_id) do
    fn message ->
      send_codex_update(recipient, issue, message, attempt_id)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message, attempt_id)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, attempt_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message, _attempt_id), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, context, workspace, attempt_id)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id, attempt_id,
       %{
         worker_host: context.worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _context, _workspace, _attempt_id), do: :ok

  defp send_turns_exhausted(recipient, %Issue{id: issue_id, state: state_name}, attempt_id)
       when is_binary(issue_id) and is_binary(state_name) and is_pid(recipient) do
    send(recipient, {:agent_turns_exhausted, issue_id, attempt_id, state_name})
    :ok
  end

  defp send_turns_exhausted(_recipient, _issue, _attempt_id), do: :ok

  defp run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    backend = Keyword.get(opts, :backend_module, SymphonyElixir.Agent.Codex)

    session_opts = Keyword.put(opts, :execution_context, worker_host)

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

    turn_opts = Keyword.put(opts, :on_message, agent_message_handler(context.recipient, issue, opts[:attempt_id]))

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

        send_turns_exhausted(context.recipient, refreshed_issue, context.opts[:attempt_id])

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_turn_result(context, %Result{status: :blocked} = result, _turn_number) do
    update = %{
      event: :attempt_blocked,
      timestamp: DateTime.utc_now(),
      session_id: result.session_id,
      payload: blocked_detail(result)
    }

    send_codex_update(context.recipient, context.issue, update, context.opts[:attempt_id])

    {:blocked, result}
  end

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
