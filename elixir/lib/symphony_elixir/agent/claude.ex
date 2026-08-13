defmodule SymphonyElixir.Agent.Claude do
  @moduledoc """
  Agent backend that runs Claude Code (`claude -p`) per turn.

  Claude emits newline-delimited `stream-json`; this adapter folds decoded
  events into an `Agent.Result` while emitting normalized worker updates.
  """

  @behaviour SymphonyElixir.Agent

  require Logger

  alias SymphonyElixir.Agent.Claude.Stream
  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{Config, SSH, Tracker, Workflow}

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
          required(:worker_host) => String.t() | nil,
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
    owner = self()
    expanded_workspace = Path.expand(workspace)
    settings = Config.settings!()
    dynamic_tool_binding = Tracker.bind_agent_tools()
    secret_environment_names = valid_environment_names(dynamic_tool_binding.secret_environment_names)
    env_reader = Keyword.get(opts, :env_reader, &System.get_env/1)

    with {:ok, tracker_env} <- capture_tracker_env(secret_environment_names, env_reader),
         {:ok, workflow_snapshot} <- File.read(Workflow.current_path()),
         {:ok, parent_dir} <- mcp_config_dir(expanded_workspace),
         :ok <- ensure_private_directory(parent_dir),
         {:ok, session_dir} <- create_private_session_directory(parent_dir) do
      cleanup_monitor = start_cleanup_monitor(owner, session_dir)

      case write_session_files(session_dir, workflow_snapshot, settings.claude, tracker_env) do
        {:ok, workflow_snapshot_path, mcp_config_path} ->
          {:ok,
           %{
             workspace: expanded_workspace,
             worker_host: Keyword.get(opts, :worker_host),
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
    File.rm_rf(session_dir)
    if is_pid(session[:cleanup_monitor]), do: send(session.cleanup_monitor, :stop)
    :ok
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
    remote_workflow_path = remote_temp_path("symphony-claude-workflow", ".md")

    build_remote_command(workspace, remote_workflow_path, settings.claude, binding)
  end

  defp write_session_files(session_dir, workflow_snapshot, claude, tracker_env) do
    workflow_path = Path.join(session_dir, "WORKFLOW.md")
    mcp_path = Path.join(session_dir, "mcp.json")

    with :ok <- write_private_file(workflow_path, workflow_snapshot),
         {:ok, encoded_mcp_config} <-
           encode_mcp_config(mcp_config(workflow_path, nil, claude, tracker_env), mcp_path),
         :ok <- write_private_file(mcp_path, encoded_mcp_config) do
      {:ok, workflow_path, mcp_path}
    end
  end

  defp cleanup_failed_session(session_dir, cleanup_monitor, error) do
    File.rm_rf(session_dir)
    send(cleanup_monitor, :stop)
    error
  end

  defp ensure_private_directory(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)
  end

  defp create_private_session_directory(parent_dir) do
    session_dir = Path.join(parent_dir, "session-#{temp_token()}")

    with :ok <- File.mkdir(session_dir) do
      case File.chmod(session_dir, 0o700) do
        :ok ->
          {:ok, session_dir}

        {:error, _reason} = error ->
          File.rm_rf(session_dir)
          error
      end
    end
  end

  defp start_cleanup_monitor(owner, session_dir) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, ^owner, _reason} -> File.rm_rf(session_dir)
        :stop -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  defp mcp_config(workflow_path, command, claude, tracker_env) do
    %{
      "mcpServers" => %{
        "symphony" => %{
          "command" => command || claude.linear_mcp_command || default_mcp_command(),
          "args" => claude.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path],
          "env" => tracker_env
        }
      }
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
  def default_mcp_command(script_name \\ nil) do
    candidate =
      if is_nil(script_name) and not burrito_runtime?() do
        safe_escript_name()
      else
        script_name
      end

    executable_candidate(candidate) || System.find_executable("symphony") || "symphony"
  end

  defp safe_escript_name do
    :escript.script_name()
  catch
    _kind, _reason -> nil
  end

  defp burrito_runtime?, do: System.get_env("__BURRITO") == "1"

  defp executable_candidate(candidate) when is_list(candidate) and candidate != [] do
    candidate
    |> List.to_string()
    |> executable_candidate()
  rescue
    _error -> nil
  end

  defp executable_candidate(candidate) when is_binary(candidate) do
    path =
      cond do
        Path.type(candidate) == :absolute -> candidate
        String.contains?(candidate, "/") -> Path.expand(candidate)
        true -> System.find_executable(candidate)
      end

    if executable_regular_file?(path), do: path
  end

  defp executable_candidate(_candidate), do: nil

  defp executable_regular_file?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp executable_regular_file?(_path), do: false

  defp run_claude(
         %{
           worker_host: nil,
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
    with {:ok, executable} <- claude_executable(claude.command),
         {:ok, prompt_path} <- write_prompt_file(session_dir, prompt) do
      try do
        drive_port(
          executable,
          argv(mcp_config_path, claude, %{tool_specs: tool_specs}),
          workspace,
          on_message,
          prompt_path,
          secret_environment_names
        )
      after
        _ = File.rm(prompt_path)
      end
    end
  end

  defp run_claude(%{worker_host: worker_host} = session, workspace, prompt, on_message)
       when is_binary(worker_host) do
    drive_ssh(session, workspace, prompt, on_message)
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

  @doc false
  @spec drive_port(binary(), [String.t()], Path.t(), (map() -> any()) | nil) ::
          {:ok, Result.t()} | {:error, term()}
  def drive_port(executable, argv, workspace, on_message) do
    drive_port(executable, argv, workspace, on_message, nil)
  end

  @spec drive_port(binary(), [String.t()], Path.t(), (map() -> any()) | nil, Path.t() | nil) ::
          {:ok, Result.t()} | {:error, term()}
  def drive_port(executable, argv, workspace, on_message, stdin_path) do
    drive_port(
      executable,
      argv,
      workspace,
      on_message,
      stdin_path,
      Tracker.bind_agent_tools().secret_environment_names
    )
  end

  @doc false
  @spec drive_port(
          binary(),
          [String.t()],
          Path.t(),
          (map() -> any()) | nil,
          Path.t() | nil,
          [String.t()]
        ) :: {:ok, Result.t()} | {:error, term()}
  def drive_port(executable, argv, workspace, on_message, stdin_path, secret_environment_names) do
    env = tracker_secret_port_env(secret_environment_names)

    {port_executable, port_args} =
      case stdin_path do
        nil ->
          {executable, argv}

        path when is_binary(path) ->
          {"/bin/sh", ["-c", stdin_redirect_command(executable, argv, path)]}
      end

    port =
      Port.open({:spawn_executable, String.to_charlist(port_executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(port_args, &String.to_charlist/1),
        cd: String.to_charlist(workspace),
        env: env,
        line: @port_line_bytes
      ])

    collect_port_stream(port, on_message)
  rescue
    error -> {:error, {:claude_port, error}}
  end

  defp drive_ssh(
         %{
           worker_host: host,
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
    remote_workflow_path = remote_temp_path("symphony-claude-workflow", ".md")
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
      collect_port_stream(port, on_message)
    end
  rescue
    error -> {:error, {:claude_ssh_port, error}}
  end

  @doc false
  @spec collect_port_stream(port(), (map() -> any()) | nil) ::
          {:ok, Result.t()} | {:error, term()}
  def collect_port_stream(port, on_message) do
    settings = Config.settings!().codex
    deadline = monotonic_ms() + settings.turn_timeout_ms
    collect_stream(port, on_message, Stream.new(), "", deadline, settings.stall_timeout_ms)
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

  defp write_prompt_file(session_dir, prompt) do
    path = Path.join(session_dir, "prompt-#{temp_token()}.txt")

    case write_private_file(path, prompt) do
      :ok -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  defp write_private_file(path, contents) do
    with {:ok, result} <- File.open(path, [:write, :binary, :exclusive], &write_private_file_contents(&1, path, contents)) do
      result
    end
  end

  defp write_private_file_contents(io, path, contents) do
    with :ok <- File.chmod(path, 0o600) do
      IO.binwrite(io, contents)
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

  defp build_remote_command(workspace, remote_workflow_path, claude, binding) do
    [
      "cd #{shell_escape(workspace)}",
      "umask 077",
      remote_mktemp_function(),
      "cleanup() { rm -f #{shell_escape(remote_workflow_path)} \"${symphony_mcp_config_file:-}\"; }",
      "trap cleanup EXIT HUP INT TERM",
      "symphony_mcp_config_file=$(symphony_mktemp symphony-claude-mcp)",
      "[ -n \"$symphony_mcp_config_file\" ]",
      read_length_prefixed_file("workflow", shell_escape(remote_workflow_path)),
      "chmod 600 #{shell_escape(remote_workflow_path)}",
      read_length_prefixed_file("mcp_config", "\"$symphony_mcp_config_file\""),
      "chmod 600 \"$symphony_mcp_config_file\"",
      "IFS= read -r symphony_prompt_bytes",
      "case \"$symphony_prompt_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      tracker_secret_unset_command(binding.secret_environment_names),
      remote_claude_invocation(claude, binding)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp read_length_prefixed_file(label, destination) do
    [
      "IFS= read -r symphony_#{label}_bytes",
      "case \"$symphony_#{label}_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      "dd bs=1 count=\"$symphony_#{label}_bytes\" 2>/dev/null > #{destination}"
    ]
    |> Enum.join(" && ")
  end

  defp remote_claude_invocation(claude, binding) do
    allowed_tools = allowed_tools(claude, binding)

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

    "dd bs=1 count=\"$symphony_prompt_bytes\" 2>/dev/null | " <>
      Enum.join([shell_escape(claude.command) | args], " ")
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

  defp capture_tracker_env(names, env_reader) do
    names
    |> valid_environment_names()
    |> Enum.reduce_while({:ok, %{}}, &capture_tracker_env_value(&1, env_reader, &2))
  end

  defp capture_tracker_env_value(name, env_reader, {:ok, env}) do
    case env_reader.(name) do
      value when is_binary(value) ->
        capture_tracker_binary(name, value, env)

      nil ->
        {:cont, {:ok, env}}
    end
  end

  defp capture_tracker_binary(name, value, env) do
    if String.valid?(value) do
      {:cont, {:ok, Map.put(env, name, value)}}
    else
      {:halt, {:error, {:invalid_tracker_secret_encoding, [name]}}}
    end
  end

  defp tracker_secret_port_env(names) do
    names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(names) do
    case valid_environment_names(names) do
      [] -> nil
      valid_names -> "unset " <> Enum.join(valid_names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp stdin_redirect_command(executable, argv, stdin_path) do
    command = Enum.map_join([executable | argv], " ", &shell_escape/1)
    "exec " <> command <> " < " <> shell_escape(stdin_path)
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
        {drained_acc, drained_pending_line} = drain_port_data(port, on_message, acc, pending_line)
        finalize_stream(drained_acc, drained_pending_line, on_message, status)
    after
      receive_timeout(deadline, stall_timeout_ms) ->
        close_port(port)
        {:error, receive_timeout_reason(deadline)}
    end
  end

  defp drain_port_data(port, on_message, acc, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        updated_acc = handle_line(line, on_message, acc)
        drain_port_data(port, on_message, updated_acc, "")

      {^port, {:data, {:noeol, chunk}}} ->
        drain_port_data(port, on_message, acc, pending_line <> to_string(chunk))
    after
      0 ->
        {acc, pending_line}
    end
  end

  defp finalize_stream(acc, "", _on_message, status), do: Stream.finalize(acc, status)

  defp finalize_stream(acc, pending_line, on_message, status) do
    pending_line
    |> handle_line(on_message, acc)
    |> Stream.finalize(status)
  end

  defp handle_line(line, on_message, acc) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        {updated_acc, update} = Stream.step(event, acc)
        maybe_emit(on_message, update)
        updated_acc

      _decode_error ->
        # Log (without the line body, which may carry secrets) so a truncated or
        # oversized event is diagnosable instead of silently downgrading the run.
        Logger.warning("Claude stream line dropped (undecodable) session_id=#{acc.session_id || "unknown"} bytes=#{byte_size(line)}")
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
    "/tmp/#{prefix}.#{temp_token()}#{suffix}"
  end

  defp temp_token do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
