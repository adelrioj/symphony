defmodule SymphonyElixirWeb.RunLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{LaneContext, Lanes, Repo, Runs}
  alias SymphonyElixir.Runs.Event
  alias SymphonyElixirWeb.ObservabilityPubSub

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    endpoint_config = Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64))
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    issue = %Issue{id: "i", identifier: "RL-1", title: "t", description: "d", state: "Todo", url: "https://example.org/RL-1", dispatchable: true}
    :ok = Runs.started(%{lane_id: LaneContext.current!(), issue: issue, attempt_id: "att-live", attempt: nil, worker_ref: nil})
    :ok = Runs.event("att-live", %{event: :session_started, message: "booted", session_id: "s"}, %{}, 1)
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true})}
  end

  test "tails committed events and updates totals before the run finishes", %{conn: conn} do
    {:ok, view, html} = live(conn, "/runs/att-live")
    assert html =~ "RL-1"
    assert has_element?(view, "#run-status", "running")
    assert has_element?(view, "#events li", "booted")

    :ok = Runs.event("att-live", %{event: :turn_completed, message: "finished turn", session_id: "s"}, %{input_tokens: 3, output_tokens: 4, cached_tokens: 2, total_tokens: 7}, 2)
    :ok = Runs.flush()
    wait_until(fn -> has_element?(view, "#events li", "finished turn") end)
    assert has_element?(view, "#events li", "usage")
    assert has_element?(view, "#run-totals", "Turns 2")
    assert has_element?(view, "#run-totals", "in 3 / out 4 / cached 2 / total 7")
    assert has_element?(view, "#run-status", "running")

    :ok = Runs.finished("att-live", "done")
    :ok = Runs.flush()
    wait_until(fn -> has_element?(view, "#run-status", "done") end)
    assert has_element?(view, "#run-timings", "finished")
    assert has_element?(view, "#run-totals", "total 7")
  end

  test "elapsed time advances without new events and freezes after completion", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/runs/att-live")
    first_elapsed = elapsed_seconds(view)
    wait_until(fn -> elapsed_seconds(view) > first_elapsed end)
    second_elapsed = elapsed_seconds(view)
    wait_until(fn -> elapsed_seconds(view) > second_elapsed end)

    :ok = Runs.finished("att-live", "done")
    :ok = Runs.flush()
    wait_until(fn -> has_element?(view, "#run-status", "done") end)
    finished_timings = view |> element("#run-timings") |> render()
    send(view.pid, :runtime_tick)
    assert view |> element("#run-timings") |> render() == finished_timings
  end

  test "foreign notifications cannot contaminate the tail or refresh a removed attempt", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/runs/att-live")
    issue = %Issue{id: "foreign", identifier: "OTHER-1", title: "Other", state: "Todo"}
    :ok = Runs.started(%{lane_id: LaneContext.current!(), issue: issue, attempt_id: "foreign-run"})
    :ok = Runs.event("foreign-run", %{event: :notification, message: "foreign payload"}, %{}, 1)
    [foreign_event] = Runs.events(Runs.get_by_attempt("foreign-run").id)

    ObservabilityPubSub.broadcast_run("att-live", {:run_event, foreign_event})
    refute has_element?(view, "#events li", "foreign payload")
    assert has_element?(view, "#events li", "booted")

    Repo.delete!(Runs.get_by_attempt("att-live"))
    ObservabilityPubSub.broadcast_run("att-live", {:run_updated, "foreign-run"})
    assert has_element?(view, "#run-status", "running")

    ObservabilityPubSub.broadcast_run("att-live", {:run_updated, "att-live"})
    assert_redirect(view, "/")
  end

  test "retained event payloads without messages remain readable and escaped", %{conn: conn} do
    :ok = Runs.event("att-live", %{event: :turn_completed, message: ""}, %{}, 1)
    :ok = Runs.finished("att-live", "done")
    run = Runs.get_by_attempt("att-live")
    payload = %{"detail" => "<script>alert('retained')</script>"}
    Repo.insert!(%Event{run_id: run.id, at: DateTime.utc_now(), kind: "agent_message", payload: payload})

    {:ok, view, _html} = live(conn, "/runs/att-live")
    assert has_element?(view, "#events li", "turn_completed")
    assert has_element?(view, "#events li", Jason.encode!(payload))
    refute has_element?(view, "#events script")
    assert has_element?(view, "#run-status", "done")
  end

  test "connection reloads a run that finished after its static render", %{conn: conn} do
    conn = get(conn, "/runs/att-live")
    assert html_response(conn, 200) =~ "running"
    :ok = Runs.finished("att-live", "failed")
    {:ok, view, _html} = live(conn)
    assert has_element?(view, "#run-status", "failed")
    assert has_element?(view, "#run-timings", "finished")
  end

  test "concurrent initial history and tail retain each event once in persisted order", %{conn: conn} do
    producer =
      Task.async(fn ->
        for number <- 1..20 do
          Runs.event("att-live", %{event: :notification, message: "message #{number}", session_id: "s"}, %{}, 1)
        end

        Runs.finished("att-live", "done")
        Runs.flush()
      end)

    {:ok, view, _html} = live(conn, "/runs/att-live")
    Task.await(producer)
    wait_until(fn -> has_element?(view, "#run-status", "done") and has_element?(view, "#events li", "message 20") end)
    events = Runs.events(Runs.get_by_attempt("att-live").id)
    ids = view |> render() |> Floki.parse_document!() |> Floki.find("#events li") |> Enum.flat_map(&Floki.attribute(&1, "id"))
    assert ids == Enum.map(events, &"events-#{&1.id}")
    assert length(ids) == 21
  end

  test "retained history remains readable after its lane is removed", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "historical", front_matter: "tracker:\n  kind: memory"})
    issue = %Issue{id: "old", identifier: "OLD-1", title: "Old", state: "Done"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "old-run"})
    :ok = Runs.finished("old-run", "done")
    :ok = Runs.flush()
    :ok = Lanes.delete(lane)
    {:ok, view, _html} = live(conn, "/runs/old-run")
    assert has_element?(view, "#run-status", "done")
    assert has_element?(view, ".hero-copy", "removed")
    refute has_element?(view, "a[href='/lanes/historical']")
    assert has_element?(view, ".empty-state", "No events")
  end

  test "an unknown attempt returns to lanes", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/runs/nope")
  end

  defp elapsed_seconds(view) do
    text = view |> element("#run-timings") |> render() |> Floki.parse_document!() |> Floki.text()
    [_, elapsed] = Regex.run(~r/elapsed (\d+)s/, text)
    String.to_integer(elapsed)
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("run view did not receive its committed update")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
