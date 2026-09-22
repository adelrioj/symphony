defmodule SymphonyElixir.EnvironmentOperationsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ExecutionEnvironment.{Command, Config, Lifecycle, Operations, Record}
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
    opts = [authority: self(), request_fun: request]
    assert {:ok, task, token} = Operations.discover(supervisor, Provider, %{startup_timeout_ms: 100}, opts)
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
        {:ok, stage} = Operations.stage_private_paths(supervisor, authority, self(), [path])
        opts = [private_paths: [path], staged_paths: stage]
        {:ok, connection} = Operations.open_connection(supervisor, authority, target, opts)

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
        opts = [ports: [port], private_paths: [path], staged_paths: stage]
        {:ok, connection} = Operations.open_connection(supervisor, authority, target, opts)
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
    opts = [private_paths: [path], staged_paths: stage]
    assert {:error, _} = Operations.open_connection(supervisor, other_authority, target, opts)
    assert {:error, _} = Operations.open_connection(supervisor, self(), target, Keyword.put(opts, :private_paths, []))
    invalid = Keyword.put(opts, :staged_paths, {:staged_paths, owner, make_ref()})
    assert {:error, _} = Operations.open_connection(supervisor, self(), target, invalid)
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
    ready = fn _, _, _ -> {:ok, %{output: "", status: 0}} end
    opts = [task_supervisor: supervisor, authority: self(), request_fun: request, command_fun: ready]
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

      {:intent, %{desired: :running, terminal_observed_at: 123}}, record, _ ->
        publish_current_intent(record)

      {:intent, _}, record, _ ->
        {:error, {:denied, :stale_attempt_intent}, record}

      :start, record, _ ->
        start_current_attempt(record)

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

  defp current_attempt?(record) do
    current = record.attempt_id == "current-attempt" and record.issue_state == "In Review"
    current and record.issue_identifier == "ISSUE-42"
  end

  defp publish_current_intent(record) do
    if current_attempt?(record) do
      metadata = Map.put(record.metadata, "accepted_attempt", "current-attempt")
      {:ok, %{record | desired: :running, metadata: metadata}}
    else
      {:error, {:denied, :stale_attempt_intent}, record}
    end
  end

  defp start_current_attempt(record) do
    if current_attempt?(record) and record.metadata["accepted_attempt"] == "current-attempt" do
      {:ok, %{record | phase: :running}}
    else
      {:error, {:denied, :stale_attempt_start}, record}
    end
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
        scope: Config.scope(config),
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
        end,
        task_supervisor: supervisor
      )
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
          end,
          task_supervisor: supervisor,
          authority: authority
        )
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

  test "discovery reads retained inventory only after successful preflight" do
    inventory = start_supervised!({Agent, fn -> %{authorized?: false, records: [record()]} end})
    supervisor = start_supervised!(Task.Supervisor)

    request = fn
      :preflight, _, _ ->
        Agent.update(inventory, &%{&1 | authorized?: true})

      :discover, _, _ ->
        Agent.get(inventory, fn
          %{authorized?: true, records: records} -> {:ok, records}
          _ -> {:error, {:denied, :preflight_required}}
        end)
    end

    {:ok, task, token} = Operations.discover(supervisor, Provider, %{}, request_fun: request)
    assert {^token, {:ok, [retained]}} = Task.await(task)
    assert retained.key == "se-ticket"
  end

  test "destroy waits for settled absence instead of accepting a pending deletion observation" do
    root = temporary_path("destroy")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "retained"), "disk")
    state = start_supervised!({Agent, fn -> %{desired: :stopped, inspections: 0} end})
    entry = Lifecycle.new(%{record() | terminal_observed_at: 123}, "a", :cleanup)

    request = fn
      {:intent, %{desired: desired, terminal_observed_at: 123}}, current, _ ->
        Agent.update(state, &%{&1 | desired: desired})
        {:ok, %{current | desired: desired}}

      :destroy, current, _ ->
        assert Agent.get(state, & &1.desired) == :absent
        File.rm_rf!(root)
        {:ok, %{current | pending: [%{verb: :destroy, id: "delete", outcome: :pending}]}}

      :inspect, current, _ ->
        count = Agent.get_and_update(state, &{&1.inspections + 1, %{&1 | inspections: &1.inspections + 1}})
        pending = if count == 1, do: current.pending, else: []
        {:ok, %{current | absent?: not File.exists?(root), pending: pending}}
    end

    opts = [request_fun: request, sleep_fun: fn _ -> :ok end]
    assert {:ok, absent} = Operations.run(Provider, %{}, entry, :destroy, opts)
    refute File.exists?(root)
    assert absent.absent?
    assert absent.pending == []
    assert Agent.get(state, & &1.inspections) == 2
  end

  test "stop needs qualified quiescence even when the provider reports stopped" do
    state = start_supervised!({Agent, fn -> 0 end})
    entry = Lifecycle.new(record(), "a", :cleanup)

    request = fn
      {:intent, %{desired: :stopped}}, current, _ ->
        {:ok, %{current | desired: :stopped}}

      :stop, current, _ ->
        {:ok, %{current | phase: :stopped}}

      :inspect, current, _ ->
        count = Agent.get_and_update(state, &{&1 + 1, &1 + 1})
        proof = if count == 1, do: {:quiescent, %{}}, else: {:quiescent, %{workers: []}}
        {:ok, %{current | proof: proof}}
    end

    assert {:ok, stopped} =
             Operations.run(Provider, %{}, entry, :stop, request_fun: request, sleep_fun: fn _ -> :ok end)

    {stopping, [{:provider, :stop, id}]} = Lifecycle.step(entry, {:cancel, :denied}, 0)
    {released, [{:release, :denied}]} = Lifecycle.step(stopping, {:stopped, id, stopped}, 1)
    refute Lifecycle.occupied?(released)
    assert Agent.get(state, & &1) == 2
  end

  test "metadata failures retain durable uncertainty for subsequent inspection" do
    durable = start_supervised!({Agent, fn -> record() end})
    entry = %{Lifecycle.new(record(), "a", :cleanup) | metadata_intent: %{terminal_observed_at: 123}}

    request = fn
      {:intent, %{terminal_observed_at: stamp}}, current, _ ->
        latest = %{current | terminal_observed_at: stamp, pending: [%{verb: :metadata, id: "write", outcome: :unknown}]}
        Agent.update(durable, fn _ -> latest end)
        {:error, {:unknown, :metadata_response_lost}, latest}

      :inspect, _, _ ->
        {:ok, Agent.get(durable, &%{&1 | pending: []})}
    end

    assert {:error, {:unknown, :metadata_response_lost}, latest} =
             Operations.run(Provider, %{}, entry, :metadata, request_fun: request)

    {updating, _} = Lifecycle.step(entry, {:reconcile, :metadata}, 0)
    {unknown, []} = Lifecycle.step(updating, {:failed, updating.operation_id, :unknown, latest}, 1)
    refute Lifecycle.deletion_due?(unknown.record, :terminal, 10, 132)
    assert {:ok, observed} = Operations.run(Provider, %{}, unknown, :inspect, request_fun: request)
    assert Lifecycle.deletion_due?(observed, :terminal, 10, 133)
    assert observed.pending == []
  end

  test "failure without a newer record cannot erase terminal retention or permit deletion" do
    retained = %{record() | terminal_observed_at: 123, pending: [%{verb: :start, id: "start", outcome: :unknown}]}
    entry = Lifecycle.new(retained, "a", :cleanup)
    request = fn _, _, _ -> {:error, {:denied, :credentials}} end

    for operation <- [:metadata, :stop, :inspect] do
      assert {:error, {:denied, :credentials}, latest} =
               Operations.run(Provider, %{}, entry, operation, request_fun: request)

      {active, _} = Lifecycle.step(entry, {:reconcile, operation}, 0)
      {unknown, []} = Lifecycle.step(active, {:failed, active.operation_id, :denied, latest}, 1)
      assert Lifecycle.occupied?(unknown)
      refute Lifecycle.deletion_due?(unknown.record, :terminal, 10, 132)
      assert Lifecycle.deletion_due?(unknown.record, :terminal, 10, 133)
    end
  end

  test "polling failure retains the last mutation and metadata success is durable" do
    durable = start_supervised!({Agent, fn -> record() end})
    entry = %{Lifecycle.new(record(), "a", :cleanup) | metadata_intent: %{terminal_observed_at: 123}}

    request = fn
      {:intent, intent}, current, _ ->
        latest = struct!(current, intent)
        Agent.update(durable, fn _ -> latest end)
        {:ok, latest}

      :destroy, current, _ ->
        latest = %{current | pending: [%{verb: :destroy, id: "disk", outcome: :unknown}]}
        Agent.update(durable, fn _ -> latest end)
        {:ok, latest}

      :inspect, _, _ ->
        {:error, {:retryable, :unavailable}}
    end

    assert {:ok, stamped} = Operations.run(Provider, %{}, entry, :metadata, request_fun: request)
    assert Lifecycle.deletion_due?(Agent.get(durable, & &1), :terminal, 0, 123)

    assert {:error, {:retryable, :unavailable}, latest} =
             Operations.run(Provider, %{}, %{entry | record: stamped}, :destroy, request_fun: request)

    assert latest.pending == [%{verb: :destroy, id: "disk", outcome: :unknown}]
    assert latest.desired == :absent
    assert Lifecycle.deletion_due?(latest, :terminal, 0, 123)
  end

  test "invalid operations and rejected holders cannot create resources" do
    supervisor = start_supervised!(Task.Supervisor)
    path = temporary_path("rejected")
    target = %Target{executable: "/bin/sh", prefix: [], label: "local-owned"}
    assert {:error, {:invalid, :environment_operation}} = Operations.run(Provider, %{}, nil, :invalid, [])

    assert {:error, {:invalid, :environment_operation}, _} =
             Operations.run(Provider, %{}, Lifecycle.new(record(), "a", :cleanup), :invalid, [])

    assert {:error, {:invalid, :connection_authority}} =
             Operations.stage_private_paths(supervisor, nil, self(), [path])

    assert {:error, {:invalid, :connection_authority}} = Operations.open_connection(supervisor, nil, target, [])

    assert {:error, {:invalid, :staged_paths}} =
             Operations.open_connection(supervisor, self(), target, staged_paths: :invalid)

    refute File.exists?(path)
    assert Task.Supervisor.children(supervisor) == []
  end

  test "supervisor rejection and failed executables leave no staged resources" do
    supervisor = start_supervised!({Task.Supervisor, max_children: 0})

    assert {:error, {:unknown, :connection_holder_failed}} =
             Operations.stage_private_paths(supervisor, self(), self(), [])

    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}
    assert {:error, {:unknown, :connection_holder_failed}} = Operations.open_connection(supervisor, self(), target, [])

    assert {:error, {:unknown, :command_resource_owner}} =
             Command.run("/bin/sh", ["-c", "exit 0"], task_supervisor: supervisor, timeout_ms: 100)

    assert Task.Supervisor.children(supervisor) == []
  end

  test "failed port creation keeps the lease usable and closed leases reject further work" do
    supervisor = start_supervised!(Task.Supervisor)
    directory = temporary_path("failed-port")
    {:ok, lease} = Operations.stage_private_paths(supervisor, self(), self(), [directory])

    assert {:error, {:unknown, :staged_port_failed}} =
             Operations.start_staged_port(lease, Path.join(directory, "missing"), [], [])

    assert :ok = Operations.create_staged_directory(lease, directory)

    assert {:error, {:unknown, :private_directory_creation_failed}} =
             Operations.create_staged_directory(lease, directory)

    assert :ok = Operations.release_staged_paths(lease)
    refute File.exists?(directory)
    assert {:error, :connection_closed} = Operations.release_staged_paths(lease)

    assert {:error, {:unknown, :private_directory_creation_failed}} =
             Operations.create_staged_directory(lease, directory)

    assert {:error, {:unknown, :staged_port_failed}} = Operations.start_staged_port(lease, "/bin/sh", [], [])
    refute File.exists?(directory)

    assert {:error, {:unknown, :command_failed}} =
             Command.run(Path.join(directory, "missing"), [], task_supervisor: supervisor, timeout_ms: 100)

    eventually(fn -> Task.Supervisor.children(supervisor) == [] end)
  end

  test "authority loss during JSON consumption cannot return success after losing cleanup ownership" do
    supervisor = start_supervised!(Task.Supervisor)

    authority =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(authority)
    parent = self()

    result =
      Command.with_json_file(
        %{"private" => true},
        fn path ->
          send(parent, {:owned_json, path})
          send(authority, :stop)
          assert_receive {:DOWN, ^monitor, :process, ^authority, :normal}
          eventually(fn -> not File.exists?(Path.dirname(path)) end)
          :success
        end,
        task_supervisor: supervisor,
        authority: authority
      )

    assert {:error, {:unknown, :local_cleanup_unconfirmed}} = result
    assert_receive {:owned_json, path}
    refute File.exists?(Path.dirname(path))
  end

  test "invalid execution identity releases a newly adopted connection without losing running evidence" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}
    {config, entry} = preparation("/state/workspaces")
    entry = %{entry | record: %{entry.record | key: "wrong-identity"}}
    request = prepare_request(supervisor, target, self())

    assert {:error, {:invalid, :managed_execution_context}, latest} =
             Operations.run(Provider, config, entry, :prepare, task_supervisor: supervisor, authority: self(), request_fun: request, agent_executable: "sh")

    assert latest.phase == :running
    assert_receive {:connected, lease}
    assert {:error, :connection_closed} = Operations.close_connection(lease)
    assert Lifecycle.occupied?(Lifecycle.new(latest, "a", :cleanup))
  end

  test "provider exceptions still release the stop operation's private connection" do
    supervisor = start_supervised!(Task.Supervisor)
    path = temporary_path("stop-exception")
    File.write!(path, "private")
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}
    {:ok, lease} = Operations.open_connection(supervisor, self(), target, private_paths: [path])
    entry = %{Lifecycle.new(record(), "a", :cleanup) | context: %{connection: lease}}

    request = fn
      {:intent, %{desired: :stopped}}, current, _ -> {:ok, %{current | desired: :stopped}}
      :stop, _, _ -> raise "provider crashed"
    end

    assert_raise RuntimeError, "provider crashed", fn ->
      Operations.run(Provider, %{}, entry, :stop, request_fun: request)
    end

    refute File.exists?(path)
    assert {:error, :connection_closed} = Operations.close_connection(lease)
    assert Lifecycle.occupied?(entry)
  end

  test "dead supervisors and authorities fail closed without taking an existing private file" do
    supervisor = start_supervised!(Task.Supervisor)
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    path = temporary_path("dead-owner")
    File.write!(path, "private")
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}

    assert {:error, {:invalid, :connection_authority}} =
             Operations.stage_private_paths(supervisor, dead, self(), [path])

    assert {:error, {:invalid, :connection_authority}} =
             Operations.open_connection(supervisor, dead, target, private_paths: [path])

    assert {:error, {:unknown, :private_paths_staging_failed}} =
             Operations.stage_private_paths(dead, self(), self(), [path])

    assert {:error, {:unknown, :connection_adoption_failed}} =
             Operations.open_connection(dead, self(), target, private_paths: [path])

    assert {:error, _} = Operations.open_connection(supervisor, self(), target, ports: [123])

    assert File.read!(path) == "private"
    assert Task.Supervisor.children(supervisor) == []
  end

  test "exited staged transports cannot be promoted and retain keys until explicit cleanup" do
    supervisor = start_supervised!(Task.Supervisor)
    directory = temporary_path("exited-stage")
    {:ok, stage} = Operations.stage_private_paths(supervisor, self(), self(), [directory])
    assert :ok = Operations.create_staged_directory(stage, directory)
    File.write!(Path.join(directory, "key"), "private")
    {:ok, port} = Operations.start_staged_port(stage, "/bin/sh", ["-c", "exit 0"], retain_on_exit: true)
    assert_receive {^port, {:exit_status, 0}}
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}
    opts = [ports: [port], private_paths: [directory], staged_paths: stage]
    assert {:error, {:invalid, :staged_paths}} = Operations.open_connection(supervisor, self(), target, opts)
    assert File.read!(Path.join(directory, "key")) == "private"
    assert :ok = Operations.release_staged_paths(stage)
    refute File.exists?(directory)
  end

  test "a different donor cannot start commands using a staged lease" do
    supervisor = start_supervised!(Task.Supervisor)
    path = temporary_path("foreign-donor")
    {:ok, stage} = Operations.stage_private_paths(supervisor, self(), self(), [])
    args = ["-c", "printf forbidden > \"$OUTPUT\"", "owned"]
    opts = [env: [{"OUTPUT", path}]]
    task = Task.async(fn -> Operations.start_staged_port(stage, "/bin/sh", args, opts) end)
    assert {:error, :invalid_connection} = Task.await(task)
    refute File.exists?(path)
    {:ok, port} = Operations.start_staged_port(stage, "/bin/sh", ["-c", "printf owned"], retain_on_exit: true)
    assert_receive {^port, {:data, "owned"}}
    assert_receive {^port, {:exit_status, 0}}
    assert :ok = Operations.release_staged_paths(stage)
  end

  test "connection denial and readiness process loss retain running capacity" do
    supervisor = start_supervised!(Task.Supervisor)
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}
    {config, entry} = preparation("/state/workspaces")
    fallback = prepare_request(supervisor, target, self())

    request = fn
      :connect, _, _ -> {:error, {:denied, :connection_permission}}
      operation, current, opts -> fallback.(operation, current, opts)
    end

    opts = [task_supervisor: supervisor, authority: self(), agent_executable: "sh", request_fun: request]

    assert {:error, {:denied, :connection_permission}, denied} =
             Operations.run(Provider, config, entry, :prepare, opts)

    assert denied.phase == :running
    assert Lifecycle.occupied?(Lifecycle.new(denied, "a", :cleanup))
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    command = fn _, _, _ -> GenServer.call(dead, :readiness) end
    opts = Keyword.merge(opts, request_fun: fallback, command_fun: command)

    assert {:error, {:unknown, :connection_closed}, latest} =
             Operations.run(Provider, config, entry, :prepare, opts)

    assert latest.phase == :running
    assert_receive {:connected, lease}
    assert {:error, :connection_closed} = Operations.close_connection(lease)
    assert Lifecycle.occupied?(Lifecycle.new(latest, "a", :cleanup))
  end

  test "holder startup cannot acquire authority that dies while the supervisor is unavailable" do
    supervisor = start_supervised!(Task.Supervisor)

    authority =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    path = temporary_path("startup-authority")
    File.write!(path, "private")
    assert :ok = :sys.suspend(supervisor)
    caller = Task.async(fn -> Operations.stage_private_paths(supervisor, authority, self(), [path]) end)

    try do
      eventually(fn -> queued_call?(supervisor, caller.pid) end)
      monitor = Process.monitor(authority)
      send(authority, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^authority, :normal}
    after
      :sys.resume(supervisor)
    end

    assert {:error, _} = Task.await(caller)
    eventually(fn -> not File.exists?(path) end)
  end

  test "connection transfer rejects authority loss during supervised holder startup" do
    supervisor = start_supervised!(Task.Supervisor)

    authority =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    path = temporary_path("transfer-authority")
    File.write!(path, "private")
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}
    parent = self()
    assert :ok = :sys.suspend(supervisor)

    caller =
      Task.async(fn ->
        port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
        send(parent, {:transferring_port, port})
        Operations.open_connection(supervisor, authority, target, ports: [port], private_paths: [path])
      end)

    try do
      eventually(fn -> queued_call?(supervisor, caller.pid) end)
      monitor = Process.monitor(authority)
      send(authority, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^authority, :normal}
    after
      :sys.resume(supervisor)
    end

    assert {:error, _} = Task.await(caller)
    assert_receive {:transferring_port, port}
    eventually(fn -> Port.info(port) == nil and not File.exists?(path) end)
  end

  test "loss of a staged authority before acknowledgement rejects access and cleans private files" do
    supervisor = start_supervised!(Task.Supervisor)

    authority =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    path = temporary_path("stage-ack")
    File.write!(path, "private")

    {caller, owner} =
      paused_holder_start(supervisor, fn ->
        Operations.stage_private_paths(supervisor, authority, self(), [path])
      end)

    assert true = :erlang.suspend_process(owner)
    on_exit(fn -> resume_owned_process(owner) end)
    assert true = :erlang.resume_process(caller.pid)
    eventually(fn -> queued_call?(owner, caller.pid) end)
    authority_ref = Process.monitor(authority)
    send(authority, :finish)
    assert_receive {:DOWN, ^authority_ref, :process, ^authority, :normal}
    assert true = :erlang.resume_process(owner)
    assert {:error, _} = Task.await(caller)
    eventually(fn -> not File.exists?(path) end)
  end

  test "a staged owner lost before its acknowledgement call still rejects access and cleans files" do
    supervisor = start_supervised!(Task.Supervisor)
    authority = spawn(fn -> receive do: (:finish -> :ok) end)
    path = temporary_path("stage-owner-lost")
    File.write!(path, "private")

    {caller, owner} =
      paused_holder_start(supervisor, fn ->
        Operations.stage_private_paths(supervisor, authority, self(), [path])
      end)

    monitor = Process.monitor(owner)
    send(authority, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert true = :erlang.resume_process(caller.pid)
    assert {:error, _} = Task.await(caller)
    refute File.exists?(path)
  end

  test "adoption acknowledgement cannot revive a connection after its authority exits" do
    supervisor = start_supervised!(Task.Supervisor)

    authority =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    path = temporary_path("adoption-ack")
    File.write!(path, "private")
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}

    {caller, owner} =
      paused_holder_start(supervisor, fn ->
        Operations.open_connection(supervisor, authority, target, private_paths: [path])
      end)

    assert true = :erlang.suspend_process(owner)
    on_exit(fn -> resume_owned_process(owner) end)
    assert true = :erlang.resume_process(caller.pid)
    eventually(fn -> queued_call?(owner, caller.pid) end)
    authority_ref = Process.monitor(authority)
    send(authority, :finish)
    assert_receive {:DOWN, ^authority_ref, :process, ^authority, :normal}
    assert true = :erlang.resume_process(owner)
    assert {:error, _} = Task.await(caller)
    eventually(fn -> not File.exists?(path) end)
    refute Process.alive?(owner)
  end

  test "adoption timeout releases the holder after it resumes instead of retaining private files" do
    supervisor = start_supervised!(Task.Supervisor)
    authority = self()
    path = temporary_path("adoption-timeout")
    File.write!(path, "private")
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}

    {caller, owner} =
      paused_holder_start(supervisor, fn ->
        Operations.open_connection(supervisor, authority, target, private_paths: [path])
      end)

    monitor = Process.monitor(owner)
    assert true = :erlang.suspend_process(owner)
    assert true = :erlang.resume_process(caller.pid)
    assert {:error, {:unknown, :connection_adoption_failed}} = Task.await(caller, 5_000)
    assert File.read!(path) == "private"
    assert true = :erlang.resume_process(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    refute File.exists?(path)
  end

  test "a port closed during supervised transfer cannot produce a connection" do
    supervisor = start_supervised!(Task.Supervisor)
    path = temporary_path("closed-transfer")
    File.write!(path, "private")
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}
    authority = self()

    {caller, owner} =
      paused_holder_start(supervisor, fn ->
        port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
        send(authority, {:transfer_port, port})
        Operations.open_connection(supervisor, authority, target, ports: [port], private_paths: [path])
      end)

    assert_receive {:transfer_port, port}
    assert true = Port.close(port)
    assert true = :erlang.resume_process(caller.pid)
    assert {:error, _} = Task.await(caller)
    eventually(fn -> not File.exists?(path) and not Process.alive?(owner) end)
  end

  test "failure after staged OS launch still reaps the child and private files" do
    supervisor = start_supervised!(Task.Supervisor)
    path = temporary_path("staged-option-failure")
    File.write!(path, "private")
    {:ok, {:staged_paths, owner, _} = lease} = Operations.stage_private_paths(supervisor, self(), self(), [path])
    monitor = Process.monitor(owner)
    malformed = [{:env, []}, {:retain_on_exit, false, :malformed}]

    assert {:ok, port} = Operations.start_staged_port(lease, System.find_executable("cat"), [], malformed)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert Port.info(port) == nil
    refute File.exists?(path)
    assert {:error, :connection_closed} = Operations.release_staged_paths(lease)
  end

  test "supervisor shutdown reaps a connection after unrelated messages leave it usable" do
    supervisor = start_supervised!(Task.Supervisor)
    path = temporary_path("supervisor-cleanup")
    File.write!(path, "private")
    target = %Target{executable: "/bin/sh", prefix: [], label: "worker"}
    {:ok, lease} = Operations.open_connection(supervisor, self(), target, private_paths: [path])
    send(lease.owner, {:unrelated_notification, make_ref()})
    assert :ok = GenServer.call(lease.owner, {:validate_connection, lease.id, target})
    assert File.read!(path) == "private"
    assert :ok = stop_supervised(Task.Supervisor)
    refute File.exists?(path)
    assert {:error, :connection_closed} = Operations.close_connection(lease)
  end

  test "an abnormal exit of the actual command port remains unknown and cleans the OS child" do
    supervisor = start_supervised!(Task.Supervisor)
    path = temporary_path("abnormal-command")
    authority = self()
    command = "printf '%s' \"$$\" > \"$PID_FILE\"; exec cat"

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        opts = [task_supervisor: supervisor, authority: authority, timeout_ms: 5_000, env: [{"PID_FILE", path}]]
        Command.run("/bin/sh", ["-c", command], opts)
      end)

    eventually(fn -> match?({:ok, content} when byte_size(content) > 0, File.read(path)) end)
    pid = path |> File.read!() |> String.to_integer()
    port = Enum.find(:erlang.ports(), &(Port.info(&1, :os_pid) == {:os_pid, pid}))
    assert is_port(port)
    assert true = :erlang.exit(port, :kill)
    assert {:error, {:unknown, _}} = Task.await(task)
    kill = System.find_executable("kill")
    eventually(fn -> elem(System.cmd(kill, ["-0", Integer.to_string(pid)], stderr_to_stdout: true), 1) != 0 end)
    eventually(fn -> Task.Supervisor.children(supervisor) == [] end)
  end

  test "a readiness command adapter refusing a missing executable releases only local ownership" do
    supervisor = start_supervised!(Task.Supervisor)
    path = temporary_path("missing-readiness")
    target = %Target{executable: path, prefix: [], label: "worker"}
    {config, entry} = preparation("/state/workspaces")
    request = prepare_request(supervisor, target, self())

    command = fn executable, args, opts ->
      with {:ok, _} <- File.stat(executable), do: Command.run(executable, args, opts)
    end

    opts = [task_supervisor: supervisor, authority: self(), request_fun: request, agent_executable: "sh"]

    assert {:error, {:unknown, :readiness_transport}, latest} =
             Operations.run(Provider, config, entry, :prepare, Keyword.put(opts, :command_fun, command))

    assert_receive {:connected, lease}
    assert {:error, :connection_closed} = Operations.close_connection(lease)
    assert Lifecycle.occupied?(Lifecycle.new(latest, "a", :cleanup))
    refute File.exists?(path)
  end

  test "a lost intent response retains newly journaled uncertainty and never starts stop mutation" do
    path = temporary_path("intent-journal")
    entry = Lifecycle.new(record(), "a", :cleanup)

    request = fn {:intent, %{desired: :stopped}}, current, _ ->
      File.write!(path, "pending-stop-intent")
      pending = [%{verb: :metadata, id: "new-intent", outcome: :unknown}]
      {:error, {:unknown, :response_lost}, %{current | pending: pending}}
    end

    assert {:error, {:unknown, :response_lost}, latest} =
             Operations.run(Provider, %{}, entry, :stop, request_fun: request)

    assert File.read!(path) == "pending-stop-intent"
    {stopping, [{:provider, :stop, id}]} = Lifecycle.step(entry, {:cancel, :done}, 0)
    proof = %{latest | phase: :stopped, proof: {:quiescent, %{workers: []}}}
    {unknown, []} = Lifecycle.step(stopping, {:stopped, id, proof}, 1)
    assert Lifecycle.occupied?(unknown)
  end

  defp queued_call?(owner, caller) do
    {:messages, messages} = Process.info(owner, :messages)
    Enum.any?(messages, &match?({:"$gen_call", {^caller, _}, _}, &1))
  end

  defp paused_holder_start(supervisor, fun) do
    assert :ok = :sys.suspend(supervisor)
    caller = Task.async(fun)
    on_exit(fn -> resume_owned_process(caller.pid) end)

    try do
      eventually(fn -> queued_call?(supervisor, caller.pid) end)
      assert true = :erlang.suspend_process(caller.pid)
    after
      :sys.resume(supervisor)
    end

    eventually(fn -> Task.Supervisor.children(supervisor) != [] end)
    [owner] = Task.Supervisor.children(supervisor)
    on_exit(fn -> resume_owned_process(owner) end)
    {caller, owner}
  end

  defp resume_owned_process(owner) do
    :erlang.resume_process(owner)
  catch
    :error, :badarg -> :ok
  end

  defp temporary_path(label) do
    path = Path.join(System.tmp_dir!(), "symphony-#{label}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    path
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

defmodule SymphonyElixir.EnvironmentOperationsHookTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.ExecutionEnvironment.{Lifecycle, Operations, Record}
  alias SymphonyElixir.SSH.Target

  test "cleanup hook runs in the retained workspace without deleting it" do
    {root, entry} = hook_entry()
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_before_remove: "printf cleaned > marker")
    assert {:ok, _} = Operations.run(nil, %{}, entry, :cleanup_hook, [])
    assert File.read!(Path.join(entry.record.workspace_path, "marker")) == "cleaned"
    assert File.read!(Path.join(entry.record.workspace_path, "retained")) == "disk"
  end

  test "async cleanup runs the retained hook after its caller restores a lane with the hook cleared" do
    supervisor = start_supervised!(Task.Supervisor)
    {root, entry} = hook_entry()
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_before_remove: "printf archived > marker")
    {:ok, snapshot} = LaneContext.capture()
    entry = %{entry | lane_snapshot: snapshot}
    parent = self()

    operation_fun = fn adapter, config, retained, operation, opts ->
      send(parent, {:cleanup_waiting, self()})

      receive do
        :run_cleanup -> Operations.run(adapter, config, retained, operation, opts)
      end
    end

    LaneContext.install(snapshot)
    assert {:ok, task} = Operations.start(supervisor, nil, %{}, entry, :cleanup_hook, operation_fun: operation_fun)
    assert_receive {:cleanup_waiting, worker}
    LaneContext.put(snapshot.lane_id)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_before_remove: nil)
    send(worker, :run_cleanup)

    assert {nil, {:ok, _}} = Task.await(task)
    assert File.read(Path.join(entry.record.workspace_path, "marker")) == {:ok, "archived"}
    assert File.read!(Path.join(entry.record.workspace_path, "retained")) == "disk"
  end

  test "async managed cleanup uses its retained timeout after a newer timeout is published" do
    supervisor = start_supervised!(Task.Supervisor)
    {root, entry} = hook_entry()
    realpath = System.find_executable("grealpath") || System.find_executable("realpath") || flunk("managed workspace fixtures require realpath supporting -m")
    bin = Path.join(root, "fixture-bin")
    File.mkdir_p!(bin)
    File.ln_s!(realpath, Path.join(bin, "realpath"))
    bash_env = Path.join(root, "fixture-bash-env")
    escaped_bin = "'" <> String.replace(bin, "'", "'\"'\"'") <> "'"
    File.write!(bash_env, "export PATH=#{escaped_bin}:\"$PATH\"\n")
    target = %Target{executable: "/bin/sh", prefix: ["-c"], label: "fixture", env: [{"BASH_ENV", bash_env}]}
    gate = Path.join(root, "release")
    pidfile = Path.join(root, "remote.pid")
    assert {_, 0} = System.cmd("mkfifo", [gate])

    on_exit(fn ->
      if File.exists?(pidfile) do
        System.cmd("kill", ["-KILL", String.trim(File.read!(pidfile))], stderr_to_stdout: true)
      end
    end)

    hook = "trap '' HUP; printf '%s' \"$$\" > '#{pidfile}'; printf archived > marker; IFS= read -r token < '#{gate}'"
    workflow_path = Workflow.workflow_file_path()
    write_workflow_file!(workflow_path, workspace_root: root, hook_before_remove: hook, hook_timeout_ms: 1_000)
    {:ok, snapshot} = LaneContext.capture()
    context = %{entry.context | mode: :managed, target: target, workspace_path: entry.record.workspace_path}
    entry = %{entry | context: context, lane_snapshot: snapshot}
    parent = self()

    operation_fun = fn adapter, config, retained, operation, opts ->
      send(parent, {:cleanup_waiting, self()})

      receive do
        :run_cleanup -> Operations.run(adapter, config, retained, operation, opts)
      end
    end

    LaneContext.install(snapshot)
    assert {:ok, task} = Operations.start(supervisor, nil, %{}, entry, :cleanup_hook, operation_fun: operation_fun)
    assert_receive {:cleanup_waiting, worker}
    LaneContext.put(snapshot.lane_id)
    write_workflow_file!(workflow_path, workspace_root: root, hook_before_remove: hook, hook_timeout_ms: 2_000)
    send(worker, :run_cleanup)

    assert {nil, {:error, {:managed_execution_unknown, {:remote_command_timeout, "before_remove", 1_000}}, latest}} = Task.await(task)
    assert File.read(Path.join(latest.workspace_path, "marker")) == {:ok, "archived"}
    assert File.read!(Path.join(latest.workspace_path, "retained")) == "disk"
    assert Lifecycle.occupied?(Lifecycle.new(latest, "a", :cleanup))
  end

  test "ambiguous cleanup transport preserves the record and does not prove stop" do
    {root, entry} = hook_entry()
    opts = [workspace_root: root, hook_before_remove: "printf unsafe > marker", hook_timeout_ms: 10]
    write_workflow_file!(Workflow.workflow_file_path(), opts)
    target = %Target{executable: "/bin/sh", prefix: ["-c", "exec sleep 1"], label: "owned-transport"}
    context = %{entry.context | mode: :managed, target: target}
    entry = %{entry | context: context}
    assert {:error, {:managed_execution_unknown, _}, latest} = Operations.run(nil, %{}, entry, :cleanup_hook, [])
    refute File.exists?(Path.join(latest.workspace_path, "marker"))
    assert File.read!(Path.join(latest.workspace_path, "retained")) == "disk"
    assert Lifecycle.occupied?(Lifecycle.new(latest, "a", :cleanup))
  end

  defp hook_entry do
    root = Path.join(System.tmp_dir!(), "symphony-operation-hook-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "ticket")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "retained"), "disk")
    on_exit(fn -> File.rm_rf(root) end)

    record = %Record{
      key: "se-ticket",
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "kubernetes",
      scope: %{},
      workspace_path: workspace,
      template_identity: "template-v1"
    }

    context = ExecutionContext.local(root)
    {root, %{Lifecycle.new(record, "a", :cleanup) | context: context}}
  end
end

defmodule SymphonyElixir.EnvironmentCommandTerminationTest do
  use ExUnit.Case
  alias SymphonyElixir.ExecutionEnvironment.Command

  test "a port without exit-status reporting confirms termination from its real exit signal" do
    Process.flag(:trap_exit, true)
    {port, pid, kill} = owned_cat()
    assert :ok = Command.terminate_port(port)
    assert Port.info(port) == nil
    {_output, status} = System.cmd(kill, ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    refute status == 0
  end

  test "a different process cannot claim receipt of the port owner's termination confirmation" do
    Process.flag(:trap_exit, true)
    parent = self()
    executable = System.find_executable("cat")

    owner =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        port = Port.open({:spawn_executable, executable}, [:binary])
        send(parent, {:owned_port, port})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned_port, port}

    try do
      assert {:error, :local_process_termination_unconfirmed} = Command.terminate_port(port)
      assert Port.info(port) == nil
    after
      send(owner.pid, :finish)
      Task.await(owner)
    end
  end

  test "a non-process port cannot establish OS process termination proof" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    assert {:error, :local_process_termination_unconfirmed} = Command.terminate_port(socket)
    assert Port.info(socket) == nil
  end

  test "missing local signal utility cannot produce termination proof" do
    {port, _pid, _kill} = owned_cat()
    directory = private_command_directory()
    previous = System.fetch_env!("PATH")

    try do
      System.put_env("PATH", directory)
      assert {:error, :local_process_termination_unconfirmed} = Command.terminate_port(port)
      assert Port.info(port) == nil
    after
      System.put_env("PATH", previous)
    end
  end

  test "a broken signal executable closes the handle but reports unconfirmed cleanup" do
    {port, _pid, _kill} = owned_cat()
    directory = private_command_directory()
    executable = Path.join(directory, "kill")
    File.write!(executable, "#!/symphony-missing-interpreter\n")
    File.chmod!(executable, 0o700)
    previous = System.fetch_env!("PATH")

    try do
      System.put_env("PATH", directory)
      assert {:error, :local_process_termination_unconfirmed} = Command.terminate_port(port)
      assert Port.info(port) == nil
    after
      System.put_env("PATH", previous)
    end
  end

  test "an exhausted temporary pathname cannot expose a request body to its consumer" do
    supervisor = start_supervised!(Task.Supervisor)
    root = private_command_directory()
    directory = extend_temp_directory(root, 200)
    previous = System.get_env("TMPDIR")
    parent = self()

    try do
      System.put_env("TMPDIR", directory)
      consumer = fn path -> send(parent, {:consumed_private_request, path}) end

      assert {:error, {:unknown, _}} =
               Command.with_json_file(%{"private" => "request"}, consumer, task_supervisor: supervisor)

      refute_received {:consumed_private_request, _}
      assert File.ls!(directory) == []
    after
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end
  end

  defp extend_temp_directory(directory, size) do
    child = Path.join(directory, String.duplicate("d", size))

    case File.mkdir(child) do
      :ok -> extend_temp_directory(child, size)
      {:error, :enametoolong} when size > 1 -> extend_temp_directory(directory, div(size, 2))
      {:error, :enametoolong} -> directory
      {:error, reason} -> flunk("cannot construct temporary pathname boundary: #{inspect(reason)}")
    end
  end

  defp owned_cat do
    kill = System.find_executable("kill")
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> Command.terminate_port(port) end)
    {port, pid, kill}
  end

  defp private_command_directory do
    path = Path.join(System.tmp_dir!(), "symphony-command-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
