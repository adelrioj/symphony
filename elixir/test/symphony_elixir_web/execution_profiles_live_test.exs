defmodule SymphonyElixirWeb.ExecutionProfilesLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Repo}
  alias SymphonyElixir.ExecutionProfiles.Profile
  alias SymphonyElixir.Lanes.{Lane, LaneVersion}
  alias SymphonyElixirWeb.ConfigurationFields

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    endpoint_config = Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64))
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true})}
  end

  test "creates and deletes an unreferenced local profile", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "profile-live-create-#{System.unique_integer([:positive])}")
    {:ok, view, _html} = live(conn, "/execution-profiles/new")

    view
    |> form("#profile-form",
      profile: %{
        name: "Created in UI",
        description: "temporary",
        workspace_base: root,
        worker_mode: "local"
      }
    )
    |> render_submit()

    profile = Enum.find(ExecutionProfiles.list(), &(&1.name == "Created in UI"))
    assert profile.worker == %{}
    assert_redirect(view, "/execution-profiles/#{profile.id}")

    {:ok, detail, _html} = live(conn, "/execution-profiles/#{profile.id}")
    detail |> element("button[phx-click='prepare_delete']") |> render_click()
    detail |> element("#delete-confirmation button[phx-click='delete']") |> render_click()
    assert_redirect(detail, "/execution-profiles")
    assert is_nil(ExecutionProfiles.get(profile.id))
  end

  test "worker mode edits persist exact durations and restore redacted provider values", %{conn: conn} do
    {:ok, profile} = profile("Modes")
    {:ok, ssh_view, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")
    ssh_view |> form("#profile-form", profile: %{worker_mode: "ssh"}) |> render_change()

    ssh_view
    |> form("#profile-form",
      profile: %{
        worker_mode: "ssh",
        ssh_hosts: "worker-a\nworker-b",
        max_concurrent_agents_per_host: "3"
      }
    )
    |> render_submit()

    assert ExecutionProfiles.get(profile.id).worker == %{
             "ssh_hosts" => ["worker-a", "worker-b"],
             "max_concurrent_agents_per_host" => 3
           }

    {:ok, managed_view, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")
    managed_view |> form("#profile-form", profile: %{worker_mode: "managed"}) |> render_change()

    invalid =
      managed_view
      |> form("#profile-form",
        profile: %{
          worker_mode: "managed",
          environment_kind: "kubernetes",
          deployment_id: "customer-one",
          startup_timeout: "1.001",
          shutdown_timeout: "2.002",
          terminal_retention: "0.001",
          provider_json: "{"
        }
      )
      |> render_submit()

    assert invalid =~ "invalid JSON"
    assert has_element?(managed_view, "#profile-deployment-id[value='customer-one']")

    provider = %{
      "kubeconfig" => "/etc/kubeconfig",
      "context" => "prod",
      "namespace" => "agents",
      "template" => "worker",
      "ssh_user" => "runner",
      "ssh_auth_volume" => "ssh-auth",
      "ssh_port" => 22,
      "credential" => "literal-secret"
    }

    managed_view
    |> form("#profile-form",
      profile: %{
        worker_mode: "managed",
        environment_kind: "kubernetes",
        deployment_id: "customer-one",
        startup_timeout: "1.001",
        shutdown_timeout: "2.002",
        terminal_retention: "0.001",
        provider_json: Jason.encode!(provider)
      }
    )
    |> render_submit()

    environment = get_in(ExecutionProfiles.get(profile.id).worker, ["environment"])
    assert environment["startup_timeout_ms"] == 1_001
    assert environment["shutdown_timeout_ms"] == 2_002
    assert environment["terminal_retention_ms"] == 1

    {:ok, redacted_view, html} = live(conn, "/execution-profiles/#{profile.id}/edit")
    assert html =~ "$REDACTED"
    refute html =~ "literal-secret"
    redacted_view |> form("#profile-form", profile: %{name: "Modes renamed"}) |> render_submit()
    assert get_in(ExecutionProfiles.get(profile.id).worker, ["environment", "provider", "credential"]) == "literal-secret"
  end

  test "quoted managed durations display seconds without changing raw values on name edits", %{conn: conn} do
    worker = managed_worker(managed_provider(%{})) |> put_in(["environment", "startup_timeout_ms"], "1001")
    {:ok, edited} = profile("Quoted managed duration", worker)
    {:ok, view, _html} = live(conn, "/execution-profiles/#{edited.id}/edit")
    assert has_element?(view, "input[name='profile[startup_timeout]'][value='1.001']")
    view |> form("#profile-form", profile: %{name: "Duration unchanged"}) |> render_submit()
    assert_redirect(view, "/execution-profiles/#{edited.id}")
    assert ExecutionProfiles.get(edited.id).worker == worker

    {:ok, editing, _html} = live(conn, "/execution-profiles/#{edited.id}/edit")
    editing |> form("#profile-form", profile: %{startup_timeout: "1.002"}) |> render_submit()
    assert_redirect(editing, "/execution-profiles/#{edited.id}")
    assert get_in(ExecutionProfiles.get(edited.id).worker, ["environment", "startup_timeout_ms"]) == 1_002
  end

  test "referenced profile deletion is rejected without leaving the detail page or changing data", %{conn: conn} do
    {:ok, profile} = profile("Referenced")
    {:ok, lane} = Lanes.create(%{slug: "profile-delete-lane", execution_profile_id: profile.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, view, _html} = live(conn, "/execution-profiles/#{profile.id}")

    view |> element("button[phx-click='prepare_delete']") |> render_click()
    assert has_element?(view, "#delete-confirmation", "Linked lanes")
    view |> element("#delete-confirmation button[phx-click='delete']") |> render_click()

    assert has_element?(view, "#profile-errors", "lanes")
    assert has_element?(view, "#profile-lanes a[href='/lanes/profile-delete-lane']")
    assert ExecutionProfiles.get(profile.id).name == "Referenced"
    assert Lanes.get!(lane.id).execution_profile_id == profile.id
  end

  test "an error on a referenced profile keeps the affected lane visible", %{conn: conn} do
    {:ok, profile} = profile("Shared")
    {:ok, _lane} = Lanes.create(%{slug: "affected-profile-lane", execution_profile_id: profile.id, workspace_subdir: ".", config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, duplicate} = profile("Duplicate")
    {:ok, view, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")

    html = view |> form("#profile-form", profile: %{name: duplicate.name}) |> render_submit()

    assert html =~ "name"
    assert has_element?(view, "#profile-errors", "already been taken")
    assert has_element?(view, ".affected-lanes a[href='/lanes/affected-profile-lane']")
    assert ExecutionProfiles.get(profile.id).name == "Shared"
  end

  test "unrelated name edits preserve unexposed nested worker maps", %{conn: conn} do
    worker = %{"ssh_hosts" => ["worker-1"], "max_concurrent_agents_per_host" => 2, "extension" => %{"nested" => [true, nil, 7]}}
    {:ok, profile} = profile("Original", worker)
    {:ok, view, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")

    view |> form("#profile-form", profile: %{name: "Renamed"}) |> render_submit()

    assert ExecutionProfiles.get(profile.id).name == "Renamed"
    assert ExecutionProfiles.get(profile.id).worker == worker
  end

  test "duration formatting and parsing preserve exact integer milliseconds" do
    for milliseconds <- [0, 1, 999, 1_000, 1_001, 1_500, 60_001] do
      input = ConfigurationFields.duration_input(milliseconds)
      assert {:ok, ^milliseconds} = ConfigurationFields.parse_duration(input, "duration")
    end

    assert {:error, %{path: "duration"}} = ConfigurationFields.parse_duration("0.0005", "duration")
  end

  @tag :remediation
  test "remediation: the profile list tracks external changes and links to the selected profile", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/execution-profiles")
    {:ok, local} = profile("Listed local")
    {:ok, ssh} = profile("Listed SSH", %{"ssh_hosts" => ["worker-a"]})
    {:ok, managed} = profile("Listed managed", managed_worker(managed_provider(%{})))

    assert has_element?(view, "#execution-profile-#{local.id} td:nth-child(3)", "Local")
    assert has_element?(view, "#execution-profile-#{ssh.id} td:nth-child(3)", "Static SSH")
    assert has_element?(view, "#execution-profile-#{managed.id} td:nth-child(3)", "Existing managed environment")
    assert view |> element("#execution-profile-#{local.id} .numeric") |> render() |> Floki.parse_fragment!() |> Floki.text() == "0"

    {:ok, lane} = Lanes.create(%{slug: "listed-profile-lane", execution_profile_id: local.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, local} = ExecutionProfiles.update(local, %{name: "Renamed listed local", description: "Updated externally"})

    assert has_element?(view, "#execution-profile-#{local.id} a", "Renamed listed local")
    assert has_element?(view, "#execution-profile-#{local.id}", "Updated externally")
    assert view |> element("#execution-profile-#{local.id} .numeric") |> render() |> Floki.parse_fragment!() |> Floki.text() == "1"
    assert :ok = ExecutionProfiles.delete(ssh)
    refute has_element?(view, "#execution-profile-#{ssh.id}")

    [href] = view |> element("#execution-profile-#{local.id} a") |> render() |> Floki.parse_fragment!() |> Floki.attribute("href")
    {:ok, detail, _html} = live(conn, href)
    assert has_element?(detail, "h1", "Renamed listed local")
    assert has_element?(detail, "#profile-lanes a[href='/lanes/#{lane.slug}']")
  end

  @tag :remediation
  test "remediation: unrelated profile notifications preserve dirty input while refreshing linked-lane impact", %{conn: conn} do
    {:ok, edited} = profile("Editing")
    {:ok, destination} = profile("Relink destination")
    {:ok, old_lane} = Lanes.create(%{slug: "old-profile-impact", execution_profile_id: edited.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, view, _html} = live(conn, "/execution-profiles/#{edited.id}/edit")

    view
    |> form("#profile-form", profile: %{name: "Unsaved name", description: "Unsaved description"})
    |> render_change()

    assert {:ok, _relocated} = Lanes.update(old_lane, %{execution_profile_id: destination.id})
    {:ok, new_lane} = Lanes.create(%{slug: "new-profile-impact", execution_profile_id: edited.id, config: %{"tracker" => %{"kind" => "memory"}}})
    {:ok, _unrelated} = profile("Unrelated notification")

    assert has_element?(view, "#profile-name[value='Unsaved name']")
    assert has_element?(view, "#profile-description", "Unsaved description")
    assert has_element?(view, ".affected-lanes a[href='/lanes/#{new_lane.slug}']")
    refute has_element?(view, ".affected-lanes a[href='/lanes/#{old_lane.slug}']")
    assert ExecutionProfiles.get(edited.id).name == "Editing"

    view |> form("#profile-form") |> render_submit()
    assert_redirect(view, "/execution-profiles/#{edited.id}")
    assert ExecutionProfiles.get(edited.id).name == "Unsaved name"
    assert ExecutionProfiles.get(edited.id).description == "Unsaved description"
  end

  @tag :remediation
  test "remediation: deletion of an open dirty profile is explicit and cannot recreate the profile", %{conn: conn} do
    {:ok, edited} = profile("Deleted while editing")
    {:ok, view, _html} = live(conn, "/execution-profiles/#{edited.id}/edit")
    view |> form("#profile-form", profile: %{name: "Unsaved deleted draft"}) |> render_change()

    assert :ok = ExecutionProfiles.delete(edited)
    assert_redirect(view, "/execution-profiles")
    assert is_nil(ExecutionProfiles.get(edited.id))
    refute Enum.any?(ExecutionProfiles.list(), &(&1.name == "Unsaved deleted draft"))
  end

  @tag :remediation
  test "remediation: an unrelated profile edit restores provider credentials inside nested arrays", %{conn: conn} do
    provider = managed_provider(%{"groups" => [%{"accounts" => [%{"token" => "profile-array-secret", "api_key" => "$PROFILE_CREDENTIAL", "label" => "primary"}]}]})
    {:ok, edited} = profile("Nested credentials", managed_worker(provider))
    {:ok, view, html} = live(conn, "/execution-profiles/#{edited.id}/edit")
    refute html =~ "profile-array-secret"
    assert has_element?(view, "#profile-provider", "$REDACTED")

    # The actual rendered provider textarea participates in this name-only submission.
    view |> form("#profile-form", profile: %{name: "Nested renamed"}) |> render_submit()
    assert_redirect(view, "/execution-profiles/#{edited.id}")
    assert get_in(ExecutionProfiles.get(edited.id).worker, ["environment", "provider"]) == provider
  end

  for {scenario, original, forged} <- [
        {"missing original", %{}, %{"new_token" => "$REDACTED"}},
        {"scalar replaced by object", %{"account" => "plain"}, %{"account" => %{"token" => "$REDACTED"}}}
      ] do
    @tag :remediation
    test "remediation: profile redaction forgery with #{scenario} returns an error without discarding the draft", %{conn: conn} do
      provider = managed_provider(unquote(Macro.escape(original)))
      {:ok, edited} = profile("Forged credentials", managed_worker(provider))
      {:ok, view, _html} = live(conn, "/execution-profiles/#{edited.id}/edit")
      forged = provider |> Map.put("extension", unquote(Macro.escape(forged))) |> Jason.encode!()

      view
      |> form("#profile-form", profile: %{name: "Keep forged name", description: "Keep forged description", provider_json: forged})
      |> render_change()

      assert has_element?(view, "#profile-errors[role='alert']", "worker.environment.provider")
      assert has_element?(view, "#profile-name[value='Keep forged name']")
      assert has_element?(view, "#profile-description", "Keep forged description")
      assert has_element?(view, "#profile-provider", "$REDACTED")
      view |> form("#profile-form") |> render_submit()
      assert has_element?(view, "#profile-errors[role='alert']", "worker.environment.provider")
      assert ExecutionProfiles.get(edited.id).name == "Forged credentials"
      assert get_in(ExecutionProfiles.get(edited.id).worker, ["environment", "provider"]) == provider
    end
  end

  test "detail refreshes external edits, cancels deletion, and leaves when its profile is deleted", %{conn: conn} do
    {:ok, profile} = profile("Live detail")
    {:ok, view, _html} = live(conn, "/execution-profiles/#{profile.id}")
    view |> element("button[phx-click='prepare_delete']") |> render_click()
    view |> element("#delete-confirmation button[phx-click='cancel_delete']") |> render_click()
    refute has_element?(view, "#delete-confirmation")
    assert ExecutionProfiles.get(profile.id)

    {:ok, updated} = ExecutionProfiles.update(profile, %{name: "External detail", description: "Fresh description"})
    assert has_element?(view, "h1", updated.name)
    assert has_element?(view, ".hero-copy", updated.description)
    assert :ok = ExecutionProfiles.delete(updated)
    assert_redirect(view, "/execution-profiles")
  end

  test "detail summarizes static and managed workers without exposing credentials", %{conn: conn} do
    {:ok, ssh} = profile("SSH detail", %{"ssh_hosts" => ["worker-a", "worker-b"]})
    {:ok, ssh_view, _html} = live(conn, "/execution-profiles/#{ssh.id}")
    assert has_element?(ssh_view, ".metric-value", "Static SSH")
    assert has_element?(ssh_view, "dd", "SSH: worker-a, worker-b")

    provider = managed_provider(%{}) |> Map.put("credential", "must-stay-private")
    {:ok, managed} = profile("Managed detail", managed_worker(provider))
    {:ok, managed_view, html} = live(conn, "/execution-profiles/#{managed.id}")
    assert has_element?(managed_view, ".metric-value", "Managed")
    assert has_element?(managed_view, "dd", "kubernetes deployment editor-remediation")
    assert has_element?(managed_view, "dd", "References configured")
    refute html =~ "must-stay-private"
  end

  test "invalid profile routes redirect rather than opening a new profile", %{conn: conn} do
    for path <- ["/execution-profiles/not-an-id", "/execution-profiles/not-an-id/edit"] do
      assert {:error, {:live_redirect, %{to: "/execution-profiles"}}} = live(conn, path)
    end
  end

  test "clean editor refreshes externally changed values and rejects malformed events", %{conn: conn} do
    {:ok, profile} = profile("Clean editor")
    {:ok, view, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")
    {:ok, _updated} = ExecutionProfiles.update(profile, %{name: "New canonical name"})
    assert has_element?(view, "#profile-name[value='New canonical name']")
    render_submit(view, "save", %{"profile" => ["not an object"]})
    assert has_element?(view, "#profile-errors", "profile")
    assert ExecutionProfiles.get(profile.id).name == "New canonical name"

    view |> form("#profile-form", profile: %{worker_mode: "managed"}) |> render_change()
    render_submit(view, "save", %{"profile" => %{"environment_kind" => "unsupported", "deployment_id" => "existing", "startup_timeout" => "1", "shutdown_timeout" => "2", "terminal_retention" => "0"}})
    assert has_element?(view, "#profile-errors", "worker.environment")
    assert ExecutionProfiles.get(profile.id).worker == %{}
  end

  test "invalid SSH concurrency is shown beside the field without replacing worker settings", %{conn: conn} do
    {:ok, profile} = profile("Invalid SSH limit")
    {:ok, view, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")
    view |> form("#profile-form", profile: %{worker_mode: "ssh"}) |> render_change()
    view |> form("#profile-form", profile: %{ssh_hosts: "worker-a", max_concurrent_agents_per_host: "1.5"}) |> render_submit()
    assert has_element?(view, "#profile-host-limit + .field-error[role='alert']")
    assert ExecutionProfiles.get(profile.id).worker == %{}
  end

  test "invalid linked lane capacity is excluded and profile errors navigate to the lane", %{conn: conn} do
    {:ok, profile} = profile("Repair linked lane")
    {:ok, lane} = Lanes.create(%{slug: "invalid-profile-lane", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    version = Lanes.current_version(lane)
    SymphonyElixir.Repo.update!(Ecto.Changeset.change(version, front_matter: "tracker: ["))
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.LaneStore)
    assert {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.LaneStore)

    {:ok, detail, _html} = live(conn, "/execution-profiles/#{profile.id}")
    assert has_element?(detail, "#profile-lane-#{lane.id}")
    assert detail |> element(".metric-card:nth-child(3) .metric-value") |> render() |> Floki.parse_fragment!() |> Floki.text() == "0"

    {:ok, editor, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")
    editor |> form("#profile-form", profile: %{description: "Must not persist"}) |> render_submit()
    assert has_element?(editor, "#profile-errors a[href='/lanes/#{lane.slug}']")
    assert is_nil(ExecutionProfiles.get(profile.id).description)
  end

  @tag :remediation
  test "remediation: lane creation and relinking refresh connected profile list counts", %{conn: conn} do
    {:ok, source} = profile("Membership source")
    {:ok, destination} = profile("Membership destination")
    {:ok, view, _html} = live(conn, "/execution-profiles")

    {:ok, lane} = Lanes.create(%{slug: "membership-count", execution_profile_id: source.id, config: %{"tracker" => %{"kind" => "memory"}}})

    assert rendered_text(view, "#execution-profile-#{source.id} .numeric") == "1"
    assert rendered_text(view, "#execution-profile-#{destination.id} .numeric") == "0"

    assert {:ok, _lane} = Lanes.update(lane, %{execution_profile_id: destination.id})

    assert rendered_text(view, "#execution-profile-#{source.id} .numeric") == "0"
    assert rendered_text(view, "#execution-profile-#{destination.id} .numeric") == "1"
  end

  @tag :remediation
  test "remediation: lane mutations refresh connected profile detail membership names and capacity", %{conn: conn} do
    {:ok, source} = profile("Detail membership")
    {:ok, destination} = profile("Detail destination")
    {:ok, view, _html} = live(conn, "/execution-profiles/#{source.id}")

    {:ok, lane} =
      Lanes.create(%{
        slug: "membership-detail",
        name: "Original lane name",
        execution_profile_id: source.id,
        config: %{"tracker" => %{"kind" => "memory"}, "agent" => %{"max_concurrent_agents" => 2}}
      })

    assert has_element?(view, "#profile-lane-#{lane.id} a", "Original lane name")
    assert rendered_text(view, ".metric-card:nth-child(2) .metric-value") == "1"
    assert rendered_text(view, ".metric-card:nth-child(3) .metric-value") == "2"

    {:ok, lane} =
      Lanes.update(lane, %{
        name: "Renamed linked lane",
        config: %{"tracker" => %{"kind" => "memory"}, "agent" => %{"max_concurrent_agents" => 7}}
      })

    assert has_element?(view, "#profile-lane-#{lane.id} a", "Renamed linked lane")
    assert rendered_text(view, ".metric-card:nth-child(3) .metric-value") == "7"

    assert {:ok, _lane} = Lanes.update(lane, %{execution_profile_id: destination.id})

    refute has_element?(view, "#profile-lane-#{lane.id}")
    assert rendered_text(view, ".metric-card:nth-child(2) .metric-value") == "0"
    assert rendered_text(view, ".metric-card:nth-child(3) .metric-value") == "0"
  end

  @tag :remediation
  test "remediation: lane notifications refresh editor impact without overwriting a dirty profile draft", %{conn: conn} do
    {:ok, edited} = profile("Dirty lane impact")
    {:ok, destination} = profile("Dirty impact destination")
    {:ok, view, _html} = live(conn, "/execution-profiles/#{edited.id}/edit")

    view
    |> form("#profile-form", profile: %{name: "Unsaved impact name", description: "Unsaved impact description"})
    |> render_change()

    {:ok, lane} = Lanes.create(%{slug: "dirty-lane-impact", name: "New impact lane", execution_profile_id: edited.id, config: %{"tracker" => %{"kind" => "memory"}}})

    assert has_element?(view, ".affected-lanes a[href='/lanes/#{lane.slug}']", "New impact lane")
    assert has_element?(view, ".affected-lanes .section-copy", "1 linked lane")
    assert has_element?(view, "#profile-name[value='Unsaved impact name']")
    assert has_element?(view, "#profile-description", "Unsaved impact description")

    {:ok, lane} = Lanes.update(lane, %{name: "Renamed impact lane"})
    assert has_element?(view, ".affected-lanes a[href='/lanes/#{lane.slug}']", "Renamed impact lane")

    assert {:ok, _lane} = Lanes.update(lane, %{execution_profile_id: destination.id})
    refute has_element?(view, ".affected-lanes a[href='/lanes/#{lane.slug}']")
    assert has_element?(view, "#profile-name[value='Unsaved impact name']")
    assert has_element?(view, "#profile-description", "Unsaved impact description")
    assert ExecutionProfiles.get(edited.id).name == "Dirty lane impact"

    view |> form("#profile-form") |> render_submit()
    assert_redirect(view, "/execution-profiles/#{edited.id}")
    assert ExecutionProfiles.get(edited.id).name == "Unsaved impact name"
    assert ExecutionProfiles.get(edited.id).description == "Unsaved impact description"
  end

  for {scenario, mode, path, invalid} <- [
        {"scalar environment", :managed, ["environment"], "broken"},
        {"null environment", :managed, ["environment"], nil},
        {"scalar SSH hosts", :ssh, ["ssh_hosts"], "broken"},
        {"object SSH host", :ssh, ["ssh_hosts"], [%{"host" => "worker-a"}]},
        {"scalar provider", :managed, ["environment", "provider"], "broken"},
        {"object provider kind", :managed, ["environment", "kind"], %{"kind" => "kubernetes"}},
        {"object deployment identifier", :managed, ["environment", "deployment_id"], %{"id" => "editor-remediation"}},
        {"object SSH concurrency", :ssh, ["max_concurrent_agents_per_host"], %{"limit" => 2}},
        {"string startup duration", :managed, ["environment", "startup_timeout_ms"], "broken"},
        {"list shutdown duration", :managed, ["environment", "shutdown_timeout_ms"], [2002]},
        {"object retention duration", :managed, ["environment", "terminal_retention_ms"], %{"milliseconds" => 1}}
      ] do
    @tag :remediation
    @tag :tmp_dir
    test "remediation: persisted repair profile with #{scenario} mounts safely and cannot be accepted by default", %{conn: conn, tmp_dir: root} do
      stub_ssh_canonicalization(root)

      worker =
        case unquote(mode) do
          :ssh -> %{"ssh_hosts" => ["worker-a"], "max_concurrent_agents_per_host" => 2}
          :managed -> managed_worker(managed_provider(%{}))
        end
        |> put_in(unquote(path), unquote(Macro.escape(invalid)))

      {profile, lane, version} = persisted_repair_profile(worker, "/remote/repair")
      error_path = if unquote(mode) == :managed, do: "worker.environment", else: Enum.join(["worker" | unquote(path)], ".")

      {:ok, detail, _html} = live(conn, "/execution-profiles/#{profile.id}")
      assert has_element?(detail, "[role='alert']", error_path)
      assert has_element?(detail, "#profile-lane-#{lane.id}")
      assert rendered_text(detail, ".metric-card:nth-child(3) .metric-value") == "0"

      {:ok, editor, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")
      assert has_element?(editor, "#profile-errors", error_path)

      editor |> form("#profile-form", profile: %{name: "Must remain quarantined"}) |> render_submit()

      assert has_element?(editor, "#profile-errors")
      assert ExecutionProfiles.get(profile.id).name == profile.name
      assert ExecutionProfiles.get(profile.id).worker == worker
      assert ExecutionProfiles.get(profile.id).repair_error == profile.repair_error
      assert {:error, _} = Lanes.resolve_lane(Lanes.get!(lane.id))
      assert Lanes.current_version(lane).front_matter == version.front_matter
      assert Lanes.current_version(lane).prompt == version.prompt
    end
  end

  @tag :remediation
  @tag :tmp_dir
  test "remediation: structured repair corrects malformed SSH concurrency without changing ownership or historical bytes", %{conn: conn, tmp_dir: root} do
    stub_ssh_canonicalization(root)
    {profile, lane, version} = persisted_repair_profile(%{"ssh_hosts" => ["worker-a"], "max_concurrent_agents_per_host" => %{"limit" => 2}}, "/remote/repair")
    {:ok, editor, _html} = live(conn, "/execution-profiles/#{profile.id}/edit")

    assert has_element?(editor, "#profile-errors", "worker.max_concurrent_agents_per_host")
    assert has_element?(editor, "#profile-ssh-hosts", "worker-a")

    editor |> form("#profile-form", profile: %{max_concurrent_agents_per_host: "3"}) |> render_submit()

    assert_redirect(editor, "/execution-profiles/#{profile.id}")
    repaired = ExecutionProfiles.get(profile.id)
    assert is_nil(repaired.repair_error)
    assert repaired.workspace_base == profile.workspace_base
    assert repaired.worker == %{"ssh_hosts" => ["worker-a"], "max_concurrent_agents_per_host" => 3}
    assert {:ok, _} = Lanes.resolve_lane(Lanes.get!(lane.id))
    refute Lanes.get!(lane.id).enabled
    assert Lanes.current_version(lane).id == version.id
    assert Lanes.current_version(lane).front_matter == version.front_matter
    assert Lanes.current_version(lane).prompt == version.prompt
  end

  defp persisted_repair_profile(worker, base) do
    unique = System.unique_integer([:positive])

    # Persist the quarantined shape retained by migration, without ever publishing a valid ownership guard.
    profile = Repo.insert!(%Profile{name: "Legacy repair #{unique}", workspace_base: base, worker: worker, repair_error: "legacy configuration requires repair"})
    lane = Repo.insert!(%Lane{slug: "legacy-repair-#{unique}", name: "Legacy repair", execution_profile_id: profile.id, workspace_subdir: ".", enabled: false})
    front_matter = Jason.encode!(%{"tracker" => %{"kind" => "memory"}, "workspace" => %{"root" => base}, "worker" => worker})
    version = Repo.insert!(%LaneVersion{lane_id: lane.id, front_matter: front_matter, prompt: "Original migration prompt\n"})
    lane = Repo.update!(Ecto.Changeset.change(lane, current_version_id: version.id))
    LaneStore.refresh(lane.id)
    {profile, lane, version}
  end

  defp stub_ssh_canonicalization(root) do
    fake_ssh = Path.join(root, "ssh")
    previous_path = System.get_env("PATH")
    File.write!(fake_ssh, "#!/bin/sh\ncase \"$*\" in *\"find \"*) exit 0 ;; esac\nprintf '/remote/repair\\t/remote/repair\\n'\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))
    on_exit(fn -> if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH") end)
  end

  defp rendered_text(view, selector), do: view |> element(selector) |> render() |> Floki.parse_fragment!() |> Floki.text()

  defp managed_provider(extension) do
    %{
      "kubeconfig" => "/etc/kubeconfig",
      "context" => "prod",
      "namespace" => "agents",
      "template" => "worker",
      "ssh_user" => "runner",
      "ssh_auth_volume" => "ssh-auth",
      "ssh_port" => 22,
      "extension" => extension
    }
  end

  defp managed_worker(provider) do
    %{
      "environment" => %{
        "kind" => "kubernetes",
        "deployment_id" => "editor-remediation",
        "startup_timeout_ms" => 1_001,
        "shutdown_timeout_ms" => 2_002,
        "terminal_retention_ms" => 1,
        "provider" => provider
      }
    }
  end

  defp profile(name, worker \\ %{}) do
    ExecutionProfiles.create(%{name: name, workspace_base: Path.join(System.tmp_dir!(), "profile-#{System.unique_integer([:positive])}"), worker: worker})
  end
end
