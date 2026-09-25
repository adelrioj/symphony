defmodule SymphonyElixir.ExecutionEnvironment.Operations do
  @moduledoc "Bounded provider work and authority-owned transport leases, independent of scheduler state."
  alias SymphonyElixir.{ExecutionContext, LaneContext}
  alias SymphonyElixir.ExecutionEnvironment.{Command, Connection, Lifecycle, Record}
  alias SymphonyElixir.SSH
  alias SymphonyElixir.SSH.Target

  @spec start(pid() | atom(), module(), map(), Lifecycle.Entry.t(), atom(), keyword()) :: {:ok, Task.t()}
  def start(supervisor, adapter, config, entry, operation, opts) do
    opts = Keyword.put(opts, :task_supervisor, supervisor)
    operation_fun = Keyword.get(opts, :operation_fun, &run/5)

    run = fn ->
      if entry.lane_snapshot, do: LaneContext.install(entry.lane_snapshot)
      {entry.operation_id, operation_fun.(adapter, config, entry, operation, opts)}
    end

    task = Task.Supervisor.async_nolink(supervisor, run)
    {:ok, task}
  end

  @spec discover(pid() | atom(), module(), map(), keyword()) :: {:ok, Task.t(), {:discovery, reference()}}
  def discover(supervisor, adapter, config, opts) do
    token = {:discovery, make_ref()}
    opts = Keyword.put(opts, :task_supervisor, supervisor)
    operation_fun = Keyword.get(opts, :operation_fun, &run/5)
    run = fn -> {token, operation_fun.(adapter, config, nil, :discover, opts)} end
    task = Task.Supervisor.async_nolink(supervisor, run)
    {:ok, task, token}
  end

  @spec run(module(), map(), Lifecycle.Entry.t() | nil, atom(), keyword()) :: term()
  def run(adapter, config, nil, :discover, opts) do
    opts = deadline_options(config, :discover, opts)

    with :ok <- invoke(adapter, :preflight, [config], opts) do
      invoke(adapter, :discover, [config], opts)
    end
  end

  def run(adapter, config, %Lifecycle.Entry{} = entry, :prepare, opts) do
    opts = deadline_options(config, :prepare, opts)
    record = %{entry.record | attempt_id: entry.attempt_id}

    with {:ok, ensured} <- mutate(adapter, :ensure, config, record, opts),
         ensured = %{ensured | attempt_id: entry.attempt_id, issue_state: entry.record.issue_state, issue_identifier: entry.record.issue_identifier},
         {:ok, intended} <- intent(adapter, config, ensured, :running, opts),
         {:ok, started} <- mutate(adapter, :start, config, intended, opts),
         {:ok, running} <- poll(adapter, config, started, :running, opts) do
      prepare_connection(adapter, config, entry.purpose, running, opts)
    end
  end

  def run(adapter, config, %Lifecycle.Entry{} = entry, :stop, opts) do
    opts = deadline_options(config, :stop, opts)

    try do
      with {:ok, intended} <- intent(adapter, config, entry.record, :stopped, opts),
           {:ok, stopped} <- mutate(adapter, :stop, config, intended, opts) do
        poll(adapter, config, stopped, :stopped, opts)
      end
    after
      close_entry_connection(entry)
    end
  end

  def run(adapter, config, %Lifecycle.Entry{} = entry, :destroy, opts) do
    opts = deadline_options(config, :destroy, opts)

    with {:ok, intended} <- intent(adapter, config, entry.record, :absent, opts),
         {:ok, deleting} <- mutate(adapter, :destroy, config, intended, opts) do
      poll(adapter, config, deleting, :absent, opts)
    end
  end

  def run(adapter, config, %Lifecycle.Entry{} = entry, :inspect, opts) do
    mutate(adapter, :inspect, config, entry.record, deadline_options(config, :inspect, opts))
  end

  def run(adapter, config, %Lifecycle.Entry{} = entry, :metadata, opts) do
    opts = deadline_options(config, :metadata, opts)

    case invoke(adapter, :put_intent, [config, entry.record, entry.metadata_intent || %{}], opts) do
      {:ok, latest} -> {:ok, latest}
      {:error, failure, latest} -> {:error, failure, latest}
      {:error, failure} -> {:error, failure, entry.record}
    end
  end

  def run(_adapter, _config, %Lifecycle.Entry{context: %ExecutionContext{} = context} = entry, :cleanup_hook, _opts) do
    case SymphonyElixir.Workspace.run_before_remove_hook(entry.record.workspace_path, entry.issue || entry.record.issue_identifier, context) do
      :ok -> {:ok, entry.record}
      {:error, failure} -> {:error, failure, entry.record}
    end
  end

  def run(_adapter, _config, %Lifecycle.Entry{record: record}, _operation, _opts), do: {:error, {:invalid, :environment_operation}, record}
  def run(_adapter, _config, nil, _operation, _opts), do: {:error, {:invalid, :environment_operation}}

  @opaque staged_paths :: {:staged_paths, pid(), reference()}

  @spec stage_private_paths(pid() | atom(), pid(), pid(), [String.t()]) :: {:ok, staged_paths()} | {:error, term()}
  def stage_private_paths(supervisor, authority, donor, paths) when is_pid(authority) and is_pid(donor) and is_list(paths) do
    if node(authority) == node() and node(donor) == node() and Process.alive?(authority) and Process.alive?(donor) do
      id = make_ref()

      start_staged_holder(supervisor, authority, donor, id, paths)
    else
      {:error, {:invalid, :connection_authority}}
    end
  catch
    :exit, _ -> {:error, {:unknown, :private_paths_staging_failed}}
  end

  def stage_private_paths(_supervisor, _authority, _donor, _paths), do: {:error, {:invalid, :connection_authority}}

  defp start_staged_holder(supervisor, authority, donor, id, paths) do
    start = fn -> holder(authority, donor, id, nil, [], paths) end

    case Task.Supervisor.start_child(supervisor, start) do
      {:ok, owner} -> acknowledge_staged_paths({:staged_paths, owner, id})
      {:error, _} -> {:error, {:unknown, :connection_holder_failed}}
    end
  end

  @spec release_staged_paths(staged_paths()) :: :ok | {:error, term()}
  def release_staged_paths({:staged_paths, owner, id}) do
    GenServer.call(owner, {:release_connection, id}, 1_000)
  catch
    :exit, _ -> {:error, :connection_closed}
  end

  @spec create_staged_directory(staged_paths(), String.t()) :: :ok | {:error, term()}
  def create_staged_directory({:staged_paths, owner, id}, directory) do
    GenServer.call(owner, {:create_staged_directory, id, directory}, 1_000)
  catch
    :exit, _ -> {:error, {:unknown, :private_directory_creation_failed}}
  end

  @spec start_staged_port(staged_paths(), String.t(), [String.t()], keyword()) :: {:ok, port()} | {:error, term()}
  def start_staged_port({:staged_paths, owner, id}, executable, args, opts) do
    GenServer.call(owner, {:start_staged_port, id, self(), executable, args, opts}, 1_000)
  catch
    :exit, _ -> {:error, {:unknown, :staged_port_failed}}
  end

  @spec open_connection(pid() | atom(), pid(), Target.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def open_connection(supervisor, authority, %Target{} = target, opts) when is_pid(authority) do
    ports = Keyword.get(opts, :ports, [])
    paths = Keyword.get(opts, :private_paths, [])
    donor = self()

    if node(authority) == node() and Process.alive?(authority) do
      case Keyword.get(opts, :staged_paths) do
        nil -> open_unstaged_connection(supervisor, authority, donor, target, ports, paths)
        {:staged_paths, owner, id} -> promote_connection(owner, id, authority, donor, target, ports, paths)
        _ -> {:error, {:invalid, :staged_paths}}
      end
    else
      {:error, {:invalid, :connection_authority}}
    end
  rescue
    _ -> {:error, {:unknown, :connection_adoption_failed}}
  catch
    :exit, _ -> {:error, {:unknown, :connection_adoption_failed}}
  end

  def open_connection(_supervisor, _authority, _target, _opts), do: {:error, {:invalid, :connection_authority}}

  defp open_unstaged_connection(supervisor, authority, donor, target, ports, paths) do
    if Enum.all?(ports, &(Port.info(&1, :connected) == {:connected, donor})) do
      id = make_ref()
      start_connection_holder(supervisor, authority, donor, id, target, ports, paths)
    else
      {:error, {:invalid, :connection_ports}}
    end
  end

  defp start_connection_holder(supervisor, authority, donor, id, target, ports, paths) do
    start = fn -> holder(authority, donor, id, target, ports, paths) end

    case Task.Supervisor.start_child(supervisor, start) do
      {:ok, owner} -> adopt_connection(owner, id, target, ports)
      {:error, _} -> {:error, {:unknown, :connection_holder_failed}}
    end
  end

  @spec close_connection(Connection.t()) :: :ok | {:error, term()}
  def close_connection(%Connection{owner: owner, id: id}) do
    GenServer.call(owner, {:release_connection, id}, 1_000)
  catch
    :exit, _ -> {:error, :connection_closed}
  end

  defp acknowledge_staged_paths({:staged_paths, owner, id} = lease) do
    case GenServer.call(owner, {:stage_paths, id}, 1_000) do
      :ok ->
        {:ok, lease}

      _ ->
        release_staged_paths(lease)
        {:error, {:unknown, :private_paths_staging_failed}}
    end
  catch
    :exit, _ ->
      release_staged_paths(lease)
      {:error, {:unknown, :private_paths_staging_failed}}
  end

  defp promote_connection(owner, id, authority, donor, target, ports, paths) do
    case GenServer.call(owner, {:promote_connection, id, authority, donor, target, ports, paths}, 1_000) do
      :ok -> adopt_connection(owner, id, target, ports)
      _ -> {:error, {:invalid, :staged_paths}}
    end
  end

  defp adopt_connection(owner, id, target, ports) do
    Enum.each(ports, fn port ->
      true = Port.connect(port, owner)
      Process.unlink(port)
    end)

    case GenServer.call(owner, {:adopt_connection, id}, 1_000) do
      :ok ->
        {:ok, %Connection{owner: owner, id: id, target: target}}

      _ ->
        close_connection(%Connection{owner: owner, id: id, target: target})
        {:error, {:unknown, :connection_adoption_failed}}
    end
  rescue
    _ ->
      close_connection(%Connection{owner: owner, id: id, target: target})
      {:error, {:unknown, :connection_adoption_failed}}
  catch
    :exit, _ ->
      close_connection(%Connection{owner: owner, id: id, target: target})
      {:error, {:unknown, :connection_adoption_failed}}
  end

  defp holder(authority, donor, id, target, ports, paths) do
    Process.flag(:trap_exit, true)
    authority_ref = Process.monitor(authority)
    donor_ref = Process.monitor(donor)
    # Cleanup must retain promoted ports even if the holder loop exits exceptionally.
    Process.put({__MODULE__, :owned_ports}, ports)

    state = %{
      authority: authority,
      authority_ref: authority_ref,
      donor: donor,
      donor_ref: donor_ref,
      id: id,
      target: target,
      ports: ports,
      paths: paths,
      adopted?: false,
      retained_ports: []
    }

    result =
      try do
        holder_loop(state)
      catch
        _kind, _reason -> :holder_failed
      end

    cleanup_result = cleanup_connection(Process.get({__MODULE__, :owned_ports}), paths)

    case result do
      {:release, from} -> GenServer.reply(from, cleanup_result)
      _ -> :ok
    end
  end

  defp holder_loop(state) do
    receive do
      message -> holder_message(message, state)
    end
  end

  defp holder_call({:stage_paths, id}, from, %{id: id, target: nil} = state) do
    if live_owners?(state) do
      GenServer.reply(from, :ok)
      holder_loop(state)
    else
      GenServer.reply(from, {:error, :connection_closed})
    end
  end

  defp holder_call({:create_staged_directory, id, directory}, from, %{id: id, target: nil} = state) do
    result =
      if directory in state.paths and live_owners?(state) do
        create_private_directory(directory)
      else
        {:error, {:invalid, :staged_directory}}
      end

    GenServer.reply(from, result)
    holder_loop(state)
  end

  defp holder_call({:start_staged_port, id, src, bin, args, opts}, from, %{id: id, donor: src, target: nil} = state) do
    case start_owned_port(bin, args, opts) do
      {:ok, port} ->
        ports = [port | state.ports]
        Process.put({__MODULE__, :owned_ports}, ports)
        GenServer.reply(from, {:ok, port})
        retain? = Keyword.get(opts, :retain_on_exit, false)
        retained = if retain?, do: [port | state.retained_ports], else: state.retained_ports
        holder_loop(%{state | ports: ports, retained_ports: retained})

      error ->
        GenServer.reply(from, error)
        holder_loop(state)
    end
  end

  defp holder_call(
         {:promote_connection, id, authority, donor, %Target{} = target, ports, paths},
         from,
         %{id: id, authority: authority, donor: donor, target: nil, ports: ports, paths: paths} = state
       ) do
    if live_owners?(state) and live_ports?(ports) do
      GenServer.reply(from, :ok)
      holder_loop(%{state | target: target, ports: ports})
    else
      GenServer.reply(from, {:error, :invalid_connection})
      holder_loop(state)
    end
  end

  defp holder_call({:adopt_connection, id}, from, %{id: id, target: target} = state) when not is_nil(target) do
    if live_ports?(state.ports) and Process.alive?(state.authority) do
      GenServer.reply(from, :ok)
      holder_loop(%{state | adopted?: true})
    else
      GenServer.reply(from, {:error, :connection_closed})
    end
  end

  defp holder_call({:validate_connection, id, target}, from, state) do
    valid = state.adopted? and id == state.id and target === state.target
    valid = valid and live_ports?(state.ports) and Process.alive?(state.authority)
    GenServer.reply(from, if(valid, do: :ok, else: {:error, :invalid_connection}))
    holder_loop(state)
  end

  defp holder_call({:release_connection, id}, from, %{id: id}), do: {:release, from}

  defp holder_call(_request, from, state) do
    GenServer.reply(from, {:error, :invalid_connection})
    holder_loop(state)
  end

  defp holder_message({:"$gen_call", from, request}, state), do: holder_call(request, from, state)

  defp holder_message({:DOWN, ref, :process, _, _}, %{authority_ref: ref}), do: :ok

  defp holder_message({:DOWN, ref, :process, _, :normal}, %{donor_ref: ref, adopted?: true} = state) do
    holder_loop(%{state | donor_ref: nil})
  end

  defp holder_message({:DOWN, ref, :process, _, _}, %{donor_ref: ref}), do: :ok

  defp holder_message({port, {:data, _}} = message, state) when is_port(port) do
    if not state.adopted?, do: send(state.donor, message)
    holder_loop(state)
  end

  defp holder_message({port, {:exit_status, _}} = message, state) when is_port(port) do
    if not state.adopted?, do: send(state.donor, message)
    if retained_port?(state, port), do: holder_loop(state), else: :ok
  end

  defp holder_message({:EXIT, port, reason} = message, state) when is_port(port) do
    retain? = retained_port?(state, port)
    if not state.adopted? and (not retain? or reason != :normal), do: send(state.donor, message)
    if retain?, do: holder_loop(state), else: :ok
  end

  defp holder_message({:EXIT, _, _}, _state), do: :ok
  defp holder_message(_message, state), do: holder_loop(state)

  defp retained_port?(state, port), do: not state.adopted? and port in state.retained_ports
  defp live_owners?(state), do: Process.alive?(state.authority) and Process.alive?(state.donor)

  defp create_private_directory(directory) do
    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700) do
      :ok
    else
      {:error, _} -> {:error, {:unknown, :private_directory_creation_failed}}
    end
  end

  defp start_owned_port(executable, args, opts) do
    env = Enum.map(Keyword.get(opts, :env, []), fn {key, value} -> {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))} end)
    {:ok, Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide, args: args, env: env])}
  rescue
    _ -> {:error, {:unknown, :staged_port_failed}}
  end

  defp live_ports?(ports), do: Enum.all?(ports, &(Port.info(&1, :connected) == {:connected, self()}))

  defp cleanup_connection(ports, paths) do
    port_results = Enum.map(ports, &Command.terminate_port/1)
    path_results = Enum.map(paths, &File.rm_rf/1)

    if Enum.all?(port_results, &(&1 == :ok)) and Enum.all?(path_results, &match?({:ok, _}, &1)) do
      :ok
    else
      {:error, :connection_cleanup_failed}
    end
  end

  defp prepare_connection(adapter, config, purpose, record, opts) do
    case invoke(adapter, :connect, [config, record], opts) do
      {:ok, %Connection{} = connection} ->
        try do
          context = ExecutionContext.managed(config, record, connection)

          case readiness(context, purpose, opts) do
            :ok ->
              {:ok, context}

            {:error, failure} ->
              close_connection(connection)
              {:error, failure, record}
          end
        rescue
          _ ->
            close_connection(connection)
            {:error, {:invalid, :managed_execution_context}, record}
        catch
          :exit, _ ->
            close_connection(connection)
            {:error, {:unknown, :connection_closed}, record}
        end

      {:error, failure} ->
        {:error, failure, record}
    end
  end

  defp readiness(context, purpose, opts) do
    executable = Keyword.get(opts, :agent_executable)

    if purpose == :agent and (not is_binary(executable) or String.trim(executable) == "") do
      {:error, {:invalid, :agent_executable}}
    else
      target = context.target
      command = readiness_command(context.workspace_root, executable, purpose)
      command_fun = Keyword.get(opts, :command_fun, &Command.run/3)
      command_opts = Keyword.merge(remaining_options(opts), env: target.env)

      if command_opts[:timeout_ms] <= 0 do
        {:error, {:unknown, :readiness_timeout}}
      else
        run_readiness(command_fun, target, command, command_opts)
      end
    end
  end

  defp run_readiness(command_fun, target, command, opts) do
    case command_fun.(target.executable, target.prefix ++ [SSH.remote_shell_command(command)], opts) do
      {:ok, %{status: 0}} -> :ok
      {:ok, %{status: _}} -> {:error, {:invalid, :worker_readiness}}
      {:error, {:unknown, _}} -> {:error, {:unknown, :readiness_timeout_or_transport}}
      {:error, _} -> {:error, {:unknown, :readiness_transport}}
    end
  end

  defp readiness_command(root, executable, purpose) do
    backend = if purpose == :cleanup, do: ":", else: "command -v -- " <> quote_shell(executable) <> " >/dev/null"

    Enum.join(
      [
        "set -eu",
        "root=" <> quote_shell(root),
        "test -d \"$root\" && test -w \"$root\"",
        "mount=$(findmnt -n -o TARGET -T \"$root\"); test -n \"$mount\" && test \"$mount\" != /",
        "probe=$(mktemp \"$root/.symphony-readiness.XXXXXXXX\"); trap 'rm -f -- \"$probe\"' EXIT; printf readiness >\"$probe\"",
        "realpath --version | grep -q 'GNU coreutils'",
        "test \"$(realpath -m -- \"$root/.symphony-missing/../.symphony-realpath-probe\")\" = \"$root/.symphony-realpath-probe\"",
        backend,
        "test \"${DOCKER_HOST:-unix:///var/run/docker.sock}\" = unix:///var/run/docker.sock",
        "test -S /var/run/docker.sock",
        "docker_root=$(docker --host unix:///var/run/docker.sock info --format '{{.DockerRootDir}}')",
        "test -n \"$docker_root\" && test -d \"$docker_root\" && test -w \"$docker_root\"",
        "docker_mount=$(findmnt -n -o TARGET -T \"$docker_root\"); test -n \"$docker_mount\" && test \"$docker_mount\" != /"
      ],
      "; "
    )
  end

  defp intent(adapter, config, record, desired, opts) do
    intent = %{desired: desired}
    intent = if record.terminal_observed_at, do: Map.put(intent, :terminal_observed_at, record.terminal_observed_at), else: intent

    case invoke(adapter, :put_intent, [config, record, intent], opts) do
      {:ok, latest} -> {:ok, latest}
      {:error, failure, latest} -> {:error, failure, latest}
      {:error, failure} -> {:error, failure, record}
    end
  end

  defp mutate(adapter, operation, config, record, opts) do
    case invoke(adapter, operation, [config, record], opts) do
      {:ok, latest} -> {:ok, latest}
      {:error, failure, latest} -> {:error, failure, latest}
      {:error, failure} -> {:error, failure, record}
    end
  end

  defp poll(adapter, config, record, expected, opts) do
    if remaining(opts) <= 0 do
      {:error, {:unknown, {:operation_timeout, expected}}, record}
    else
      case mutate(adapter, :inspect, config, record, opts) do
        {:ok, latest} ->
          continue_poll(adapter, config, latest, expected, opts)

        error ->
          error
      end
    end
  end

  defp continue_poll(adapter, config, record, expected, opts) do
    if reached?(record, expected) do
      {:ok, record}
    else
      sleep = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
      sleep.(min(1_000, remaining(opts)))
      poll(adapter, config, record, expected, opts)
    end
  end

  defp reached?(%Record{phase: :running, pending: pending}, :running), do: not Enum.any?(pending, &(&1.outcome in [:pending, :unknown]))
  defp reached?(%Record{proof: {:quiescent, evidence}, pending: pending}, :stopped), do: is_map(evidence) and map_size(evidence) > 0 and not Enum.any?(pending, &(&1.outcome in [:pending, :unknown]))
  defp reached?(%Record{absent?: true, pending: pending}, :absent), do: not Enum.any?(pending, &(&1.outcome in [:pending, :unknown]))
  defp reached?(_record, _expected), do: false

  defp invoke(adapter, operation, args, opts) do
    if remaining(opts) > 0 do
      apply(adapter, operation, args ++ [remaining_options(opts)])
    else
      {:error, {:unknown, {:operation_timeout, operation}}}
    end
  end

  defp deadline_options(config, operation, opts) do
    timeout = if operation in [:stop, :destroy], do: Map.get(config, :shutdown_timeout_ms, 60_000), else: Map.get(config, :startup_timeout_ms, 300_000)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    opts |> Keyword.put_new(:clock, clock) |> Keyword.put_new(:deadline, clock.() + Keyword.get(opts, :timeout_ms, timeout))
  end

  defp remaining_options(opts), do: Keyword.put(opts, :timeout_ms, remaining(opts))
  defp remaining(opts), do: max(Keyword.fetch!(opts, :deadline) - Keyword.fetch!(opts, :clock).(), 0)
  defp close_entry_connection(%Lifecycle.Entry{context: %{connection: %Connection{} = connection}}), do: close_connection(connection)
  defp close_entry_connection(_entry), do: :ok
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
