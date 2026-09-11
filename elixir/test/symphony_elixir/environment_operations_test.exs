defmodule SymphonyElixir.EnvironmentOperationsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ExecutionEnvironment.{Command, Lifecycle, Operations, Record}
  alias SymphonyElixir.SSH.Target

  defmodule Provider do
    def preflight(_config, opts), do: callback(opts, :preflight, nil)
    def discover(_config, opts), do: callback(opts, :discover, nil)
    def ensure(_config, record, opts), do: callback(opts, :ensure, record)
    def put_intent(_config, record, intent, opts), do: callback(opts, {:intent, intent}, record)
    def start(_config, record, opts), do: callback(opts, :start, record)
    def connect(_config, record, opts), do: callback(opts, :connect, record)
    def stop(_config, record, opts), do: callback(opts, :stop, record)
    def inspect(_config, record, opts), do: callback(opts, :inspect, record)
    def destroy(_config, record, opts), do: callback(opts, :destroy, record)
    defp callback(opts, operation, record), do: Keyword.fetch!(opts, :request_fun).(operation, record, opts)
  end

  defp record do
    %Record{
      key: "se-ticket",
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "kubernetes",
      scope: %{},
      workspace_path: "/state/workspaces/se-ticket",
      template_identity: "template-v1"
    }
  end

  test "blocked provider work does not block its orchestrator-style authority" do
    supervisor = start_supervised!(Task.Supervisor)
    owner = start_supervised!({Agent, fn -> :responsive end})
    parent = self()
    entry = Lifecycle.new(record(), "a", :agent)

    operation_fun = fn _, _, _, _, opts ->
      send(parent, {:blocked, self(), opts[:authority], opts[:task_supervisor]})

      receive do
        :finish -> {:error, {:unknown, :blocked}, entry.record}
      end
    end

    assert {:ok, task} = Operations.start(supervisor, Provider, %{}, entry, :prepare, authority: owner, operation_fun: operation_fun)
    assert_receive {:blocked, job, ^owner, ^supervisor}
    assert Agent.get(owner, & &1) == :responsive
    send(job, :finish)
    assert {nil, {:error, {:unknown, :blocked}, _}} = Task.await(task)
  end

  test "unknown discovery stays a tagged failure instead of empty inventory" do
    supervisor = start_supervised!(Task.Supervisor)
    request = fn :preflight, _, _ -> {:error, {:unknown, :timeout}} end
    assert {:ok, task, token} = Operations.discover(supervisor, Provider, %{startup_timeout_ms: 100}, authority: self(), request_fun: request)
    assert {^token, {:error, {:unknown, :timeout}}} = Task.await(task)
  end

  test "holder adopts ports and private files beyond the prepare task lifetime" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/usr/bin/ssh", prefix: ["worker"], label: "worker"}
    path = Path.join(System.tmp_dir!(), "symphony-lease-#{System.unique_integer([:positive])}")
    File.write!(path, "private")
    on_exit(fn -> File.rm(path) end)
    authority = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
        {:ok, lease} = Operations.open_connection(supervisor, authority, target, ports: [port], private_paths: [path])
        {lease, port}
      end)

    {lease, port} = Task.await(task)
    assert Port.info(port, :connected) == {:connected, lease.owner}
    assert GenServer.call(lease.owner, {:validate_connection, lease.id, target}) == :ok
    assert {:error, :invalid_connection} = GenServer.call(lease.owner, {:validate_connection, make_ref(), target})
    assert {:error, :invalid_connection} = Operations.close_connection(%{lease | id: make_ref()})
    assert :ok = Operations.close_connection(lease)
    assert Port.info(port) == nil
    refute File.exists?(path)
  end

  test "staged private paths are removed if the preparing donor dies before adoption" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    path = Path.join(System.tmp_dir!(), "symphony-staged-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "key"), "private")
    on_exit(fn -> File.rm_rf(path) end)

    donor =
      spawn(fn ->
        {:ok, lease} = Operations.stage_private_paths(supervisor, parent, self(), [path])
        send(parent, {:staged, lease})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:staged, {:staged_paths, owner, id}}
    monitor = Process.monitor(owner)
    assert {:error, :invalid_connection} = GenServer.call(owner, {:adopt_connection, id})
    assert {:error, :invalid_connection} = GenServer.call(owner, {:validate_connection, id, nil})
    Process.exit(donor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    refute File.exists?(path)
  end

  test "staged lease release is ID checked and authority death cleans unreleased paths" do
    supervisor = start_supervised!(Task.Supervisor)

    authority =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    path = Path.join(System.tmp_dir!(), "symphony-staged-authority-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, {:staged_paths, owner, id} = lease} = Operations.stage_private_paths(supervisor, authority, self(), [path])
    assert {:error, :invalid_connection} = Operations.release_staged_paths({:staged_paths, owner, make_ref()})
    assert File.dir?(path)
    assert :ok = Operations.release_staged_paths(lease)
    refute File.exists?(path)
    File.mkdir_p!(path)
    {:ok, {:staged_paths, next_owner, next_id}} = Operations.stage_private_paths(supervisor, authority, self(), [path])
    refute next_id == id
    monitor = Process.monitor(next_owner)
    send(authority, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^next_owner, _}
    refute File.exists?(path)
  end

  test "staged holder promotion preserves files and survives normal prepare completion" do
    supervisor = start_supervised!(Task.Supervisor)
    authority = self()
    target = %Target{executable: "/usr/bin/ssh", prefix: ["worker"], label: "worker"}
    path = Path.join(System.tmp_dir!(), "symphony-promoted-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "key"), "private")
    on_exit(fn -> File.rm_rf(path) end)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {:ok, {:staged_paths, owner, id} = stage} = Operations.stage_private_paths(supervisor, authority, self(), [path])
        {:ok, connection} = Operations.open_connection(supervisor, authority, target, private_paths: [path], staged_paths: stage)
        assert connection.owner == owner
        assert connection.id == id

        receive do
          :return -> connection
        end
      end)

    monitor = Process.monitor(task.pid)
    send(task.pid, :return)
    connection = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert File.read!(Path.join(path, "key")) == "private"
    assert :ok = GenServer.call(connection.owner, {:validate_connection, connection.id, target})
    assert :ok = Operations.close_connection(connection)
    refute File.exists?(path)
  end

  test "abnormal donor death after promotion cleans files and adopted tunnel" do
    supervisor = start_supervised!(Task.Supervisor)
    authority = self()
    target = %Target{executable: "/usr/bin/ssh", prefix: ["worker"], label: "worker"}
    path = Path.join(System.tmp_dir!(), "symphony-promoted-crash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    donor =
      spawn(fn ->
        {:ok, stage} = Operations.stage_private_paths(supervisor, authority, self(), [path])
        {:ok, port} = Operations.start_staged_port(stage, System.find_executable("cat"), [], [])
        {:ok, connection} = Operations.open_connection(supervisor, authority, target, ports: [port], private_paths: [path], staged_paths: stage)
        send(authority, {:promoted, connection, port})

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(donor, :kill) end)
    assert_receive {:promoted, connection, port}
    monitor = Process.monitor(connection.owner)
    Process.exit(donor, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    refute File.exists?(path)
    assert Port.info(port) == nil
  end

  test "staged holder owns tunnel before readiness and reaps it when donor dies" do
    supervisor = start_supervised!(Task.Supervisor)
    authority = self()
    path = Path.join(System.tmp_dir!(), "symphony-staged-port-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    donor =
      spawn(fn ->
        {:ok, {:staged_paths, owner, _} = stage} = Operations.stage_private_paths(supervisor, authority, self(), [path])
        {:ok, port} = Operations.start_staged_port(stage, "/bin/sh", ["-c", "printf ready; exec sleep 10"], [])

        receive do
          {^port, {:data, "ready"}} ->
            {:os_pid, pid} = Port.info(port, :os_pid)
            send(authority, {:staged_tunnel, owner, port, pid})
        end

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(donor, :kill) end)
    assert_receive {:staged_tunnel, owner, port, pid}
    assert Port.info(port, :connected) == {:connected, owner}
    monitor = Process.monitor(owner)
    Process.exit(donor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    refute File.exists?(path)
    assert Port.info(port) == nil
    {_diagnostic, status} = System.cmd(System.find_executable("kill"), ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    refute status == 0
  end

  test "promotion rejects mismatched authority paths and ID without destroying staged files" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/usr/bin/ssh", prefix: [], label: "worker"}
    path = Path.join(System.tmp_dir!(), "symphony-promotion-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    other_authority =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(other_authority, :kill) end)
    {:ok, {:staged_paths, owner, _id} = stage} = Operations.stage_private_paths(supervisor, self(), self(), [path])
    assert {:error, _} = Operations.open_connection(supervisor, other_authority, target, private_paths: [path], staged_paths: stage)
    assert {:error, _} = Operations.open_connection(supervisor, self(), target, private_paths: [], staged_paths: stage)
    assert {:error, _} = Operations.open_connection(supervisor, self(), target, private_paths: [path], staged_paths: {:staged_paths, owner, make_ref()})
    assert File.dir?(path)
    assert :ok = Operations.release_staged_paths(stage)
  end

  test "authority death invalidates lease and removes owned local resources" do
    supervisor = start_supervised!(Task.Supervisor)

    authority =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    target = %Target{executable: "/usr/bin/ssh", prefix: ["worker"], label: "worker"}
    {:ok, lease} = Operations.open_connection(supervisor, authority, target, [])
    monitor = Process.monitor(lease.owner)
    send(authority, :stop)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert {:error, :connection_closed} = Operations.close_connection(lease)
  end

  test "tunnel exit invalidates lease without proving remote compute quiescent" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/usr/bin/ssh", prefix: [], label: "worker"}
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
    {:ok, lease} = Operations.open_connection(supervisor, self(), target, ports: [port])
    monitor = Process.monitor(lease.owner)
    Port.close(port)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    entry = %{Lifecycle.new(record(), "a", :agent) | phase: :unknown}
    assert Lifecycle.occupied?(entry)
  end

  test "stop preserves latest unresolved start evidence and cannot release on local cleanup" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/usr/bin/ssh", prefix: [], label: "worker"}
    {:ok, lease} = Operations.open_connection(supervisor, self(), target, [])
    pending = %{record() | pending: [%{verb: :start, id: "late-start", outcome: :unknown}]}
    entry = %{Lifecycle.new(pending, "a", :agent) | context: %{connection: lease}}

    request = fn
      {:intent, %{desired: :stopped}}, record, _ -> {:ok, %{record | desired: :stopped}}
      :stop, record, _ -> {:error, {:unknown, :still_starting}, record}
    end

    assert {:error, {:unknown, :still_starting}, latest} = Operations.run(Provider, %{shutdown_timeout_ms: 100}, entry, :stop, request_fun: request)
    assert latest.pending == pending.pending
    assert latest.proof == :unknown
    assert {:error, :connection_closed} = Operations.close_connection(lease)
  end

  test "readiness rejects incompatible realpath behavior and retains latest running resource for stop" do
    supervisor = start_supervised!(Task.Supervisor)
    root = Path.join(System.tmp_dir!(), "environment-ready-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    shell_env = Path.join(root, "worker-environment")
    probe_observation = Path.join(root, "realpath-behavior-observed")

    File.write!(shell_env, """
    findmnt() { printf '/persistent\\n'; }
    realpath() {
      if [ "$1" = --version ]; then printf 'GNU coreutils\\n'; else printf called > "$SYMPHONY_REALPATH_PROBE"; printf '/incorrect-result\\n'; fi
    }
    """)

    target = %Target{executable: "/bin/sh", prefix: ["-c", "eval \"$1\"", "fake-ssh"], label: "worker", env: [{"BASH_ENV", shell_env}, {"SYMPHONY_REALPATH_PROBE", probe_observation}]}
    {config, entry} = preparation(root)
    parent = self()
    request = prepare_request(supervisor, target, parent)

    assert {:error, {:invalid, :worker_readiness}, latest} =
             Operations.run(Provider, config, entry, :prepare, task_supervisor: supervisor, authority: self(), agent_executable: "sh", request_fun: request)

    assert latest.phase == :running
    assert latest.version == "observed-running"
    assert latest.proof == :unknown
    assert_receive {:connected, lease}
    assert {:error, :connection_closed} = Operations.close_connection(lease)
    assert File.read!(probe_observation) == "called"
    refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".symphony-readiness."))
  end

  test "successful readiness captures context while transport timeout closes only the local lease" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/usr/bin/ssh", prefix: ["worker"], label: "worker"}
    {config, entry} = preparation("/state/workspaces")
    request = prepare_request(supervisor, target, self())
    opts = [task_supervisor: supervisor, authority: self(), agent_executable: "codex", request_fun: request]
    assert {:ok, context} = Operations.run(Provider, config, entry, :prepare, Keyword.put(opts, :command_fun, fn _, _, _ -> {:ok, %{output: "", status: 0}} end))
    assert context.environment.record.version == "observed-running"
    assert :ok = GenServer.call(context.connection.owner, {:validate_connection, context.connection.id, target})
    assert :ok = Operations.close_connection(context.connection)
    assert_receive {:connected, _}
    assert {:error, {:unknown, _}, latest} = Operations.run(Provider, config, entry, :prepare, Keyword.put(opts, :command_fun, fn _, _, _ -> {:error, {:unknown, :timeout}} end))
    assert latest.version == "observed-running"
    assert_receive {:connected, failed_lease}
    assert {:error, :connection_closed} = Operations.close_connection(failed_lease)
    assert latest.proof == :unknown
  end

  test "cleanup purpose does not require the selected agent executable" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/usr/bin/ssh", prefix: ["worker"], label: "worker"}
    {config, entry} = preparation("/state/workspaces")
    request = prepare_request(supervisor, target, self())
    opts = [task_supervisor: supervisor, authority: self(), request_fun: request, command_fun: fn _, _, _ -> {:ok, %{output: "", status: 0}} end]
    assert {:error, {:invalid, :agent_executable}, _} = Operations.run(Provider, config, entry, :prepare, opts)
    assert {:ok, context} = Operations.run(Provider, config, %{entry | purpose: :cleanup}, :prepare, opts)
    assert :ok = Operations.close_connection(context.connection)
  end

  test "prepare publishes current attempt intent before a start that rejects stale durable routing" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/usr/bin/ssh", prefix: ["worker"], label: "worker"}
    {config, entry} = preparation("/state/workspaces")
    entry = %{entry | attempt_id: "current-attempt", record: %{entry.record | issue_state: "In Review", issue_identifier: "ISSUE-42"}}
    fallback = prepare_request(supervisor, target, self())

    request = fn
      :ensure, record, _ ->
        {:ok,
         %{
           record
           | attempt_id: "durable-old-attempt",
             issue_state: "Implemented",
             issue_identifier: "OLD-7",
             template_identity: "retained-template",
             workspace_path: "/state/workspaces/retained-ticket",
             terminal_observed_at: 123
         }}

      {:intent, %{desired: :running, terminal_observed_at: 123}}, %{attempt_id: "current-attempt", issue_state: "In Review", issue_identifier: "ISSUE-42"} = record, _ ->
        {:ok, %{record | desired: :running, metadata: Map.put(record.metadata, "accepted_attempt", "current-attempt")}}

      {:intent, _}, record, _ ->
        {:error, {:denied, :stale_attempt_intent}, record}

      :start, %{attempt_id: "current-attempt", issue_state: "In Review", issue_identifier: "ISSUE-42", metadata: %{"accepted_attempt" => "current-attempt"}} = record, _ ->
        {:ok, %{record | phase: :running}}

      :start, record, _ ->
        {:error, {:denied, :stale_attempt_start}, record}

      operation, record, opts ->
        fallback.(operation, record, opts)
    end

    assert {:ok, context} =
             Operations.run(Provider, config, entry, :prepare,
               task_supervisor: supervisor,
               authority: self(),
               request_fun: request,
               agent_executable: "claude",
               command_fun: fn _, _, _ -> {:ok, %{output: "", status: 0}} end
             )

    assert context.workspace_path == "/state/workspaces/retained-ticket"
    assert context.environment.record.template_identity == "retained-template"
    assert context.environment.record.terminal_observed_at == 123
    assert :ok = Operations.close_connection(context.connection)
  end

  defp preparation(root) do
    config = %{
      kind: "kubernetes",
      deployment_id: "deployment",
      tracker_kind: "memory",
      workspace_root: root,
      provider: %{
        "kubeconfig" => "/operator/config",
        "context" => "test",
        "namespace" => "workers",
        "template" => "/operator/template",
        "ssh_user" => "worker",
        "ssh_auth_volume" => "key",
        "ssh_port" => 2222
      },
      startup_timeout_ms: 5_000,
      shutdown_timeout_ms: 5_000,
      terminal_retention_ms: 0
    }

    record = %{
      record()
      | key: SymphonyElixir.ExecutionEnvironment.resource_key("deployment", "memory", "ticket"),
        scope: SymphonyElixir.ExecutionEnvironment.Config.scope(config),
        workspace_path: Path.join(root, "ticket")
    }

    {config, Lifecycle.new(record, "attempt", :agent)}
  end

  defp prepare_request(supervisor, target, parent) do
    fn
      :ensure, record, _ ->
        {:ok, record}

      {:intent, %{desired: :running}}, record, _ ->
        {:ok, %{record | desired: :running}}

      :start, record, _ ->
        {:ok, %{record | phase: :running}}

      :inspect, record, _ ->
        {:ok, %{record | version: "observed-running"}}

      :connect, _, opts ->
        {:ok, lease} = Operations.open_connection(supervisor, opts[:authority], target, [])
        send(parent, {:connected, lease})
        {:ok, lease}
    end
  end

  test "poll deadline returns the newest unresolved observation without clearing terminal time" do
    clock = start_supervised!({Agent, fn -> 0 end})
    pending = %{record() | terminal_observed_at: 1_000, pending: [%{verb: :stop, id: "stop", outcome: :pending}]}
    entry = Lifecycle.new(pending, "a", :cleanup)

    request = fn
      {:intent, %{desired: :stopped, terminal_observed_at: 1_000}}, record, _ -> {:ok, record}
      :stop, record, _ -> {:ok, record}
      :inspect, record, opts -> {:ok, %{record | version: opts[:timeout_ms]}}
    end

    opts = [request_fun: request, clock: fn -> Agent.get(clock, & &1) end, sleep_fun: fn milliseconds -> Agent.update(clock, &(&1 + milliseconds)) end]
    assert {:error, {:unknown, {:operation_timeout, :stopped}}, latest} = Operations.run(Provider, %{shutdown_timeout_ms: 1_500}, entry, :stop, opts)
    assert latest.version == 500
    assert latest.pending == pending.pending
    assert latest.terminal_observed_at == 1_000
  end

  test "argv helper does not interpret shell metacharacters and bounds diagnostics" do
    supervisor = start_supervised!(Task.Supervisor)
    assert {:ok, %{output: "$(echo forbidden)", status: 0}} = Command.run(System.find_executable("printf"), ["%s", "$(echo forbidden)"], task_supervisor: supervisor, timeout_ms: 1_000)

    assert {:error, {:unknown, {:output_limit, output}}} =
             Command.run(System.find_executable("printf"), ["%s", String.duplicate("x", 100)], task_supervisor: supervisor, timeout_ms: 1_000, max_output_bytes: 8)

    assert byte_size(output) <= 8
    assert {:error, {:unknown, {:timeout, _}}} = Command.run(System.find_executable("sleep"), ["10"], task_supervisor: supervisor, timeout_ms: 10)
  end

  test "command timeout reaps the known local process rather than just closing its port" do
    supervisor = start_supervised!(Task.Supervisor)
    assert {:error, {:unknown, {:timeout, output}}} = Command.run("/bin/sh", ["-c", "printf '%s\\n' \"$$\"; exec sleep 10"], task_supervisor: supervisor, timeout_ms: 200)
    pid = output |> String.trim() |> String.to_integer()
    assert pid > 0
    {_diagnostic, status} = System.cmd(System.find_executable("kill"), ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    refute status == 0
  end

  test "JSON request bodies are private and removed even when the consumer raises" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    assert_raise RuntimeError, fn ->
      Command.with_json_file(
        %{"safe" => true},
        fn path ->
          send(parent, {:private_file, path})
          assert {:ok, %{mode: mode}} = File.stat(path)
          assert Bitwise.band(mode, 0o777) == 0o600
          assert Jason.decode!(File.read!(path)) == %{"safe" => true}
          raise "consumer failure"
        end, task_supervisor: supervisor)
    end

    assert_receive {:private_file, path}
    refute File.exists?(path)
  end

  test "brutal command caller cancellation reaps its already-started OS child" do
    supervisor = start_supervised!(Task.Supervisor)
    root = Path.join(System.tmp_dir!(), "symphony-command-cancel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    pid_path = Path.join(root, "pid")
    authority = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Command.run("/bin/sh", ["-c", "printf '%s\\n' \"$$\" > \"$PID_FILE\"; exec sleep 30"], task_supervisor: supervisor, authority: authority, timeout_ms: 30_000, env: [{"PID_FILE", pid_path}])
      end)

    eventually(fn -> match?({:ok, content} when byte_size(content) > 0, File.read(pid_path)) end)
    pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()
    assert {_diagnostic, 0} = System.cmd(System.find_executable("kill"), ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    Task.shutdown(task, :brutal_kill)
    eventually(fn -> elem(System.cmd(System.find_executable("kill"), ["-0", Integer.to_string(pid)], stderr_to_stdout: true), 1) != 0 end)
    eventually(fn -> Task.Supervisor.children(supervisor) == [] end)
  end

  test "brutal JSON callback cancellation removes the protected request directory" do
    supervisor = start_supervised!(Task.Supervisor)
    authority = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Command.with_json_file(
          %{"secret" => "private"},
          fn path ->
            send(authority, {:json_callback_blocked, path})

            receive do
              :finish -> :ok
            end
          end, task_supervisor: supervisor, authority: authority)
      end)

    assert_receive {:json_callback_blocked, path}
    assert Jason.decode!(File.read!(path)) == %{"secret" => "private"}
    Task.shutdown(task, :brutal_kill)
    eventually(fn -> not File.exists?(Path.dirname(path)) end)
    eventually(fn -> Task.Supervisor.children(supervisor) == [] end)
  end

  test "staged directory creation is private and rejects a path outside the lease" do
    supervisor = start_supervised!(Task.Supervisor)
    directory = Path.join(System.tmp_dir!(), "symphony-owned-directory-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(directory) end)
    {:ok, lease} = Operations.stage_private_paths(supervisor, self(), self(), [directory])
    assert {:error, _} = Operations.create_staged_directory(lease, directory <> "-unowned")
    refute File.exists?(directory <> "-unowned")
    assert :ok = Operations.create_staged_directory(lease, directory)
    assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700
    assert :ok = Operations.release_staged_paths(lease)
    refute File.exists?(directory)
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    unless fun.() do
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end
end
