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

    render_change(view, "validate", %{
      "lane" => %{
        "slug" => "features",
        "name" => "Features",
        "prompt" => "keep this prompt",
        "tracker_api_key" => "$LINEAR_API_KEY",
        "tracker_required_labels" => "ready",
        "advanced_json" => advanced
      }
    })

    view |> element("button", "Create profile inline") |> render_click()
    assert has_element?(view, "#profile-create-panel")
    assert has_element?(view, "#lane-prompt", "keep this prompt")
    assert has_element?(view, "#advanced-json", "extension")

    view |> form("#profile-create-form", profile: %{name: "Inline profile", workspace_base: Path.join(System.tmp_dir!(), "inline-profile")}) |> render_submit()
    profile = Enum.find(ExecutionProfiles.list(), &(&1.name == "Inline profile"))
    assert profile
    assert has_element?(view, "#profile-select option[selected]", "Inline profile")
    assert has_element?(view, "#lane-prompt", "keep this prompt")

    view
    |> form("#lane-form", lane: %{slug: "features", name: "Features", prompt: "keep this prompt", tracker_api_key: "$LINEAR_API_KEY", advanced_json: advanced})
    |> render_submit()

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

  test "optional values clear, dashboard toggles off, and Jira remains selectable", %{conn: conn} do
    profile = new_profile!()

    {:ok, lane} =
      Lanes.create(%{
        slug: "clear-values",
        execution_profile_id: profile.id,
        config: %{
          "tracker" => %{
            "kind" => "jira",
            "active_states" => ["To Do"],
            "terminal_states" => ["Done"],
            "provider" => %{
              "base_url" => "https://jira.example.com",
              "email" => "operator@example.com",
              "api_token" => "test-token",
              "project_key" => "OPS"
            }
          },
          "hooks" => %{"before_run" => "echo old", "timeout_ms" => 1_000},
          "observability" => %{"dashboard_enabled" => true}
        }
      })

    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    assert has_element?(view, "#tracker-kind option[value='jira'][selected]")

    view
    |> form("#lane-form",
      lane: %{
        hooks_before_run: "",
        hooks_timeout_ms: "",
        observability_dashboard_enabled: "false"
      }
    )
    |> render_submit()

    version = lane.id |> Lanes.get!() |> Lanes.current_version()
    assert {:ok, workflow} = Workflow.parse_parts(version.front_matter, version.prompt)
    refute get_in(workflow.config, ["hooks", "before_run"])
    refute get_in(workflow.config, ["hooks", "timeout_ms"])
    assert get_in(workflow.config, ["observability", "dashboard_enabled"]) == false
  end

  test "a malformed lane event cannot terminate the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes/new")
    render_submit(view, "save", %{"lane" => ["not", "an", "object"]})
    assert has_element?(view, "#lane-errors", "lane:")
    assert has_element?(view, "#lane-form")
  end

  test "unknown edits redirect and duplicate creates keep their validation error", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/lanes/not-found/edit")

    profile = new_profile!()
    {:ok, _lane} = Lanes.create(%{slug: "duplicate", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, view, _html} = live(conn, "/lanes/new")

    view
    |> form("#lane-form",
      lane: %{
        slug: "duplicate",
        name: "Duplicate",
        execution_profile_id: to_string(profile.id),
        workspace_subdir: "duplicate"
      }
    )
    |> render_submit()

    assert has_element?(view, "#lane-errors", "already been taken")
    assert length(Enum.filter(Lanes.list(), &(&1.slug == "duplicate"))) == 1
  end

  test "external updates preserve a draft and external deletion redirects", %{conn: conn} do
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "external-editor", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}, prompt: "saved"})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")

    render_change(view, "validate", %{"lane" => %{"prompt" => "unsaved draft"}})
    assert {:ok, _} = Lanes.update(lane, %{name: "Externally renamed"})
    assert has_element?(view, "#lane-prompt", "unsaved draft")

    assert :ok = Lanes.delete(Lanes.get!(lane.id))
    assert_redirect(view, "/")
  end

  test "saving an open editor does not overwrite a newer enabled state", %{conn: conn} do
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "enabled-editor", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")

    assert {:ok, %{enabled: true}} = Lanes.set_enabled(lane, true)
    view |> form("#lane-form", lane: %{name: "Saved while running"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert Lanes.get!(lane.id).enabled
  end

  defp new_profile! do
    {:ok, profile} =
      ExecutionProfiles.create(%{name: "Lane test #{System.unique_integer([:positive])}", workspace_base: Path.join(System.tmp_dir!(), "lane-test-#{System.unique_integer([:positive])}"), worker: %{}})

    profile
  end
end
