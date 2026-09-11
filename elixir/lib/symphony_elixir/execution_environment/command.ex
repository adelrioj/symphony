defmodule SymphonyElixir.ExecutionEnvironment.Command do
  @moduledoc "Bounded local argv execution. Killing local transport never proves remote cancellation."
  alias SymphonyElixir.ExecutionEnvironment.Operations

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, %{output: binary(), status: integer()}} | {:error, {:unknown, term()}}
  def run(executable, args, opts) when is_binary(executable) and is_list(args) do
    timeout = Keyword.fetch!(opts, :timeout_ms)
    limit = Keyword.get(opts, :max_output_bytes, 65_536)

    if is_integer(timeout) and timeout > 0 and is_integer(limit) and limit > 0 do
      execute(executable, args, opts, timeout, limit)
    else
      {:error, {:unknown, :invalid_command_bounds}}
    end
  end

  @spec with_json_file(term(), (String.t() -> result), keyword()) :: result | {:error, {:unknown, term()}} when result: term()
  def with_json_file(body, fun, opts) when is_function(fun, 1) do
    directory = Path.join(System.tmp_dir!(), "symphony-command-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))

    with_stage(opts, [directory], fn lease ->
      with :ok <- Operations.create_staged_directory(lease, directory),
           {:ok, path} <- write_request_file(directory, body) do
        fun.(path)
      else
        {:error, _} -> {:error, {:unknown, :private_request_file}}
      end
    end)
  end

  defp execute(executable, args, opts, timeout, limit) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    remaining = if Keyword.has_key?(opts, :deadline), do: max(Keyword.fetch!(opts, :deadline) - clock.(), 0), else: timeout
    deadline = System.monotonic_time(:millisecond) + min(timeout, remaining)

    with_stage(opts, [], fn lease ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, {:unknown, {:timeout, ""}}}
      else
        case Operations.start_staged_port(lease, executable, args, Keyword.put(opts, :retain_on_exit, true)) do
          {:ok, port} -> collect(port, deadline, limit, [], 0)
          {:error, _} -> {:error, {:unknown, :command_failed}}
        end
      end
    end)
  end

  defp with_stage(opts, paths, fun) do
    supervisor = Keyword.fetch!(opts, :task_supervisor)
    authority = Keyword.get(opts, :authority, self())

    case Operations.stage_private_paths(supervisor, authority, self(), paths) do
      {:ok, lease} ->
        outcome =
          try do
            {:returned, fun.(lease)}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        cleanup = Operations.release_staged_paths(lease)

        case {outcome, cleanup} do
          {{:raised, kind, reason, stacktrace}, _} -> :erlang.raise(kind, reason, stacktrace)
          {{:returned, result}, :ok} -> result
          {{:returned, _result}, {:error, _}} -> {:error, {:unknown, :local_cleanup_unconfirmed}}
        end

      {:error, _} ->
        {:error, {:unknown, :command_resource_owner}}
    end
  end

  defp write_request_file(directory, body) do
    path = Path.join(directory, "request.json")

    with {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(file, Jason.encode!(body)) do
          {:ok, path}
        end
      after
        File.close(file)
      end
    end
  end

  defp collect(port, deadline, limit, chunks, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > limit do
          output = IO.iodata_to_binary(Enum.reverse([binary_part(data, 0, max(limit - size, 0)) | chunks]))
          {:error, {:unknown, {:output_limit, output}}}
        else
          collect(port, deadline, limit, [data | chunks], size + byte_size(data))
        end

      {^port, {:exit_status, status}} ->
        {:ok, %{output: IO.iodata_to_binary(Enum.reverse(chunks)), status: status}}

      {:EXIT, ^port, _reason} ->
        {:error, {:unknown, :command_exited}}
    after
      remaining ->
        {:error, {:unknown, {:timeout, IO.iodata_to_binary(Enum.reverse(chunks))}}}
    end
  end

  @spec terminate_port(port()) :: :ok | {:error, :local_process_termination_unconfirmed}
  def terminate_port(port) when is_port(port) do
    try do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          # Signal only the child of this still-owned port, never a process-name match.
          case System.find_executable("kill") do
            nil ->
              {:error, :local_process_termination_unconfirmed}

            executable ->
              System.cmd(executable, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
              await_port_exit(port)
          end

        nil ->
          :ok
      end
    rescue
      _ -> {:error, :local_process_termination_unconfirmed}
    after
      close_port(port)
    end
  end

  defp await_port_exit(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {:EXIT, ^port, _} -> :ok
    after
      250 -> {:error, :local_process_termination_unconfirmed}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
