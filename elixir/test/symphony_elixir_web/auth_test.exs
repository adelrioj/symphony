defmodule SymphonyElixirWeb.AuthTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias SymphonyElixirWeb.{LiveAuth, ObservabilityPubSub}
  alias SymphonyElixirWeb.Plugs.Authenticate

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    original = Application.get_env(:symphony_elixir, @endpoint, [])
    Application.put_env(:symphony_elixir, @endpoint, Keyword.merge(original, server: false, secret_key_base: Config.operator_session_secret()))
    on_exit(fn -> Application.put_env(:symphony_elixir, @endpoint, original) end)
    start_supervised!({@endpoint, []})
    :ok
  end

  test "browser routes require authentication while login and assets are public" do
    for path <- ["/", "/lanes/new", "/lanes/default", "/runs/missing", "/unknown"] do
      assert redirected_to(get(build_conn(), path)) == "/login"
    end

    assert response(get(build_conn(), "/dashboard.css"), 200) =~ ":root"
    assert get(secure_conn(), "/login").status == 200
  end

  test "all API routes including method and path fallbacks require authentication" do
    for path <- ["/api/v1/state", "/api/v1/lanes", "/api/v1/refresh", "/api/v1/unknown/deeper"] do
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(get(build_conn(), path), 401)
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(post(build_conn(), path, %{}), 401)
    end

    for header <- ["Bearer wrong", "Basic test-token", "Bearer ", "Bearer test-token "] do
      conn = build_conn() |> put_req_header("authorization", header) |> get("/api/v1/state")
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  test "a runtime plug pipeline rejects ambiguous authorization headers before protected work" do
    conn = Plug.Test.init_test_session(Plug.Test.conn(:get, "/api/v1/state"), %{})
    conn = %{conn | req_headers: [{"authorization", "Bearer test-token"}, {"authorization", "Bearer wrong"}]}

    conn = Plug.run(conn, [{Authenticate, :api}, fn conn -> send_resp(conn, 200, "protected response") end])

    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    refute get_session(conn, :operator)
  end

  test "login requires CSRF and a valid credential, then the cookie grants browser and API access" do
    assert_error_sent(403, fn -> post(secure_conn(), "/login", %{"token" => "test-token"}) end)

    {conn, csrf} = login_form()
    conn = post(conn, "/login", %{"token" => "wrong", "_csrf_token" => csrf})
    assert html_response(conn, 401) =~ "Invalid operator token"
    refute get_session(conn, :operator)

    {conn, csrf} = login_form()
    assert html_response(post(conn, "/login", %{"_csrf_token" => csrf}), 400) =~ "Token required"

    {conn, csrf} = login_form()
    assert html_response(post(conn, "/login", %{"_csrf_token" => csrf, "token" => ["test-token"]}), 400) =~ "Token required"

    {conn, csrf} = login_form()
    logged_in = post(conn, "/login", %{"token" => "test-token", "_csrf_token" => csrf})
    assert redirected_to(logged_in) == "/"
    assert get_session(logged_in, :operator) == true
    assert %{"lanes" => _} = json_response(get(recycle(logged_in), "/api/v1/state"), 200)
    assert {:ok, _view, _html} = live(recycle(logged_in), "/")
  end

  test "cookie API mutations reject missing or invalid CSRF, while valid CSRF or explicit bearer works" do
    {conn, csrf} = login_form()
    logged_in = post(conn, "/login", %{"token" => "test-token", "_csrf_token" => csrf})
    attrs = %{"slug" => "csrf-lane", "front_matter" => "tracker:\n  kind: memory", "prompt" => "hi"}

    cookie_conn = logged_in |> recycle() |> put_private(:plug_skip_csrf_protection, false)
    assert %{"error" => %{"code" => "invalid_csrf_token"}} = json_response(post(cookie_conn, "/api/v1/lanes", attrs), 403)
    refute SymphonyElixir.Lanes.get_by_slug("csrf-lane")

    cookie_conn = logged_in |> recycle() |> put_private(:plug_skip_csrf_protection, false)
    cookie_conn = put_req_header(cookie_conn, "x-csrf-token", "wrong")
    cookie_conn = put_req_header(cookie_conn, "authorization", "Bearer wrong")
    assert json_response(post(cookie_conn, "/api/v1/lanes", attrs), 403)

    cookie_conn = logged_in |> recycle() |> put_private(:plug_skip_csrf_protection, false) |> put_req_header("x-csrf-token", csrf)
    assert %{"slug" => "csrf-lane"} = json_response(post(cookie_conn, "/api/v1/lanes", attrs), 201)

    bearer_conn = logged_in |> recycle() |> put_private(:plug_skip_csrf_protection, false) |> put_req_header("authorization", "Bearer test-token")
    assert response(delete(bearer_conn, "/api/v1/lanes/csrf-lane"), 204) == ""
  end

  test "bearer credentials establish a LiveView session and unauthenticated websocket mounts halt" do
    conn = build_conn() |> put_req_header("authorization", "Bearer test-token") |> get("/")
    assert get_session(conn, :operator) == true
    assert {:ok, _view, _html} = live(conn)
    assert {:halt, socket} = LiveAuth.on_mount(:default, %{}, %{}, %Phoenix.LiveView.Socket{})
    assert {:redirect, %{to: "/login"}} = socket.redirected
    assert {:cont, _socket} = LiveAuth.on_mount(:default, %{}, %{"operator" => true}, %Phoenix.LiveView.Socket{})
  end

  test "tokens must be configured, nonempty strings with an exact constant-time match" do
    refute Authenticate.token_matches?(nil)
    refute Authenticate.token_matches?(%{})
    refute Authenticate.token_matches?("short")
    assert Authenticate.token_matches?("test-token")
    Application.put_env(:symphony_elixir, :operator_token, "")
    refute Authenticate.token_matches?("")
    Application.delete_env(:symphony_elixir, :operator_token)
    refute Authenticate.token_matches?("anything")
  end

  test "cookies signed with the former public key cannot forge operator access" do
    forged =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
      |> Plug.Session.call(Plug.Session.init(store: :cookie, key: "_symphony_elixir_key", signing_salt: "symphony-session"))
      |> fetch_session()
      |> put_session(:operator, true)
      |> send_resp(200, "")

    conn = build_conn() |> Plug.Test.recycle_cookies(forged) |> get("/api/v1/state")
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "lane and run subscriptions are isolated" do
    assert :ok = ObservabilityPubSub.subscribe_lane("features")
    assert :ok = ObservabilityPubSub.subscribe_run("attempt-one")
    ObservabilityPubSub.broadcast_lane("features")
    ObservabilityPubSub.broadcast_lane("bugs")
    ObservabilityPubSub.broadcast_run("attempt-one", {:run_updated, "attempt-one"})
    ObservabilityPubSub.broadcast_run("attempt-two", {:run_updated, "attempt-two"})
    assert_receive {:lane_updated, "features"}
    assert_receive {:run_updated, "attempt-one"}
    refute_receive {:lane_updated, "bugs"}
    refute_receive {:run_updated, "attempt-two"}
  end

  defp secure_conn, do: build_conn() |> put_private(:plug_skip_csrf_protection, false)

  defp login_form do
    conn = get(secure_conn(), "/login")
    [csrf] = conn |> html_response(200) |> Floki.parse_document!() |> Floki.attribute("input[name=_csrf_token]", "value")
    {conn |> recycle() |> put_private(:plug_skip_csrf_protection, false), csrf}
  end
end
