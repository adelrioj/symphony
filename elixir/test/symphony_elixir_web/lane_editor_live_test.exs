defmodule SymphonyElixirWeb.LaneEditorLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Repo, Workflow}

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
        "tracker_kind" => "linear",
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

    render_change(view, "validate", %{"lane" => %{"tracker_kind" => "memory"}})

    view
    |> form("#lane-form", lane: %{slug: "features", name: "Features", prompt: "keep this prompt", tracker_kind: "memory", advanced_json: advanced})
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

  test "new lanes show schema defaults, structured adapter fields, and exact duration conversion", %{conn: conn} do
    profile = new_profile!()
    {:ok, view, html} = live(conn, "/lanes/new")
    assert html =~ ~s(name="lane[polling_interval_ms]" value="30")
    assert html =~ ~s(name="lane[codex_command]" value="codex app-server")
    assert html =~ ~s(name="lane[observability_render_interval_ms]" value="0.016")

    render_change(view, "validate", %{"lane" => %{"tracker_kind" => "github"}})
    assert has_element?(view, "#github-repo")
    assert has_element?(view, "#github-token")

    render_change(view, "validate", %{"lane" => %{"slug" => "exact-duration", "name" => "Exact duration", "tracker_kind" => "memory", "polling_interval_ms" => "0"}})
    assert has_element?(view, "#limits .field-error", "must be greater than 0")

    view
    |> form("#lane-form", lane: %{slug: "exact-duration", name: "Exact duration", execution_profile_id: profile.id, tracker_kind: "memory", polling_interval_ms: "0.017"})
    |> render_submit()

    lane = Lanes.get_by_slug("exact-duration")
    assert lane
    assert {:ok, workflow} = Workflow.parse_parts(Lanes.current_version(lane).front_matter, "")
    assert get_in(workflow.config, ["polling", "interval_ms"]) == 17
  end

  test "a blank new-lane workspace follows the complete slug", %{conn: conn} do
    profile = new_profile!()
    {:ok, view, _html} = live(conn, "/lanes/new")

    render_change(view, "validate", %{"lane" => %{"slug" => "f"}})
    assert has_element?(view, "#lane-workspace-subdir[value='']")
    render_change(view, "validate", %{"lane" => %{"slug" => "features"}})

    view
    |> form("#lane-form", lane: %{slug: "features", name: "Features", execution_profile_id: profile.id, tracker_kind: "memory"})
    |> render_submit()

    assert Lanes.get_by_slug("features").workspace_subdir == "features"
  end

  @tag :tmp_dir
  test "an unchanged SSH location remains editable while its host is unavailable", %{conn: conn, tmp_dir: root} do
    fake_ssh = Path.join(root, "ssh")
    previous_path = System.get_env("PATH")
    File.write!(fake_ssh, "#!/bin/sh\nprintf '/remote/base\\t/remote/base/ssh-editor\\n'\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))
    on_exit(fn -> restore_env("PATH", previous_path) end)

    {:ok, profile} = ExecutionProfiles.create(%{name: "SSH editor", workspace_base: "/remote/base", worker: %{"ssh_hosts" => ["host-a"]}})
    {:ok, lane} = Lanes.create(%{slug: "ssh-editor", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    File.rm!(fake_ssh)

    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    view |> form("#lane-form", lane: %{name: "Renamed offline"}) |> render_submit()

    assert_redirect(view, "/lanes/#{lane.slug}")
    assert Lanes.get!(lane.id).name == "Renamed offline"
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

  @tag :remediation
  test "remediation: a name-only sparse lane edit preserves absent settings and their effective defaults", %{conn: conn} do
    profile = new_profile!()
    config = %{"tracker" => %{"kind" => "memory"}, "agent" => %{"in_progress_state" => ""}, "claude" => %{"allowed_tools" => []}}
    {:ok, lane} = Lanes.create(%{slug: "sparse-editor", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")

    view |> form("#lane-form", lane: %{name: "Sparse renamed"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert Lanes.get!(lane.id).name == "Sparse renamed"
    assert saved_config(lane) == config
    assert {:ok, settings} = Schema.parse(saved_config(lane))
    assert settings.observability.dashboard_enabled

    {:ok, toggled_view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    assert has_element?(toggled_view, "#observability-dashboard-enabled[checked]")
    toggled_view |> form("#lane-form", lane: %{observability_dashboard_enabled: "false"}) |> render_submit()
    assert_redirect(toggled_view, "/lanes/#{lane.slug}")
    assert saved_config(lane) == Map.put(config, "observability", %{"dashboard_enabled" => false})
  end

  @tag :remediation
  test "remediation: sparse lane JSON defaults remain editable without materializing unrelated settings", %{conn: conn} do
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "sparse-explicit-edit", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")

    view
    |> form("#lane-form", lane: %{codex_approval_policy_json: ~s("never")})
    |> render_change()

    view |> form("#lane-form", lane: %{name: "Explicit sparse changes"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")

    assert saved_config(lane) == %{
             "tracker" => %{"kind" => "memory"},
             "codex" => %{"approval_policy" => "never"}
           }
  end

  @tag :remediation
  test "remediation: a name-only edit preserves meaningful empty settings while optional hooks can still be cleared", %{conn: conn} do
    profile = new_profile!()

    {:ok, lane} =
      Lanes.create(%{
        slug: "meaningful-empty",
        name: "Before",
        execution_profile_id: profile.id,
        config: %{
          "tracker" => %{"kind" => "memory"},
          "agent" => %{"backend" => "claude", "in_progress_state" => ""},
          "claude" => %{"allowed_tools" => []},
          "hooks" => %{"before_run" => "echo keep"}
        }
      })

    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    # form/3 submits the rendered empty controls, JSON textareas, and hidden inputs too.
    view |> form("#lane-form", lane: %{name: "After"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    config = saved_config(lane)
    assert config["agent"]["in_progress_state"] == ""
    assert config["claude"]["allowed_tools"] == []
    assert config["hooks"]["before_run"] == "echo keep"

    {:ok, clearing_view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    clearing_view |> form("#lane-form", lane: %{hooks_before_run: ""}) |> render_submit()
    assert_redirect(clearing_view, "/lanes/#{lane.slug}")
    cleared = saved_config(lane)
    refute Map.has_key?(cleared["hooks"] || %{}, "before_run")
    assert cleared["agent"]["in_progress_state"] == ""
    assert cleared["claude"]["allowed_tools"] == []
  end

  @tag :remediation
  test "remediation: a name-only Linear edit retains canonical provider credentials and endpoint", %{conn: conn} do
    previous_key = System.get_env("LANE_LINEAR_API_KEY")
    System.put_env("LANE_LINEAR_API_KEY", "lane-specific-key")
    on_exit(fn -> restore_env("LANE_LINEAR_API_KEY", previous_key) end)
    profile = new_profile!()

    {:ok, lane} =
      Lanes.create(%{
        slug: "canonical-linear",
        execution_profile_id: profile.id,
        config: %{
          "tracker" => %{
            "kind" => "linear",
            "provider" => %{
              "api_key" => "$LANE_LINEAR_API_KEY",
              "endpoint" => "https://linear.example.test/graphql",
              "team_keys" => ["OPS"],
              "extension" => %{"keep" => true}
            }
          }
        }
      })

    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    view |> form("#lane-form", lane: %{name: "Canonical renamed"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    provider = saved_config(lane)["tracker"]["provider"]
    assert provider["api_key"] == "$LANE_LINEAR_API_KEY"
    assert provider["endpoint"] == "https://linear.example.test/graphql"
    assert provider["extension"] == %{"keep" => true}
  end

  test "nullable Linear provider data opens and preserves legacy credentials on an unrelated edit", %{conn: conn} do
    profile = new_profile!()

    {:ok, lane} =
      Lanes.create(%{
        slug: "nullable-linear",
        execution_profile_id: profile.id,
        config: %{
          "tracker" => %{
            "kind" => "linear",
            "provider" => nil,
            "api_key" => "$LINEAR_API_KEY",
            "endpoint" => "https://linear.example.test/graphql",
            "project_slug" => "legacy-project"
          }
        }
      })

    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    assert has_element?(view, "#tracker-api-key[value='$LINEAR_API_KEY']")
    view |> form("#lane-form", lane: %{name: "Nullable renamed"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    provider = saved_config(lane)["tracker"]["provider"]
    assert provider["api_key"] == "$LINEAR_API_KEY"
    assert provider["endpoint"] == "https://linear.example.test/graphql"
    assert provider["project_slug"] == "legacy-project"
  end

  test "nullable Linear children retain legacy fallbacks without overriding canonical values", %{conn: conn} do
    profile = new_profile!()

    config = %{
      "tracker" => %{
        "kind" => "linear",
        "api_key" => "lane-specific-token",
        "endpoint" => "https://legacy.example.test/graphql",
        "project_slug" => "legacy-project",
        "assignee" => "lane-owner",
        "provider" => %{
          "api_key" => nil,
          "endpoint" => "https://canonical.example.test/graphql",
          "project_slug" => nil,
          "assignee" => nil
        }
      }
    }

    assert {:ok, before} = Schema.parse(config)
    assert before.tracker.api_key == "lane-specific-token"
    {:ok, lane} = Lanes.create(%{slug: "nullable-linear-children", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    view |> form("#lane-form", lane: %{name: "Unrelated rename"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert {:ok, after_edit} = Schema.parse(saved_config(lane))
    assert after_edit.tracker == before.tracker
  end

  test "structured tracker inputs redact dollar-prefixed literal secrets without replacing them on save", %{conn: conn} do
    profile = new_profile!()
    provider = %{"api_key" => "$private-token", "team_keys" => ["OPS"]}
    {:ok, lane} = Lanes.create(%{slug: "literal-dollar-secret", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "linear", "provider" => provider}}})

    {:ok, view, html} = live(conn, "/lanes/#{lane.slug}/edit")
    refute html =~ "$private-token"
    assert has_element?(view, "#tracker-api-key[value='$REDACTED']")
    view |> form("#lane-form", lane: %{name: "Secret retained"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert saved_config(lane)["tracker"]["provider"] == provider
  end

  @tag :remediation
  test "remediation: malformed named JSON retains a recoverable lane draft and leaves storage unchanged", %{conn: conn} do
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "named-json", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}, prompt: "saved prompt"})
    version = Lanes.current_version(lane)
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")

    view
    |> form("#lane-form", lane: %{name: "Draft name", prompt: "unsaved prompt", agent_backend_by_state_json: "{"})
    |> render_change()

    assert has_element?(view, "#lane-errors[role='alert']", "agent_backend_by_state")
    assert has_element?(view, "#agent-backend-by-state", "{")
    assert has_element?(view, "#lane-prompt", "unsaved prompt")
    assert has_element?(view, "#lane-name[value='Draft name']")
    view |> form("#lane-form") |> render_submit()
    assert has_element?(view, "#lane-errors[role='alert']", "agent_backend_by_state")
    assert Lanes.current_version(Lanes.get!(lane.id)).id == version.id

    view |> form("#lane-form", lane: %{agent_backend_by_state_json: ~s({"Review":"claude"})}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    updated = Lanes.get!(lane.id)
    assert updated.name == "Draft name"
    assert Lanes.current_version(updated).prompt == "unsaved prompt"
    assert saved_config(lane)["agent"]["backend_by_state"] == %{"Review" => "claude"}
  end

  @tag :remediation
  test "remediation: an unrelated lane edit restores credentials inside nested arrays", %{conn: conn} do
    profile = new_profile!()
    extension = %{"groups" => [%{"accounts" => [%{"token" => "lane-array-secret", "api_key" => "$LINEAR_API_KEY", "label" => "primary"}]}]}
    {:ok, lane} = Lanes.create(%{slug: "array-secrets", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}, "extension" => extension}})
    {:ok, view, html} = live(conn, "/lanes/#{lane.slug}/edit")
    refute html =~ "lane-array-secret"
    assert has_element?(view, "#advanced-json", "$REDACTED")

    view |> form("#lane-form", lane: %{name: "Array renamed"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert saved_config(lane)["extension"] == extension
  end

  for {scenario, original, forged} <- [
        {"missing original", %{}, %{"new_token" => "$REDACTED"}},
        {"scalar replaced by object", %{"account" => "plain"}, %{"account" => %{"token" => "$REDACTED"}}}
      ] do
    @tag :remediation
    test "remediation: lane redaction forgery with #{scenario} returns an error without discarding the draft", %{conn: conn} do
      profile = new_profile!()
      original = unquote(Macro.escape(original))
      forged = unquote(Macro.escape(forged))
      slug = "forged-#{System.unique_integer([:positive])}"
      {:ok, lane} = Lanes.create(%{slug: slug, execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}, "extension" => original}})
      version = Lanes.current_version(lane)
      {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
      advanced = Jason.encode!(%{"extension" => forged})

      view |> form("#lane-form", lane: %{prompt: "keep forged draft", advanced_json: advanced}) |> render_change()
      assert has_element?(view, "#lane-errors[role='alert']", "extension")
      assert has_element?(view, "#lane-prompt", "keep forged draft")
      assert has_element?(view, "#advanced-json", "$REDACTED")
      view |> form("#lane-form") |> render_submit()
      assert has_element?(view, "#lane-errors[role='alert']", "extension")
      assert Lanes.current_version(Lanes.get!(lane.id)).id == version.id
    end
  end

  for {kind, provider, controls} <- [
        {"gitlab", %{"api_url" => "https://gitlab.example/api/v4", "api_key" => "private-gitlab-key", "project_path" => "team/project"},
         [{"gitlab-api-url", "https://gitlab.example/api/v4"}, {"gitlab-api-key", "$REDACTED"}, {"gitlab-project-path", "team/project"}]},
        {"asana", %{"endpoint" => "https://app.asana.com/api/1.0", "api_key" => "private-asana-key", "project_gid" => "123456"},
         [{"asana-endpoint", "https://app.asana.com/api/1.0"}, {"asana-api-key", "$REDACTED"}, {"asana-project-gid", "123456"}]}
      ] do
    test "#{kind} controls preserve provider values across a name edit", %{conn: conn} do
      profile = new_profile!()
      provider = unquote(Macro.escape(provider))
      {active_state, terminal_state} = if unquote(kind) == "gitlab", do: {"opened", "closed"}, else: {"Todo", "Done"}
      config = %{"tracker" => %{"kind" => unquote(kind), "provider" => provider, "active_states" => [active_state], "terminal_states" => [terminal_state]}}
      {:ok, lane} = Lanes.create(%{slug: "provider-#{unquote(kind)}", execution_profile_id: profile.id, config: config})
      {:ok, view, html} = live(conn, "/lanes/#{lane.slug}/edit")

      for {id, value} <- unquote(Macro.escape(controls)) do
        assert has_element?(view, "##{id}[value='#{value}']")
      end

      refute html =~ provider["api_key"]
      view |> form("#lane-form", lane: %{name: "Renamed provider"}) |> render_submit()
      assert_redirect(view, "/lanes/#{lane.slug}")
      assert saved_config(lane) == config
    end
  end

  test "switching tracker applies only the selected adapter's provider controls", %{conn: conn} do
    profile = new_profile!()
    provider = %{"api_url" => "https://gitlab.example/api/v4", "api_key" => "old-gitlab-key", "project_path" => "team/project"}
    config = %{"tracker" => %{"kind" => "gitlab", "provider" => provider, "active_states" => ["opened"], "terminal_states" => ["closed"]}}
    {:ok, lane} = Lanes.create(%{slug: "switch-adapter", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    view |> form("#lane-form", lane: %{tracker_kind: "github"}) |> render_change()
    refute has_element?(view, "#gitlab-api-url")

    github_params = %{
      github_api_url: "https://api.github.com",
      github_token: "new-github-token",
      github_repo: "org/repo",
      tracker_active_states: "open",
      tracker_terminal_states: "closed"
    }

    view |> form("#lane-form", lane: github_params) |> render_submit()

    assert_redirect(view, "/lanes/#{lane.slug}")
    assert {:ok, settings} = LaneStore.settings(lane.id)
    assert settings.tracker.kind == "github"
    assert settings.tracker.provider["api_url"] == "https://api.github.com"
    assert settings.tracker.provider["token"] == "new-github-token"
  end

  test "explicit policy edits change integer limits and disable the in-progress transition", %{conn: conn} do
    profile = new_profile!()
    config = %{"tracker" => %{"kind" => "memory"}, "agent" => %{"max_turns" => 7, "in_progress_state" => "Doing"}}
    {:ok, lane} = Lanes.create(%{slug: "edit-policy", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    view |> form("#lane-form", lane: %{agent_max_turns: "9", agent_in_progress_state: ""}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert {:ok, settings} = LaneStore.settings(lane.id)
    assert settings.agent.max_turns == 9
    assert settings.agent.in_progress_state == ""
  end

  test "a credential retention marker preserves an existing environment reference", %{conn: conn} do
    profile = new_profile!()
    provider = %{"api_key" => "$LINEAR_API_KEY", "project_slug" => "project"}
    {:ok, lane} = Lanes.create(%{slug: "retain-reference", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "linear", "provider" => provider}}})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    assert has_element?(view, "#tracker-api-key[value='$LINEAR_API_KEY']")
    view |> form("#lane-form", lane: %{tracker_api_key: "$REDACTED"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert saved_config(lane)["tracker"]["provider"]["api_key"] == "$LINEAR_API_KEY"
  end

  test "invalid scalar types and numeric controls preserve the stored lane and its draft", %{conn: conn} do
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "invalid-control", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})

    for {field, value, error_path} <- [
          {"name", %{"nested" => "object"}, "name"},
          {"codex_command", true, "config"},
          {"agent_max_turns", "one", "agent_max_turns"},
          {"observability_dashboard_enabled", "yes", "observability_dashboard_enabled"},
          {"tracker_required_labels", false, "tracker_required_labels"},
          {"agent_max_turns", false, "agent_max_turns"},
          {"advanced_json", "[]", "advanced"},
          {"advanced_json", false, "advanced"},
          {"execution_profile_id", "not-an-id", "execution_profile_id"},
          {"execution_profile_id", false, "execution_profile_id"}
        ] do
      {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
      render_hook(view, "save", %{"lane" => %{field => value, "prompt" => "Retained draft"}})
      assert has_element?(view, "#lane-errors", error_path)
      assert has_element?(view, "#lane-prompt", "Retained draft")
      assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    end
  end

  test "blank and integer-valued controls remove overrides without losing redacted unchanged values", %{conn: conn} do
    profile = new_profile!()
    config = %{"tracker" => %{"kind" => "memory", "required_labels" => ["ready"]}, "agent" => %{"max_turns" => 7, "max_turn_exhaustions" => 2}, "polling" => %{"interval_ms" => 2_000}}
    {:ok, lane} = Lanes.create(%{slug: "clear-integer", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")

    render_hook(view, "save", %{
      "lane" => %{
        "tracker_required_labels" => "$REDACTED",
        "agent_max_turns" => "$REDACTED",
        "polling_interval_ms" => "$REDACTED",
        "agent_max_turn_exhaustions" => "",
        "agent_max_concurrent_agents" => 3,
        "tracker_active_states" => ""
      }
    })

    assert_redirect(view, "/lanes/#{lane.slug}")
    saved = saved_config(lane)
    assert saved["tracker"]["required_labels"] == ["ready"]
    refute Map.has_key?(saved["tracker"], "active_states")
    assert saved["agent"]["max_turns"] == 7
    assert saved["agent"]["max_concurrent_agents"] == 3
    refute Map.has_key?(saved["agent"], "max_turn_exhaustions")
    assert saved["polling"]["interval_ms"] == 2_000
  end

  test "inline profile failures retain the lane draft and external profile options refresh", %{conn: conn} do
    profile = new_profile!()
    {:ok, view, _html} = live(conn, "/lanes/new")
    render_change(view, "validate", %{"lane" => %{"slug" => "pending-inline", "prompt" => "Keep this draft", "tracker_kind" => "memory"}})
    render_submit(view, "create_profile", %{"profile" => false})
    assert has_element?(view, "#profile-create-errors", "profile")

    view |> form("#profile-create-form", profile: %{name: profile.name}) |> render_submit()
    assert has_element?(view, "#profile-create-errors", "already been taken")
    assert has_element?(view, "#lane-prompt", "Keep this draft")

    render_change(view, "validate_profile_create", %{
      "profile" => %{"worker_mode" => "managed", "environment_kind" => "unsupported", "deployment_id" => "existing", "startup_timeout" => "1", "shutdown_timeout" => "2", "terminal_retention" => "0"}
    })

    assert has_element?(view, "#profile-create-errors", "worker")

    external = new_profile!()
    assert has_element?(view, "#profile-select option[value='#{external.id}']")
    assert :ok = ExecutionProfiles.delete(external)
    refute has_element?(view, "#profile-select option[value='#{external.id}']")
    assert has_element?(view, "#lane-prompt", "Keep this draft")
  end

  test "a deleted selected profile cannot be saved from an open creation form", %{conn: conn} do
    profile = new_profile!()
    {:ok, view, _html} = live(conn, "/lanes/new")
    render_change(view, "validate", %{"lane" => %{"slug" => "stale-profile", "execution_profile_id" => to_string(profile.id), "tracker_kind" => "memory"}})
    assert :ok = ExecutionProfiles.delete(profile)
    render_submit(view, "save", %{"lane" => %{"prompt" => "Still a draft"}})
    assert has_element?(view, "#lane-errors", "execution_profile_id")
    assert has_element?(view, "#lane-prompt", "Still a draft")
    assert is_nil(Lanes.get_by_slug("stale-profile"))
  end

  test "a save racing a deletion cannot recreate a lane before its notification arrives", %{conn: conn} do
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "stale-lane-save", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    SymphonyElixir.Repo.update!(Ecto.Changeset.change(lane, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)))
    view |> form("#lane-form", lane: %{name: "Must not resurrect"}) |> render_submit()
    assert has_element?(view, "#lane-errors", "Lane no longer exists")
    assert is_nil(Lanes.get(lane.id))
    assert Lanes.get_any(lane.id).current_version_id == lane.current_version_id
  end

  test "missing and malformed historical configuration can be repaired through the editor", %{conn: conn} do
    profile = new_profile!()

    for {suffix, corrupt} <- [{"missing", :missing}, {"malformed", :malformed}] do
      {:ok, lane} = Lanes.create(%{slug: "repair-#{suffix}", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})

      case corrupt do
        :missing -> SymphonyElixir.Repo.update!(Ecto.Changeset.change(lane, current_version_id: nil))
        :malformed -> SymphonyElixir.Repo.update!(Ecto.Changeset.change(Lanes.current_version(lane), front_matter: "tracker: ["))
      end

      assert :ok = SymphonyElixir.LaneStore.refresh(lane.id)
      {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
      view |> form("#lane-form", lane: %{tracker_kind: "memory", prompt: "Repaired"}) |> render_submit()
      assert_redirect(view, "/lanes/#{lane.slug}")
      assert saved_config(lane)["tracker"]["kind"] == "memory"
      assert Lanes.current_version(Lanes.get!(lane.id)).prompt == "Repaired"
      assert {:ok, %{error: nil}} = SymphonyElixir.LaneStore.lookup(lane.id)
    end
  end

  test "quoted millisecond durations display seconds and survive unrelated edits", %{conn: conn} do
    profile = new_profile!()
    config = %{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => "30017"}}
    {:ok, lane} = Lanes.create(%{slug: "quoted-duration", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    assert has_element?(view, "#polling-interval-ms[value='30.017']")
    view |> form("#lane-form", lane: %{name: "Duration retained"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert saved_config(lane) == config

    {:ok, editing, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    editing |> form("#lane-form", lane: %{polling_interval_ms: "0.019"}) |> render_submit()
    assert_redirect(editing, "/lanes/#{lane.slug}")
    assert saved_config(lane)["polling"]["interval_ms"] == 19
  end

  test "malformed duration values remain repairable without implicit name-only correction", %{conn: conn} do
    profile = new_profile!()

    for {suffix, invalid, displayed} <- [{"text", "broken", "broken"}, {"negative", -500, "-0.5"}] do
      {:ok, lane} = Lanes.create(%{slug: "duration-repair-#{suffix}", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
      version = Lanes.current_version(lane)
      source = Jason.encode!(%{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => invalid}})
      Repo.update!(Ecto.Changeset.change(version, front_matter: source))
      assert :ok = LaneStore.refresh(lane.id)
      {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
      assert has_element?(view, "#polling-interval-ms[value='#{displayed}']")
      view |> form("#lane-form", lane: %{name: "Duration repair draft"}) |> render_submit()
      assert has_element?(view, "#lane-errors", "polling.interval_ms")
      assert Lanes.get!(lane.id).current_version_id == version.id
      view |> form("#lane-form", lane: %{polling_interval_ms: "0.5"}) |> render_submit()
      assert_redirect(view, "/lanes/#{lane.slug}")
      assert saved_config(lane)["polling"]["interval_ms"] == 500
      assert Repo.get!(version.__struct__, version.id).front_matter == source
    end
  end

  test "schema-cast booleans retain their effective value and raw representation on name edits", %{conn: conn} do
    profile = new_profile!()
    config = %{"tracker" => %{"kind" => "memory"}, "observability" => %{"dashboard_enabled" => "1"}}
    {:ok, lane} = Lanes.create(%{slug: "cast-boolean", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    assert has_element?(view, "#observability-dashboard-enabled[checked]")
    view |> form("#lane-form", lane: %{name: "Dashboard unchanged"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert saved_config(lane) == config
    assert {:ok, settings} = LaneStore.settings(lane.id)
    assert settings.observability.dashboard_enabled
  end

  test "an explicit-null checkbox uses its default and supports explicit off/on transitions", %{conn: conn} do
    profile = new_profile!()
    config = %{"tracker" => %{"kind" => "memory"}, "observability" => %{"dashboard_enabled" => nil}}
    {:ok, lane} = Lanes.create(%{slug: "null-boolean", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    assert has_element?(view, "#observability-dashboard-enabled[checked]")
    view |> form("#lane-form", lane: %{observability_dashboard_enabled: "false"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert saved_config(lane)["observability"]["dashboard_enabled"] == false
    assert {:ok, settings} = LaneStore.settings(lane.id)
    refute settings.observability.dashboard_enabled

    {:ok, enabling_view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    refute has_element?(enabling_view, "#observability-dashboard-enabled[checked]")
    enabling_view |> form("#lane-form", lane: %{observability_dashboard_enabled: "true"}) |> render_submit()
    assert_redirect(enabling_view, "/lanes/#{lane.slug}")
    assert {:ok, enabled_settings} = LaneStore.settings(lane.id)
    assert enabled_settings.observability.dashboard_enabled
  end

  test "edited backend commands survive conditional controls disappearing before save", %{conn: conn} do
    profile = new_profile!()
    config = %{"tracker" => %{"kind" => "memory"}, "codex" => %{"command" => "old-codex app-server"}}
    {:ok, lane} = Lanes.create(%{slug: "hidden-backend-draft", execution_profile_id: profile.id, config: config})
    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    view |> form("#lane-form", lane: %{codex_command: "new-codex app-server"}) |> render_change()
    view |> form("#lane-form", lane: %{agent_backend: "claude", agent_backend_by_state_json: ~s({"Review":"codex"})}) |> render_change()
    refute has_element?(view, "#codex-command")
    view |> form("#lane-form") |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    saved = saved_config(lane)
    assert saved["agent"]["backend"] == "claude"
    assert saved["agent"]["backend_by_state"] == %{"Review" => "codex"}
    assert {:ok, settings} = LaneStore.settings(lane.id)
    assert settings.codex.command == "new-codex app-server"
  end

  test "a nullable provider can be populated through named adapter controls", %{conn: conn} do
    profile = new_profile!()
    {:ok, lane} = Lanes.create(%{slug: "repair-null-provider", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    version = Lanes.current_version(lane)
    config = %{"tracker" => %{"kind" => "github", "provider" => nil, "active_states" => ["open"], "terminal_states" => ["closed"]}}
    source = Jason.encode!(config)
    Repo.update!(Ecto.Changeset.change(version, front_matter: source))
    assert :ok = LaneStore.refresh(lane.id)

    {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
    view |> form("#lane-form", lane: %{github_repo: "owner/repo", github_token: "github-lane-token"}) |> render_submit()
    assert_redirect(view, "/lanes/#{lane.slug}")
    assert saved_config(lane)["tracker"]["provider"] == %{"repo" => "owner/repo", "token" => "github-lane-token"}
    refute Lanes.get!(lane.id).enabled
    assert Repo.get!(version.__struct__, version.id).front_matter == source
  end

  test "malformed provider scalars require explicit repair without losing drafts or history", %{conn: conn} do
    profile = new_profile!()

    for {suffix, provider} <- [{"string", "broken"}, {"boolean", false}] do
      {:ok, lane} = Lanes.create(%{slug: "repair-provider-#{suffix}", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
      version = Lanes.current_version(lane)
      source = Jason.encode!(%{"tracker" => %{"kind" => "linear", "api_key" => "old-lane-token", "project_slug" => "legacy-project", "provider" => provider}})
      Repo.update!(Ecto.Changeset.change(version, front_matter: source))
      assert :ok = LaneStore.refresh(lane.id)

      {:ok, view, _html} = live(conn, "/lanes/#{lane.slug}/edit")
      assert has_element?(view, "#lane-errors[role='alert']", "tracker.provider")
      assert has_element?(view, "#tracker-provider", Jason.encode!(provider))
      view |> form("#lane-form", lane: %{name: "Repair draft", prompt: "Keep this draft"}) |> render_submit()
      assert has_element?(view, "#lane-errors[role='alert']", "tracker.provider")
      assert Lanes.get!(lane.id).current_version_id == version.id
      assert has_element?(view, "#lane-prompt", "Keep this draft")

      view |> form("#lane-form", lane: %{tracker_api_key: "replacement-token"}) |> render_change()
      assert has_element?(view, "#lane-errors[role='alert']", "tracker.provider")
      assert Lanes.get!(lane.id).current_version_id == version.id

      view |> form("#lane-form", lane: %{tracker_provider_json: "{}"}) |> render_submit()
      assert_redirect(view, "/lanes/#{lane.slug}")
      repaired = Lanes.get!(lane.id)
      refute repaired.enabled
      assert repaired.name == "Repair draft"
      assert Lanes.current_version(repaired).prompt == "Keep this draft"
      assert {:ok, settings} = Schema.parse(saved_config(lane))
      assert settings.tracker.api_key == "replacement-token"
      assert settings.tracker.project_slug == "legacy-project"
      assert Repo.get!(version.__struct__, version.id).front_matter == source
    end
  end

  defp saved_config(lane) do
    version = lane.id |> Lanes.get!() |> Lanes.current_version()
    {:ok, workflow} = Workflow.parse_parts(version.front_matter, version.prompt)
    workflow.config
  end

  defp new_profile! do
    {:ok, profile} =
      ExecutionProfiles.create(%{name: "Lane test #{System.unique_integer([:positive])}", workspace_base: Path.join(System.tmp_dir!(), "lane-test-#{System.unique_integer([:positive])}"), worker: %{}})

    profile
  end
end
