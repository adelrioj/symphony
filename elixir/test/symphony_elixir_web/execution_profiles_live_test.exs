defmodule SymphonyElixirWeb.ExecutionProfilesLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes}
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

  defp profile(name, worker \\ %{}) do
    ExecutionProfiles.create(%{name: name, workspace_base: Path.join(System.tmp_dir!(), "profile-#{System.unique_integer([:positive])}"), worker: worker})
  end
end
