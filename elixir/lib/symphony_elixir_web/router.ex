defmodule SymphonyElixirWeb.Router do
  @moduledoc "Authenticated lane UI and API, with public static assets and login."

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :public_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(SymphonyElixirWeb.Plugs.Authenticate, :browser)
  end

  pipeline :api do
    plug(:fetch_session)
    plug(SymphonyElixirWeb.Plugs.Authenticate, :api)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:public_browser)
    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live_session :operator, on_mount: SymphonyElixirWeb.LiveAuth do
      live("/", LanesLive, :index)
      live("/lanes/new", LaneEditorLive, :new)
      live("/lanes/:slug/edit", LaneEditorLive, :edit)
      live("/lanes/:slug/versions", LaneVersionsLive, :index)
      live("/lanes/:slug", LaneLive, :show)
      live("/runs/:attempt_id", RunLive, :show)
    end
  end

  scope "/api/v1", SymphonyElixirWeb do
    pipe_through(:api)

    get("/state", ObservabilityApiController, :state)
    post("/refresh", ObservabilityApiController, :refresh)
    get("/lanes", LanesApiController, :index)
    post("/lanes", LanesApiController, :create)
    put("/lanes/:slug", LanesApiController, :update)
    delete("/lanes/:slug", LanesApiController, :delete)
    get("/lanes/:slug/export", LanesApiController, :export)
    post("/lanes/:slug/versions/:id/activate", LanesApiController, :activate)
    get("/lanes/:slug/:issue_identifier", ObservabilityApiController, :lane_issue)

    match(:*, "/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/lanes", ObservabilityApiController, :method_not_allowed)
    match(:*, "/lanes/:slug", ObservabilityApiController, :method_not_allowed)
    match(:*, "/lanes/:slug/export", ObservabilityApiController, :method_not_allowed)
    match(:*, "/lanes/:slug/versions/:id/activate", ObservabilityApiController, :method_not_allowed)
    match(:*, "/lanes/:slug/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    get("/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)
    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
