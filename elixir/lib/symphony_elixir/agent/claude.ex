defmodule SymphonyElixir.Agent.Claude do
  @moduledoc """
  Agent backend that runs Claude Code (`claude -p`) per turn.

  Claude emits newline-delimited `stream-json`; this adapter folds decoded
  events into an `Agent.Result` while emitting normalized worker updates.
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Claude.Stream
  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{Config, SSH, Workflow}

  @approval_tool "mcp__symphony__approval_prompt"
  @default_allowed_tools [
    "mcp__symphony__linear_graphql",
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
          required(:worker_host) => String.t() | nil,
          required(:mcp_config_path) => Path.t()
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)

    with {:ok, mcp_config_path} <- write_mcp_config(expanded_workspace) do
      {:ok,
       %{
         workspace: expanded_workspace,
         worker_host: Keyword.get(opts, :worker_host),
         mcp_config_path: mcp_config_path
       }}
    end
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
  def stop_session(%{mcp_config_path: path}) when is_binary(path) do
    _ = File.rm(path)
    :ok
  end

  @doc false
  @spec remote_command(String.t(), String.t()) :: String.t()
  def remote_command(workspace, _prompt) when is_binary(workspace) do
    remote_workflow_path = remote_temp_path("symphony-claude-workflow", ".md")
    remote_mcp_config = mcp_config(remote_workflow_path, remote_mcp_command())

    [
      "cd #{shell_escape(workspace)}",
      "umask 077",
      remote_mktemp_function(),
      "cleanup() { rm -f #{shell_escape(remote_workflow_path)} \"${symphony_mcp_config_file:-}\"; }",
      "trap cleanup EXIT HUP INT TERM",
      "symphony_mcp_config_file=$(symphony_mktemp symphony-claude-mcp)",
      "[ -n \"$symphony_mcp_config_file\" ]",
      "IFS= read -r symphony_workflow_bytes",
      "case \"$symphony_workflow_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      "dd bs=1 count=\"$symphony_workflow_bytes\" 2>/dev/null > #{shell_escape(remote_workflow_path)}",
      "chmod 600 #{shell_escape(remote_workflow_path)}",
      "IFS= read -r symphony_prompt_bytes",
      "case \"$symphony_prompt_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      "printf %s #{shell_escape(Jason.encode!(remote_mcp_config))} > \"$symphony_mcp_config_file\"",
      "chmod 600 \"$symphony_mcp_config_file\"",
      remote_claude_invocation()
    ]
    |> Enum.join(" && ")
  end

  defp write_mcp_config(workspace) do
    with {:ok, dir} <- mcp_config_dir(workspace),
         :ok <- File.mkdir_p(dir),
         path = Path.join(dir, "symphony-claude-mcp-#{System.unique_integer([:positive])}.json"),
         :ok <- File.write(path, Jason.encode!(mcp_config()), [:write, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    end
  end

  defp mcp_config(workflow_path \\ Workflow.current_path(), command \\ nil) do
    claude = Config.settings!().claude

    %{
      "mcpServers" => %{
        "symphony" => %{
          "command" => command || claude.linear_mcp_command || default_mcp_command(),
          "args" => claude.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path]
        }
      }
    }
  end

  @doc false
  @spec mcp_config_dir(term()) :: {:ok, Path.t()} | {:error, {:mcp_config_dir, term()}}
  def mcp_config_dir(workspace) do
    tmp_dir = Path.join(System.tmp_dir!(), "symphony-claude-mcp")

    dir =
      if path_inside?(tmp_dir, workspace) do
        Path.join(Path.dirname(workspace), ".symphony-claude-mcp")
      else
        tmp_dir
      end

    {:ok, Path.expand(dir)}
  rescue
    error -> {:error, {:mcp_config_dir, error}}
  end

  defp path_inside?(path, root) when is_binary(path) and is_binary(root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  @doc false
  @spec default_mcp_command(charlist() | term()) :: String.t()
  def default_mcp_command(script_name \\ :escript.script_name()) do
    case script_name do
      script_name when is_list(script_name) and script_name != [] ->
        script_name
        |> List.to_string()
        |> expand_script_name()

      _ ->
        System.find_executable("symphony") || "symphony"
    end
  end

  defp run_claude(%{worker_host: nil, mcp_config_path: mcp_config_path}, workspace, prompt, on_message) do
    with {:ok, executable} <- claude_executable(Config.settings!().claude.command) do
      drive_port(executable, argv(mcp_config_path, prompt), workspace, on_message)
    end
  end

  defp run_claude(%{worker_host: worker_host}, workspace, prompt, on_message) when is_binary(worker_host) do
    drive_ssh(worker_host, workspace, prompt, on_message)
  end

  defp claude_executable(command) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" ->
        {:error, :claude_command_not_configured}

      Path.type(command) == :absolute ->
        {:ok, command}

      String.contains?(command, "/") ->
        {:ok, Path.expand(command)}

      executable = System.find_executable(command) ->
        {:ok, executable}

      true ->
        {:error, {:executable_not_found, command}}
    end
  end

  defp argv(mcp_config_path, prompt) do
    claude = Config.settings!().claude
    allowed_tools = claude.allowed_tools || @default_allowed_tools

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
        @approval_tool,
        "--",
        prompt
      ]
  end

  @doc false
  @spec drive_port(binary(), [String.t()], Path.t(), (map() -> any()) | nil) ::
          {:ok, Result.t()} | {:error, term()}
  def drive_port(executable, argv, workspace, on_message) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(argv, &String.to_charlist/1),
        cd: String.to_charlist(workspace),
        line: @port_line_bytes
      ])

    collect_port_stream(port, on_message)
  rescue
    error -> {:error, {:claude_port, error}}
  end

  defp drive_ssh(host, workspace, prompt, on_message) do
    with {:ok, payload} <- ssh_payload(prompt),
         {:ok, port} <- SSH.start_port(host, remote_command(workspace, prompt), line: @port_line_bytes),
         :ok <- SSH.write_stdin(port, payload) do
      collect_port_stream(port, on_message)
    end
  rescue
    error -> {:error, {:claude_ssh_port, error}}
  end

  defp collect_port_stream(port, on_message) do
    settings = Config.settings!().codex
    deadline = monotonic_ms() + settings.turn_timeout_ms
    collect_stream(port, on_message, Stream.new(), "", deadline, settings.stall_timeout_ms)
  end

  defp ssh_payload(prompt) when is_binary(prompt) do
    with {:ok, workflow} <- File.read(Workflow.current_path()) do
      {:ok, [Integer.to_string(byte_size(workflow)), "\n", workflow, Integer.to_string(byte_size(prompt)), "\n", prompt]}
    end
  end

  defp remote_mktemp_function do
    [
      "symphony_mktemp() {",
      "symphony_prefix=$1;",
      "symphony_dir=${TMPDIR:-/tmp};",
      "case \"$symphony_dir\" in \"$PWD\"|\"$PWD\"/*) symphony_dir=$(dirname \"$PWD\");; esac;",
      "mktemp \"$symphony_dir/$symphony_prefix.XXXXXX\" 2>/dev/null || mktemp \"/tmp/$symphony_prefix.XXXXXX\";",
      "}"
    ]
    |> Enum.join(" ")
  end

  defp remote_claude_invocation do
    claude = Config.settings!().claude
    allowed_tools = claude.allowed_tools || @default_allowed_tools

    args =
      Enum.map(claude.args, &shell_escape/1) ++
        [
          "-p",
          "--output-format",
          "stream-json",
          "--verbose",
          "--mcp-config",
          "\"$symphony_mcp_config_file\"",
          "--strict-mcp-config",
          "--allowedTools",
          shell_escape(Enum.join(allowed_tools, ",")),
          "--permission-prompt-tool",
          shell_escape(@approval_tool)
        ]

    "dd bs=1 count=\"$symphony_prompt_bytes\" 2>/dev/null | " <> Enum.join([shell_escape(claude.command) | args], " ")
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp collect_stream(port, on_message, acc, pending_line, deadline, stall_timeout_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        updated_acc = handle_line(line, on_message, acc)
        collect_stream(port, on_message, updated_acc, "", deadline, stall_timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        collect_stream(
          port,
          on_message,
          acc,
          pending_line <> to_string(chunk),
          deadline,
          stall_timeout_ms
        )

      {^port, {:exit_status, status}} ->
        Stream.finalize(acc, status)
    after
      receive_timeout(deadline, stall_timeout_ms) ->
        close_port(port)
        {:error, receive_timeout_reason(deadline)}
    end
  end

  defp handle_line(line, on_message, acc) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        {updated_acc, update} = Stream.step(event, acc)
        maybe_emit(on_message, update)
        updated_acc

      _decode_error ->
        acc
    end
  end

  defp receive_timeout(deadline, stall_timeout_ms) do
    remaining = max(deadline - monotonic_ms(), 0)

    case stall_timeout_ms do
      timeout when is_integer(timeout) and timeout > 0 -> min(remaining, timeout)
      _ -> remaining
    end
  end

  defp receive_timeout_reason(deadline) do
    if monotonic_ms() >= deadline, do: :turn_timeout, else: :stall_timeout
  end

  @doc false
  @spec close_port(port()) :: :ok
  def close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  defp maybe_emit(on_message, event) do
    if is_function(on_message, 1) and is_map(event) do
      on_message.(event)
    else
      :ok
    end
  end

  defp remote_mcp_command do
    Config.settings!().claude.linear_mcp_command || "symphony"
  end

  defp remote_temp_path(prefix, suffix) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    "/tmp/#{prefix}.#{token}#{suffix}"
  end

  defp expand_script_name(script_name) do
    cond do
      Path.type(script_name) == :absolute ->
        script_name

      String.contains?(script_name, "/") ->
        Path.expand(script_name)

      executable = System.find_executable(script_name) ->
        executable

      true ->
        Path.expand(script_name)
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
