defmodule SymphonyElixir.Agent.Claude do
  @moduledoc """
  Agent backend that runs Claude Code (`claude -p`) per turn.

  Claude emits newline-delimited `stream-json`; this adapter folds decoded
  events into an `Agent.Result` while emitting normalized worker updates.
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Claude.Stream
  alias SymphonyElixir.Agent.CliHarness
  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{Config, ExecutionContext, LaneContext, SSH, Tracker, Workflow, Workspace}
  alias SymphonyElixir.MCP.ProcedureSession

  @approval_tool "mcp__symphony__approval_prompt"
  @procedure_tool "mcp__symphony__read_procedure"
  @default_non_tracker_tools [
    "Read",
    "Grep",
    "Glob",
    "Bash",
    "Edit",
    "Write"
  ]
  @port_line_bytes 1_048_576

  @type session :: %{
          required(:workspace) => Path.t(),
          required(:execution_context) => ExecutionContext.t(),
          required(:session_dir) => Path.t(),
          required(:mcp_config_path) => Path.t(),
          required(:workflow_snapshot_path) => Path.t(),
          required(:procedure_path) => Path.t() | nil,
          required(:procedure_preflight?) => boolean(),
          required(:secret_environment_names) => [String.t()],
          required(:tool_specs) => [map()],
          required(:claude_settings) => map(),
          required(:cleanup_monitor) => pid()
        }

  defmodule RemoteProcedureStream do
    @moduledoc false
    @behaviour CliHarness.StreamFolder

    # The SSH wrapper reserves these codes for its private outcome file, not Claude's own exit.
    @blocked %{80 => "qa", 81 => "bug", 82 => "deliver", 83 => "error-reporting"}
    @unread 84
    @outcome_timeout_ms 2_000

    @impl true
    def new, do: Stream.new()

    @impl true
    def step(event, acc), do: Stream.step(event, acc)

    @impl true
    def finalize(acc, code) when is_map_key(@blocked, code) do
      section = Map.fetch!(@blocked, code)
      {:ok, result} = Stream.finalize(%{acc | blocked_action: ProcedureSession.missing_text(section)}, code)
      {:ok, %{result | missing_procedure: section}}
    end

    def finalize(acc, @unread) do
      case Stream.finalize(acc, 0) do
        {:ok, %Result{status: :done} = result} -> {:error, {:procedure_unread, result}}
        other -> other
      end
    end

    def finalize(acc, code), do: Stream.finalize(acc, code)

    @spec wrap_command(String.t(), Path.t()) :: String.t()
    def wrap_command(command, path) do
      {check, cases} = outcome_check(path)

      "{ #{command}; symphony_claude_status=$?; " <>
        "case \"$symphony_claude_status\" in 8[0-4]) symphony_claude_status=1;; esac; " <>
        "#{check} #{cases} " <>
        "read:qa|read:bug|read:deliver) ;; *) [ \"$symphony_claude_status\" -ne 0 ] || exit #{@unread};; esac; " <>
        "exit \"$symphony_claude_status\"; }"
    end

    @spec timeout_handler(String.t() | SSH.Target.t(), Path.t() | nil) ::
            (term(), atom() -> {:ok, Result.t()} | {:error, atom()}) | nil
    def timeout_handler(_host, nil), do: nil

    def timeout_handler(host, path) do
      fn acc, reason ->
        case probe_outcome(host, path) do
          code when is_map_key(@blocked, code) -> finalize(acc, code)
          _ -> {:error, reason}
        end
      end
    end

    # Check the private outcome before closing the turn port, which can trigger remote cleanup.
    # Only the probe's exit status is used; Claude's stream cannot supply a procedure outcome.
    defp probe_outcome(host, path) do
      {check, cases} = outcome_check(path)

      with {:ok, port} <- SSH.start_port(host, "#{check} #{cases} esac; exit 0") do
        try do
          receive do
            {^port, {:exit_status, code}} -> code
          after
            @outcome_timeout_ms -> nil
          end
        after
          CliHarness.close_port(port)
        end
      end
    rescue
      _error -> nil
    end

    defp outcome_check(path) do
      check = "case \"$(cat #{CliHarness.shell_escape(path)} 2>/dev/null)\" in"
      cases = Enum.map_join(@blocked, " ", fn {code, section} -> "blocked:#{section}) exit #{code};;" end)
      {check, cases}
    end
  end

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts) when is_binary(workspace) do
    context = Keyword.get(opts, :execution_context)
    settings = Config.settings!()
    dynamic_tool_binding = Tracker.bind_agent_tools()
    secret_environment_names = CliHarness.valid_environment_names(dynamic_tool_binding.secret_environment_names)
    env_reader = Keyword.get(opts, :env_reader, &System.get_env/1)

    with :ok <- require_context(context),
         {:ok, expanded_workspace} <- workspace_cwd(workspace, context),
         {:ok, tracker_env} <- CliHarness.capture_tracker_env(secret_environment_names, env_reader),
         {:ok, workflow} <- Workflow.current(),
         {:ok, procedure_payload, procedure_preflight?} <- procedure_payload(Keyword.get(opts, :issue_id)),
         {:ok, session_dir, cleanup_monitor} <- CliHarness.create_session_dir("symphony-claude-mcp", expanded_workspace) do
      # MCP needs tracker configuration, not controller-only provider files or agent runtime settings.
      workflow_snapshot = Workflow.render(Jason.encode!(Map.take(workflow.config, ["tracker"])), "")

      case write_session_files(session_dir, workflow_snapshot, procedure_payload, settings.claude, tracker_env) do
        {:ok, workflow_snapshot_path, mcp_config_path, procedure_path} ->
          {:ok,
           %{
             workspace: expanded_workspace,
             execution_context: context,
             session_dir: session_dir,
             cleanup_monitor: cleanup_monitor,
             mcp_config_path: mcp_config_path,
             workflow_snapshot_path: workflow_snapshot_path,
             procedure_path: procedure_path,
             procedure_preflight?: procedure_preflight?,
             secret_environment_names: secret_environment_names,
             tool_specs: dynamic_tool_binding.tool_specs,
             claude_settings: settings.claude
           }}

        {:error, _reason} = error ->
          cleanup_failed_session(session_dir, cleanup_monitor, error)
      end
    end
  end

  defp require_context(context) do
    case {Map.get(Config.settings!().worker, :environment), context} do
      {%{}, %ExecutionContext{mode: :managed}} -> :ok
      {%{}, _} -> {:error, :managed_context_required}
      {nil, %ExecutionContext{}} -> :ok
      {nil, _} -> {:error, :execution_context_required}
    end
  end

  defp workspace_cwd(workspace, %ExecutionContext{mode: :managed} = context) do
    with :ok <- Workspace.validate_workspace_path(workspace, context), do: {:ok, workspace}
  end

  defp workspace_cwd(workspace, context) do
    if ExecutionContext.remote?(context), do: {:ok, workspace}, else: {:ok, Path.expand(workspace)}
  end

  @impl true
  @spec run_turn(SymphonyElixir.Agent.session(), String.t(), map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_turn(%{workspace: workspace} = session, prompt, _issue, opts) when is_binary(prompt) do
    on_message = Keyword.get(opts, :on_message)

    case session[:procedure_path] do
      nil ->
        run_claude(session, workspace, prompt, on_message)

      path ->
        case preflight_procedure(session, path) do
          :ok ->
            result = run_claude(session, workspace, prompt, gate_completion(on_message))
            result |> finish_procedure_turn(path) |> report_accepted_completion(on_message)

          {:blocked, detail} ->
            ProcedureSession.blocked_result(detail)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp preflight_procedure(%{procedure_preflight?: true}, path) do
    with {:ok, procedure} <- ProcedureSession.load(path), do: ProcedureSession.preflight(procedure)
  end

  defp preflight_procedure(_session, _path), do: :ok

  defp gate_completion(on_message) when is_function(on_message, 1) do
    fn
      %{event: :completed} = update ->
        on_message.(%{update | event: :usage_updated, payload: "Claude turn ended"})

      update ->
        on_message.(update)
    end
  end

  defp gate_completion(_on_message), do: nil

  defp finish_procedure_turn({:error, {:procedure_unread, result}}, path) do
    with {:ok, procedure} <- ProcedureSession.load(path),
         :ok <- ProcedureSession.check_unread(procedure) do
      {:ok, result}
    else
      {:blocked, detail} -> ProcedureSession.blocked_result(detail, {:ok, result})
      {:error, _reason} = error -> error
    end
  end

  defp finish_procedure_turn(result, _procedure), do: result

  defp report_accepted_completion({:ok, %Result{status: :done} = result} = outcome, on_message)
       when is_function(on_message, 1) do
    # The stream already reported final usage, including for turns the gate rejects.
    on_message.(%{
      event: :completed,
      timestamp: DateTime.utc_now(),
      session_id: result.session_id,
      payload: "Completed: " <> String.slice(result.summary || "Claude turn", 0, 500)
    })

    outcome
  end

  defp report_accepted_completion(outcome, _on_message), do: outcome

  defp procedure_payload(issue_id) do
    with {:ok, %{slug: slug, version_id: version_id, procedures: procedures, workflow: %{config: config}}} <-
           LaneContext.capture(),
         true <- not is_nil(version_id) and ProcedureSession.managed_lane?(slug) do
      with {:ok, payload} <- ProcedureSession.encode(issue_id, slug, procedures, config["procedure_policy_version"]) do
        {:ok, payload, ProcedureSession.incomplete?(procedures)}
      end
    else
      _ -> {:ok, nil, false}
    end
  end

  @impl true
  @spec stop_session(SymphonyElixir.Agent.session()) :: :ok
  def stop_session(%{session_dir: session_dir} = session) when is_binary(session_dir) do
    CliHarness.remove_session_dir(session_dir, session[:cleanup_monitor])
  end

  def stop_session(session) do
    Enum.each([session[:mcp_config_path], session[:workflow_snapshot_path]], fn
      path when is_binary(path) -> File.rm(path)
      _ -> :ok
    end)

    :ok
  end

  @doc false
  @spec remote_command(String.t(), String.t()) :: String.t()
  def remote_command(workspace, _prompt) when is_binary(workspace) do
    settings = Config.settings!()
    binding = Tracker.bind_agent_tools()
    remote_workflow_path = CliHarness.remote_temp_path("symphony-claude-workflow", ".md")

    build_remote_command(workspace, remote_workflow_path, nil, settings.claude, binding)
  end

  defp write_session_files(session_dir, workflow_snapshot, procedure_payload, claude, tracker_env) do
    workflow_path = Path.join(session_dir, "WORKFLOW.md")
    mcp_path = Path.join(session_dir, "mcp.json")

    with :ok <- CliHarness.write_private_file(workflow_path, workflow_snapshot),
         {:ok, procedure_path} <- write_procedure_file(session_dir, procedure_payload),
         {:ok, encoded_mcp_config} <-
           encode_mcp_config(mcp_config(workflow_path, procedure_path, nil, claude, tracker_env), mcp_path),
         :ok <- CliHarness.write_private_file(mcp_path, encoded_mcp_config) do
      {:ok, workflow_path, mcp_path, procedure_path}
    end
  end

  defp write_procedure_file(_session_dir, nil), do: {:ok, nil}

  defp write_procedure_file(session_dir, payload) do
    path = Path.join(session_dir, "procedures.json")
    with :ok <- CliHarness.write_private_file(path, payload), do: {:ok, path}
  end

  defp cleanup_failed_session(session_dir, cleanup_monitor, error) do
    CliHarness.remove_session_dir(session_dir, cleanup_monitor)
    error
  end

  defp mcp_config(workflow_path, procedure_path, command, claude, tracker_env) do
    # `argv/3` passes `--strict-mcp-config`, so this map is the agent's entire server list and
    # `~/.claude.json` is ignored. Configured servers are merged in on the left, which leaves
    # `symphony` winning any name collision: a workflow file cannot displace the tracker server.
    %{
      "mcpServers" =>
        Map.merge(claude.extra_mcp_servers || %{}, %{
          "symphony" => %{
            "command" => command || claude.linear_mcp_command || CliHarness.default_mcp_command(),
            "args" => claude.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path],
            "env" => procedure_env(tracker_env, procedure_path)
          }
        })
    }
  end

  defp procedure_env(tracker_env, nil), do: Map.delete(tracker_env, ProcedureSession.env_name())

  defp procedure_env(tracker_env, path), do: Map.put(tracker_env, ProcedureSession.env_name(), path)

  defp encode_mcp_config(config, path) do
    case Jason.encode(config) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, {:claude_mcp_config_encode, path}}
    end
  rescue
    _error -> {:error, {:claude_mcp_config_encode, path}}
  end

  defp decode_mcp_config(encoded, path) do
    case Jason.decode(encoded) do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> {:error, {:claude_mcp_config_decode, path}}
    end
  end

  defp run_claude(%{execution_context: context} = session, workspace, prompt, on_message) do
    if ExecutionContext.remote?(context) do
      drive_ssh(session, workspace, prompt, on_message)
    else
      run_local_claude(session, workspace, prompt, on_message)
    end
  end

  defp run_local_claude(
         %{
           session_dir: session_dir,
           mcp_config_path: mcp_config_path,
           procedure_path: procedure_path,
           claude_settings: claude,
           secret_environment_names: secret_environment_names,
           tool_specs: tool_specs
         },
         workspace,
         prompt,
         on_message
       ) do
    with {:ok, executable} <- CliHarness.resolve_executable(claude.command, :claude_command_not_configured),
         :ok <- reset_procedure_outcome(procedure_path),
         {:ok, prompt_path} <- CliHarness.write_prompt_file(session_dir, prompt) do
      try do
        result =
          CliHarness.drive_port(
            executable,
            argv(mcp_config_path, claude, %{tool_specs: tool_specs, procedure?: is_binary(procedure_path)}),
            workspace,
            on_message,
            prompt_path,
            [ProcedureSession.env_name() | secret_environment_names],
            stream: Stream,
            error_tag: :claude_port,
            label: "Claude"
          )

        local_procedure_outcome(procedure_path, result)
      after
        _ = File.rm(prompt_path)
      end
    end
  end

  defp reset_procedure_outcome(nil), do: :ok

  defp reset_procedure_outcome(path) do
    outcome = ProcedureSession.outcome_path(path)

    case File.rm(outcome) do
      result when result in [:ok, {:error, :enoent}] -> CliHarness.write_private_file(outcome, "")
      {:error, _reason} = error -> error
    end
  end

  defp local_procedure_outcome(nil, result), do: result

  defp local_procedure_outcome(path, result) do
    case File.read(ProcedureSession.outcome_path(path)) do
      {:ok, "blocked:" <> section} when section in ~w(qa bug deliver error-reporting) ->
        ProcedureSession.blocked_result({:missing_procedure, section}, result)

      {:ok, "read:" <> section} when section in ~w(qa bug deliver) ->
        result

      _ ->
        case result do
          {:ok, %Result{status: :done} = completed} -> {:error, {:procedure_unread, completed}}
          other -> other
        end
    end
  end

  defp argv(mcp_config_path, claude, binding) do
    allowed_tools = allowed_tools(claude, binding)

    claude.args ++
      [
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--mcp-config",
        mcp_config_path,
        "--strict-mcp-config",
        "--allowedTools",
        Enum.join(allowed_tools, ","),
        "--permission-prompt-tool",
        @approval_tool
      ]
  end

  defp drive_ssh(
         %{
           execution_context: %ExecutionContext{target: host},
           workflow_snapshot_path: workflow_snapshot_path,
           procedure_path: procedure_path,
           mcp_config_path: mcp_config_path,
           claude_settings: claude,
           secret_environment_names: secret_environment_names,
           tool_specs: tool_specs
         },
         workspace,
         prompt,
         on_message
       ) do
    binding = %{
      tool_specs: tool_specs,
      secret_environment_names: secret_environment_names,
      procedure?: is_binary(procedure_path)
    }

    remote_workflow_path = CliHarness.remote_temp_path("symphony-claude-workflow", ".md")
    remote_procedure_path = if procedure_path, do: CliHarness.remote_temp_path("symphony-claude-procedures", ".json")
    command = build_remote_command(workspace, remote_workflow_path, remote_procedure_path, claude, binding)
    stream = if procedure_path, do: RemoteProcedureStream, else: Stream

    with {:ok, workflow_snapshot} <- File.read(workflow_snapshot_path),
         {:ok, procedure} <- read_procedure_payload(procedure_path),
         {:ok, encoded_local_mcp_config} <- File.read(mcp_config_path),
         {:ok, local_mcp_config} <- decode_mcp_config(encoded_local_mcp_config, mcp_config_path),
         tracker_env = get_in(local_mcp_config, ["mcpServers", "symphony", "env"]) || %{},
         {:ok, encoded_mcp_config} <-
           encode_mcp_config(
             mcp_config(remote_workflow_path, remote_procedure_path, remote_mcp_command(), claude, tracker_env),
             mcp_config_path
           ),
         payload = ssh_payload(workflow_snapshot, encoded_mcp_config, procedure, prompt),
         {:ok, port} <- SSH.start_port(host, command, line: @port_line_bytes),
         :ok <- SSH.write_stdin(port, payload) do
      outcome_path = if remote_procedure_path, do: ProcedureSession.outcome_path(remote_procedure_path)
      on_timeout = RemoteProcedureStream.timeout_handler(host, outcome_path)
      CliHarness.collect_port_stream(port, on_message, stream, "Claude", on_timeout)
    end
  rescue
    error -> {:error, {:claude_ssh_port, error}}
  end

  defp read_procedure_payload(nil), do: {:ok, nil}
  defp read_procedure_payload(path), do: File.read(path)

  defp ssh_payload(workflow, encoded_mcp_config, procedure, prompt) do
    if is_binary(procedure) do
      CliHarness.ssh_payload([workflow, encoded_mcp_config, procedure, prompt])
    else
      CliHarness.ssh_payload([workflow, encoded_mcp_config, prompt])
    end
  end

  defp build_remote_command(workspace, remote_workflow_path, remote_procedure_path, claude, binding) do
    private_paths = [
      CliHarness.shell_escape(remote_workflow_path),
      "\"${symphony_mcp_config_file:-}\""
      | remote_procedure_paths(remote_procedure_path)
    ]

    {procedure_setup, invocation} =
      case remote_procedure_path do
        nil ->
          {nil, remote_claude_invocation(claude, binding)}

        path ->
          outcome = ProcedureSession.outcome_path(path)
          setup = CliHarness.read_length_prefixed_file("procedures", CliHarness.shell_escape(path))
          setup = setup <> " && : > " <> CliHarness.shell_escape(outcome)
          {setup, RemoteProcedureStream.wrap_command(remote_claude_invocation(claude, binding), outcome)}
      end

    [
      "cd #{CliHarness.shell_escape(workspace)}",
      "umask 077",
      CliHarness.remote_mktemp_function(),
      "cleanup() { rm -f #{Enum.join(private_paths, " ")}; }",
      "trap cleanup EXIT HUP INT TERM",
      "symphony_mcp_config_file=$(symphony_mktemp symphony-claude-mcp)",
      "[ -n \"$symphony_mcp_config_file\" ]",
      CliHarness.read_length_prefixed_file("workflow", CliHarness.shell_escape(remote_workflow_path)),
      "chmod 600 #{CliHarness.shell_escape(remote_workflow_path)}",
      CliHarness.read_length_prefixed_file("mcp_config", "\"$symphony_mcp_config_file\""),
      "chmod 600 \"$symphony_mcp_config_file\"",
      procedure_setup,
      "IFS= read -r symphony_prompt_bytes",
      "case \"$symphony_prompt_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      CliHarness.tracker_secret_unset_command([ProcedureSession.env_name() | binding.secret_environment_names]),
      invocation
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_procedure_paths(nil), do: []

  defp remote_procedure_paths(path) do
    [CliHarness.shell_escape(path), CliHarness.shell_escape(ProcedureSession.outcome_path(path))]
  end

  defp remote_claude_invocation(claude, binding) do
    allowed_tools = allowed_tools(claude, binding)

    args =
      Enum.map(claude.args, &CliHarness.shell_escape/1) ++
        [
          "-p",
          "--output-format",
          "stream-json",
          "--verbose",
          "--mcp-config",
          "\"$symphony_mcp_config_file\"",
          "--strict-mcp-config",
          "--allowedTools",
          CliHarness.shell_escape(Enum.join(allowed_tools, ",")),
          "--permission-prompt-tool",
          CliHarness.shell_escape(@approval_tool)
        ]

    "dd bs=1 count=\"$symphony_prompt_bytes\" 2>/dev/null | " <>
      Enum.join([CliHarness.shell_escape(claude.command) | args], " ")
  end

  defp allowed_tools(claude, binding) do
    not_procedure =
      case claude.allowed_tools do
        tools when is_list(tools) -> Enum.reject(tools, &(&1 == @procedure_tool))
        _ -> tracker_allowed_tools(binding.tool_specs)
      end

    if Map.get(binding, :procedure?), do: not_procedure ++ [@procedure_tool], else: not_procedure
  end

  defp tracker_allowed_tools(tool_specs) do
    tracker_tools =
      Enum.flat_map(tool_specs, fn
        %{"name" => name} when is_binary(name) -> ["mcp__symphony__#{name}"]
        _ -> []
      end)

    tracker_tools ++ @default_non_tracker_tools
  end

  defp remote_mcp_command do
    Config.settings!().claude.linear_mcp_command || "symphony"
  end
end
