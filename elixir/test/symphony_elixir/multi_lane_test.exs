defmodule SymphonyElixir.MultiLaneTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ExecutionProfiles, LaneRegistry, Runs, Workflow}
  alias SymphonyElixir.ExecutionProfiles.Configuration

  defmodule TrackerEndpoint do
    @behaviour Plug
    @impl true
    def init(parent), do: parent
    @impl true
    def call(conn, parent) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:new_tracker_request, Jason.decode!(body)})
      response = %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  defmodule RetryTrackerEndpoint do
    @behaviour Plug
    @impl true
    def init(parent), do: parent
    @impl true
    def call(conn, parent) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:retry_refresh, self(), Jason.decode!(body)})

      receive do
        {:respond, response} ->
          conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, a} = create_lane("lane-a", yaml("Queue A", 60_000, 20), "Prompt A")
    {:ok, b} = create_lane("lane-b", yaml("Queue B", 70_000, 7), "Prompt B")
    %{a: a, b: b}
  end

  test "enabled lanes poll their own configuration and retain independent task authorities", %{a: a, b: b} do
    enable(a)
    enable(b)
    assert %{running: [], polling: %{poll_interval_ms: 60_000}} = snapshot(a)
    assert %{running: [], polling: %{poll_interval_ms: 70_000}} = snapshot(b)

    parent = self()

    for lane <- [a, b] do
      lane_id = lane.id

      Task.Supervisor.start_child(LaneRegistry.via(lane.id, :tasks), fn ->
        LaneContext.put(lane_id)
        send(parent, {:lane_prompt, lane_id, Config.workflow_prompt()})
      end)
    end

    assert_receive {:lane_prompt, id_a, "Prompt A"}
    assert_receive {:lane_prompt, id_b, "Prompt B"}
    assert id_a == a.id
    assert id_b == b.id
  end

  test "crashing one scheduler kills its tasks but another lane continues servicing work", %{a: a, b: b} do
    enable(a)
    enable(b)
    parent = self()
    a_worker = start_responder(a, parent)
    b_worker = start_responder(b, parent)
    monitor = Process.monitor(a_worker)
    a_owner = LaneRegistry.whereis(a.id, :orchestrator)
    b_owner = LaneRegistry.whereis(b.id, :orchestrator)

    capture_log(fn ->
      Process.exit(a_owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^a_worker, _}, 5_000
      wait_until(fn -> LaneRegistry.whereis(a.id, :orchestrator) not in [nil, a_owner] end)
    end)

    send(b_worker, {:ping, self()})
    assert_receive {:pong, ^b_worker}
    assert LaneRegistry.whereis(b.id, :orchestrator) == b_owner
    assert %{polling: %{poll_interval_ms: 70_000}} = snapshot(b)
    assert %{polling: %{poll_interval_ms: 60_000}} = snapshot(a)
  end

  test "saving one enabled lane hot-applies scheduling without altering the other", %{a: a, b: b} do
    enable(a)
    enable(b)
    a_owner = LaneRegistry.whereis(a.id, :orchestrator)
    b_owner = LaneRegistry.whereis(b.id, :orchestrator)
    {:ok, _} = update_workflow(Lanes.get!(a.id), yaml("Queue A", 45_000, 3))
    wait_until(fn -> snapshot(a).polling.poll_interval_ms == 45_000 end)
    assert snapshot(b).polling.poll_interval_ms == 70_000
    assert LaneRegistry.whereis(a.id, :orchestrator) == a_owner
    assert LaneRegistry.whereis(b.id, :orchestrator) == b_owner
  end

  test "actual dispatches use lane-specific tracker states, prompts, hooks and settings", %{a: a, b: b} do
    parent = self()
    first = start_reader(a, parent)
    second = start_reader(b, parent)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("a", "Queue A"), issue("b", "Queue B")])
    send(first, :run_poll_cycle)
    send(second, :run_poll_cycle)
    assert_receive {:attempt, "a", worker_a, _, values_a}, 5_000
    assert_receive {:attempt, "b", worker_b, _, values_b}, 5_000
    assert values_a == {20, "Prompt A", "echo hook-20 > hook-version", ["Queue A"]}
    assert values_b == {7, "Prompt B", "echo hook-7 > hook-version", ["Queue B"]}
    assert [%{issue_id: "a"}] = Orchestrator.snapshot(first, 5_000).running
    assert [%{issue_id: "b"}] = Orchestrator.snapshot(second, 5_000).running
    send(worker_a, {:read, self()})
    send(worker_b, {:read, self()})
    assert_receive {:reread, ^worker_a, ^values_a, ^values_a, {:ok, content_a}}
    assert_receive {:reread, ^worker_b, ^values_b, ^values_b, {:ok, content_b}}
    assert content_a =~ "Prompt A"
    assert content_b =~ "Prompt B"
  end

  test "mid-attempt saves pin all reads and helper reads while next dispatch records the new version", %{a: a} do
    parent = self()
    owner = start_reader(a, parent)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("first", "Queue A")])
    send(owner, :run_poll_cycle)
    assert_receive {:attempt, "first", worker, first_attempt, old_values}, 5_000
    {:ok, old_entry} = LaneStore.lookup(a.id)

    {:ok, _} = update_workflow(Lanes.get!(a.id), yaml("Queue New", 45_000, 3), "New prompt")
    {:ok, new_entry} = LaneStore.lookup(a.id)
    refute old_entry.version_id == new_entry.version_id
    send(worker, {:read, self()})
    assert_receive {:reread, ^worker, ^old_values, ^old_values, {:ok, old_content}}, 5_000
    assert old_content =~ "Prompt A"
    refute old_content =~ "New prompt"
    workspace = Path.join(Config.data_root(), "hook-workspace")
    File.mkdir_p!(workspace)
    send(worker, {:hook, workspace, self()})
    assert_receive {:hook_ran, ^worker, :ok}, 5_000
    assert File.read!(Path.join(workspace, "hook-version")) == "hook-20\n"

    # Remove the completed issue before releasing the runner, then wait for the
    # scheduler's DOWN handling before asking it to dispatch the next issue.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    send(worker, :finish)
    wait_until(fn -> Orchestrator.snapshot(owner, 5_000).running == [] end)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("next", "Queue New")])
    send(owner, :run_poll_cycle)
    assert_receive {:attempt, "next", next_worker, next_attempt, {3, "New prompt", "echo hook-3 > hook-version", ["Queue New"]}}, 5_000
    assert %{polling: %{poll_interval_ms: 45_000}} = Orchestrator.snapshot(owner, 5_000)
    assert Runs.get_by_attempt(first_attempt).lane_version_id == old_entry.version_id
    assert Runs.get_by_attempt(next_attempt).lane_version_id == new_entry.version_id
    send(next_worker, {:hook, workspace, self()})
    assert_receive {:hook_ran, ^next_worker, :ok}, 5_000
    assert File.read!(Path.join(workspace, "hook-version")) == "hook-3\n"
    send(next_worker, {:read, self()})
    assert_receive {:reread, ^next_worker, _, _, {:ok, new_content}}
    assert new_content =~ "New prompt"
  end

  test "profile updates pin attempts and fence retained local workspaces", %{a: a} do
    parent = self()
    owner = start_reader(a, parent)
    {:ok, old_entry} = LaneStore.lookup(a.id)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("profile-first", "Queue A")])

    :sys.replace_state(
      owner,
      &%{
        &1
        | runner_fun: fn issue, _recipient, _opts ->
            send(parent, {:profile_attempt, issue.id, self(), Config.settings!().worker.max_concurrent_agents_per_host})

            receive do
              {:read_profile, caller} ->
                send(caller, {:profile_value, self(), Config.settings!().worker.max_concurrent_agents_per_host})
                receive do: (:finish -> :ok)

              :finish ->
                :ok
            end
          end
      }
    )

    send(owner, :run_poll_cycle)
    assert_receive {:profile_attempt, "profile-first", worker, nil}, 5_000

    profile = ExecutionProfiles.get(a.execution_profile_id)
    assert {:ok, updated_profile} = ExecutionProfiles.update(profile, %{worker: %{"max_concurrent_agents_per_host" => 2}})
    assert {:ok, %{settings: %{worker: %{max_concurrent_agents_per_host: 2}}}} = LaneStore.lookup(a.id)

    send(worker, {:read_profile, self()})
    assert_receive {:profile_value, ^worker, nil}, 5_000

    retained = Path.join(old_entry.settings.workspace.root, "profile-retained")
    File.mkdir_p!(retained)
    assert {:error, _} = ExecutionProfiles.update(updated_profile, %{workspace_base: old_entry.settings.workspace.root <> "-replacement"})

    send(worker, :finish)
    wait_until(fn -> Orchestrator.snapshot(owner, 5_000).running == [] end)
    assert {:error, _} = ExecutionProfiles.update(updated_profile, %{workspace_base: old_entry.settings.workspace.root <> "-replacement"})

    File.rm_rf!(old_entry.settings.workspace.root)
    assert {:ok, _} = ExecutionProfiles.update(updated_profile, %{workspace_base: old_entry.settings.workspace.root <> "-replacement"})
  end

  test "one-for-all scheduler restart finalizes its attempt without stopping another lane", %{a: a, b: b} do
    parent = self()
    owner_a = start_reader(a, parent)
    owner_b = start_reader(b, parent)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("a", "Queue A"), issue("b", "Queue B")])
    send(owner_a, :run_poll_cycle)
    send(owner_b, :run_poll_cycle)
    assert_receive {:attempt, "a", worker_a, attempt_a, _}, 5_000
    assert_receive {:attempt, "b", worker_b, attempt_b, values_b}, 5_000
    monitor = Process.monitor(worker_a)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("b", "Queue B")])

    capture_log(fn ->
      Process.exit(owner_a, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker_a, _}, 5_000
      wait_until(fn -> Runs.get_by_attempt(attempt_a).status == "failed" end)
    end)

    send(worker_b, {:read, self()})
    assert_receive {:reread, ^worker_b, ^values_b, ^values_b, _}
    assert Runs.get_by_attempt(attempt_b).status == "running"
    assert [%{issue_id: "b"}] = Orchestrator.snapshot(owner_b, 5_000).running
  end

  test "changing tracker provider does not reconcile an active attempt against the replacement tracker", %{a: a} do
    parent = self()
    server = start_supervised!({Bandit, plug: {TrackerEndpoint, parent}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    owner = start_reader(a, parent)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("old-provider-id", "Queue A")])
    send(owner, :run_poll_cycle)
    assert_receive {:attempt, "old-provider-id", worker, attempt, original}, 5_000

    front = """
    tracker:
      kind: linear
      endpoint: http://127.0.0.1:#{port}/graphql
      api_key: replacement-token
      project_slug: replacement-project
      active_states: [Queue New]
    polling:
      interval_ms: 45000
    """

    {:ok, _} = update_workflow(Lanes.get!(a.id), front, "Replacement tracker")
    send(owner, :run_poll_cycle)
    assert_receive {:new_tracker_request, %{"query" => query}}, 5_000
    assert query =~ "SymphonyLinearPoll"
    assert [%{issue_id: "old-provider-id"}] = Orchestrator.snapshot(owner, 5_000).running
    refute_receive {:new_tracker_request, %{"query" => "query SymphonyLinearIssuesById" <> _}}, 50
    send(worker, {:read, self()})
    assert_receive {:reread, ^worker, ^original, ^original, _}
    assert Runs.get_by_attempt(attempt).status == "running"
  end

  test "retry dispatch pins backend workspace prompt and recorded version before its refresh", %{a: a} do
    parent = self()
    server = start_supervised!({Bandit, plug: {RetryTrackerEndpoint, parent}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    root = Path.join(Config.data_root(), "retry-original")

    front = """
    tracker:
      kind: linear
      endpoint: http://127.0.0.1:#{port}/graphql
      api_key: fixture-token
      project_slug: fixture-project
      active_states: [In Progress]
    workspace:
      root: #{root}
    agent:
      backend: codex
      in_progress_state: ""
    """

    {:ok, _} = update_workflow(a, front, "Original retry prompt")
    {:ok, a} = Lanes.update(Lanes.get!(a.id), %{workspace_subdir: "."})
    {:ok, entry} = LaneStore.lookup(a.id)
    :ok = LaneStore.put_entry(%{entry | enabled: true})
    {:ok, original} = LaneStore.lookup(a.id)
    tasks = start_supervised!({Task.Supervisor, []})

    runner = fn _issue, _recipient, opts ->
      send(parent, {:retry_started, opts, Config.workflow_prompt()})

      receive do
        :finish -> :ok
      end
    end

    dispatch =
      Task.async(fn ->
        LaneContext.put(a.id)
        state = %Orchestrator.State{lane_id: a.id, max_concurrent_agents: 1, task_supervisor: tasks, runner_fun: runner}
        Orchestrator.handle_retry_issue_lookup_for_test(issue("retry", "In Progress"), state, "retry", 1, %{})
      end)

    assert_receive {:retry_refresh, request, %{"query" => query}}, 5_000
    assert query =~ "SymphonyLinearIssuesById"
    replacement = front |> String.replace("backend: codex", "backend: claude") |> String.replace(root, root <> "-replacement")
    assert {:error, _} = update_workflow(Lanes.get!(a.id), replacement, "Replacement retry prompt")

    send(
      request,
      {:respond,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{"id" => "retry", "identifier" => "ML-retry", "title" => "retry", "state" => %{"name" => "In Progress"}}
             ]
           }
         }
       }}
    )

    assert_receive {:retry_started, opts, "Original retry prompt"}, 5_000
    assert opts[:backend_module] == SymphonyElixir.Agent.Codex
    assert opts[:execution_context].workspace_root == root
    state = Task.await(dispatch, 5_000)
    assert Map.has_key?(state.running, "retry")
    assert Runs.get_by_attempt(opts[:attempt_id]).lane_version_id == original.version_id
  end

  defp reader(parent) do
    fn issue, _recipient, opts ->
      send(parent, {:attempt, issue.id, self(), opts[:attempt_id], values()})
      reader_loop()
    end
  end

  defp reader_loop do
    receive do
      {:hook, workspace, parent} ->
        context = SymphonyElixir.ExecutionContext.local(Path.dirname(workspace))
        result = SymphonyElixir.Workspace.run_before_run_hook(workspace, "ML-hook", context)
        send(parent, {:hook_ran, self(), result})
        reader_loop()

      {:read, parent} ->
        own = values()
        inherited = Task.async(fn -> values() end) |> Task.await()
        send(parent, {:reread, self(), own, inherited, Workflow.current_content()})
        reader_loop()

      :finish ->
        :ok
    end
  end

  defp values do
    config = Config.settings!()
    {config.agent.max_turns, Config.workflow_prompt(), config.hooks.before_run, config.tracker.active_states}
  end

  defp start_reader(lane, parent) do
    enable(lane)
    owner = LaneRegistry.whereis(lane.id, :orchestrator)
    :sys.replace_state(owner, &%{&1 | runner_fun: reader(parent)})
    owner
  end

  defp enable(lane) do
    {:ok, _} = Lanes.set_enabled(lane, true)

    wait_until(fn ->
      owner = LaneRegistry.whereis(lane.id, :orchestrator)
      is_pid(owner) and is_map(Orchestrator.snapshot(owner, 5_000))
    end)
  end

  defp snapshot(lane), do: Orchestrator.snapshot(LaneRegistry.via(lane.id, :orchestrator), 5_000)

  defp start_responder(lane, parent) do
    {:ok, pid} =
      Task.Supervisor.start_child(LaneRegistry.via(lane.id, :tasks), fn ->
        send(parent, {:ready, self()})

        receive do
          {:ping, caller} -> send(caller, {:pong, self()})
        end
      end)

    assert_receive {:ready, ^pid}
    pid
  end

  defp issue(id, state), do: %Issue{id: id, identifier: "ML-#{id}", title: id, state: state, dispatchable: true}

  defp yaml(state, interval, turns) do
    "tracker:\n  kind: memory\n  active_states: [#{state}]\npolling:\n  interval_ms: #{interval}\nagent:\n  max_turns: #{turns}\nhooks:\n  before_run: echo hook-#{turns} > hook-version\ncodex:\n  command: /bin/false"
  end

  defp create_lane(slug, front_matter, prompt) do
    {:ok, workflow} = Workflow.parse_parts(front_matter, prompt)
    {profile_attrs, config} = Configuration.split(workflow.config)

    {:ok, profile} =
      ExecutionProfiles.create(%{
        name: "Test #{slug} #{System.unique_integer([:positive])}",
        workspace_base: profile_attrs["workspace_base"] || Path.join(Config.data_root(), "workspaces-#{slug}"),
        worker: profile_attrs["worker"] || %{}
      })

    Lanes.create(%{slug: slug, execution_profile_id: profile.id, config: config, prompt: prompt})
  end

  defp update_workflow(lane, front_matter, prompt \\ nil) do
    {:ok, workflow} = Workflow.parse_parts(front_matter, prompt || LaneStore.workflow(lane.id) |> elem(1) |> Map.fetch!(:prompt))
    {profile_attrs, config} = Configuration.split(workflow.config)
    profile = ExecutionProfiles.get(lane.execution_profile_id)

    with {:ok, _profile} <- update_profile(profile, profile_attrs),
         {:ok, updated} <- Lanes.update(lane, %{config: config, prompt: workflow.prompt}) do
      {:ok, updated}
    end
  end

  defp update_profile(_profile, %{} = attrs) when map_size(attrs) == 0, do: {:ok, :unchanged}
  defp update_profile(profile, attrs), do: ExecutionProfiles.update(profile, attrs)

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("lane transition did not complete")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
