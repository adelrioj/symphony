defmodule SymphonyElixir.RunsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LaneContext, LaneStore, Repo, Runs, TestSupport}
  alias SymphonyElixir.Runs.{Event, Run}
  alias SymphonyElixirWeb.ObservabilityPubSub

  test "lane observers discover starts and committed updates without knowing attempt topics" do
    Runs.flush()
    :ok = ObservabilityPubSub.subscribe()
    start_run("discoverable")
    assert_receive :observability_updated, 1_000
    assert %Run{status: "running"} = Repo.get_by(Run, attempt_id: "discoverable")

    Runs.event("discoverable", %{event: :notification}, %{input_tokens: 3}, 1)
    assert_receive :observability_updated, 1_000
    assert %Run{input_tokens: 3, turns: 1} = Repo.get_by(Run, attempt_id: "discoverable")

    Runs.finished("discoverable", "done")
    assert_receive :observability_updated, 1_000
    assert %Run{status: "done"} = Repo.get_by(Run, attempt_id: "discoverable")
  end

  test "ordered writes commit an attempt, ledger and cached usage before publishing" do
    lane_id = LaneContext.current!()
    {:ok, %{version_id: version_id}} = LaneStore.lookup(lane_id)
    :ok = ObservabilityPubSub.subscribe_run("ordered")

    assert :ok = start_run("ordered")
    assert :ok = Runs.event("ordered", %{event: :session_started, message: "hello", session_id: "s1"}, %{}, 1)
    assert :ok = Runs.event("ordered", %{event: :turn_completed, message: "done", session_id: "s1"}, %{input_tokens: 10, output_tokens: 5, cached_tokens: 4, total_tokens: 15}, 2)
    assert :ok = Runs.finished("ordered", "done")

    run = Runs.get_by_attempt("ordered")
    assert %Run{status: "done", lane_version_id: ^version_id, finished_at: %DateTime{}} = run
    assert %Run{issue_identifier: "RN-1", executor: "local", turns: 2} = run
    assert %Run{input_tokens: 10, output_tokens: 5, cached_tokens: 4} = run

    assert_receive {:run_event, %Event{kind: "turn_started", payload: %{"message" => "hello", "session_id" => "s1"}}}
    assert_receive {:run_event, %Event{kind: "turn_finished"}}
    assert_receive {:run_event, %Event{kind: "usage", payload: %{"cached_tokens" => 4, "total_tokens" => 15}}}
    assert_receive {:run_updated, "ordered"}
    assert ["turn_started", "turn_finished", "usage"] == Enum.map(Runs.events(run.id), & &1.kind)
    assert [%Run{attempt_id: "ordered"}] = Runs.list_for_lane(lane_id, 10)
  end

  test "event notification consumers observe committed totals without a writer barrier" do
    start_run("committed")
    run = Runs.get_by_attempt("committed")
    :ok = ObservabilityPubSub.subscribe_run("committed")
    Runs.event("committed", %{event: :notification, session_id: "commit-session"}, %{cached_tokens: 7}, 3)

    assert_receive {:run_event, %Event{kind: "agent_message"}}, 1_000
    assert %Run{turns: 3, cached_tokens: 7} = Repo.get!(Run, run.id)
    assert [%Event{kind: "agent_message"}, %Event{kind: "usage", payload: %{"cached_tokens" => 7}}] = Runs.events(run.id)
    Runs.event("committed", %{event: :notification}, %{cached_tokens: 2}, 1)
    assert %Run{turns: 3, cached_tokens: 9} = Runs.get_by_attempt("committed")
  end

  test "a rejected aggregate update rolls back both ledger events and broadcasts" do
    start_run("atomic")
    run = Runs.get_by_attempt("atomic")
    :ok = ObservabilityPubSub.subscribe_run("atomic")

    Repo.query!("""
    CREATE TRIGGER reject_run_usage BEFORE UPDATE OF input_tokens ON runs
    WHEN NEW.input_tokens = 99
    BEGIN SELECT RAISE(ABORT, 'rejected usage'); END
    """)

    try do
      log =
        capture_log(fn ->
          Runs.event("atomic", %{event: :turn_completed, session_id: "atomic-session"}, %{input_tokens: 99, total_tokens: 99}, 2)
          Runs.flush()
        end)

      assert log =~ "Best-effort record run event failed"
      assert log =~ "issue_id=iss-1"
      assert log =~ "issue_identifier=RN-1"
      assert log =~ "session_id=atomic-session"
      assert [] = Runs.events(run.id)
      assert %Run{turns: 0, input_tokens: 0} = Runs.get_by_attempt("atomic")
      refute_receive {:run_event, _}
    after
      Repo.query!("DROP TRIGGER reject_run_usage")
    end

    Runs.event("atomic", %{event: :turn_completed}, %{input_tokens: 1}, 1)
    assert %Run{turns: 1, input_tokens: 1} = Runs.get_by_attempt("atomic")
  end

  test "terminal transitions are idempotent and ignore delayed worker events" do
    start_run("terminal")
    Runs.finished("terminal", "blocked")
    assert %Run{status: "blocked", finished_at: at} = run = Runs.get_by_attempt("terminal")
    :ok = ObservabilityPubSub.subscribe_run("terminal")

    Runs.finished("terminal", "failed")
    Runs.event("terminal", %{event: :turn_completed}, %{input_tokens: 20}, 9)
    assert %Run{status: "blocked", finished_at: ^at, input_tokens: 0, turns: 0} = Runs.get_by_attempt("terminal")
    assert [] = Runs.events(run.id)
    refute_receive {:run_updated, "terminal"}
    refute_receive {:run_event, _}
  end

  test "lane finalization preserves successful attempts and distinguishes disable from crash" do
    lane_id = LaneContext.current!()
    {:ok, entry} = LaneStore.lookup(lane_id)
    {:ok, other_lane} = TestSupport.create_lane_from_front_matter(%{slug: "other-history", front_matter: entry.front_matter, prompt: entry.prompt})
    start_run("other-lane", %{lane_id: other_lane.id})
    start_run("done")
    Runs.finished("done", "done")
    start_run("disabled")
    :ok = ObservabilityPubSub.subscribe_run("disabled")
    assert :ok = Runs.finish_lane(lane_id, "stopped")
    assert %Run{status: "stopped"} = Runs.get_by_attempt("disabled")
    assert_receive {:run_updated, "disabled"}

    start_run("crashed")
    :ok = ObservabilityPubSub.subscribe_run("crashed")
    assert :ok = Runs.finish_lane(lane_id, "failed")
    assert %Run{status: "failed"} = Runs.get_by_attempt("crashed")
    assert_receive {:run_updated, "crashed"}
    assert %Run{status: "stopped"} = Runs.get_by_attempt("disabled")
    assert %Run{status: "done"} = Runs.get_by_attempt("done")
    assert %Run{status: "running"} = Runs.get_by_attempt("other-lane")
    assert [%Run{attempt_id: "other-lane"}] = Runs.list_for_lane(other_lane.id, 10)
    assert ["crashed", "disabled"] == Enum.map(Runs.list_for_lane(lane_id, 2), & &1.attempt_id)
  end

  test "a killed dispatch owner fails its active attempts without changing completed or unrelated history" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    start_run("owner-active", %{owner_pid: owner})
    start_run("owner-done", %{owner_pid: owner})
    Runs.finished("owner-done", "done")
    start_run("unrelated-owner")
    :ok = ObservabilityPubSub.subscribe_run("owner-active")
    assert %Run{status: "running"} = Runs.get_by_attempt("owner-active")

    Process.exit(owner, :kill)
    assert_receive {:run_updated, "owner-active"}, 1_000
    assert %Run{status: "failed", finished_at: %DateTime{}} = Runs.get_by_attempt("owner-active")
    assert %Run{status: "done"} = Runs.get_by_attempt("owner-done")
    assert %Run{status: "running"} = Runs.get_by_attempt("unrelated-owner")

    :ok = ObservabilityPubSub.subscribe_run("owner-already-dead")
    start_run("owner-already-dead", %{owner_pid: owner})
    assert_receive {:run_updated, "owner-already-dead"}, 1_000
    assert %Run{status: "failed", finished_at: %DateTime{}} = Runs.get_by_attempt("owner-already-dead")
    assert %Run{status: "done"} = Runs.get_by_attempt("owner-done")
    assert %Run{status: "running"} = Runs.get_by_attempt("unrelated-owner")
  end

  test "dispatch snapshot retains the original version after a workflow change" do
    lane_id = LaneContext.current!()
    {:ok, before} = LaneStore.lookup(lane_id)
    :ok = write_workflow_file!(Workflow.workflow_file_path(), prompt: "A changed workflow")
    {:ok, current} = LaneStore.lookup(lane_id)
    assert current.version_id != before.version_id

    start_run("pinned", %{lane_version_id: before.version_id, executor: before.executor})
    assert %Run{lane_version_id: version_id} = Runs.get_by_attempt("pinned")
    assert version_id == before.version_id
    start_run("current")
    assert %Run{lane_version_id: version_id} = Runs.get_by_attempt("current")
    assert version_id == current.version_id
  end

  test "source events retain their classification and readable names in the durable feed" do
    start_run("kinds")

    Enum.each([:turn_input_required, :approval_required, :hook_before_run, :startup_failed, :turn_failed, "turn_started", "result", "hook", {:vendor, 7}], fn event ->
      Runs.event("kinds", %{event: event}, %{}, 0)
    end)

    run = Runs.get_by_attempt("kinds")

    assert [
             {"blocked", "turn_input_required"},
             {"blocked", "approval_required"},
             {"hook", "hook_before_run"},
             {"error", "startup_failed"},
             {"error", "turn_failed"},
             {"turn_started", "turn_started"},
             {"turn_finished", "result"},
             {"hook", "hook"},
             {"agent_message", "{:vendor, 7}"}
           ] == Enum.map(Runs.events(run.id), &{&1.kind, &1.payload["event"]})
  end

  test "unknown attempts and malformed writes cannot break subsequent attempts" do
    log =
      capture_log(fn ->
        Runs.event("missing", %{event: :notification}, %{}, 0)
        Runs.finished("missing", "done")
        Runs.finished("missing", "not-a-status")
        Runs.finished("missing", "running")
        start_run("invalid-lane", %{lane_id: -1})
        start_run("invalid-foreign-key", %{lane_id: -1, lane_version_id: -1, executor: "local"})
        Runs.flush()
      end)

    assert log =~ "Best-effort record run finish failed"
    assert log =~ "Best-effort record run start failed"
    assert is_nil(Runs.get_by_attempt("missing"))
    assert is_nil(Runs.get_by_attempt("invalid-lane"))
    start_run("after-error")
    assert %Run{status: "running"} = Runs.get_by_attempt("after-error")

    log =
      capture_log(fn ->
        Runs.event("after-error", %{event: :notification}, %{input_tokens: -1}, 0)
        Runs.event("after-error", %{event: :notification}, %{}, -1)
        Runs.flush()
      end)

    assert log =~ "invalid input_tokens delta"
    assert log =~ "invalid turn count"
    assert %Run{turns: 0, input_tokens: 0} = Runs.get_by_attempt("after-error")
  end

  test "retention deletes only expired events and a triggered pass uses installation retention" do
    start_run("retained")
    run = Runs.get_by_attempt("retained")
    now = DateTime.utc_now()
    old = Repo.insert!(%Event{run_id: run.id, at: DateTime.add(now, -40 * 86_400), kind: "hook", payload: %{}})
    recent = Repo.insert!(%Event{run_id: run.id, at: now, kind: "agent_message", payload: %{}})
    assert 1 = Runs.prune_events(30)
    assert is_nil(Repo.get(Event, old.id))
    assert [^recent] = Runs.events(run.id)
    assert %Run{id: id} = Runs.get_by_attempt("retained")
    assert id == run.id

    previous = Application.fetch_env(:symphony_elixir, :events_retention_days)
    Application.put_env(:symphony_elixir, :events_retention_days, 1)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :events_retention_days, value)
        :error -> Application.delete_env(:symphony_elixir, :events_retention_days)
      end
    end)

    expired = Repo.insert!(%Event{run_id: run.id, at: DateTime.add(now, -2 * 86_400), kind: "error", payload: %{}})
    pid = start_supervised!({Runs.Retention, name: nil})
    send(pid, :prune)
    await_deleted(expired.id)
    assert [^recent] = Runs.events(run.id)
    assert %Run{} = Runs.get_by_attempt("retained")
  end

  test "stopped Repo writes warn while the same writer remains usable after Repo restart" do
    isolated_script(
      """
      :ok = Runs.started(Map.put(attrs, :attempt_id, "retained-boundary"))
      :ok = Runs.finished("retained-boundary", "done")
      :ok = Runs.flush()
      :ok = Supervisor.stop(repo)
      :ok = Runs.started(attrs)
      :ok = Runs.event("boundary", %{event: :notification, session_id: "offline"}, %{}, 0)
      :ok = Runs.finished("boundary", "failed")
      :ok = Runs.finish_lane(1, "failed")
      :ok = Runs.flush()
      0 = Runs.prune_events(30)
      {:ok, _repo} = Repo.start_link(database: database)
      :ok = Runs.started(attrs)
      :ok = Runs.finished("boundary", "done")
      %Run{status: "done"} = Runs.get_by_attempt("boundary")
      %Run{status: "done"} = Runs.get_by_attempt("retained-boundary")
      """,
      "Best-effort record run start failed"
    )
  end

  test "an absent lane registry cannot break dispatch and captured attempts still persist" do
    isolated_script(
      """
      :ok = Runs.started(attrs |> Map.drop([:lane_version_id, :executor]) |> Map.put(:attempt_id, "uncaptured"))
      :ok = Runs.flush()
      nil = Runs.get_by_attempt("uncaptured")
      :ok = Runs.started(attrs)
      :ok = Runs.event("boundary", %{event: :turn_completed}, %{input_tokens: 3}, 1)
      :ok = Runs.finished("boundary", "done")
      %Run{status: "done", lane_version_id: 1, input_tokens: 3, turns: 1} = run = Runs.get_by_attempt("boundary")
      ["turn_finished", "usage"] = Enum.map(Runs.events(run.id), & &1.kind)
      """,
      "Best-effort record run start failed"
    )
  end

  test "a database pool exit during queued retention leaves history and the writer recoverable" do
    isolated_script(
      """
      :ok = Runs.started(attrs)
      :ok = Runs.event("boundary", %{event: :notification}, %{input_tokens: 2}, 1)
      run = Runs.get_by_attempt("boundary")
      [event, _usage] = Runs.events(run.id)
      Repo.update!(Ecto.Changeset.change(event, at: DateTime.add(DateTime.utc_now(), -40 * 86_400)))
      writer = Process.whereis(Runs.Writer)
      %{pid: pool} = Ecto.Adapter.lookup_meta(Repo)
      parent = self()
      holder = spawn(fn ->
        Repo.checkout(fn ->
          send(parent, :connection_held)
          receive do
            :release -> :ok
          end
        end)
      end)
      receive do
        :connection_held -> :ok
      after
        1_000 -> raise "could not hold the database connection"
      end
      spawn(fn -> send(parent, {:pruned, Runs.prune_events(30)}) end)
      Enum.reduce_while(1..100, nil, fn _, _ ->
        if Enum.any?(DBConnection.get_connection_metrics(pool), &(&1.checkout_queue_length == 1)) do
          {:halt, :queued}
        else
          Process.sleep(10)
          {:cont, nil}
        end
      end) == :queued || raise "retention never reached the database queue"
      :ok = Supervisor.stop(repo)
      send(holder, :release)
      receive do
        {:pruned, 0} -> :ok
      after
        1_000 -> raise "retention did not recover from the database exit"
      end
      {:ok, _repo} = Repo.start_link(database: database, pool_size: 1)
      ^writer = Process.whereis(Runs.Writer)
      :ok = Runs.event("boundary", %{event: :turn_completed}, %{input_tokens: 3}, 2)
      :ok = Runs.finished("boundary", "done")
      %Run{status: "done", input_tokens: 5, turns: 2} = run = Runs.get_by_attempt("boundary")
      ["agent_message", "usage", "turn_finished", "usage"] = Enum.map(Runs.events(run.id), & &1.kind)
      1 = Runs.prune_events(30)
      ["usage", "turn_finished", "usage"] = Enum.map(Runs.events(run.id), & &1.kind)
      """,
      "Best-effort prune run events failed"
    )
  end

  test "a real SQLite write lock cannot delay scheduling and queued commands preserve their order" do
    isolated_script("""
    {:ok, lock} = Exqlite.Sqlite3.open(database)
    :ok = Exqlite.Sqlite3.execute(lock, "BEGIN IMMEDIATE")
    parent = self()
    spawn(fn ->
      :ok = Runs.started(attrs)
      :ok = Runs.event("boundary", %{event: :turn_completed}, %{input_tokens: 2, cached_tokens: 1}, 1)
      :ok = Runs.finished("boundary", "done")
      :ok = Runs.finish_lane(1, "failed")
      send(parent, :enqueued_without_database)
    end)
    receive do
      :enqueued_without_database -> :ok
    after
      1_000 -> raise "scheduler waited for the locked database"
    end
    :ok = Exqlite.Sqlite3.execute(lock, "COMMIT")
    :ok = Exqlite.Sqlite3.close(lock)
    %Run{status: "done", turns: 1, input_tokens: 2, cached_tokens: 1} = run = Runs.get_by_attempt("boundary")
    ["turn_finished", "usage"] = Enum.map(Runs.events(run.id), & &1.kind)
    """)
  end

  defp issue, do: %Issue{id: "iss-1", identifier: "RN-1", title: "Run history", description: "", state: "Todo", url: "https://example.org/RN-1", dispatchable: true}

  defp start_run(attempt_id, extra \\ %{}) do
    Runs.started(Map.merge(%{lane_id: LaneContext.current!(), issue: issue(), attempt_id: attempt_id, attempt: nil, worker_ref: nil}, extra))
  end

  defp await_deleted(id, attempts \\ 100)
  defp await_deleted(id, 0), do: assert(is_nil(Repo.get(Event, id)))

  defp await_deleted(id, attempts) do
    if Repo.get(Event, id) do
      Process.sleep(10)
      await_deleted(id, attempts - 1)
    end
  end

  defp isolated_script(body, expected_output \\ nil) do
    root = Path.join(System.tmp_dir!(), "symphony-runs-#{System.unique_integer([:positive, :monotonic])}")
    on_exit(fn -> File.rm_rf!(root) end)
    coverage_file = Path.join(root, "runs.coverdata")

    script = """
    alias SymphonyElixir.{Repo, Runs}
    alias SymphonyElixir.Runs.Run
    [tools] = Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "tools-*", "ebin"]))
    Code.prepend_path(tools)
    {:ok, _} = :cover.start()
    Enum.each([Runs, Runs.Writer, Runs.Retention], fn module -> {:ok, ^module} = :cover.compile_beam(module) end)
    Application.put_env(:symphony_elixir, :data_root, #{inspect(root)})
    Application.delete_env(:symphony_elixir, Repo)
    :ok = Repo.migrate()
    database = Path.join(#{inspect(root)}, "symphony.sqlite3")
    {:ok, repo} = Repo.start_link(database: database, pool_size: 1)
    {:ok, _writer} = Runs.start_link()
    Repo.query!("INSERT INTO execution_profiles (id, name, workspace_base, worker, inserted_at, updated_at) VALUES (1, 'Boundary profile', ?, '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)", [Path.join(#{inspect(root)}, "workspaces")])
    Repo.query!("INSERT INTO lanes (id, slug, name, execution_profile_id, workspace_subdir, inserted_at, updated_at) VALUES (1, 'boundary', 'Boundary', 1, '.', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
    Repo.query!("INSERT INTO lane_versions (id, lane_id, front_matter, prompt, inserted_at) VALUES (1, 1, 'tracker: {}', 'Run', CURRENT_TIMESTAMP)")
    attrs = %{lane_id: 1, lane_version_id: 1, executor: "local", issue: %SymphonyElixir.Tracker.Issue{id: "boundary-issue", identifier: "BD-1", state: "Todo"}, attempt_id: "boundary"}
    #{body}
    :ok = :cover.export(#{inspect(coverage_file)})
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "--no-compile", "-e", script], cd: Path.expand("../..", __DIR__), env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert status == 0, output
    if expected_output, do: assert(output =~ expected_output)
    SymphonyElixir.TestSupport.import_coverage(Runs, coverage_file)
  end
end
