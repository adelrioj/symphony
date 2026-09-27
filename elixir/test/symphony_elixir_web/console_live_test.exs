defmodule SymphonyElixirWeb.ConsoleLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Runs}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}
    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: []}, state}

    def handle_call(message, _from, state) do
      send(state.parent, {:orchestrator_call, message})
      {:reply, state.reply, state}
    end
  end

  setup context do
    {:ok, fake} = FakeOrchestrator.start_link(%{snapshot: Map.get(context, :snapshot, snapshot()), parent: self(), reply: Map.get(context, :reply, :ok)})
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
