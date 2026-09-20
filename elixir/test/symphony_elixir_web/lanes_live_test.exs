defmodule SymphonyElixirWeb.LanesLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, LaneRegistry, Lanes, LaneStore, LaneSupervisor}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    endpoint_config = :symphony_elixir |> Application.get_env(SymphonyElixirWeb.Endpoint, []) |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true})}
  end

  test "renders one card per lane with state, links, and last error", %{conn: conn} do
    {:ok, bugs} = Lanes.create(%{slug: "bugs", name: "Bugs", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}, prompt: "b"})
    :ok = LaneStore.mark_error(bugs.id, "Tracker preflight failed: unknown team")

    {:ok, view, html} = live(conn, "/")
    assert html =~ "default"
    assert has_element?(view, "#lane-bugs", "Bugs")
    assert has_element?(view, "#lane-bugs", "Tracker preflight failed")
    assert has_element?(view, "#lane-bugs a[href='/lanes/bugs']")
    assert has_element?(view, "#lane-bugs a[href='/lanes/bugs/edit']")
    assert has_element?(view, "a[href='/lanes/new']")
    assert has_element?(view, "#lane-bugs", "disabled")
  end

  test "the toggle enables and disables a lane and the card follows pubsub updates", %{conn: conn} do
    {:ok, lane} =
      Lanes.create(%{
        slug: "qa",
        execution_profile_id: new_profile!().id,
        config: %{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => 60000}, "codex" => %{"command" => "/bin/false"}},
        prompt: "q"
      })

    {:ok, view, _html} = live(conn, "/")

    view |> element("#lane-qa button[phx-click='toggle']") |> render_click()
    assert Lanes.get!(lane.id).enabled
    wait_until(fn -> LaneSupervisor.running?(lane.id) end)
    wait_until(fn -> has_element?(view, "#lane-qa .state-badge", "running") end)
    assert has_element?(view, "#lane-qa", "running 0")
    assert has_element?(view, "#lane-qa", "claimed 0")
    assert has_element?(view, "#lane-qa", "blocked 0")

    runtime = LaneRegistry.whereis(lane.id, :runtime)
    Process.exit(runtime, :kill)
    wait_until(fn -> has_element?(view, "#lane-qa", "restarts 1") end)
    wait_until(fn -> LaneSupervisor.running?(lane.id) end)

    view |> element("#lane-qa button[phx-click='toggle']") |> render_click()
    refute Lanes.get!(lane.id).enabled
    wait_until(fn -> not LaneSupervisor.running?(lane.id) end)
    wait_until(fn -> has_element?(view, "#lane-qa .state-badge", "disabled") end)
  end

  test "external store changes add and remove cards without an injected broadcast", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    {:ok, lane} = Lanes.create(%{slug: "external", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}})
    wait_until(fn -> has_element?(view, "#lane-external") end)
    :ok = LaneStore.mark_error(lane.id, "Tracker preflight failed")
    wait_until(fn -> has_element?(view, "#lane-external", "Tracker preflight failed") end)
    :ok = Lanes.delete(lane)
    wait_until(fn -> not has_element?(view, "#lane-external") end)
  end

  test "an unresponsive lane keeps its error and controls visible until snapshot counts recover", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "slow-snapshot", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => 60000}}})
    {:ok, lane} = Lanes.set_enabled(lane, true)
    wait_until(fn -> LaneSupervisor.running?(lane.id) end)
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#lane-slow-snapshot .numeric", "running 0")

    :ok = LaneStore.mark_error(lane.id, "Tracker temporarily unavailable")
    wait_until(fn -> has_element?(view, "#lane-slow-snapshot .state-badge-danger", "error") end)
    orchestrator = LaneRegistry.whereis(lane.id, :orchestrator)
    :ok = :sys.suspend(orchestrator)

    try do
      send(view.pid, :observability_updated)
      assert has_element?(view, "#lane-slow-snapshot .error-copy", "Tracker temporarily unavailable")
      assert has_element?(view, "#lane-slow-snapshot .state-badge-danger", "error")
      refute has_element?(view, "#lane-slow-snapshot .numeric")
      assert has_element?(view, "#lane-slow-snapshot button[phx-click='toggle']", "Disable")
      assert has_element?(view, "#lane-slow-snapshot a[href='/lanes/slow-snapshot/edit']")
      assert has_element?(view, "#lane-default")
    after
      :ok = :sys.resume(orchestrator)
    end

    send(view.pid, :observability_updated)
    assert has_element?(view, "#lane-slow-snapshot .numeric", "running 0")
    assert has_element?(view, "#lane-slow-snapshot .state-badge-danger", "error")
  end

  test "invalid and deleted toggle IDs show an error without mutating another lane", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "removed", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, view, _html} = live(conn, "/")
    render_click(view, "toggle", %{})
    assert has_element?(view, "#flash-error", "lane:")
    render_click(view, "toggle", %{"id" => "malformed"})
    assert has_element?(view, "#flash-error", "lane:")
    :ok = Lanes.delete(lane)
    render_click(view, "toggle", %{"id" => Integer.to_string(lane.id)})
    assert has_element?(view, "#flash-error", "lane:")
    assert Enum.map(Lanes.list(), & &1.slug) == ["default"]
  end

  test "bearer authentication supports the connected landing view and mutations" do
    {:ok, lane} = Lanes.create(%{slug: "bearer", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}})
    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Bearer test-token")
    {:ok, view, _html} = live(conn, "/")
    view |> element("#lane-bearer button[phx-click='toggle']") |> render_click()
    assert Lanes.get!(lane.id).enabled
    wait_until(fn -> has_element?(view, "#lane-bearer .state-badge", "running") end)
  end

  test "a lane whose scheduler is restarting keeps controls visible and recovers counts", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "restarting", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, lane} = Lanes.set_enabled(lane, true)
    wait_until(fn -> is_pid(LaneRegistry.whereis(lane.id, :orchestrator)) end)
    runtime = LaneRegistry.whereis(lane.id, :runtime)
    orchestrator = LaneRegistry.whereis(lane.id, :orchestrator)
    :ok = :sys.suspend(runtime)
    monitor = Process.monitor(orchestrator)
    Process.exit(orchestrator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^orchestrator, :killed}
    wait_until(fn -> LaneRegistry.whereis(lane.id, :orchestrator) == nil end)

    try do
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#lane-restarting button[phx-click='toggle']", "Disable")
      refute has_element?(view, "#lane-restarting .numeric")
      assert has_element?(view, "#lane-default")
      :ok = :sys.resume(runtime)
      wait_until(fn -> has_element?(view, "#lane-restarting .numeric", "running 0") end)
    after
      :sys.resume(runtime)
    end
  end

  test "the landing page explains how to create a lane when the installation is empty", %{conn: conn} do
    :ok = Lanes.delete(Lanes.get_by_slug("default"))
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, ".empty-state", "No lanes yet")
    assert has_element?(view, "a[href='/lanes/new']")
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met")

      true ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)
    end
  end

  defp new_profile! do
    {:ok, profile} =
      ExecutionProfiles.create(%{
        name: "Lanes live #{System.unique_integer([:positive])}",
        workspace_base: Path.join(System.tmp_dir!(), "lanes-live-#{System.unique_integer([:positive])}"),
        worker: %{}
      })

    profile
  end
end
