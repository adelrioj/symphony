defmodule SymphonyElixirWeb.SessionController do
  @moduledoc "Single-field operator login with a renewed, signed browser session."

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias SymphonyElixirWeb.Plugs.Authenticate

  plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
  plug(:put_layout, false)
  plug(:put_view, html: SymphonyElixirWeb.LoginHTML)

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params), do: render(conn, :new, error: nil)

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"token" => token}) when is_binary(token) do
    if Authenticate.token_matches?(token) do
      conn |> configure_session(renew: true) |> put_session(:operator, true) |> redirect(to: "/")
    else
      conn |> put_status(401) |> render(:new, error: "Invalid operator token")
    end
  end

  def create(conn, _params), do: conn |> put_status(400) |> render(:new, error: "Token required")
end
