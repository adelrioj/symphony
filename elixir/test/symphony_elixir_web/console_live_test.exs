defmodule SymphonyElixirWeb.ConsoleLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Runs, Tracker.Memory}

  @endpoint SymphonyElixirWeb.Endpoint

  @recovery_snapshot %{
    running: [],
    blocked: [],
    retrying: [],
    queued: [],
    claimed: 0,
    codex_totals: %{},
    rate_limits: nil,
    environments: [
      %{
        environment_id: "workstation-bon-143",
        provider: "workstation",
        issue_id: "bon-143",
        issue_identifier: "BON-143",
        phase: :stopping,
        desired: :stopped,
        occupies_slot: true,
        workspace_path: "/workspace/BON-143",
        credential: %{stage: "recovery_required", reason: "checkpoint_failed"},
        unresolved: nil
      }
    ]
  }

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}
    def handle_call({:operator_blocked?, _issue_id}, _from, state), do: {:reply, state.blocked?, state}

    def handle_call(:request_refresh, _from, state),
      do: {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: []}, state}

    def handle_call(message, _from, state) do
      send(state.parent, {:orchestrator_call, message})
      {:reply, state.reply, state}
    end
  end

  setup context do
    {:ok, fake} =
      FakeOrchestrator.start_link(%{
        snapshot: Map.get(context, :snapshot, snapshot()),
        parent: self(),
        reply: Map.get(context, :reply, :ok),
        blocked?: Map.get(context, :blocked?, true)
      })

    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: fake)
    )

    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    {:ok, profile} =
      ExecutionProfiles.create(%{
        name: "Console #{System.unique_integer([:positive])}",
        workspace_base: Path.join(System.tmp_dir!(), "console-#{System.unique_integer([:positive])}"),
        worker: %{}
      })

    {:ok, lane} =
      Lanes.create(%{
        slug: "ops",
        name: "Ops",
        execution_profile_id: profile.id,
        config: %{
          "tracker" => %{"kind" => "memory", "active_states" => ["Todo", "In Progress"]},
          "agent" => %{"max_concurrent_agents" => 2}
        }
      })

    {:ok, entry} = LaneStore.lookup(lane.id)
    :ok = LaneStore.put_entry(%{entry | enabled: true})
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true}), lane: lane, fake: fake}
  end

  test "rows show elapsed time, tokens, backend and a relative retry time", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    assert has_element?(view, "#console-list [data-ticket='ops:run-1'] .console-sub", ~r/12m 0[4-6]s/)
    assert has_element?(view, "#console-list [data-ticket='ops:run-1'] .console-sub", "3.1m in · 1.8k out")
    assert has_element?(view, "#console-list [data-ticket='ops:run-1'] .console-backend", "codex")
    assert render(element(view, "#console-list [data-ticket='ops:rty-1'] .console-sub")) =~ ~r/retry in (59|1m 00)s/
  end

  test "the panel shows session, worker, workspace, elapsed and cached tokens", %{conn: conn, lane: lane} do
    issue = %Issue{id: "run-1", identifier: "OPS-1", title: "Cache deps in CI", state: "In Progress"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "att-1", attempt: 1})
    :ok = Runs.event("att-1", %{event: :notification}, %{input_tokens: 5, output_tokens: 1, cached_tokens: 1_200}, 1)
    :ok = Runs.flush()
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    assert has_element?(view, "#console-detail .console-kv", "s1")
    assert has_element?(view, "#console-detail .console-kv", "worker-a")
    assert has_element?(view, "#console-detail .console-kv", "/ws/OPS-1")
    assert has_element?(view, "#console-detail .console-kv", ~r/12m 0[4-6]s/)
    assert has_element?(view, "#console-detail .console-kv", "1.2k cached")
  end

  test "a queued ticket's panel says why it has no run", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Aq-1")
    assert has_element?(view, "#queued-note", "No run yet. Waiting on OPS-1.")
  end

  @tag snapshot: @recovery_snapshot
  test "workstation recovery stays visible through filters and clears after a healthy refresh", %{
    conn: conn,
    fake: fake
  } do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    assert has_element?(view, "#console-list [data-group='blocked'] [data-ticket='ops:bon-143']", "BON-143")

    view |> element("#attention-toggle") |> render_click()
    view |> element("#group-tracker") |> render_click()
    view |> element("#console-list [data-ticket='ops:bon-143']") |> render_click()
    assert_patch(view, "/?lane=ops&group=tracker&attention=1&ticket=ops%3Abon-143")
    assert has_element?(view, "#console-detail h2", "BON-143")
    assert has_element?(view, "#environment-detail", "stopping")
    assert has_element?(view, "#environment-detail", "stopped")
    assert has_element?(view, "#environment-detail", "yes")
    assert has_element?(view, "#environment-detail", "recovery_required")
    assert has_element?(view, "#environment-detail", "checkpoint_failed")
    refute has_element?(view, "#console-detail button")
    refute has_element?(view, "#console-detail a[href^='/runs/']")

    :sys.replace_state(fake, fn state ->
      environments =
        Enum.map(state.snapshot.environments, &%{&1 | phase: :stopped, occupies_slot: false, credential: nil})

      %{state | snapshot: %{state.snapshot | environments: environments}}
    end)

    send(view.pid, :observability_updated)
    refute has_element?(view, "#console-list [data-ticket='ops:bon-143']")
    assert has_element?(view, "#console-detail", "Select a ticket")
  end

  @tag snapshot: %{
         @recovery_snapshot
         | queued: [
             %{
               issue_id: "bon-143",
               identifier: "BON-143",
               title: "Run the judges",
               state: "In Progress",
               issue_url: "https://linear.app/example/issue/BON-143",
               labels: [],
               priority: nil,
               blocked_by: []
             }
           ]
       }
  test "a queued issue with a recovery blocker remains in the attention view", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&attention=1&ticket=ops%3Abon-143")
    assert has_element?(view, "#console-list [data-group='blocked'] [data-ticket='ops:bon-143']", "Run the judges")
    assert has_element?(view, "#console-detail .console-kv", "In Progress")
    assert has_element?(view, "#environment-detail", "checkpoint_failed")
    refute has_element?(view, "#queued-note")
    refute has_element?(view, "#console-detail button")
  end

  @tag snapshot: @recovery_snapshot
  test "environment-only selections reject forged agent actions and panels", %{conn: conn} do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Abon-143")

    for panel <- ["stop", "reply"] do
      render_hook(view, "panel", %{"panel" => panel})
      refute has_element?(view, "#stop-confirm")
      refute has_element?(view, "#reply-form")
    end

    for event <- ["approve", "reply", "retry_now", "stop"] do
      render_hook(view, event, %{"message" => "Do not post this"})
      assert has_element?(view, "#flash-error", "No agent run is available for this workstation.")
    end

    refute_receive {:orchestrator_call, _}, 50
    refute_receive {:memory_tracker_state_update, _, _}, 50
    refute_receive {:memory_tracker_comment, _, _}, 50
  end

  @tag snapshot: %{
         @recovery_snapshot
         | environments: [
             %{
               issue_id: "bon-143",
               issue_identifier: "BON-143",
               phase: :unknown,
               desired: :stopped,
               occupies_slot: true,
               credential: nil,
               unresolved: %{operation: :reconcile, category: :unknown, code: :environment_state_unknown}
             }
           ]
       }
  test "unresolved workstation details explain an unknown environment phase", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&attention=1&ticket=ops%3Abon-143")
    assert has_element?(view, "#console-list [data-ticket='ops:bon-143']")
    assert has_element?(view, "#environment-detail", "unknown")
    assert has_element?(view, "#environment-detail", "environment_state_unknown")
    refute has_element?(view, "#console-detail button")
  end

  @tag snapshot: %{
         running: [],
         blocked: [],
         retrying: [],
         claimed: 0,
         codex_totals: %{},
         rate_limits: nil,
         queued: [
           %{issue_id: "q-2", identifier: "OPS-5", title: "Free", state: "Todo"}
           |> Map.merge(%{labels: [], issue_url: nil, priority: nil, blocked_by: []})
         ]
       }
  test "an unblocked queued ticket waits for a slot", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Aq-2")
    assert has_element?(view, "#queued-note", "Dispatches when a slot frees up.")
  end

  test "a lane that crashed in the last hour warns under its sidebar entry", %{conn: conn, lane: lane} do
    {:ok, entry} = LaneStore.lookup(lane.id)
    crashed = fn at -> %{entry | runtime: %{entry.runtime | restarts: 2, last_crash: %{reason: ":boom", at: at}}} end
    :ok = LaneStore.put_entry(crashed.(DateTime.utc_now()))
    {:ok, view, _html} = live(conn, "/?lane=ops")
    assert has_element?(view, "#lane-crash-ops", "restarted 2×")

    :ok = LaneStore.put_entry(crashed.(DateTime.add(DateTime.utc_now(), -7200)))
    send(view.pid, :observability_updated)
    refute has_element?(view, "#lane-crash-ops")
  end

  test "poll trackers asks the scoped lanes to poll now", %{conn: conn, fake: fake} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    view |> element("#poll-trackers") |> render_click()
    assert has_element?(view, "#flash-info", "Polling 1 lane(s) now.")

    GenServer.stop(fake)
    view |> element("#poll-trackers") |> render_click()
    assert has_element?(view, "#flash-error", "nothing was polled")
  end

  test "grouped list and history render from lane snapshots", %{conn: conn, lane: lane} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    refute has_element?(view, ".console-strip")
    assert has_element?(view, "#console-list [data-group='running'] [data-ticket='ops:run-1']", "In Progress")
    assert has_element?(view, "#console-list [data-group='queued'] [data-ticket='ops:q-1']", "⊘ OPS-1")
    assert has_element?(view, "#console-detail", "Select a ticket")
    assert has_element?(view, "#lane-nav-ops", "1/2")

    issue = %Issue{
      id: "old-1",
      identifier: "OPS-9",
      title: "Old work",
      state: "Done",
      url: "https://linear.app/o/OPS-9"
    }

    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "old-att", attempt: 1})
    :ok = Runs.event("old-att", %{event: :turn_completed, message: "wrapped up"}, %{}, 1)
    :ok = Runs.finished("old-att", "done")
    :ok = Runs.flush()
    send(view.pid, :observability_updated)
    assert has_element?(view, "#console-list [data-group='finished'] [data-ticket='ops:old-1']", "Old work")

    view |> element("#console-list [data-ticket='ops:old-1']") |> render_click()
    assert has_element?(view, "#console-detail .console-chip", "attempt 1 · done")
    assert has_element?(view, "#console-detail .console-events", "wrapped up")
    assert has_element?(view, "#console-detail a[href='https://linear.app/o/OPS-9']", "Open in tracker")
  end

  test "tracker grouping, attention filter and selection live in the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    view |> element("#group-tracker") |> render_click()
    assert_patch(view, "/?lane=ops&group=tracker")
    assert has_element?(view, "#console-list [data-group='state:In Progress'] [data-ticket='ops:run-1']", "running")

    view |> element("#attention-toggle") |> render_click()
    assert_patch(view, "/?lane=ops&group=tracker&attention=1")
    refute has_element?(view, "#console-list [data-ticket='ops:run-1']")

    view |> element("#console-list [data-ticket='ops:blk-1']") |> render_click()
    assert_patch(view, "/?lane=ops&group=tracker&attention=1&ticket=ops%3Ablk-1")
    assert has_element?(view, "#console-detail h2", "Rotate deploy key")

    view |> element("#group-status") |> render_click()
    assert_patch(view, "/?lane=ops&attention=1&ticket=ops%3Ablk-1")
  end

  test "the all-lanes view tags rows with their lane and the sidebar links configuration", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#console-list [data-ticket='ops:run-1'] .console-lane-tag", "ops")
    assert has_element?(view, ".console-side a.console-brand[href='/']", "Symphony")
    assert has_element?(view, ".console-configure a[href='/lanes']", "Lanes")
    assert has_element?(view, ".console-configure a[href='/execution-profiles']", "Execution profiles")
    view |> element("#lane-nav-ops") |> render_click()
    assert_patch(view, "/?lane=ops")
  end

  test "lane cards moved to /lanes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes")
    assert has_element?(view, "#lane-ops")
  end

  test "console_path defaults to no overrides" do
    nav = %{lane: nil, group: :status, attention: false, selected: nil}
    assert SymphonyElixirWeb.ConsoleComponents.console_path(nav) == "/"
  end

  @tag snapshot: %{running: [], blocked: [], retrying: [], queued: [], claimed: 0, codex_totals: %{}, rate_limits: nil}
  test "an idle lane with no live tickets shows the idle dot", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    assert has_element?(view, "#lane-nav-ops .console-dot--idle")
  end

  test "finished rows show run status and the panel labels the stored state", %{conn: conn, lane: lane} do
    issue = %Issue{id: "old-2", identifier: "OPS-7", title: "Shipped last week", state: "In Progress"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "old-2-att", attempt: 1})

    :ok =
      Runs.event(
        "old-2-att",
        %{event: :usage},
        %{input_tokens: 5_000_000, output_tokens: 2_600, total_tokens: 5_002_600},
        3
      )

    :ok = Runs.finished("old-2-att", "done")
    :ok = Runs.flush()

    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Aold-2")
    assert has_element?(view, "#console-list [data-ticket='ops:old-2'] .console-chip", "done")
    refute has_element?(view, "#console-list [data-ticket='ops:old-2']", "In Progress")
    assert has_element?(view, "#console-detail dt", "Tracker state at dispatch")
    assert has_element?(view, "#console-detail dd", "5.0m in · 2.6k out")
  end

  test "a disabled lane says so instead of showing free slots", %{conn: conn, lane: lane} do
    {:ok, entry} = LaneStore.lookup(lane.id)
    :ok = LaneStore.put_entry(%{entry | enabled: false})
    {:ok, view, _html} = live(conn, "/?lane=ops")
    assert has_element?(view, "#lane-nav-ops .console-count", "off")
    refute has_element?(view, "#lane-nav-ops", "/2")
  end

  @tag snapshot: %{running: [], blocked: [], retrying: [], queued: [], claimed: 0, codex_totals: %{}, rate_limits: nil}
  test "a blocked run from history is only a finished ticket", %{conn: conn, lane: lane} do
    issue = %Issue{id: "old-blk", identifier: "OPS-8", title: "Blocked long ago", state: "Blocked / Needs Attention"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "old-blk-att", attempt: 1})
    :ok = Runs.finished("old-blk-att", "blocked")
    :ok = Runs.flush()

    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Aold-blk")
    assert has_element?(view, "#console-list [data-group='finished'] [data-ticket='ops:old-blk']")
    refute has_element?(view, "#console-list [data-group='blocked'] [data-ticket='ops:old-blk']")
    assert has_element?(view, "#lane-nav-ops .console-dot--idle")
    assert has_element?(view, "#attention-toggle .console-count", "0")
    refute has_element?(view, "#console-detail button")

    view |> element("#attention-toggle") |> render_click()
    refute has_element?(view, "#console-list [data-ticket='ops:old-blk']")
  end

  @tag snapshot: %{
         running: [
           %{
             issue_id: "run-2",
             identifier: "OPS-5",
             title: "Bump deps",
             labels: [],
             attempt_id: "att-2",
             state: "In Progress",
             session_id: "s3",
             turn_count: 1,
             last_codex_event: :notification,
             last_codex_message: nil,
             started_at: DateTime.utc_now(),
             last_codex_timestamp: DateTime.utc_now(),
             codex_input_tokens: 1,
             codex_output_tokens: 1,
             codex_total_tokens: 2
           }
         ],
         blocked: [],
         retrying: [],
         queued: [],
         claimed: 0,
         codex_totals: %{},
         rate_limits: nil
       }
  test "a lane running agents with nothing blocked shows the active dot", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    assert has_element?(view, "#lane-nav-ops .console-dot--on")
  end

  test "the detail panel shows attempts and the latest activity", %{conn: conn, lane: lane} do
    issue = %Issue{id: "run-1", identifier: "OPS-1", title: "Cache deps in CI", state: "In Progress"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "att-1", attempt: 1})
    :ok = Runs.event("att-1", %{event: :session_started, message: %{event: :session_started, message: nil}}, %{}, 0)

    # The orchestrator stores its update summary; the agent's text is nested inside it.
    summary = %{event: :usage_updated, message: "Reading make-all.yml", timestamp: DateTime.utc_now()}
    :ok = Runs.event("att-1", %{event: :usage_updated, message: summary}, %{input_tokens: 5}, 1)
    :ok = Runs.event("att-1", %{event: :usage_updated, message: summary}, %{input_tokens: 5}, 1)
    :ok = Runs.flush()

    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    assert has_element?(view, "#console-detail a[href='/runs/att-1']", "Full run log")
    assert has_element?(view, "#console-detail a[href='/runs/att-1']", "attempt 1 · running")
    assert has_element?(view, "#console-detail .console-events .console-turn", "New turn")
    assert has_element?(view, "#console-detail .console-events", "Reading make-all.yml")
    refute has_element?(view, "#console-detail .console-events", "usage_updated")
    refute has_element?(view, "#console-detail .console-events", "in 5 / out 0")
    assert has_element?(view, "#console-detail", "3 / 20")
  end

  test "stop asks for confirmation, then calls the lane orchestrator", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    view |> element("#console-detail button", "Stop run") |> render_click()
    assert has_element?(view, "#stop-confirm")
    view |> element("#stop-confirm button", "Keep running") |> render_click()
    refute has_element?(view, "#stop-confirm")

    view |> element("#console-detail button", "Stop run") |> render_click()
    view |> element("#stop-confirm button", "Stop run") |> render_click()
    assert_receive {:orchestrator_call, {:operator_stop, "run-1"}}
    assert has_element?(view, "#flash-info", "OPS-1 stopped.")
  end

  @tag reply: {:error, :not_retrying}
  test "a stale action explains why nothing changed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arty-1")
    view |> element("#console-detail button", "Retry now") |> render_click()
    assert_receive {:orchestrator_call, {:operator_retry_now, "rty-1"}}
    assert has_element?(view, "#flash-error", "OPS-3 was not changed: it is no longer waiting to retry.")
  end

  test "approve and reply resume a blocked runtime ticket with workstation details", %{conn: conn, fake: fake} do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    :sys.replace_state(fake, fn state ->
      environment = %{hd(@recovery_snapshot.environments) | issue_id: "blk-1", issue_identifier: "OPS-2"}
      %{state | snapshot: Map.put(state.snapshot, :environments, [environment])}
    end)

    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Ablk-1")
    assert has_element?(view, "#environment-detail", "checkpoint_failed")

    view |> element("#console-detail button", "Approve") |> render_click()
    assert_receive {:memory_tracker_state_update, "blk-1", "Todo"}
    assert_receive {:orchestrator_call, {:operator_release_blocked, "blk-1"}}
    assert has_element?(view, "#flash-info", "OPS-2 resumed.")

    view |> element("#console-detail button", "Reply to agent") |> render_click()
    view |> element("#reply-form button", "Cancel") |> render_click()
    refute has_element?(view, "#reply-form")

    view |> element("#console-detail button", "Reply to agent") |> render_click()
    view |> form("#reply-form", message: "Palette is in tokens/dark.json") |> render_submit()
    assert_receive {:memory_tracker_comment, "blk-1", "Palette is in tokens/dark.json"}
    assert has_element?(view, "#flash-info", "OPS-2 resumed with your reply.")
  end

  @tag reply: {:error, :unavailable}
  test "unknown tickets show the empty panel and actions need a selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?ticket=ops%3Agone")
    assert has_element?(view, "#console-detail", "Select a ticket")
    assert render_hook(view, "approve", %{}) =~ "Select a ticket first."

    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    view |> element("#console-detail button", "Stop run") |> render_click()
    view |> element("#stop-confirm button", "Stop run") |> render_click()
    assert has_element?(view, "#flash-error", "OPS-1 was not changed: the lane is not running.")
  end

  @tag reply: {:error, :not_running}
  test "stopping a finished run says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    view |> element("#console-detail button", "Stop run") |> render_click()
    view |> element("#stop-confirm button", "Stop run") |> render_click()
    assert has_element?(view, "#flash-error", "its run already ended")
  end

  @tag blocked?: false
  test "approving a ticket that is no longer blocked says so", %{conn: conn} do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Ablk-1")
    view |> element("#console-detail button", "Approve") |> render_click()
    assert has_element?(view, "#flash-error", "OPS-2 was not changed: it is no longer blocked.")
    refute_receive {:memory_tracker_state_update, _, _}, 50
  end

  test "resume failures name the cause", %{conn: conn} do
    Memory.fail(:update_issue_state)
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Ablk-1")
    view |> element("#console-detail button", "Approve") |> render_click()
    assert has_element?(view, "#flash-error", "the tracker returned {:memory_tracker_failed, :update_issue_state}")
  end

  test "a lane without another active state cannot resume", %{conn: conn, lane: lane} do
    {:ok, _} =
      Lanes.update(lane, %{
        config: %{"tracker" => %{"kind" => "memory", "active_states" => ["Blocked / Needs Attention"]}}
      })

    {:ok, entry} = LaneStore.lookup(lane.id)
    :ok = LaneStore.put_entry(%{entry | enabled: true})
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Ablk-1")
    view |> element("#console-detail button", "Approve") |> render_click()
    assert has_element?(view, "#flash-error", "the lane has no active state to move it to")
  end

  defp snapshot do
    now = DateTime.utc_now()

    %{
      running: [
        %{
          issue_id: "run-1",
          identifier: "OPS-1",
          title: "Cache deps in CI",
          labels: ["ci"],
          attempt_id: "att-1",
          state: "In Progress",
          session_id: "s1",
          worker_host: "worker-a",
          workspace_path: "/ws/OPS-1",
          turn_count: 3,
          last_codex_event: :notification,
          last_codex_message: nil,
          started_at: DateTime.add(now, -724),
          last_codex_timestamp: now,
          codex_input_tokens: 3_100_000,
          codex_output_tokens: 1_800,
          codex_total_tokens: 3_101_800
        }
      ],
      blocked: [
        %{
          issue_id: "blk-1",
          identifier: "OPS-2",
          title: "Rotate deploy key",
          labels: [],
          state: "Blocked / Needs Attention",
          error: "approval_required: needs a human",
          session_id: "s2",
          blocked_at: now,
          last_codex_event: :approval_required,
          last_codex_message: "waiting on operator approval",
          last_codex_timestamp: now
        }
      ],
      retrying: [
        %{
          issue_id: "rty-1",
          identifier: "OPS-3",
          title: "Pin OTP",
          state: "Todo",
          labels: [],
          attempt: 2,
          due_in_ms: 60_000,
          error: "turn_failed"
        }
      ],
      queued: [
        %{
          issue_id: "q-1",
          identifier: "OPS-4",
          title: "Backups",
          state: "Todo",
          labels: [],
          issue_url: nil,
          priority: nil,
          blocked_by: ["OPS-1"]
        }
      ],
      claimed: 0,
      codex_totals: %{},
      rate_limits: nil
    }
  end
end
