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
    assert %{"errors" => [%{"path" => "version", "message" => "lane has no version"}]} = json_response(get(api_conn(), "/api/v1/lanes/no-version/export"), 422)
  end

  test "enabled lanes cannot be deleted, and disable allows deletion" do
    {:ok, _lane} = Lanes.create(attrs("active-lane"))
    assert %{"enabled" => true} = json_response(put(api_conn(), "/api/v1/lanes/active-lane", Jason.encode!(%{enabled: true})), 200)
    assert %{"error" => %{"code" => "lane_active"}} = json_response(delete(api_conn(), "/api/v1/lanes/active-lane"), 409)
    assert %{"enabled" => false} = json_response(put(api_conn(), "/api/v1/lanes/active-lane", Jason.encode!(%{enabled: false})), 200)
    assert response(delete(api_conn(), "/api/v1/lanes/active-lane"), 204) == ""
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
