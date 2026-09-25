defmodule SymphonyElixirWeb.ExecutionProfilesApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn

  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Repo}

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

    updated =
      created
      |> Map.put("description", "round trip")
      |> then(&json_response(put(api_conn(), "/api/v1/execution-profiles/#{created["id"]}", Jason.encode!(&1)), 200))

    assert updated["worker"]["api_key"] == "$REDACTED"
    assert ExecutionProfiles.get(created["id"]).worker["api_key"] == "literal-worker-secret"

    errors = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "No source", worker: %{api_key: "$REDACTED"}})), 422)["errors"]
    assert Enum.any?(errors, &(&1["path"] == "worker.api_key"))
  end

  @tag :remediation
  test "secret-labelled collections stay confidential through API read-modify-write" do
    worker = %{
      "credentials" => %{"primary" => "collection-secret", "reference" => "$WORKER_CREDENTIAL"},
      "tokens" => ["array-secret", "$WORKER_TOKEN", %{"value" => "nested-secret"}],
      "extension" => %{"keep" => [1, false]}
    }

    created = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "Collection secrets", worker: worker})), 201)
    shown = json_response(get(api_conn(), "/api/v1/execution-profiles/#{created["id"]}"), 200)

    for secret <- ["collection-secret", "array-secret", "nested-secret"] do
      refute Jason.encode!(shown) =~ secret
    end

    assert shown["worker"]["credentials"]["reference"] == "$WORKER_CREDENTIAL"
    assert Enum.at(shown["worker"]["tokens"], 1) == "$WORKER_TOKEN"
    assert shown["worker"]["extension"] == worker["extension"]

    updated = json_response(put(api_conn(), "/api/v1/execution-profiles/#{created["id"]}", Jason.encode!(Map.put(shown, "description", "Unrelated edit"))), 200)
    assert updated["description"] == "Unrelated edit"
    assert ExecutionProfiles.get(created["id"]).worker == worker
  end

  @tag :remediation
  test "dollar-prefixed literal secrets stay redacted through API projections and retain their stored bytes on round trip" do
    worker = %{
      "api_key" => "$private-token",
      "credentials" => [%{"value" => "$WORKER_TOKEN\n", "reference" => "$_WORKER_TOKEN_2"}, ["$", "$TOKEN\nprivate"]],
      "extension" => %{"keep" => true}
    }

    expected_worker = %{
      "api_key" => "$REDACTED",
      "credentials" => [%{"value" => "$REDACTED", "reference" => "$_WORKER_TOKEN_2"}, ["$REDACTED", "$REDACTED"]],
      "extension" => %{"keep" => true}
    }

    created = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "Dollar literal secrets", worker: worker})), 201)
    path = "/api/v1/execution-profiles/#{created["id"]}"
    shown = json_response(get(api_conn(), path), 200)
    listed = json_response(get(api_conn(), "/api/v1/execution-profiles"), 200)["execution_profiles"] |> Enum.find(&(&1["id"] == created["id"]))

    assert created["worker"] == expected_worker
    assert shown["worker"] == expected_worker
    assert listed["worker"] == expected_worker
    assert ExecutionProfiles.get(created["id"]).worker == worker

    updated = json_response(put(api_conn(), path, Jason.encode!(Map.put(shown, "description", "Unrelated edit"))), 200)
    assert updated["description"] == "Unrelated edit"
    assert updated["worker"] == expected_worker
    assert ExecutionProfiles.get(created["id"]).worker == worker
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

  test "invalid profile bodies and infrastructure ownership keys leave storage unchanged" do
    for body <- ["[]", Jason.encode!(%{name: "Forbidden", workspace: %{root: "/tmp"}})] do
      response = post(api_conn(), "/api/v1/execution-profiles", body)
      assert response.status == 422
      assert json_response(response, 422)["errors"] != []
    end

    refute Enum.any?(ExecutionProfiles.list(), &(&1.name == "Forbidden"))
  end

  test "failed profile updates preserve prior values and credential material" do
    first = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "First"})), 201)
    second = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "Second"})), 201)
    path = "/api/v1/execution-profiles/#{second["id"]}"

    duplicate = json_response(put(api_conn(), path, Jason.encode!(%{name: first["name"]})), 422)
    assert Enum.any?(duplicate["errors"], &(&1["path"] == "name"))

    forged = json_response(put(api_conn(), path, Jason.encode!(%{worker: %{accounts: [%{token: "$REDACTED"}]}})), 422)
    assert Enum.any?(forged["errors"], &(&1["path"] == "worker.accounts[0].token"))
    assert ExecutionProfiles.get(second["id"]).name == "Second"
    assert ExecutionProfiles.get(second["id"]).worker == %{}
  end

  test "an unreferenced profile is removed from API reads" do
    created = json_response(post(api_conn(), "/api/v1/execution-profiles", Jason.encode!(%{name: "Disposable"})), 201)
    path = "/api/v1/execution-profiles/#{created["id"]}"
    assert response(delete(api_conn(), path), 204) == ""
    assert json_response(get(api_conn(), path), 404)["error"]["code"] == "execution_profile_not_found"
  end

  test "a migrated profile with an unknown base remains inspectable but cannot dispatch" do
    {:ok, profile} = ExecutionProfiles.create(%{name: "Repair base", workspace_base: "/tmp/profile-repair-base"})
    {:ok, lane} = Lanes.create(%{slug: "repair-profile-base", execution_profile_id: profile.id, config: %{"tracker" => %{"kind" => "memory"}}})
    Repo.update!(Ecto.Changeset.change(profile, workspace_base: nil, repair_error: "Invalid legacy workspace base"))
    assert :ok = LaneStore.refresh(lane.id)

    repair = json_response(get(api_conn(), "/api/v1/execution-profiles/#{profile.id}"), 200)
    assert repair["workspace_base"] == nil
    assert repair["repair_error"]
    assert {:error, {:lane_invalid, _}} = LaneStore.reserve_dispatch(lane.id)
    assert %{"error" => error} = json_response(get(api_conn(), "/api/v1/lanes"), 200)["lanes"] |> Enum.find(&(&1["id"] == lane.id))
    assert error
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
