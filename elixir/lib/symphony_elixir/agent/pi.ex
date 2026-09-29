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
  alias SymphonyElixir.{Config, ExecutionContext, SSH, Tracker, Workflow}

  @bridge_path Path.expand("../../../priv/pi/symphony-mcp-bridge.ts", __DIR__)
  @external_resource @bridge_path
  @bridge_source File.read!(@bridge_path)

  @default_tools ~w(read bash edit write grep find ls)
  @port_line_bytes 1_048_576

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
      drive_ssh(session, workspace, prompt, Keyword.get(opts, :on_message))
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
  @spec remote_command(String.t(), String.t()) :: String.t()
  def remote_command(workspace, remote_dir) when is_binary(workspace) and is_binary(remote_dir) do
    binding = Tracker.bind_agent_tools()

    build_remote_command(
      workspace,
      remote_dir,
      Config.settings!().pi,
      binding.tool_specs,
      binding.secret_environment_names
    )
  end

  defp drive_ssh(
         %{
           execution_context: %ExecutionContext{target: host},
           remote_dir: remote_dir,
           workflow_snapshot_path: workflow_snapshot_path,
           session_dir: session_dir,
           pi_settings: pi,
           tool_specs: tool_specs,
           secret_environment_names: secret_environment_names
         },
         workspace,
         prompt,
         on_message
       ) do
    command = build_remote_command(workspace, remote_dir, pi, tool_specs, secret_environment_names)
    local_bridge_config_path = Path.join(session_dir, "bridge.json")

    with {:ok, workflow_snapshot} <- File.read(workflow_snapshot_path),
         {:ok, encoded_local_bridge} <- File.read(local_bridge_config_path),
         {:ok, local_bridge} <- Jason.decode(encoded_local_bridge),
         {:ok, encoded_bridge} <-
           encode_bridge_config(
             bridge_config(
               pi.linear_mcp_command || "symphony",
               pi.linear_mcp_args ++ ["--linear-mcp", "--workflow", Path.join(remote_dir, "WORKFLOW.md")],
               Map.get(local_bridge, "env", %{}),
               Map.fetch!(local_bridge, "timeoutMs")
             )
           ),
         payload =
           CliHarness.ssh_payload([workflow_snapshot, @bridge_source, encoded_bridge, settings_json(), prompt]),
         {:ok, port} <- SSH.start_port(host, command, line: @port_line_bytes),
         :ok <- SSH.write_stdin(port, payload) do
      CliHarness.collect_port_stream(port, on_message, Stream, "pi")
    end
  rescue
    error -> {:error, {:pi_ssh_port, error}}
  end

  defp build_remote_command(workspace, remote_dir, pi, tool_specs, secret_environment_names) do
    path = &CliHarness.shell_escape(Path.join(remote_dir, &1))

    [
      "cd #{CliHarness.shell_escape(workspace)}",
      "umask 077",
      # Installed before any secret file is written so a killed runner cannot leave tracker secrets behind.
      "trap #{CliHarness.shell_escape(secret_cleanup_command(remote_dir))} EXIT HUP INT TERM",
      "mkdir -p #{path.("agent")} #{path.("sessions")}",
      "chmod 700 #{CliHarness.shell_escape(remote_dir)}",
      CliHarness.read_length_prefixed_file("workflow", path.("WORKFLOW.md")),
      CliHarness.read_length_prefixed_file("bridge", path.("bridge.ts")),
      CliHarness.read_length_prefixed_file("bridge_config", path.("bridge.json")),
      CliHarness.read_length_prefixed_file("settings", path.("agent/settings.json")),
      "IFS= read -r symphony_prompt_bytes",
      "case \"$symphony_prompt_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      CliHarness.tracker_secret_unset_command(secret_environment_names),
      "symphony_continue=",
      "if [ -n \"$(ls -A #{path.("sessions")} 2>/dev/null)\" ]; then symphony_continue=--continue; fi",
      remote_pi_invocation(remote_dir, pi, tool_specs)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  # Files rewritten every turn that hold tracker secrets; `bridge.ts`, `agent/settings.json` and
  # `sessions/` are not secret and stay for `--continue`.
  defp secret_cleanup_command(remote_dir) do
    files = Enum.map_join(["bridge.json", "WORKFLOW.md"], " ", &CliHarness.shell_escape(Path.join(remote_dir, &1)))
    "rm -f " <> files
  end

  defp remote_pi_invocation(remote_dir, pi, tool_specs) do
    paths = %{sessions_dir: Path.join(remote_dir, "sessions"), bridge_path: Path.join(remote_dir, "bridge.ts")}
    args = paths |> argv(pi, tool_specs, false) |> Enum.map(&CliHarness.shell_escape/1)

    "dd bs=1 count=\"$symphony_prompt_bytes\" 2>/dev/null | " <>
      "PI_CODING_AGENT_DIR=#{CliHarness.shell_escape(Path.join(remote_dir, "agent"))} " <>
      "SYMPHONY_BRIDGE_CONFIG=#{CliHarness.shell_escape(Path.join(remote_dir, "bridge.json"))} " <>
      Enum.join([CliHarness.shell_escape(pi.command) | args] ++ ["$symphony_continue"], " ")
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
