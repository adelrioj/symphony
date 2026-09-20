defmodule SymphonyElixirWeb.LanesApiController do
  @moduledoc "Lane configuration, immutable versions, and workflow export for automation."

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.{Lanes, LaneStore, LaneSupervisor, Workflow}
  alias SymphonyElixir.Lanes.Lane
  alias SymphonyElixirWeb.ConfigurationFields

  @lane_params ~w(slug name enabled execution_profile_id workspace_subdir config prompt note front_matter executor)

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params), do: json(conn, %{lanes: Enum.map(Lanes.list(), &lane_json/1)})

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params), do: with_attributes(conn, &create_lane(conn, &1))

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, _params) do
    with_lane(conn, fn lane ->
      with_attributes(conn, &update_lane(conn, lane, &1))
    end)
  end

  @spec activate(Conn.t(), map()) :: Conn.t()
  def activate(conn, _params) do
    with_lane(conn, fn lane ->
      case Integer.parse(conn.path_params["id"]) do
        {version_id, ""} when version_id > 0 ->
          lane_response(conn, Lanes.activate_version(lane, version_id))

        _ ->
          errors_response(conn, [%{path: "version", message: "must be a positive integer id"}])
      end
    end)
  end

  @spec export(Conn.t(), map()) :: Conn.t()
  def export(conn, _params) do
    with_lane(conn, fn lane ->
      case Lanes.export(lane) do
        {:ok, content} -> conn |> put_resp_content_type("text/markdown") |> send_resp(200, content)
        {:error, :no_version} -> errors_response(conn, [%{path: "version", message: "lane has no version"}])
      end
    end)
  end

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, _params) do
    with_lane(conn, fn lane ->
      case Lanes.delete(lane) do
        :ok -> send_resp(conn, 204, "")
        {:error, :lane_active} -> conn |> put_status(409) |> json(%{error: %{code: "lane_active", message: "Disable the lane and wait for its agents to stop before deleting it"}})
        {:error, errors} -> errors_response(conn, errors)
      end
    end)
  end

  # Path identity never comes from merged query/body params: slug is also an editable field.
  defp with_lane(conn, fun) do
    case Lanes.get_by_slug(conn.path_params["slug"]) do
      nil -> conn |> put_status(404) |> json(%{error: %{code: "lane_not_found", message: "Lane not found"}})
      %Lane{} = lane -> fun.(lane)
    end
  end

  defp with_attributes(conn, fun) do
    case conn.body_params do
      %{"_json" => _} ->
        errors_response(conn, [%{path: "body", message: "must be a JSON object"}])

      %{} = attrs ->
        forbidden =
          ["worker", "workspace", "workspace_base"]
          |> Enum.filter(&Map.has_key?(attrs, &1))
          |> Enum.map(&%{path: &1, message: "is owned by the execution profile"})

        if forbidden == [], do: fun.(Map.take(attrs, @lane_params)), else: errors_response(conn, forbidden)
    end
  end

  defp lane_response(conn, {:ok, lane}), do: json(conn, lane_json(lane))
  defp lane_response(conn, {:error, errors}), do: errors_response(conn, errors)

  defp create_lane(conn, attrs) do
    with {:ok, attrs} <- restore_config(attrs, %{}),
         {:ok, lane} <- Lanes.create(attrs) do
      conn |> put_status(201) |> json(lane_json(lane))
    else
      {:error, errors} -> errors_response(conn, errors)
    end
  end

  defp update_lane(conn, lane, attrs) do
    case restore_config(attrs, lane_config(lane)) do
      {:ok, attrs} -> lane_response(conn, Lanes.update(lane, attrs))
      {:error, errors} -> errors_response(conn, errors)
    end
  end

  defp errors_response(conn, errors), do: conn |> put_status(422) |> json(%{errors: errors})

  defp lane_json(%Lane{} = lane) do
    {:ok, entry} = LaneStore.lookup(lane.id)
    config = lane_config(lane)

    %{
      id: lane.id,
      slug: lane.slug,
      name: lane.name,
      enabled: lane.enabled,
      executor: lane.executor,
      execution_profile_id: lane.execution_profile_id,
      execution_profile_name: entry.profile_name,
      workspace_subdir: lane.workspace_subdir,
      config: ConfigurationFields.safe_value(config),
      current_version_id: lane.current_version_id,
      running: LaneSupervisor.running?(lane.id),
      updated_at: lane.updated_at,
      error: entry.error,
      restarts: entry.runtime.restarts,
      last_crash: entry.runtime.last_crash && entry.runtime.last_crash.reason,
      warnings: entry.warnings
    }
  end

  defp lane_config(%Lane{} = lane) do
    case Lanes.current_version(lane) do
      nil ->
        %{}

      version ->
        case Workflow.parse_parts(version.front_matter, "") do
          {:ok, %{config: config}} ->
            {_profile, config} = Configuration.split(config)
            config

          _ ->
            %{}
        end
    end
  end

  defp restore_config(attrs, original) do
    case Map.fetch(attrs, "config") do
      {:ok, config} ->
        case Configuration.restore_redacted(config, original, "config") do
          {:ok, restored} -> {:ok, Map.put(attrs, "config", restored)}
          error -> error
        end

      :error ->
        {:ok, attrs}
    end
  end
end
