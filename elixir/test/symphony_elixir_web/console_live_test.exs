defmodule SymphonyElixirWeb.ConsoleLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Runs, Tracker.Memory}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}
    def handle_call({:operator_blocked?, _issue_id}, _from, state), do: {:reply, state.blocked?, state}
    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: []}, state}

    def handle_call(message, _from, state) do
      send(state.parent, {:orchestrator_call, message})
      {:reply, state.reply, state}
    end
  end

  setup context do
    {:ok, fake} = FakeOrchestrator.start_link(%{snapshot: Map.get(context, :snapshot, snapshot()), parent: self(), reply: Map.get(context, :reply, :ok), blocked?: Map.get(context, :blocked?, true)})
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: fake))
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    {:ok, profile} =
      ExecutionProfiles.create(%{name: "Console #{System.unique_integer([:positive])}", workspace_base: Path.join(System.tmp_dir!(), "console-#{System.unique_integer([:positive])}"), worker: %{}})

    {:ok, lane} =
      Lanes.create(%{
        slug: "ops",
        name: "Ops",
        execution_profile_id: profile.id,
        config: %{"tracker" => %{"kind" => "memory", "active_states" => ["Todo", "In Progress"]}, "agent" => %{"max_concurrent_agents" => 2}}
      })

    {:ok, entry} = LaneStore.lookup(lane.id)
    :ok = LaneStore.put_entry(%{entry | enabled: true})
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true}), lane: lane}
  end

  test "strip, grouped list and history render from lane snapshots", %{conn: conn, lane: lane} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    assert has_element?(view, "#strip-ops [data-ticket='ops:run-1']", "Cache deps in CI")
    assert has_element?(view, "#strip-ops [data-ticket='ops:blk-1']", "blocked")
    assert has_element?(view, "#strip-ops .console-tile--idle", "1 idle")
    assert has_element?(view, "#console-list [data-group='running'] [data-ticket='ops:run-1']", "In Progress")
    assert has_element?(view, "#console-list [data-group='queued'] [data-ticket='ops:q-1']", "⊘ OPS-1")
    assert has_element?(view, "#console-detail", "Select a ticket")
    assert has_element?(view, "#lane-nav-ops", "1/2")

    issue = %Issue{id: "old-1", identifier: "OPS-9", title: "Old work", state: "Done"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "old-att", attempt: 1})
    :ok = Runs.event("old-att", %{event: :turn_completed, message: "wrapped up"}, %{}, 1)
    :ok = Runs.finished("old-att", "done")
    :ok = Runs.flush()
    send(view.pid, :observability_updated)
    assert has_element?(view, "#console-list [data-group='finished'] [data-ticket='ops:old-1']", "Old work")

    view |> element("#console-list [data-ticket='ops:old-1']") |> render_click()
    assert has_element?(view, "#console-detail .console-chip", "attempt 1 · done")
    assert has_element?(view, "#console-detail .console-events", "wrapped up")
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

  test "the all-lanes view tags rows with their lane and links lane management", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#console-list [data-ticket='ops:run-1'] .console-lane-tag", "ops")
    assert has_element?(view, "a[href='/lanes']", "Manage lanes")
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
    :ok = Runs.event("att-1", %{event: :notification, message: "Reading make-all.yml"}, %{}, 1)
    :ok = Runs.flush()

    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    assert has_element?(view, "#console-detail a[href='/runs/att-1']", "Full run log")
    assert has_element?(view, "#console-detail a[href='/runs/att-1']", "attempt 1 · running")
    assert has_element?(view, "#console-detail .console-events", "Reading make-all.yml")
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

  test "approve and reply resume a blocked ticket through the tracker", %{conn: conn} do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Ablk-1")

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
    {:ok, _} = Lanes.update(lane, %{config: %{"tracker" => %{"kind" => "memory", "active_states" => ["Blocked / Needs Attention"]}}})
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
          turn_count: 3,
          last_codex_event: :notification,
          last_codex_message: nil,
          started_at: now,
          last_codex_timestamp: now,
          codex_input_tokens: 10,
          codex_output_tokens: 2,
          codex_total_tokens: 12
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
