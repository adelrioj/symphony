defmodule SymphonyElixirWeb.LaneEditorLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes, Workflow}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    endpoint_config = :symphony_elixir |> Application.get_env(SymphonyElixirWeb.Endpoint, []) |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    previous_key = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "test-linear-api-key")

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous)
      restore_env("LINEAR_API_KEY", previous_key)
    end)

    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true})}
  end

  test "the four sections expose structured controls and retain a pending draft through profile creation", %{conn: conn} do
    {:ok, view, html} = live(conn, "/lanes/new")
    assert html =~ "Work selection"
    assert html =~ "Execution"
    assert html =~ "Workflow"
    assert html =~ "Limits"
    refute html =~ "Executor"

    advanced = Jason.encode!(%{"tracker" => %{"kind" => "memory", "api_key" => "$LINEAR_API_KEY"}, "extension" => %{"nested" => [1, true]}}, pretty: true)

    render_change(view, "validate", %{"lane" => %{"slug" => "features", "name" => "Features", "prompt" => "keep this prompt", "tracker_required_labels" => "ready", "advanced_json" => advanced}})
    view |> element("button", "Create profile inline") |> render_click()
    assert has_element?(view, "#profile-create-panel")
    assert has_element?(view, "#lane-prompt", "keep this prompt")
    assert has_element?(view, "#advanced-json", "extension")

    view |> form("#profile-create-form", profile: %{name: "Inline profile", workspace_base: Path.join(System.tmp_dir!(), "inline-profile")}) |> render_submit()
    profile = Enum.find(ExecutionProfiles.list(), &(&1.name == "Inline profile"))
    assert profile
    assert has_element?(view, "#profile-select option[selected]", "Inline profile")
    assert has_element?(view, "#lane-prompt", "keep this prompt")

    view |> form("#lane-form", lane: %{slug: "features", name: "Features", prompt: "keep this prompt", advanced_json: advanced}) |> render_submit()
    assert_redirect(view, "/lanes/features")
    lane = Lanes.get_by_slug("features")
    assert lane.execution_profile_id == profile.id
    version = Lanes.current_version(lane)
    assert {:ok, workflow} = Workflow.parse_parts(version.front_matter, version.prompt)
    assert workflow.config["extension"] == %{"nested" => [1, true]}
    assert workflow.config["tracker"]["api_key"] == "$LINEAR_API_KEY"
  end

  test "canceling inline profile creation keeps the draft untouched", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")
    render_change(view, "validate", %{"lane" => %{"slug" => "cancelled", "name" => "Pending", "prompt" => "draft survives"}})
    view |> element("button", "Create profile inline") |> render_click()
    view |> element("#profile-create-panel button", "Cancel") |> render_click()
    refute has_element?(view, "#profile-create-panel")
    assert has_element?(view, "#lane-prompt", "draft survives")
    assert has_element?(view, "#lane-slug[value='cancelled']")
    refute Enum.any?(ExecutionProfiles.list(), &(&1.name == ""))
  end

  test "unknown nested config and raw secret references survive an unrelated name edit", %{conn: conn} do
    config = %{"tracker" => %{"kind" => "memory", "api_key" => "$LINEAR_API_KEY"}, "extension" => %{"nested" => [%{"keep" => true}]}}
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "lossless", name: "Before", execution_profile_id: profile.id, config: config, prompt: "prompt"})
    {:ok, view, _html} = live(conn, "/lanes/lossless/edit")
    view |> form("#lane-form", lane: %{name: "After"}) |> render_submit()
    assert_redirect(view, "/lanes/lossless")
    version = Lanes.current_version(Lanes.get!(lane.id))
    {:ok, workflow} = Workflow.parse_parts(version.front_matter, version.prompt)
    assert workflow.config["extension"] == %{"nested" => [%{"keep" => true}]}
    assert workflow.config["tracker"]["api_key"] == "$LINEAR_API_KEY"
  end

  test "malformed advanced JSON reports an error without saving or discarding the draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")
    render_change(view, "validate", %{"lane" => %{"slug" => "bad-json", "prompt" => "preserve me", "advanced_json" => "{"}})
    assert has_element?(view, "#lane-errors", "advanced:")
    assert has_element?(view, "#lane-prompt", "preserve me")
    assert is_nil(Lanes.get_by_slug("bad-json"))
    render_submit(view, "save", %{"lane" => %{"advanced_json" => "{"}})
    assert has_element?(view, "#lane-errors", "advanced:")
    assert is_nil(Lanes.get_by_slug("bad-json"))
  end

  test "slug mutation is rejected by the domain", %{conn: conn} do
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "immutable", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    assert {:error, [%{path: "slug", message: "is immutable"}]} = Lanes.update(lane, %{slug: "changed"})
    {:ok, _view, _html} = live(conn, "/lanes/immutable/edit")
  end

  test "a malformed lane event cannot terminate the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")
    render_submit(view, "save", %{"lane" => ["not", "an", "object"]})
    assert has_element?(view, "#lane-errors", "lane:")
    assert has_element?(view, "#lane-form")
  end

  defp new_profile! do
    {:ok, profile} =
      ExecutionProfiles.create(%{name: "Lane test #{System.unique_integer([:positive])}", workspace_base: Path.join(System.tmp_dir!(), "lane-test-#{System.unique_integer([:positive])}"), worker: %{}})

    profile
  end
end
