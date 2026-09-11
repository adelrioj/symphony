defmodule SymphonyElixir.ExecutionEnvironment.Command do
  @moduledoc "Bounded local argv execution. Killing local transport never proves remote cancellation."

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

  @spec with_json_file(term(), (String.t() -> result)) :: result | {:error, {:unknown, term()}} when result: term()
  def with_json_file(body, fun) when is_function(fun, 1) do
    directory = Path.join(System.tmp_dir!(), "symphony-command-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))

    case File.mkdir(directory) do
      :ok ->
        try do
          path = Path.join(directory, "request.json")

          with :ok <- File.chmod(directory, 0o700),
               {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
            try do
              with :ok <- File.chmod(path, 0o600),
                   :ok <- IO.binwrite(file, Jason.encode!(body)) do
                File.close(file)
                fun.(path)
              else
                {:error, _} -> {:error, {:unknown, :private_request_file}}
              end
            after
              File.close(file)
            end
          else
            {:error, _} -> {:error, {:unknown, :private_request_file}}
          end
        after
          File.rm_rf(directory)
        end

      {:error, _} ->
        {:error, {:unknown, :private_request_file}}
    end
  end

  defp execute(executable, args, opts, timeout, limit) do
    previous_trap = Process.flag(:trap_exit, true)

    try do
      port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide, args: args, env: port_env(Keyword.get(opts, :env, []))])

      try do
        collect(port, System.monotonic_time(:millisecond) + timeout, limit, [], 0)
      after
        close_port(port)
      end
    rescue
      _ -> {:error, {:unknown, :command_failed}}
    after
      Process.flag(:trap_exit, previous_trap)
    end
  end

  defp collect(port, deadline, limit, chunks, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > limit do
          output = IO.iodata_to_binary(Enum.reverse([binary_part(data, 0, max(limit - size, 0)) | chunks]))
          terminate_port(port)
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
        terminate_port(port)
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
            nil -> {:error, :local_process_termination_unconfirmed}
            executable ->
              System.cmd(executable, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
              await_port_exit(port)
          end

        nil -> :ok
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

  defp port_env(env), do: Enum.map(env, fn {key, value} -> {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))} end)
end
