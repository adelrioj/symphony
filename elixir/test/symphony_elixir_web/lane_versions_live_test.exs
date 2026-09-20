defmodule SymphonyElixirWeb.LaneVersionsLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Repo}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    endpoint_config = :symphony_elixir |> Application.get_env(SymphonyElixirWeb.Endpoint, []) |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true})}
  end

  test "lists versions newest first, marks the current one, and make-current rolls back live", %{conn: conn} do
    {:ok, lane} =
      Lanes.create(%{slug: "vers", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => 1000}}, prompt: "v1", note: "one"})

    v1 = lane.current_version_id
    {:ok, lane} = Lanes.update(lane, %{config: %{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => 2000}}, note: "two"})
    v2 = lane.current_version_id

    {:ok, view, html} = live(conn, "/lanes/vers/versions")
    assert html =~ "two"
    assert has_element?(view, "#version-#{v2} .state-badge", "current")
    refute has_element?(view, "#version-#{v1} .state-badge")
    assert Floki.find(Floki.parse_document!(html), "#versions tbody tr") |> Enum.map(&Floki.attribute(&1, "id")) == [["version-#{v2}"], ["version-#{v1}"]]

    view |> element("#version-#{v1} button[phx-click='activate']") |> render_click()
    assert has_element?(view, "#version-#{v1} .state-badge", "current")
    assert Lanes.get!(lane.id).current_version_id == v1
    assert {:ok, %{settings: %{polling: %{interval_ms: 1000}}}} = LaneStore.lookup(lane.id)
    assert length(Lanes.versions(lane)) == 2
  end

  test "rejects malformed IDs and versions belonging to another lane", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "mine", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}, prompt: "mine"})
    {:ok, other} = Lanes.create(%{slug: "other", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}, prompt: "other"})
    {:ok, view, _html} = live(conn, "/lanes/mine/versions")

    render_click(view, "activate", %{"id" => [Integer.to_string(other.current_version_id)]})
    assert has_element?(view, "#version-errors", "version_id:")
    render_click(view, "activate", %{"id" => "not-a-number"})
    assert has_element?(view, "#version-errors", "version_id:")
    render_click(view, "activate", %{"id" => "9223372036854775808"})
    assert has_element?(view, "#version-errors", "version:")
    render_click(view, "activate", %{"id" => Integer.to_string(other.current_version_id)})
    assert has_element?(view, "#version-errors", "version:")
    assert Lanes.current_version(Lanes.get!(lane.id)).prompt == "mine"
    assert [%{id: version_id}] = Lanes.versions(lane)
    assert version_id == lane.current_version_id
  end

  test "external saves and activations update an open history page", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "external", execution_profile_id: new_profile!().id, config: %{"tracker" => %{"kind" => "memory"}}, prompt: "first"})
    {:ok, view, _html} = live(conn, "/lanes/external/versions")
    {:ok, updated} = Lanes.update(lane, %{prompt: "second", note: "external save"})
    assert has_element?(view, "#version-#{updated.current_version_id} .state-badge", "current")
    {:ok, _} = Lanes.activate_version(updated, lane.current_version_id)
    assert has_element?(view, "#version-#{lane.current_version_id} .state-badge", "current")
    assert has_element?(view, "#versions", "external save")
    :ok = Lanes.delete(lane)
    assert_redirect(view, "/")
  end

  test "history inspection shows lane-owned content and preserves malformed source", %{conn: conn} do
    {:ok, lane} =
      Lanes.create(%{
        slug: "inspect-history",
        execution_profile_id: new_profile!().id,
        config: %{"tracker" => %{"kind" => "memory", "api_key" => "literal-secret"}, "extension" => %{"keep" => true}},
        prompt: "historical prompt"
      })

    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/versions")
    assert has_element?(view, "#version-#{lane.current_version_id} details", "historical prompt")
    assert has_element?(view, "#version-#{lane.current_version_id} details", "$REDACTED")
    refute render(view) =~ "literal-secret"

    version = Lanes.current_version(lane)
    Repo.update!(Ecto.Changeset.change(version, front_matter: "tracker:\n  api_key: malformed-literal-secret\n  values: [\noriginal malformed source", prompt: "repair me"))
    send(view.pid, {:lane_updated, lane.slug})

    assert has_element?(view, "#version-#{version.id} .field-error", "Invalid historical front matter")
    assert has_element?(view, "#version-#{version.id} details", "original malformed source")
    assert has_element?(view, "#version-#{version.id} details", "repair me")
    assert has_element?(view, "#version-#{version.id} details", "$REDACTED")
    refute render(view) =~ "malformed-literal-secret"
  end

  test "an unknown slug goes back to the lanes page", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/lanes/nope/versions")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/lanes/nope")
  end

  defp new_profile! do
    {:ok, profile} =
      ExecutionProfiles.create(%{name: "Versions #{System.unique_integer([:positive])}", workspace_base: Path.join(System.tmp_dir!(), "versions-#{System.unique_integer([:positive])}"), worker: %{}})

    profile
  end
end
