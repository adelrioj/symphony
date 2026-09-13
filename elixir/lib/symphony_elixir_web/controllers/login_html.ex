defmodule SymphonyElixirWeb.LoginHTML do
  @moduledoc false
  import Phoenix.Component, only: [sigil_H: 2]

  @spec new(map()) :: Phoenix.LiveView.Rendered.t()
  def new(assigns) do
    ~H"""
    <main class="app-shell">
      <section class="section-card">
        <h1 class="section-title">Symphony</h1>
        <p :if={@error} class="error-copy" role="alert">{@error}</p>
        <form method="post" action="/login">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <label for="operator-token">Operator token</label>
          <input id="operator-token" type="password" name="token" autofocus autocomplete="current-password" required />
          <button type="submit" class="subtle-button">Sign in</button>
        </form>
      </section>
    </main>
    """
  end
end
