defmodule SymphonyElixir.Agent.Omp do
  @moduledoc """
  Agent backend that runs oh-my-pi (`omp -p --mode json`) per turn.

  Each turn is a fresh process. Turn 1 sends the full prompt; later turns pass `--continue` against a
  persistent per-session `sessions/` directory. omp auto-discovers MCP servers from many user and
  project locations, so every process runs against a private `PI_CODING_AGENT_DIR` holding only the
  tracker MCP server, plus an overlay that disables project MCP config and foreign discovery providers.
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.CliHarness
  alias SymphonyElixir.Agent.Omp.Stream
  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{Config, ExecutionContext, SSH, Tracker, Workflow, Workspace}

  @providers_to_disable ~w(omp-plugins claude agent-plugins codex agents claude-plugins gemini opencode
                           cursor windsurf cline github vscode agents-md mcp-json ssh-json)
  @default_tools ~w(read grep find edit write bash)
  @port_line_bytes 1_048_576

  @type session :: %{
          required(:workspace) => Path.t(),
          required(:execution_context) => ExecutionContext.t(),
          required(:session_dir) => Path.t(),
          required(:workflow_snapshot_path) => Path.t(),
          required(:secret_environment_names) => [String.t()],
          required(:omp_settings) => map(),
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

    with :ok <- require_context(context),
         {:ok, expanded_workspace} <- workspace_cwd(workspace, context),
         {:ok, tracker_env} <- CliHarness.capture_tracker_env(secret_environment_names, env_reader),
         {:ok, workflow} <- Workflow.current(),
         {:ok, session_dir, cleanup_monitor} <- CliHarness.create_session_dir("symphony-omp", expanded_workspace) do
      # MCP needs tracker configuration, not controller-only provider files or agent runtime settings.
      workflow_snapshot = Workflow.render(Jason.encode!(Map.take(workflow.config, ["tracker"])), workflow.prompt)

      case write_session_files(session_dir, workflow_snapshot, settings.omp, tracker_env) do
        {:ok, workflow_snapshot_path} ->
          {:ok,
           %{
             workspace: expanded_workspace,
             execution_context: context,
             session_dir: session_dir,
             cleanup_monitor: cleanup_monitor,
             workflow_snapshot_path: workflow_snapshot_path,
             secret_environment_names: secret_environment_names,
             omp_settings: settings.omp,
             remote_dir: remote_dir(context)
           }}

        {:error, _reason} = error ->
          CliHarness.remove_session_dir(session_dir, cleanup_monitor)
          error
      end
    end
  end

  defp remote_dir(context) do
    if ExecutionContext.remote?(context), do: "/tmp/symphony-omp-" <> CliHarness.temp_token()
  end

  # Same rules as `Agent.Claude`; kept private here because the duplicate is only two small clauses.
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

  defp write_session_files(session_dir, workflow_snapshot, omp, tracker_env) do
    agent_dir = Path.join(session_dir, "agent")
    workflow_path = Path.join(session_dir, "WORKFLOW.md")
    mcp_path = Path.join(agent_dir, "mcp.json")

    with :ok <- mkdir_private(agent_dir),
         :ok <- mkdir_private(Path.join(session_dir, "sessions")),
         :ok <- CliHarness.write_private_file(workflow_path, workflow_snapshot),
         :ok <- CliHarness.write_private_file(Path.join(session_dir, "overlay.yml"), overlay_yaml()),
         {:ok, encoded} <- encode_mcp_config(mcp_config(workflow_path, nil, omp, tracker_env), mcp_path),
         :ok <- CliHarness.write_private_file(mcp_path, encoded) do
      {:ok, workflow_path}
    end
  end

  defp mkdir_private(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)
  end

  defp encode_mcp_config(config, path) do
    case Jason.encode(config) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, {:omp_mcp_config_encode, path}}
    end
  rescue
    _error -> {:error, {:omp_mcp_config_encode, path}}
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
    with %{remote_dir: remote_dir, execution_context: %ExecutionContext{target: host}} when is_binary(remote_dir) <-
           session do
      _ = SSH.run(host, "rm -rf " <> CliHarness.shell_escape(remote_dir))
    end

    CliHarness.remove_session_dir(session_dir, session[:cleanup_monitor])
  end

  defp run_local(session, workspace, prompt, on_message) do
    agent_dir = Path.join(session.session_dir, "agent")

    paths = %{
      sessions_dir: Path.join(session.session_dir, "sessions"),
      overlay_path: Path.join(session.session_dir, "overlay.yml")
    }

    continue? = paths.sessions_dir |> File.ls() |> then(&match?({:ok, [_ | _]}, &1))

    with {:ok, executable} <- CliHarness.resolve_executable(session.omp_settings.command, :omp_command_not_configured),
         {:ok, prompt_path} <- CliHarness.write_prompt_file(session.session_dir, prompt) do
      try do
        CliHarness.drive_port(
          executable,
          argv(paths, session.omp_settings, continue?),
          workspace,
          on_message,
          prompt_path,
          session.secret_environment_names,
          stream: Stream,
          error_tag: :omp_port,
          label: "omp",
          env: [{~c"PI_CODING_AGENT_DIR", String.to_charlist(agent_dir)}]
        )
      after
        _ = File.rm(prompt_path)
      end
    end
  end

  @doc false
  @spec overlay_yaml() :: String.t()
  def overlay_yaml do
    providers = Enum.map_join(@providers_to_disable, "\n", &"  - #{&1}")
    "mcp:\n  enableProjectConfig: false\ndisabledProviders:\n#{providers}\n"
  end

  @doc false
  @spec mcp_config(Path.t(), String.t() | nil, map(), map()) :: map()
  def mcp_config(workflow_path, command, omp, tracker_env) do
    # Configured servers merge on the left so `symphony` wins any name collision.
    %{
      "mcpServers" =>
        Map.merge(omp.extra_mcp_servers || %{}, %{
          "symphony" => %{
            "command" => command || omp.linear_mcp_command || CliHarness.default_mcp_command(),
            "args" => omp.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path],
            "env" => tracker_env
          }
        })
    }
  end

  # omp 18.4.3 validates `--tools` against built-in tools only and exits 2 on `mcp__*` names, while
  # MCP tools from the private `mcp.json` are mounted regardless of the allowlist. So the tracker
  # tools are reachable without being listed.
  @doc false
  @spec tool_allowlist(map()) :: [String.t()]
  def tool_allowlist(%{allowed_tools: tools}) when is_list(tools), do: tools
  def tool_allowlist(_omp), do: @default_tools

  @doc false
  @spec argv(map(), map(), boolean()) :: [String.t()]
  def argv(%{sessions_dir: sessions, overlay_path: overlay}, omp, continue?) do
    omp.args ++
      [
        "-p",
        "--mode",
        "json",
        "--no-title",
        "--no-extensions",
        "--no-skills",
        "--no-rules",
        "--approval-mode",
        "yolo",
        "--config",
        overlay,
        "--session-dir",
        sessions,
        "--tools",
        Enum.join(tool_allowlist(omp), ",")
      ] ++
      if(continue?, do: ["--continue"], else: []) ++
      opt("--model", omp.model) ++ opt("--thinking", omp.thinking)
  end

  @doc false
  @spec remote_command(String.t(), String.t()) :: String.t()
  def remote_command(workspace, remote_dir) when is_binary(workspace) and is_binary(remote_dir) do
    build_remote_command(
      workspace,
      remote_dir,
      Config.settings!().omp,
      Tracker.bind_agent_tools().secret_environment_names
    )
  end

  defp drive_ssh(
         %{
           execution_context: %ExecutionContext{target: host},
           remote_dir: remote_dir,
           workflow_snapshot_path: workflow_snapshot_path,
           session_dir: session_dir,
           omp_settings: omp,
           secret_environment_names: secret_environment_names
         },
         workspace,
         prompt,
         on_message
       ) do
    command = build_remote_command(workspace, remote_dir, omp, secret_environment_names)
    local_mcp_path = Path.join([session_dir, "agent", "mcp.json"])

    with {:ok, workflow_snapshot} <- File.read(workflow_snapshot_path),
         {:ok, encoded_local_mcp} <- File.read(local_mcp_path),
         {:ok, local_mcp} <- Jason.decode(encoded_local_mcp),
         tracker_env = get_in(local_mcp, ["mcpServers", "symphony", "env"]) || %{},
         {:ok, encoded_mcp} <-
           encode_mcp_config(
             mcp_config(Path.join(remote_dir, "WORKFLOW.md"), remote_mcp_command(omp), omp, tracker_env),
             local_mcp_path
           ),
         payload = ssh_payload(workflow_snapshot, encoded_mcp, overlay_yaml(), prompt),
         {:ok, port} <- SSH.start_port(host, command, line: @port_line_bytes),
         :ok <- SSH.write_stdin(port, payload) do
      CliHarness.collect_port_stream(port, on_message, Stream, "omp")
    end
  rescue
    error -> {:error, {:omp_ssh_port, error}}
  end

  defp ssh_payload(workflow, encoded_mcp, overlay, prompt) do
    Enum.map(
      [workflow, encoded_mcp, overlay, prompt],
      &[Integer.to_string(byte_size(&1)), "\n", &1]
    )
  end

  defp build_remote_command(workspace, remote_dir, omp, secret_environment_names) do
    path = &CliHarness.shell_escape(Path.join(remote_dir, &1))

    [
      "cd #{CliHarness.shell_escape(workspace)}",
      "umask 077",
      "mkdir -p #{path.("agent")} #{path.("sessions")}",
      "chmod 700 #{CliHarness.shell_escape(remote_dir)}",
      CliHarness.read_length_prefixed_file("workflow", path.("WORKFLOW.md")),
      CliHarness.read_length_prefixed_file("mcp_config", path.("agent/mcp.json")),
      CliHarness.read_length_prefixed_file("overlay", path.("overlay.yml")),
      "IFS= read -r symphony_prompt_bytes",
      "case \"$symphony_prompt_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      CliHarness.tracker_secret_unset_command(secret_environment_names),
      "symphony_continue=",
      "if [ -n \"$(ls -A #{path.("sessions")} 2>/dev/null)\" ]; then symphony_continue=--continue; fi",
      remote_omp_invocation(remote_dir, omp)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_omp_invocation(remote_dir, omp) do
    paths = %{sessions_dir: Path.join(remote_dir, "sessions"), overlay_path: Path.join(remote_dir, "overlay.yml")}
    args = paths |> argv(omp, false) |> Enum.map(&CliHarness.shell_escape/1)

    "dd bs=1 count=\"$symphony_prompt_bytes\" 2>/dev/null | " <>
      "PI_CODING_AGENT_DIR=#{CliHarness.shell_escape(Path.join(remote_dir, "agent"))} " <>
      Enum.join([CliHarness.shell_escape(omp.command) | args] ++ ["$symphony_continue"], " ")
  end

  defp remote_mcp_command(omp), do: omp.linear_mcp_command || "symphony"

  defp opt(_flag, nil), do: []
  defp opt(flag, value), do: [flag, value]
end
