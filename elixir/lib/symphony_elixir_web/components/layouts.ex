defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> Map.put_new(:__changed__, nil)
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:dashboard_css_url, SymphonyElixirWeb.StaticAssets.dashboard_css_url())
      |> assign(:favicon_url, SymphonyElixirWeb.StaticAssets.favicon_url())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony</title>
        <link rel="icon" type="image/png" sizes="128x128" href={@favicon_url} />
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            // Drag handle on the console detail pane. The width lives on <html> so LiveView patches cannot reset it.
            var DetailResize = {
              mounted: function () {
                var el = this.el, root = document.documentElement, key = "symphony.detailWidth";
                var saved = localStorage.getItem(key);
                if (saved) root.style.setProperty("--detail-w", saved);

                el.addEventListener("pointerdown", function (down) {
                  el.setPointerCapture(down.pointerId);
                  el.classList.add("dragging");
                  el.onpointermove = function (move) {
                    var width = Math.min(window.innerWidth * 0.7, Math.max(320, window.innerWidth - move.clientX));
                    root.style.setProperty("--detail-w", width + "px");
                  };
                  el.onpointerup = function () {
                    el.classList.remove("dragging");
                    el.onpointermove = el.onpointerup = null;
                    localStorage.setItem(key, root.style.getPropertyValue("--detail-w"));
                  };
                });

                el.addEventListener("dblclick", function () {
                  root.style.removeProperty("--detail-w");
                  localStorage.removeItem(key);
                });
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {DetailResize: DetailResize}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={@dashboard_css_url} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      <nav class="app-nav" aria-label="Main navigation">
        <a class="issue-link" href="/">← Console</a>
      </nav>
      <p :if={Phoenix.Flash.get(@flash, :error)} id="flash-error" class="error-card" role="alert">{Phoenix.Flash.get(@flash, :error)}</p>
      <p :if={Phoenix.Flash.get(@flash, :info)} id="flash-info" class="section-card" role="status">{Phoenix.Flash.get(@flash, :info)}</p>
      {@inner_content}
    </main>
    """
  end
end
