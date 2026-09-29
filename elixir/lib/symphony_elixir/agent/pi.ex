defmodule SymphonyElixir.Agent.Pi do
  @moduledoc """
  Agent backend that runs pi (`pi -p --mode json`) per turn.

  Each turn is a fresh process. Turn 1 sends the full prompt; later turns pass `--continue` against a
  persistent per-session `sessions/` directory. pi has no MCP support, so a private extension
  (`bridge.ts`, embedded at compile time) exposes the tracker MCP server's tools as `symphony_*` tools.
  Every process runs against a private `PI_CODING_AGENT_DIR` with project trust and packages disabled;
  tracker secrets live only in the 0600 `bridge.json` named by `SYMPHONY_BRIDGE_CONFIG`.
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.CliHarness
  alias SymphonyElixir.Agent.Pi.Stream
  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{Config, ExecutionContext, Tracker, Workflow}

  @bridge_path Path.expand("../../../priv/pi/symphony-mcp-bridge.ts", __DIR__)
  @external_resource @bridge_path
  @bridge_source File.read!(@bridge_path)

  @default_tools ~w(read bash edit write grep find ls)

  @type session :: %{
          required(:workspace) => Path.t(),
          required(:execution_context) => ExecutionContext.t(),
          required(:session_dir) => Path.t(),
          required(:workflow_snapshot_path) => Path.t(),
          required(:secret_environment_names) => [String.t()],
          required(:tool_specs) => [map()],
          required(:pi_settings) => map(),
          required(:remote_dir) => String.t() | nil,
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

    with :ok <- CliHarness.require_context(context),
         {:ok, expanded_workspace} <- CliHarness.workspace_cwd(workspace, context),
         {:ok, tracker_env} <- CliHarness.capture_tracker_env(secret_environment_names, env_reader),
         {:ok, workflow} <- Workflow.current(),
         {:ok, session_dir, cleanup_monitor} <- CliHarness.create_session_dir("symphony-pi", expanded_workspace) do
      # The bridge needs tracker configuration, not controller-only provider files or agent runtime settings.
      workflow_snapshot = Workflow.render(Jason.encode!(Map.take(workflow.config, ["tracker"])), workflow.prompt)

      case write_session_files(session_dir, workflow_snapshot, settings, tracker_env) do
        {:ok, workflow_snapshot_path} ->
          {:ok,
           %{
             workspace: expanded_workspace,
             execution_context: context,
             session_dir: session_dir,
             cleanup_monitor: cleanup_monitor,
             workflow_snapshot_path: workflow_snapshot_path,
             secret_environment_names: secret_environment_names,
             tool_specs: dynamic_tool_binding.tool_specs,
             pi_settings: settings.pi,
             remote_dir: CliHarness.new_remote_dir("symphony-pi", context)
           }}

        {:error, _reason} = error ->
          CliHarness.remove_session_dir(session_dir, cleanup_monitor)
          error
      end
    end
  end

  defp write_session_files(session_dir, workflow_snapshot, settings, tracker_env) do
    agent_dir = Path.join(session_dir, "agent")
    workflow_path = Path.join(session_dir, "WORKFLOW.md")
    pi = settings.pi

    config =
      bridge_config(
        pi.linear_mcp_command || CliHarness.default_mcp_command(),
        pi.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path],
        tracker_env,
        settings.codex.turn_timeout_ms
      )

    with :ok <- CliHarness.mkdir_private(agent_dir),
         :ok <- CliHarness.mkdir_private(Path.join(session_dir, "sessions")),
         :ok <- CliHarness.write_private_file(workflow_path, workflow_snapshot),
         :ok <- CliHarness.write_private_file(Path.join(agent_dir, "settings.json"), settings_json()),
         :ok <- CliHarness.write_private_file(Path.join(session_dir, "bridge.ts"), @bridge_source),
         {:ok, encoded} <- encode_bridge_config(config),
         :ok <- CliHarness.write_private_file(Path.join(session_dir, "bridge.json"), encoded) do
      {:ok, workflow_path}
    end
  end

  defp encode_bridge_config(config) do
    case Jason.encode(config) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, {:pi_bridge_config_encode, "bridge.json"}}
    end
  rescue
    _error -> {:error, {:pi_bridge_config_encode, "bridge.json"}}
  end

  @impl true
  @spec run_turn(SymphonyElixir.Agent.session(), String.t(), map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_turn(%{workspace: workspace, execution_context: context} = session, prompt, _issue, opts)
      when is_binary(prompt) do
    if ExecutionContext.remote?(context) do
      {:error, :pi_remote_unavailable}
    else
      run_local(session, workspace, prompt, Keyword.get(opts, :on_message))
    end
  end

  @impl true
  @spec stop_session(SymphonyElixir.Agent.session()) :: :ok
  def stop_session(%{session_dir: session_dir} = session) when is_binary(session_dir) do
    :ok = CliHarness.remove_session_dir(session_dir, session[:cleanup_monitor])

    with %{remote_dir: remote_dir, execution_context: %ExecutionContext{target: host}} when is_binary(remote_dir) <-
           session do
      CliHarness.remove_remote_dir(host, remote_dir)
    end

    :ok
  end

  defp run_local(session, workspace, prompt, on_message) do
    agent_dir = Path.join(session.session_dir, "agent")
    bridge_config_path = Path.join(session.session_dir, "bridge.json")

    paths = %{
      sessions_dir: Path.join(session.session_dir, "sessions"),
      bridge_path: Path.join(session.session_dir, "bridge.ts")
    }

    continue? = paths.sessions_dir |> File.ls() |> then(&match?({:ok, [_ | _]}, &1))

    with {:ok, executable} <- CliHarness.resolve_executable(session.pi_settings.command, :pi_command_not_configured),
         {:ok, prompt_path} <- CliHarness.write_prompt_file(session.session_dir, prompt) do
      try do
        CliHarness.drive_port(
          executable,
          argv(paths, session.pi_settings, session.tool_specs, continue?),
          workspace,
          on_message,
          prompt_path,
          session.secret_environment_names,
          stream: Stream,
          error_tag: :pi_port,
          label: "pi",
          env: [
            {~c"PI_CODING_AGENT_DIR", String.to_charlist(agent_dir)},
            {~c"SYMPHONY_BRIDGE_CONFIG", String.to_charlist(bridge_config_path)}
          ]
        )
      after
        _ = File.rm(prompt_path)
      end
    end
  end

  @doc false
  @spec settings_json() :: String.t()
  def settings_json, do: Jason.encode!(%{"defaultProjectTrust" => "never", "packages" => []})

  @doc false
  @spec bridge_config(String.t(), [String.t()], map(), pos_integer()) :: map()
  def bridge_config(command, args, env, timeout_ms),
    do: %{"command" => command, "args" => args, "env" => env, "timeoutMs" => timeout_ms}

  @doc false
  @spec tool_allowlist(map(), [map()]) :: [String.t()]
  def tool_allowlist(%{allowed_tools: tools}, specs) when is_list(tools), do: tools ++ bridge_tools(specs)
  def tool_allowlist(_pi, specs), do: @default_tools ++ bridge_tools(specs)

  defp bridge_tools(specs), do: for(%{"name" => name} when is_binary(name) <- specs, do: "symphony_" <> name)

  @doc false
  @spec argv(map(), map(), [map()], boolean()) :: [String.t()]
  def argv(%{sessions_dir: sessions, bridge_path: bridge}, pi, specs, continue?) do
    pi.args ++
      [
        "-p",
        "--mode",
        "json",
        "--offline",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-themes",
        "--no-context-files",
        "--no-approve",
        "-e",
        bridge,
        "--session-dir",
        sessions,
        "--tools",
        Enum.join(tool_allowlist(pi, specs), ",")
      ] ++
      if(continue?, do: ["--continue"], else: []) ++ opt("--model", pi.model) ++ opt("--thinking", pi.thinking)
  end

  defp opt(_flag, nil), do: []
  defp opt(flag, value), do: [flag, value]
end
