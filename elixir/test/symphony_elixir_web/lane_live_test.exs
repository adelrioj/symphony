defmodule SymphonyElixirWeb.LaneLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes, Runs}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64)))
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true})}
  end

  test "disabled lanes retain scoped history even without an available runtime", %{conn: conn} do
    profile_id = new_profile!().id
    {:ok, lane} = Lanes.create(%{slug: "history", name: "History", execution_profile_id: profile_id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, other} = Lanes.create(%{slug: "other", execution_profile_id: profile_id, config: %{"tracker" => %{"kind" => "memory"}}})
    record_run(lane.id, "mine", "SAME-1")
    record_run(other.id, "theirs", "SAME-1")

    {:ok, view, _html} = live(conn, "/lanes/history")
    assert has_element?(view, ".hero-title", "History")
    assert has_element?(view, ".error-title", "Snapshot unavailable")
    assert has_element?(view, "#run-mine a[href='/runs/mine']")
    refute has_element?(view, "#run-theirs")
    assert has_element?(view, "a[href='/lanes/history/edit']")
    assert has_element?(view, "a[href='/lanes/history/versions']")
  end

  test "new attempts and completion update recent history from the Runs producer", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "live-history", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, view, _html} = live(conn, "/lanes/live-history")
    assert has_element?(view, "#recent-runs .empty-state")
    issue = %Issue{id: "new", identifier: "NEW-1", title: "New", state: "Todo"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "new-run"})
    :ok = Runs.flush()
    wait_until(fn -> has_element?(view, "#run-new-run", "running") end)
    :ok = Runs.event("new-run", %{event: :turn_completed, message: "completed"}, %{input_tokens: 3, output_tokens: 4, total_tokens: 7}, 1)
    :ok = Runs.finished("new-run", "done")
    :ok = Runs.flush()
    wait_until(fn -> has_element?(view, "#run-new-run .state-badge", "done") end)
    assert has_element?(view, "#run-new-run td.numeric", "7")
    :ok = Lanes.delete(lane)
    assert_redirect(view, "/")
  end

  defp record_run(lane_id, attempt_id, identifier) do
    issue = %Issue{id: attempt_id, identifier: identifier, title: "Issue", state: "Todo"}
    :ok = Runs.started(%{lane_id: lane_id, issue: issue, attempt_id: attempt_id})
    :ok = Runs.finished(attempt_id, "done")
    :ok = Runs.flush()
  end

  defp new_profile! do
    {:ok, profile} =
      ExecutionProfiles.create(%{name: "Lane live #{System.unique_integer([:positive])}", workspace_base: Path.join(System.tmp_dir!(), "lane-live-#{System.unique_integer([:positive])}"), worker: %{}})

    profile
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("lane history did not receive its committed update")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
