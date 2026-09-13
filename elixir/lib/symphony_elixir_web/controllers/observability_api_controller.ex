defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    json(conn, %{generated_at: generated_at, lanes: Enum.map(Presenter.lanes(), &Presenter.lane_payload(&1, snapshot_timeout_ms()))})
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    Presenter.lanes()
    |> Enum.find_value(fn entry -> issue_in_lane(entry, issue_identifier) end)
    |> issue_response(conn)
  end

  @spec lane_issue(Conn.t(), map()) :: Conn.t()
  def lane_issue(conn, _params) do
    %{"slug" => slug, "issue_identifier" => identifier} = conn.path_params

    case SymphonyElixir.LaneStore.by_slug(slug) do
      {:ok, entry} -> entry |> issue_in_lane(identifier) |> issue_response(conn)
      :error -> error_response(conn, 404, "lane_not_found", "Lane not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    refreshed =
      Enum.flat_map(Presenter.lanes(), fn entry ->
        case Presenter.refresh_payload(Presenter.orchestrator_for(entry)) do
          {:ok, payload} -> [Map.put(payload, :lane, entry.slug)]
          {:error, :unavailable} -> []
        end
      end)

    if refreshed == [] do
      error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    else
      conn |> put_status(202) |> json(%{lanes: refreshed})
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp issue_in_lane(entry, identifier) do
    case Presenter.issue_payload(identifier, Presenter.orchestrator_for(entry), snapshot_timeout_ms()) do
      {:ok, payload} -> Map.put(payload, :lane, entry.slug)
      {:error, :issue_not_found} -> nil
    end
  end

  defp issue_response(nil, conn), do: error_response(conn, 404, "issue_not_found", "Issue not found")
  defp issue_response(payload, conn), do: json(conn, payload)

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
