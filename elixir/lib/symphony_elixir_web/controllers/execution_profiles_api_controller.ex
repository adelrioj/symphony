defmodule SymphonyElixirWeb.ExecutionProfilesApiController do
  @moduledoc "Execution profile configuration for automation."

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.ExecutionProfiles
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.ExecutionProfiles.Profile
  alias SymphonyElixirWeb.ConfigurationFields

  @profile_params ~w(name description workspace_base worker)
  @max_sqlite_id 9_223_372_036_854_775_807

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params), do: json(conn, %{execution_profiles: Enum.map(ExecutionProfiles.list(), &profile_json/1)})

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, _params), do: with_profile(conn, &json(conn, profile_json(&1)))

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    with {:ok, attrs} <- attributes(conn),
         {:ok, attrs} <- restore_worker(attrs, %{}),
         {:ok, profile} <- ExecutionProfiles.create(attrs) do
      conn |> put_status(201) |> json(profile_json(profile))
    else
      {:error, errors} -> errors_response(conn, errors)
    end
  end

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, _params) do
    with_profile(conn, fn profile ->
      with {:ok, attrs} <- attributes(conn),
           {:ok, attrs} <- restore_worker(attrs, profile.worker),
           {:ok, updated} <- ExecutionProfiles.update(profile, attrs) do
        json(conn, profile_json(updated))
      else
        {:error, errors} -> errors_response(conn, errors)
      end
    end)
  end

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, _params) do
    with_profile(conn, fn profile ->
      case ExecutionProfiles.delete(profile) do
        :ok -> send_resp(conn, 204, "")
        {:error, errors} -> errors_response(conn, errors)
      end
    end)
  end

  defp with_profile(conn, fun) do
    case parse_id(conn.path_params["id"]) do
      {:ok, id} ->
        case ExecutionProfiles.get(id) do
          nil -> conn |> put_status(404) |> json(%{error: %{code: "execution_profile_not_found", message: "Execution profile not found"}})
          %Profile{} = profile -> fun.(profile)
        end

      :error ->
        errors_response(conn, [%{path: "id", message: "must be a positive integer id"}])
    end
  end

  defp attributes(conn) do
    case conn.body_params do
      %{"_json" => _} ->
        {:error, [%{path: "body", message: "must be a JSON object"}]}

      %{} = attrs ->
        forbidden =
          ["config", "executor", "front_matter", "workspace"]
          |> Enum.filter(&Map.has_key?(attrs, &1))
          |> Enum.map(&%{path: &1, message: "is not a profile attribute"})

        if forbidden == [], do: {:ok, Map.take(attrs, @profile_params)}, else: {:error, forbidden}
    end
  end

  defp profile_json(%Profile{} = profile) do
    %{
      id: profile.id,
      name: profile.name,
      description: profile.description,
      workspace_base: profile.workspace_base,
      worker: ConfigurationFields.safe_value(profile.worker),
      repair_error: profile.repair_error,
      linked_lane_ids: Enum.map(ExecutionProfiles.linked_lanes(profile), & &1.id),
      updated_at: profile.updated_at
    }
  end

  defp restore_worker(attrs, original) do
    case Map.fetch(attrs, "worker") do
      {:ok, worker} ->
        case Configuration.restore_redacted(worker, original, "worker") do
          {:ok, restored} -> {:ok, Map.put(attrs, "worker", restored)}
          error -> error
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp errors_response(conn, errors), do: conn |> put_status(422) |> json(%{errors: errors})

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= @max_sqlite_id -> {:ok, id}
      _ -> :error
    end
  end
end
