defmodule SymphonyElixirWeb.Plugs.Authenticate do
  @moduledoc "Authenticates the installation operator, protecting cookie API writes against CSRF."

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, json: 2]

  alias SymphonyElixir.Config

  @type mode :: :browser | :api
  @csrf_options Plug.CSRFProtection.init(with: :exception)

  @spec init(mode()) :: mode()
  def init(mode) when mode in [:browser, :api], do: mode

  @spec call(Plug.Conn.t(), mode()) :: Plug.Conn.t()
  def call(conn, mode) do
    cond do
      bearer_ok?(conn) ->
        conn |> configure_session(renew: true) |> put_session(:operator, true)

      get_session(conn, :operator) == true ->
        if mode == :api, do: protect_cookie_request(conn), else: conn

      mode == :api ->
        conn |> put_status(401) |> json(%{error: %{code: "unauthorized", message: "Missing or invalid operator token"}}) |> halt()

      true ->
        conn |> redirect(to: "/login") |> halt()
    end
  end

  @spec token_matches?(term()) :: boolean()
  def token_matches?(candidate) do
    token = Config.operator_token()
    is_binary(token) and token != "" and is_binary(candidate) and Plug.Crypto.secure_compare(candidate, token)
  end

  defp bearer_ok?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> candidate] -> token_matches?(candidate)
      _ -> false
    end
  end

  defp protect_cookie_request(conn) do
    Plug.CSRFProtection.call(conn, @csrf_options)
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError ->
      conn |> put_status(403) |> json(%{error: %{code: "invalid_csrf_token", message: "A valid CSRF token is required"}}) |> halt()
  end
end
