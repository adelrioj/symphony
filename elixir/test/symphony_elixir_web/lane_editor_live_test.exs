defmodule SymphonyElixirWeb.LaneEditorLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Lanes

  @endpoint SymphonyElixirWeb.Endpoint
  @fixtures Path.expand("../fixtures/lanes", __DIR__)

  setup do
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    endpoint_config = :symphony_elixir |> Application.get_env(SymphonyElixirWeb.Endpoint, []) |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    previous_key = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "test-linear-api-key")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_key) end)
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true})}
  end

  test "validation errors show inline with the field path and nothing is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")

    html = view |> form("#lane-form", lane: %{slug: "Bad Slug", front_matter: "polling:\n  interval_ms: nope", prompt: ""}) |> render_change()
    assert html =~ "polling.interval_ms"
    assert has_element?(view, "#lane-errors li", "slug:")

    html = view |> form("#lane-form", lane: %{slug: "Bad Slug", front_matter: "polling:\n  interval_ms: nope", prompt: ""}) |> render_submit()
    assert html =~ "polling.interval_ms"
    assert has_element?(view, "#lane-errors li", "slug:")
    assert Lanes.list() |> Enum.map(& &1.slug) == ["default"]

    view |> form("#lane-form", lane: %{slug: "yaml-draft", front_matter: "tracker:\n  kind: memory\nserver:\n  port: 4000", prompt: "keep this draft"}) |> render_change()
    assert has_element?(view, "#lane-warnings", "server")
    view |> form("#lane-form", lane: %{front_matter: "tracker: ["}) |> render_submit()
    assert has_element?(view, "#lane-errors li", "front_matter:")
    refute has_element?(view, "#lane-warnings")
    assert has_element?(view, "textarea[name='lane[front_matter]']", "tracker: [")
    assert has_element?(view, "textarea[name='lane[prompt]']", "keep this draft")
    assert is_nil(Lanes.get_by_slug("yaml-draft"))
  end

  test "saving a new lane inserts a version and navigates to the lane page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")

    view
    |> form("#lane-form", lane: %{slug: "features", name: "Features", front_matter: "tracker:\n  kind: memory\nserver:\n  port: 1", prompt: "Do it", note: "first"})
    |> render_submit()

    assert_redirect(view, "/lanes/features")

    lane = Lanes.get_by_slug("features")
    assert [%{note: "first", prompt: "Do it"}] = Lanes.versions(lane)
  end

  test "the creation slug is rejected without persistence and a corrected slug reaches its dashboard", %{conn: conn} do
    lanes_before = Lanes.list()
    versions_before = SymphonyElixir.Repo.aggregate(SymphonyElixir.Lanes.LaneVersion, :count)
    {:ok, view, _html} = live(conn, "/lanes/new")

    view
    |> form("#lane-form", lane: %{slug: "new", name: "New work", front_matter: "tracker:\n  kind: memory", prompt: "Keep this draft"})
    |> render_submit()

    assert has_element?(view, "#lane-errors li", "slug:")
    assert Lanes.list() == lanes_before
    assert SymphonyElixir.Repo.aggregate(SymphonyElixir.Lanes.LaneVersion, :count) == versions_before
    assert is_nil(Lanes.get_by_slug("new"))

    view |> form("#lane-form", lane: %{slug: "new-work"}) |> render_submit()
    assert_redirect(view, "/lanes/new-work")
    lane = Lanes.get_by_slug("new-work")
    assert [%{prompt: "Keep this draft"}] = Lanes.versions(lane)

    {:ok, dashboard, _html} = live(conn, "/lanes/new-work")
    assert has_element?(dashboard, ".hero-title", "New work")
    assert has_element?(dashboard, "a[href='/lanes/new-work/versions']")
    refute has_element?(dashboard, "#lane-form")
  end

  for fixture <- ["client-template.md", "example.md"] do
    test "editor round-trips #{fixture} without changing YAML comments or the empty prompt", %{conn: conn} do
      path = Path.join(@fixtures, unquote(fixture))
      content = File.read!(path)
      {:ok, lane, _} = Lanes.import_file(path, slug: "client")

      {:ok, view, _html} = live(conn, "/lanes/client/edit")
      assert has_element?(view, "#lane-warnings", "server")
      assert has_element?(view, "textarea[name='lane[front_matter]']", "kind: linear")

      # Submit the rendered fields rather than reinjecting the original fixture.
      view |> form("#lane-form", lane: %{note: "resave"}) |> render_submit()
      assert_redirect(view, "/lanes/client")

      assert {:ok, ^content} = Lanes.export(Lanes.get!(lane.id))
      assert [%{note: "resave"}, _original] = Lanes.versions(lane)
    end
  end

  test "an unchanged editor preserves leading newlines in both raw sections", %{conn: conn} do
    front_matter = "\ntracker:\n  kind: memory\n"
    prompt = "\nKeep this leading blank line.\n"
    {:ok, lane} = Lanes.create(%{slug: "newlines", front_matter: front_matter, prompt: prompt})
    document = conn |> get("/lanes/newlines/edit") |> html_response(200) |> LazyHTML.from_document()
    rendered_front_matter = document |> LazyHTML.query("textarea[name='lane[front_matter]']") |> LazyHTML.text()
    rendered_prompt = document |> LazyHTML.query("textarea[name='lane[prompt]']") |> LazyHTML.text()
    assert rendered_front_matter == front_matter
    assert rendered_prompt == prompt
    {:ok, view, _html} = live(conn, "/lanes/newlines/edit")

    # LiveViewTest's form defaults strip a second LF after HTML5 parsing.
    # Submit the actual browser-equivalent DOM values, not the original inputs.
    render_submit(view, "save", %{"lane" => %{"front_matter" => rendered_front_matter, "prompt" => rendered_prompt, "note" => "unchanged"}})
    assert_redirect(view, "/lanes/newlines")
    version = Lanes.current_version(Lanes.get!(lane.id))
    assert version.front_matter == front_matter
    assert version.prompt == prompt
  end

  test "malformed text fields report errors without discarding the current draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")
    render_change(view, "validate", %{"lane" => %{"slug" => "draft", "front_matter" => "tracker:\n  kind: memory", "prompt" => "keep this draft"}})
    render_change(view, "validate", %{"lane" => %{"front_matter" => %{"nested" => "invalid"}, "prompt" => ["invalid"]}})

    assert has_element?(view, "#lane-errors li", "front_matter:")
    assert has_element?(view, "#lane-errors li", "prompt:")
    assert has_element?(view, "textarea[name='lane[prompt]']", "keep this draft")
    assert has_element?(view, "textarea[name='lane[front_matter]']", "kind: memory")
    assert is_nil(Lanes.get_by_slug("draft"))
  end

  test "a malformed lane event cannot save or terminate the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")
    render_submit(view, "save", %{"lane" => ["not", "an", "object"]})
    assert has_element?(view, "#lane-errors li", "lane:")
    assert Lanes.list() |> Enum.map(& &1.slug) == ["default"]
  end

  test "partial edit events retain enabled state and unsaved input during external updates", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "partial", name: "Partial", front_matter: "tracker:\n  kind: memory", prompt: "initial"})
    {:ok, view, _html} = live(conn, "/lanes/partial/edit")
    render_change(view, "validate", %{"lane" => %{"prompt" => "unsaved", "enabled" => "on"}})
    assert has_element?(view, "input[name='lane[enabled]'][checked]")
    render_submit(view, "save", %{"lane" => %{"enabled" => ["false"]}})
    assert has_element?(view, "#lane-errors li", "enabled:")
    assert has_element?(view, "input[name='lane[enabled]'][checked]")
    assert has_element?(view, "textarea[name='lane[prompt]']", "unsaved")
    refute Lanes.get!(lane.id).enabled
    assert Lanes.current_version(Lanes.get!(lane.id)).prompt == "initial"
    {:ok, _lane} = Lanes.update(lane, %{name: "External"})
    assert has_element?(view, "textarea[name='lane[prompt]']", "unsaved")

    render_submit(view, "save", %{"lane" => %{"note" => "partial event"}})
    assert_redirect(view, "/lanes/partial")
    assert Lanes.get!(lane.id).enabled
    assert Lanes.current_version(Lanes.get!(lane.id)).prompt == "unsaved"
  end

  test "duplicate slugs show errors without losing the submitted prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")
    view |> form("#lane-form", lane: %{slug: "default", name: "Duplicate", front_matter: "tracker:\n  kind: memory", prompt: "preserve me"}) |> render_submit()
    assert has_element?(view, "#lane-errors li", "slug:")
    assert has_element?(view, "textarea[name='lane[prompt]']", "preserve me")
  end

  test "deleting the edited lane redirects rather than allowing a stale save", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "removed", front_matter: "tracker:\n  kind: memory"})
    {:ok, view, _html} = live(conn, "/lanes/removed/edit")
    :ok = Lanes.delete(lane)
    assert_redirect(view, "/")
  end

  test "a save racing the deletion notification cannot resurrect the lane or append a version", %{conn: conn} do
    {:ok, lane} = Lanes.create(%{slug: "stale-editor", front_matter: "tracker:\n  kind: memory", prompt: "saved"})
    {:ok, view, _html} = live(conn, "/lanes/stale-editor/edit")

    # Model the committed soft deletion before its PubSub notification reaches this editor.
    lane
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> SymphonyElixir.Repo.update!()

    view |> form("#lane-form", lane: %{prompt: "unsaved after deletion"}) |> render_submit()

    assert has_element?(view, "#lane-errors li", "lane:")
    assert has_element?(view, "textarea[name='lane[prompt]']", "unsaved after deletion")
    assert is_nil(Lanes.get_by_slug("stale-editor"))
    assert [%{prompt: "saved"}] = Lanes.versions(lane)
  end

  test "an unknown slug goes back to the lanes page", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/lanes/nope/edit")
  end
end
