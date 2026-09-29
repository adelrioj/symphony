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
  alias SymphonyElixir.{Config, ExecutionContext, SSH, Tracker, Workflow, Workspace}

  @approval_tool "mcp__symphony__approval_prompt"
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
          required(:secret_environment_names) => [String.t()],
          required(:tool_specs) => [map()],
          required(:claude_settings) => map(),
          required(:cleanup_monitor) => pid()
        }

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
         {:ok, session_dir, cleanup_monitor} <- CliHarness.create_session_dir("symphony-claude-mcp", expanded_workspace) do
      # MCP needs tracker configuration, not controller-only provider files or agent runtime settings.
      workflow_snapshot = Workflow.render(Jason.encode!(Map.take(workflow.config, ["tracker"])), workflow.prompt)

      case write_session_files(session_dir, workflow_snapshot, settings.claude, tracker_env) do
        {:ok, workflow_snapshot_path, mcp_config_path} ->
          {:ok,
           %{
             workspace: expanded_workspace,
             execution_context: context,
             session_dir: session_dir,
             cleanup_monitor: cleanup_monitor,
             mcp_config_path: mcp_config_path,
             workflow_snapshot_path: workflow_snapshot_path,
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

    case run_claude(session, workspace, prompt, on_message) do
      {:ok, %Result{} = result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
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

    build_remote_command(workspace, remote_workflow_path, settings.claude, binding)
  end

  defp write_session_files(session_dir, workflow_snapshot, claude, tracker_env) do
    workflow_path = Path.join(session_dir, "WORKFLOW.md")
    mcp_path = Path.join(session_dir, "mcp.json")

    with :ok <- CliHarness.write_private_file(workflow_path, workflow_snapshot),
         {:ok, encoded_mcp_config} <-
           encode_mcp_config(mcp_config(workflow_path, nil, claude, tracker_env), mcp_path),
         :ok <- CliHarness.write_private_file(mcp_path, encoded_mcp_config) do
      {:ok, workflow_path, mcp_path}
    end
  end

  defp cleanup_failed_session(session_dir, cleanup_monitor, error) do
    CliHarness.remove_session_dir(session_dir, cleanup_monitor)
    error
  end

  defp mcp_config(workflow_path, command, claude, tracker_env) do
    # `argv/3` passes `--strict-mcp-config`, so this map is the agent's entire server list and
    # `~/.claude.json` is ignored. Configured servers are merged in on the left, which leaves
    # `symphony` winning any name collision: a workflow file cannot displace the tracker server.
    %{
      "mcpServers" =>
        Map.merge(claude.extra_mcp_servers || %{}, %{
          "symphony" => %{
            "command" => command || claude.linear_mcp_command || CliHarness.default_mcp_command(),
            "args" => claude.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path],
            "env" => tracker_env
          }
        })
    }
  end

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
           claude_settings: claude,
           secret_environment_names: secret_environment_names,
           tool_specs: tool_specs
         },
         workspace,
         prompt,
         on_message
       ) do
    with {:ok, executable} <- CliHarness.resolve_executable(claude.command, :claude_command_not_configured),
         {:ok, prompt_path} <- CliHarness.write_prompt_file(session_dir, prompt) do
      try do
        CliHarness.drive_port(
          executable,
          argv(mcp_config_path, claude, %{tool_specs: tool_specs}),
          workspace,
          on_message,
          prompt_path,
          secret_environment_names,
          stream: Stream,
          error_tag: :claude_port,
          label: "Claude"
        )
      after
        _ = File.rm(prompt_path)
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
           mcp_config_path: mcp_config_path,
           claude_settings: claude,
           secret_environment_names: secret_environment_names,
           tool_specs: tool_specs
         },
         workspace,
         prompt,
         on_message
       ) do
    binding = %{tool_specs: tool_specs, secret_environment_names: secret_environment_names}
    remote_workflow_path = CliHarness.remote_temp_path("symphony-claude-workflow", ".md")
    command = build_remote_command(workspace, remote_workflow_path, claude, binding)

    with {:ok, workflow_snapshot} <- File.read(workflow_snapshot_path),
         {:ok, encoded_local_mcp_config} <- File.read(mcp_config_path),
         {:ok, local_mcp_config} <- decode_mcp_config(encoded_local_mcp_config, mcp_config_path),
         tracker_env = get_in(local_mcp_config, ["mcpServers", "symphony", "env"]) || %{},
         {:ok, encoded_mcp_config} <-
           encode_mcp_config(
             mcp_config(remote_workflow_path, remote_mcp_command(), claude, tracker_env),
             mcp_config_path
           ),
         payload = ssh_payload(workflow_snapshot, encoded_mcp_config, prompt),
         {:ok, port} <- SSH.start_port(host, command, line: @port_line_bytes),
         :ok <- SSH.write_stdin(port, payload) do
      CliHarness.collect_port_stream(port, on_message, Stream, "Claude")
    end
  rescue
    error -> {:error, {:claude_ssh_port, error}}
  end

  defp ssh_payload(workflow, encoded_mcp_config, prompt) do
    [
      Integer.to_string(byte_size(workflow)),
      "\n",
      workflow,
      Integer.to_string(byte_size(encoded_mcp_config)),
      "\n",
      encoded_mcp_config,
      Integer.to_string(byte_size(prompt)),
      "\n",
      prompt
    ]
  end

  defp build_remote_command(workspace, remote_workflow_path, claude, binding) do
    [
      "cd #{CliHarness.shell_escape(workspace)}",
      "umask 077",
      CliHarness.remote_mktemp_function(),
      "cleanup() { rm -f #{CliHarness.shell_escape(remote_workflow_path)} \"${symphony_mcp_config_file:-}\"; }",
      "trap cleanup EXIT HUP INT TERM",
      "symphony_mcp_config_file=$(symphony_mktemp symphony-claude-mcp)",
      "[ -n \"$symphony_mcp_config_file\" ]",
      CliHarness.read_length_prefixed_file("workflow", CliHarness.shell_escape(remote_workflow_path)),
      "chmod 600 #{CliHarness.shell_escape(remote_workflow_path)}",
      CliHarness.read_length_prefixed_file("mcp_config", "\"$symphony_mcp_config_file\""),
      "chmod 600 \"$symphony_mcp_config_file\"",
      "IFS= read -r symphony_prompt_bytes",
      "case \"$symphony_prompt_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      CliHarness.tracker_secret_unset_command(binding.secret_environment_names),
      remote_claude_invocation(claude, binding)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
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

  defp allowed_tools(%{allowed_tools: allowed_tools}, _binding) when is_list(allowed_tools),
    do: allowed_tools

  defp allowed_tools(_claude, %{tool_specs: tool_specs}), do: tracker_allowed_tools(tool_specs)

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
