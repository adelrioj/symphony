defmodule SymphonyElixir.Agent.CliHarness do
  @moduledoc """
  Shared plumbing for CLI agent backends: private session directories, executable
  resolution, port driving with secret scrubbing, and line-delimited JSON stream
  collection folded by a `CliHarness.StreamFolder`.
  """

  require Logger

  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576

  @spec create_session_dir(String.t(), Path.t()) :: {:ok, Path.t(), pid()} | {:error, term()}
  def create_session_dir(dir_name, workspace) do
    with {:ok, parent_dir} <- session_parent_dir(dir_name, workspace),
         :ok <- ensure_private_directory(parent_dir),
         {:ok, session_dir} <- create_private_session_directory(parent_dir) do
      {:ok, session_dir, start_cleanup_monitor(self(), session_dir)}
    end
  end

  @spec remove_session_dir(Path.t(), pid() | nil) :: :ok
  def remove_session_dir(session_dir, monitor) do
    File.rm_rf(session_dir)
    if is_pid(monitor), do: send(monitor, :stop)
    :ok
  end

  defp session_parent_dir(dir_name, workspace) do
    tmp_dir = Path.join(System.tmp_dir!(), dir_name)

    dir =
      if path_inside?(tmp_dir, workspace) do
        Path.join(Path.dirname(workspace), "." <> dir_name)
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

  @spec resolve_executable(String.t(), atom()) :: {:ok, String.t()} | {:error, term()}
  def resolve_executable(command, not_configured) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" ->
        {:error, not_configured}

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

  @spec drive_port(
          binary(),
          [String.t()],
          Path.t(),
          (map() -> any()) | nil,
          Path.t() | nil,
          [String.t()],
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  def drive_port(executable, argv, workspace, on_message, stdin_path, secret_environment_names, opts) do
    env = tracker_secret_port_env(secret_environment_names) ++ Keyword.get(opts, :env, [])

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

    collect_port_stream(port, on_message, opts[:stream], opts[:label])
  rescue
    error -> {:error, {Keyword.fetch!(opts, :error_tag), error}}
  end

  @spec collect_port_stream(port(), (map() -> any()) | nil, module(), String.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def collect_port_stream(port, on_message, stream, label) do
    settings = Config.settings!().codex
    deadline = monotonic_ms() + settings.turn_timeout_ms

    collect_stream(port, on_message, stream, label, stream.new(), "", deadline, settings.stall_timeout_ms)
  end

  @spec write_prompt_file(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_prompt_file(session_dir, prompt) do
    path = Path.join(session_dir, "prompt-#{temp_token()}.txt")

    case write_private_file(path, prompt) do
      :ok -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  @spec write_private_file(Path.t(), iodata()) :: :ok | {:error, term()}
  def write_private_file(path, contents) do
    with {:ok, result} <-
           File.open(path, [:write, :binary, :exclusive], &write_private_file_contents(&1, path, contents)) do
      result
    end
  end

  defp write_private_file_contents(io, path, contents) do
    with :ok <- File.chmod(path, 0o600) do
      IO.binwrite(io, contents)
    end
  end

  @spec remote_mktemp_function() :: String.t()
  def remote_mktemp_function do
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

  @spec read_length_prefixed_file(String.t(), String.t()) :: String.t()
  def read_length_prefixed_file(label, destination) do
    [
      "IFS= read -r symphony_#{label}_bytes",
      "case \"$symphony_#{label}_bytes\" in ''|*[!0-9]*) exit 64;; esac",
      "dd bs=1 count=\"$symphony_#{label}_bytes\" 2>/dev/null > #{destination}"
    ]
    |> Enum.join(" && ")
  end

  @spec capture_tracker_env([term()], (String.t() -> String.t() | nil)) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def capture_tracker_env(names, env_reader) do
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

  @spec tracker_secret_port_env([term()]) :: [{charlist(), false}]
  def tracker_secret_port_env(names) do
    names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  @spec tracker_secret_unset_command([term()]) :: String.t() | nil
  def tracker_secret_unset_command(names) do
    case valid_environment_names(names) do
      [] -> nil
      valid_names -> "unset " <> Enum.join(valid_names, " ")
    end
  end

  @spec valid_environment_names([term()]) :: [String.t()]
  def valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp stdin_redirect_command(executable, argv, stdin_path) do
    command = Enum.map_join([executable | argv], " ", &shell_escape/1)
    "exec " <> command <> " < " <> shell_escape(stdin_path)
  end

  @spec shell_escape(term()) :: String.t()
  def shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp collect_stream(port, on_message, stream, label, acc, pending_line, deadline, stall_timeout_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        updated_acc = handle_line(line, on_message, stream, label, acc)
        collect_stream(port, on_message, stream, label, updated_acc, "", deadline, stall_timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        collect_stream(
          port,
          on_message,
          stream,
          label,
          acc,
          pending_line <> to_string(chunk),
          deadline,
          stall_timeout_ms
        )

      {^port, {:exit_status, status}} ->
        {drained_acc, drained_pending_line} = drain_port_data(port, on_message, stream, label, acc, pending_line)
        finalize_stream(drained_acc, drained_pending_line, on_message, stream, label, status)
    after
      receive_timeout(deadline, stall_timeout_ms) ->
        close_port(port)
        {:error, receive_timeout_reason(deadline)}
    end
  end

  defp drain_port_data(port, on_message, stream, label, acc, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        updated_acc = handle_line(line, on_message, stream, label, acc)
        drain_port_data(port, on_message, stream, label, updated_acc, "")

      {^port, {:data, {:noeol, chunk}}} ->
        drain_port_data(port, on_message, stream, label, acc, pending_line <> to_string(chunk))
    after
      0 ->
        {acc, pending_line}
    end
  end

  defp finalize_stream(acc, "", _on_message, stream, _label, status), do: stream.finalize(acc, status)

  defp finalize_stream(acc, pending_line, on_message, stream, label, status) do
    pending_line
    |> handle_line(on_message, stream, label, acc)
    |> stream.finalize(status)
  end

  defp handle_line(line, on_message, stream, label, acc) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        {updated_acc, update} = stream.step(event, acc)
        maybe_emit(on_message, update)
        updated_acc

      _decode_error ->
        # Log (without the line body, which may carry secrets) so a truncated or
        # oversized event is diagnosable instead of silently downgrading the run.
        Logger.warning(
          "#{label} stream line dropped (undecodable) session_id=#{acc.session_id || "unknown"} bytes=#{byte_size(line)}"
        )

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

  @spec remote_temp_path(String.t(), String.t()) :: String.t()
  def remote_temp_path(prefix, suffix) do
    "/tmp/#{prefix}.#{temp_token()}#{suffix}"
  end

  @spec temp_token() :: String.t()
  def temp_token do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
