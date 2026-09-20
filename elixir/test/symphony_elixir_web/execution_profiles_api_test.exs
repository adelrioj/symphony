defmodule SymphonyElixirWeb.ExecutionProfilesApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn

  alias SymphonyElixir.{ExecutionProfiles, Lanes}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    original = Application.get_env(:symphony_elixir, @endpoint, [])
    Application.put_env(:symphony_elixir, @endpoint, Keyword.merge(original, server: false, secret_key_base: Config.operator_session_secret()))
    on_exit(fn -> Application.put_env(:symphony_elixir, @endpoint, original) end)
    start_supervised!({@endpoint, []})
    :ok
  end

  test "profile routes use the API authentication plug" do
    assert json_response(get(build_conn(), "/api/v1/execution-profiles"), 401)["error"]["code"] == "unauthorized"
    assert json_response(post(build_conn() |> put_req_header("content-type", "application/json"), "/api/v1/execution-profiles", Jason.encode!(%{})), 401)["error"]["code"] == "unauthorized"
  end

  test "create, read and update preserve raw worker references" do
    previous_secret = System.get_env("WORKER_API_KEY")
    System.put_env("WORKER_API_KEY", "distinct-worker-test-secret")
    on_exit(fn -> SymphonyElixir.TestSupport.restore_env("WORKER_API_KEY", previous_secret) end)

    attrs = %{name: "API profile", workspace_base: "/tmp/api-profile", worker: %{ssh_hosts: ["worker-1"], api_key: "$WORKER_API_KEY"}}
    profile = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(attrs)), 201)

    assert profile["name"] == "API profile"
    assert profile["worker"]["api_key"] == "$WORKER_API_KEY"
    refute Jason.encode!(profile) =~ "distinct-worker-test-secret"
    shown = json_response(get(api_conn(), "/api/v1/execution-profiles/#{profile["id"]}"), 200)
    listed = json_response(get(api_conn(), "/api/v1/execution-profiles"), 200)
    assert shown["id"] == profile["id"]
    refute Jason.encode!([shown, listed]) =~ "distinct-worker-test-secret"

    updated = json_response(put(api_conn(), "/api/v1/execution-profiles/#{profile["id"]}", Jason.encode!(%{description: "Updated"})), 200)
    assert updated["description"] == "Updated"
    assert updated["worker"] == profile["worker"]
    refute Jason.encode!(updated) =~ "distinct-worker-test-secret"
  end

  test "create materializes the default workspace base" do
    profile = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "Default root"})), 201)
    assert is_binary(profile["workspace_base"])
    assert profile["workspace_base"] != ""
    assert ExecutionProfiles.get(profile["id"]).workspace_base == profile["workspace_base"]
  end

  test "literal worker credentials are redacted while references remain intact" do
    attrs = %{
      name: "Secret-safe profile",
      workspace_base: "/tmp/secret-safe-profile",
      worker: %{api_key: "literal-worker-secret", nested: %{credential: "$WORKER_CREDENTIAL"}}
    }

    created = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(attrs)), 201)
    assert created["worker"]["api_key"] == "$REDACTED"
    assert created["worker"]["nested"]["credential"] == "$WORKER_CREDENTIAL"
    assert ExecutionProfiles.get(created["id"]).worker["api_key"] == "literal-worker-secret"

    listed = json_response(get(api_conn(), "/api/v1/execution-profiles"), 200)
    refute Jason.encode!(listed) =~ "literal-worker-secret"
  end

  test "duplicate names and invalid profile maps return field errors" do
    assert json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "Duplicate"})), 201)
    errors = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "Duplicate"})), 422)["errors"]
    assert Enum.any?(errors, &(&1["path"] == "name"))

    errors = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "Bad", worker: []})), 422)["errors"]
    assert Enum.any?(errors, &(&1["path"] == "worker"))
  end

  test "referenced profile deletion is rejected and lane remains linked" do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Referenced", workspace_base: "/tmp/referenced", worker: %{}})
    {:ok, lane} = Lanes.create(%{slug: "profile-api-lane", execution_profile_id: profile.id, workspace_subdir: "profile-api-lane", config: %{"tracker" => %{"kind" => "memory"}}})

    response = delete(api_conn(), "/api/v1/execution-profiles/#{profile.id}")
    assert response.status == 422
    assert Enum.any?(json_response(response, 422)["errors"], &(&1["path"] == "lanes"))
    assert Lanes.get!(lane.id).execution_profile_id == profile.id
  end

  test "bounded profile ids keep 404 and validation semantics" do
    assert json_response(get(api_conn(), "/api/v1/execution-profiles/999999999999999999999"), 422)["errors"]
    assert json_response(get(api_conn(), "/api/v1/execution-profiles/999999"), 404)["error"]["code"] == "execution_profile_not_found"
  end

  defp api_conn do
    build_conn()
    |> put_req_header("authorization", "Bearer test-token")
    |> put_req_header("content-type", "application/json")
  end
end
