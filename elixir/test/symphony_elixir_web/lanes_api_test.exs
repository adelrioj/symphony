defmodule SymphonyElixirWeb.LanesApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn

  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Repo, Workflow}

  @endpoint SymphonyElixirWeb.Endpoint
  @config %{"tracker" => %{"kind" => "memory"}, "polling" => %{"interval_ms" => 60_000}, "codex" => %{"command" => "/bin/false"}}

  setup do
    original = Application.get_env(:symphony_elixir, @endpoint, [])
    endpoint_config = original |> Keyword.delete(:orchestrator) |> Keyword.merge(server: false, secret_key_base: Config.operator_session_secret(), snapshot_timeout_ms: 50)
    Application.put_env(:symphony_elixir, @endpoint, endpoint_config)
    on_exit(fn -> Application.put_env(:symphony_elixir, @endpoint, original) end)
    start_supervised!({@endpoint, []})
    :ok
  end

  test "CRUD preserves workflow versions, exports active content, and reserves deleted slugs" do
    lane = json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(attrs("api-lane"))), 201)
    v1 = lane["current_version_id"]
    assert %{"slug" => "api-lane", "enabled" => false, "executor" => "local", "workspace_subdir" => "."} = lane
    assert lane["execution_profile_id"] > 0
    assert is_binary(lane["execution_profile_name"])
    assert Enum.any?(json_response(get(api_conn(), "/api/v1/lanes"), 200)["lanes"], &(&1["slug"] == "api-lane"))

    renamed = json_response(put(api_conn(), "/api/v1/lanes/api-lane", Jason.encode!(%{name: "Renamed"})), 200)
    assert renamed["name"] == "Renamed"
    assert renamed["current_version_id"] == v1

    updated = json_response(put(api_conn(), "/api/v1/lanes/api-lane", Jason.encode!(%{prompt: "second", note: "new version"})), 200)
    refute updated["current_version_id"] == v1
    activated = json_response(post(api_conn(), "/api/v1/lanes/api-lane/versions/#{v1}/activate", ""), 200)
    assert activated["current_version_id"] == v1
    export = get(api_conn(), "/api/v1/lanes/api-lane/export")
    assert get_resp_header(export, "content-type") == ["text/markdown; charset=utf-8"]
    assert {:ok, exported} = Workflow.parse(response(export, 200))
    assert exported.config["tracker"] == %{"kind" => "memory"}
    assert exported.prompt == "hi"

    assert response(delete(api_conn(), "/api/v1/lanes/api-lane"), 204) == ""
    assert json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(attrs("api-lane"))), 422)["errors"] != []

    for conn <- [
          get(api_conn(), "/api/v1/lanes/api-lane/export"),
          put(api_conn(), "/api/v1/lanes/api-lane", "{}"),
          post(api_conn(), "/api/v1/lanes/api-lane/versions/#{v1}/activate", ""),
          delete(api_conn(), "/api/v1/lanes/api-lane")
        ] do
      assert %{"error" => %{"code" => "lane_not_found"}} = json_response(conn, 404)
    end
  end

  test "lane slugs are immutable and route identity cannot be replaced" do
    assert %{"slug" => "before-name"} = json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(attrs("before-name"))), 201)
    assert Enum.any?(json_response(put(api_conn(), "/api/v1/lanes/before-name", Jason.encode!(%{slug: "after-name"})), 422)["errors"], &(&1["path"] == "slug"))
    assert Lanes.get_by_slug("before-name")
    assert is_nil(Lanes.get_by_slug("after-name"))
    assert %{"error" => %{"code" => "lane_not_found"}} = json_response(put(api_conn(), "/api/v1/lanes/missing", Jason.encode!(%{name: "wrong target"})), 404)
  end

  test "lane responses redact literal tracker credentials and preserve references" do
    attrs =
      attrs("secret-safe-lane")
      |> Map.put(:config, %{
        "tracker" => %{"kind" => "memory", "api_key" => "literal-tracker-secret"},
        "extension" => %{"token" => "$EXTENSION_TOKEN"}
      })

    created = json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(attrs)), 201)
    assert created["config"]["tracker"]["api_key"] == "$REDACTED"
    assert created["config"]["extension"]["token"] == "$EXTENSION_TOKEN"
    refute Jason.encode!(json_response(get(api_conn(), "/api/v1/lanes"), 200)) =~ "literal-tracker-secret"

    round_tripped =
      json_response(
        put(api_conn(), "/api/v1/lanes/secret-safe-lane", Jason.encode!(%{"config" => created["config"], "name" => "Round tripped"})),
        200
      )

    assert round_tripped["config"]["tracker"]["api_key"] == "$REDACTED"
    assert {:ok, stored} = Workflow.parse_parts(Lanes.current_version(Lanes.get_by_slug("secret-safe-lane")).front_matter, "")
    assert stored.config["tracker"]["api_key"] == "literal-tracker-secret"

    bad_attrs = attrs("unmatched-redaction") |> Map.put(:config, %{"tracker" => %{"kind" => "memory", "api_key" => "$REDACTED"}})
    errors = json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(bad_attrs)), 422)["errors"]
    assert Enum.any?(errors, &(&1["path"] == "config.tracker.api_key"))
    update_errors = json_response(put(api_conn(), "/api/v1/lanes/secret-safe-lane", Jason.encode!(%{config: %{extension: %{new_token: "$REDACTED"}}})), 422)["errors"]
    assert Enum.any?(update_errors, &(&1["path"] == "config.extension.new_token"))
    assert Lanes.get_by_slug("secret-safe-lane").current_version_id == round_tripped["current_version_id"]
  end

  test "invalid JSON field types and nonobject bodies are rejected without persisting changes" do
    assert %{"current_version_id" => version} = json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(attrs("typed-lane"))), 201)

    for {field, value} <- [{"slug", nil}, {"name", []}, {"enabled", "yes"}, {"execution_profile_id", %{}}, {"workspace_subdir", nil}, {"config", []}, {"prompt", ["bad"]}, {"note", false}] do
      conn = put(api_conn(), "/api/v1/lanes/typed-lane", Jason.encode!(%{field => value}))
      errors = json_response(conn, 422)["errors"]
      assert Enum.any?(errors, &(&1["path"] == field))
      assert Lanes.get_by_slug("typed-lane").current_version_id == version
    end

    for body <- ["null", "[]", "123", "\"string\""] do
      assert %{"errors" => [%{"path" => "body"}]} = json_response(post(api_conn(), "/api/v1/lanes", body), 422)
    end

    conn = put(api_conn(), "/api/v1/lanes/typed-lane", Jason.encode!(%{front_matter: "polling:\n  interval_ms: nope"}))
    assert Enum.any?(json_response(conn, 422)["errors"], &(&1["path"] == "front_matter"))
    assert Lanes.get_by_slug("typed-lane").current_version_id == version
  end

  @tag :tmp_dir
  test "invalid fixed-root workspace updates preserve the active version", %{tmp_dir: root} do
    kubeconfig = Path.join(root, "kubeconfig")
    File.write!(kubeconfig, "test")
    provider = %{"kubeconfig" => kubeconfig, "context" => "test", "namespace" => "test", "template" => "worker-slot", "ssh_user" => "worker", "ssh_auth_volume" => "ssh", "ssh_port" => 22}
    environment = %{"kind" => "kubernetes", "deployment_id" => "test", "provider" => provider, "startup_timeout_ms" => 1_000, "shutdown_timeout_ms" => 1_000}
    {:ok, profile} = ExecutionProfiles.create(%{name: "Fixed-root API", workspace_base: "/state/workspace/worker/", worker: %{"environment" => environment}})
    attrs = %{slug: "fixed-root-api", name: "Fixed", execution_profile_id: profile.id, workspace_subdir: ".", config: @config, prompt: "work"}
    invalid = Map.put(attrs, :workspace_subdir, "tra-features")
    create_errors = json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(invalid)), 422)["errors"]
    assert Enum.any?(create_errors, &(&1["path"] == "workspace_subdir"))
    assert is_nil(Lanes.get_by_slug("fixed-root-api"))
    %{"current_version_id" => version} = json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(attrs)), 201)

    errors = json_response(put(api_conn(), "/api/v1/lanes/fixed-root-api", Jason.encode!(%{workspace_subdir: "tra-features"})), 422)["errors"]
    assert Enum.any?(errors, &(&1["path"] == "workspace_subdir"))
    assert Lanes.get_by_slug("fixed-root-api").current_version_id == version
  end

  @tag :tmp_dir
  test "disabled persisted fixed-root lane repairs only after empty provider inventory", %{tmp_dir: root} do
    kubeconfig = Path.join(root, "kubeconfig")
    File.write!(kubeconfig, "test")
    kubectl = Path.join(root, "kubectl")
    File.write!(kubectl, "#!/bin/sh\nprintf '%s\\n' '{\"metadata\":{\"resourceVersion\":\"1\"},\"items\":[]}'\n")
    File.chmod!(kubectl, 0o755)
    original_path = System.get_env("PATH")
    System.put_env("PATH", root <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    provider = %{"kubeconfig" => kubeconfig, "context" => "test", "namespace" => "test", "template" => "worker-slot", "ssh_user" => "worker", "ssh_auth_volume" => "ssh", "ssh_port" => 22}
    environment = %{"kind" => "kubernetes", "deployment_id" => "test", "provider" => provider, "startup_timeout_ms" => 1_000, "shutdown_timeout_ms" => 1_000}
    {:ok, profile} = ExecutionProfiles.create(%{name: "Persisted fixed root", workspace_base: "/state/workspace/worker", worker: %{"environment" => environment}})
    {:ok, lane} = Lanes.create(%{slug: "persisted-root", execution_profile_id: profile.id, workspace_subdir: ".", config: @config})
    Repo.update!(Ecto.Changeset.change(lane, workspace_subdir: "tra-features"))
    Supervisor.terminate_child(SymphonyElixir.Supervisor, LaneStore)
    {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, LaneStore)

    assert Enum.any?(json_response(put(api_conn(), "/api/v1/lanes/persisted-root", Jason.encode!(%{workspace_subdir: "."})), 422)["errors"], &(&1["path"] == "worker.environment"))
    before_version = Lanes.get!(lane.id).current_version_id
    File.write!(kubectl, "#!/bin/sh\nexit 1\n")
    assert Enum.any?(json_response(post(api_conn(), "/api/v1/lanes/persisted-root/repair-fixed-root", ""), 422)["errors"], &(&1["path"] == "workspace_subdir"))
    assert Lanes.get!(lane.id).workspace_subdir == "tra-features"
    assert Lanes.get!(lane.id).current_version_id == before_version
    started = Path.join(root, "discovery-started")
    resume = Path.join(root, "resume-discovery")
    File.write!(kubectl, "#!/bin/sh\ntouch '#{started}'\nwhile [ ! -f '#{resume}' ]; do sleep 0.05; done\nprintf '%s\\n' '{\"metadata\":{\"resourceVersion\":\"1\"},\"items\":[]}'\n")
    pending = Task.async(fn -> post(api_conn(), "/api/v1/lanes/persisted-root/repair-fixed-root", "") end)

    assert Enum.any?(1..100, fn _ ->
             Process.sleep(10)
             File.exists?(started)
           end)

    {:ok, healthy_profile} = ExecutionProfiles.create(%{name: "Other lane", workspace_base: root, worker: %{}})
    {:ok, healthy} = Lanes.create(%{slug: "other-lane", execution_profile_id: healthy_profile.id, config: @config})
    healthy_update = Task.async(fn -> Lanes.update(healthy, %{name: "Still responsive"}) end)
    changed = Task.async(fn -> Lanes.update(lane, %{name: "Changed during discovery"}) end)
    quick = Task.yield(healthy_update, 1_000)
    changed_result = Task.yield(changed, 1_000)
    File.write!(resume, "go")
    assert {:ok, {:ok, _}} = quick
    assert {:ok, {:ok, _}} = changed_result
    assert Enum.any?(json_response(Task.await(pending, 10_000), 422)["errors"], &(&1["path"] == "workspace_subdir"))
    assert Lanes.get!(lane.id).workspace_subdir == "tra-features"
    File.write!(kubectl, "#!/bin/sh\nprintf '%s\\n' '{\"metadata\":{\"resourceVersion\":\"1\"},\"items\":[]}'\n")
    repaired = json_response(post(api_conn(), "/api/v1/lanes/persisted-root/repair-fixed-root", ""), 200)
    assert repaired["workspace_subdir"] == "."
    assert repaired["enabled"] == false
    assert repaired["current_version_id"] == before_version
    assert {:ok, %{settings: %{workspace: %{root: "/state/workspace/worker"}}}} = LaneStore.lookup(lane.id)
    assert Enum.any?(json_response(post(api_conn(), "/api/v1/lanes/persisted-root/repair-fixed-root", ""), 422)["errors"], &(&1["path"] == "workspace_subdir"))
  end

  test "fixed-root repair rejects unrelated lanes" do
    {:ok, lane} = Lanes.create(attrs("unrelated-root"))
    assert Enum.any?(json_response(post(api_conn(), "/api/v1/lanes/unrelated-root/repair-fixed-root", ""), 422)["errors"], &(&1["path"] == "workspace_subdir"))
    assert Lanes.get!(lane.id).workspace_subdir == "."
  end

  test "version activation rejects invalid IDs and versions belonging to another lane" do
    {:ok, lane} = Lanes.create(attrs("version-lane"))
    {:ok, other} = Lanes.create(attrs("other-lane"))

    for id <- ["abc", "-1", "0", "1suffix", "9223372036854775808", to_string(other.current_version_id)] do
      assert %{"errors" => [%{"path" => "version"} | _]} = json_response(post(api_conn(), "/api/v1/lanes/version-lane/versions/#{id}/activate", ""), 422)
      assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
    end
  end

  test "export without a version returns a structured error" do
    {:ok, lane} = Lanes.create(attrs("no-version"))
    lane |> Ecto.Changeset.change(current_version_id: nil) |> Repo.update!()
    assert %{"errors" => [%{"path" => "version"}]} = json_response(get(api_conn(), "/api/v1/lanes/no-version/export"), 422)
  end

  test "enabled lanes cannot be deleted, and disable allows deletion" do
    {:ok, _lane} = Lanes.create(attrs("active-lane"))
    assert %{"enabled" => true} = json_response(put(api_conn(), "/api/v1/lanes/active-lane", Jason.encode!(%{enabled: true})), 200)
    assert %{"error" => %{"code" => "lane_active"}} = json_response(delete(api_conn(), "/api/v1/lanes/active-lane"), 409)
    assert %{"enabled" => false} = json_response(put(api_conn(), "/api/v1/lanes/active-lane", Jason.encode!(%{enabled: false})), 200)
    assert response(delete(api_conn(), "/api/v1/lanes/active-lane"), 204) == ""
  end

  @tag :tmp_dir
  test "deletion refuses retained workspaces without discarding their lane", %{tmp_dir: root} do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Retained API", workspace_base: root, worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "retained-api", execution_profile_id: profile.id, config: @config})
    {:ok, settings} = LaneStore.settings(lane.id)
    retained = Path.join(settings.workspace.root, "RETAIN-1")
    File.mkdir_p!(retained)
    File.write!(Path.join(retained, "kept"), "retained data")

    assert json_response(delete(api_conn(), "/api/v1/lanes/#{lane.slug}"), 422)["errors"] != []
    assert Lanes.get!(lane.id).deleted_at == nil
    assert File.read!(Path.join(retained, "kept")) == "retained data"
  end

  test "lane infrastructure cannot be replaced through top-level API keys" do
    {:ok, lane} = Lanes.create(attrs("owner-api"))
    profile = ExecutionProfiles.get(lane.execution_profile_id)
    errors = json_response(put(api_conn(), "/api/v1/lanes/#{lane.slug}", Jason.encode!(%{worker: %{ssh_hosts: ["replacement"]}})), 422)["errors"]
    assert Enum.any?(errors, &(&1["path"] == "worker"))
    assert ExecutionProfiles.get(profile.id).worker == profile.worker
    assert Lanes.get!(lane.id).current_version_id == lane.current_version_id
  end

  test "missing or malformed historical configuration stays visible as a repairable lane" do
    {:ok, lane} = Lanes.create(attrs("repair-api"))
    version = Lanes.current_version(lane)
    Repo.update!(Ecto.Changeset.change(version, front_matter: "tracker: [\n  literal-secret"))
    assert :ok = LaneStore.refresh(lane.id)
    lanes = json_response(get(api_conn(), "/api/v1/lanes"), 200)["lanes"]
    malformed = Enum.find(lanes, &(&1["id"] == lane.id))
    assert malformed["error"]
    assert malformed["config"] == %{}
    refute Jason.encode!(lanes) =~ "literal-secret"

    Repo.update!(Ecto.Changeset.change(Lanes.get!(lane.id), current_version_id: nil))
    assert :ok = LaneStore.refresh(lane.id)
    missing = json_response(get(api_conn(), "/api/v1/lanes"), 200)["lanes"] |> Enum.find(&(&1["id"] == lane.id))
    assert missing["error"]
    assert missing["current_version_id"] == nil
    assert missing["config"] == %{}
  end

  test "state enumerates unavailable lanes and refresh returns 503 when none can accept work" do
    {:ok, _lane} = Lanes.create(attrs("offline-lane"))
    assert %{"generated_at" => _, "lanes" => lanes} = json_response(get(api_conn(), "/api/v1/state"), 200)
    assert Enum.sort(Enum.map(lanes, & &1["lane"])) == ["default", "offline-lane"]
    assert Enum.all?(lanes, &(&1["error"]["code"] == "snapshot_unavailable"))
    assert json_response(post(api_conn(), "/api/v1/refresh", ""), 503)["error"]["code"] == "orchestrator_unavailable"
    assert json_response(get(api_conn(), "/api/v1/MISSING-1"), 404)["error"]["code"] == "issue_not_found"
    assert json_response(get(api_conn(), "/api/v1/lanes/offline-lane/MISSING-1"), 404)["error"]["code"] == "issue_not_found"
    assert json_response(get(api_conn(), "/api/v1/lanes/missing/MISSING-1"), 404)["error"]["code"] == "lane_not_found"
    assert length(LaneStore.list()) == 2
  end

  test "state and refresh preserve an available lane when another lane is unavailable" do
    assert %{"enabled" => false} =
             json_response(post(api_conn(), "/api/v1/lanes", Jason.encode!(Map.put(attrs("live-lane"), :enabled, true))), 201)

    assert %{"enabled" => true} = json_response(put(api_conn(), "/api/v1/lanes/live-lane", Jason.encode!(%{enabled: true})), 200)

    live_payload = await_snapshot("live-lane", 100)
    assert live_payload["counts"] == %{"running" => 0, "retrying" => 0, "blocked" => 0}

    assert %{"lanes" => [%{"lane" => "live-lane", "queued" => true}]} =
             json_response(post(api_conn(), "/api/v1/refresh", ""), 202)
  end

  defp await_snapshot(_slug, 0), do: flunk("lane did not become available")

  defp await_snapshot(slug, attempts) do
    payload = get(api_conn(), "/api/v1/state") |> json_response(200) |> Map.fetch!("lanes") |> Enum.find(&(&1["lane"] == slug))

    if Map.has_key?(payload, "counts") do
      payload
    else
      Process.sleep(10)
      await_snapshot(slug, attempts - 1)
    end
  end

  defp api_conn, do: build_conn() |> put_req_header("authorization", "Bearer test-token") |> put_req_header("content-type", "application/json")

  defp attrs(slug) do
    {:ok, profile} =
      ExecutionProfiles.create(%{
        name: "API #{slug} #{System.unique_integer([:positive])}",
        workspace_base: Path.join(System.tmp_dir!(), "symphony-api-#{slug}-#{System.unique_integer([:positive])}"),
        worker: %{}
      })

    %{slug: slug, name: "API", execution_profile_id: profile.id, workspace_subdir: ".", config: @config, prompt: "hi", note: "via api"}
  end
end
