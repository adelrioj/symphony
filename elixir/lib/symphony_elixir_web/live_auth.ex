defmodule SymphonyElixirWeb.LiveAuth do
  @moduledoc "Rechecks the authenticated session on LiveView joins."

  import Phoenix.LiveView, only: [redirect: 2]

  alias Phoenix.LiveView.Socket

  @spec on_mount(:default, map(), map(), Socket.t()) :: {:cont, Socket.t()} | {:halt, Socket.t()}
  def on_mount(:default, _params, session, socket) do
    if session["operator"] == true, do: {:cont, socket}, else: {:halt, redirect(socket, to: "/login")}
  end
end
