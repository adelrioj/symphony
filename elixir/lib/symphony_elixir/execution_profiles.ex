defmodule SymphonyElixir.ExecutionProfiles do
  @moduledoc "Persistence and serialized publication for reusable execution profiles."

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.ExecutionProfiles.Profile
  alias SymphonyElixir.{Lanes, LaneStore, Repo}
  alias SymphonyElixir.Runs.Run
  alias SymphonyElixirWeb.ObservabilityPubSub

  @max_sqlite_id 9_223_372_036_854_775_807

  @spec list() :: [Profile.t()]
  def list, do: Repo.all(from(p in Profile, order_by: p.id))

  @spec get(term()) :: Profile.t() | nil
  def get(id) when is_integer(id) and id > 0 and id <= @max_sqlite_id, do: Repo.get(Profile, id)
  def get(_id), do: nil

  @spec linked_lanes(Profile.t()) :: [Lanes.Lane.t()]
  def linked_lanes(%Profile{id: id}) do
    Repo.all(from(l in Lanes.Lane, where: l.execution_profile_id == ^id, order_by: l.id))
  end

  @spec create(map()) :: {:ok, Profile.t()} | {:error, [Lanes.error()]}
  def create(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize(attrs),
         attrs <- Map.put_new(attrs, "workspace_base", %SymphonyElixir.Config.Schema.Workspace{}.root),
         :ok <- validate(attrs),
         :ok <- Configuration.validate_profile(attrs) do
      LaneStore.mutate(nil, fn _check -> insert_profile(attrs) end, nil)
      |> result_errors()
      |> broadcast_result()
    end
  end

  def create(_attrs), do: {:error, [%{path: "profile", message: "must be an object"}]}

  @spec update(Profile.t(), map()) :: {:ok, Profile.t()} | {:error, [Lanes.error()]}
  def update(%Profile{id: id}, attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize(attrs),
         {:ok, profile} <- fetch_profile(id),
         attrs <- if(profile.repair_error, do: Map.put(attrs, "repair_error", nil), else: attrs),
         full_attrs <- profile_attrs(profile) |> Map.merge(attrs),
         :ok <- validate(full_attrs),
         :ok <- Configuration.validate_profile(full_attrs) do
      LaneStore.mutate(nil, fn _check -> update_profile(id, attrs) end, nil)
      |> result_errors()
      |> broadcast_result()
    end
  end

  def update(%Profile{}, _attrs), do: {:error, [%{path: "profile", message: "must be an object"}]}

  @spec delete(Profile.t()) :: :ok | {:error, [Lanes.error()]}
  def delete(%Profile{id: id}) do
    LaneStore.mutate({:delete_profile, id}, fn _check -> delete_profile(Repo.get(Profile, id)) end, nil)
    |> case do
      {:ok, :ok} ->
        ObservabilityPubSub.broadcast_profiles()
        :ok

      {:error, reason} ->
        {:error, Lanes.errors_for(reason)}
    end
  end

  defp fetch_profile(id) do
    case Repo.get(Profile, id) do
      nil -> {:error, [%{path: "profile", message: "not found"}]}
      profile -> {:ok, profile}
    end
  end

  defp insert_profile(attrs) do
    case Repo.insert(Profile.changeset(%Profile{}, attrs)) do
      {:ok, profile} -> {:ok, {:batch, profile, []}}
      {:error, changeset} -> {:error, Lanes.errors_for(changeset)}
    end
  end

  defp update_profile(id, attrs) do
    with {:ok, profile} <- fetch_profile(id) do
      case Repo.update(Profile.changeset(profile, attrs)) do
        {:ok, updated} -> {:ok, {:batch, updated, linked_lane_ids(updated)}}
        {:error, changeset} -> {:error, Lanes.errors_for(changeset)}
      end
    end
  end

  defp delete_profile(nil), do: {:ok, {:batch, :ok, []}}

  defp delete_profile(%Profile{id: id} = profile) do
    cond do
      Repo.exists?(from(l in Lanes.Lane, where: l.execution_profile_id == ^id)) ->
        {:error, [%{path: "lanes", message: "profile is still referenced by lanes"}]}

      Repo.exists?(from(r in Run, where: r.execution_profile_id == ^id)) ->
        {:error, [%{path: "runs", message: "profile is still referenced by run history"}]}

      true ->
        Repo.delete!(profile)
        {:ok, {:batch, :ok, []}}
    end
  end

  defp broadcast_result({:ok, value}) do
    ObservabilityPubSub.broadcast_profiles()
    {:ok, value}
  end

  defp broadcast_result(error), do: error

  defp linked_lane_ids(%Profile{} = profile), do: linked_lanes(profile) |> Enum.map(& &1.id)

  defp profile_attrs(profile), do: Map.take(Map.from_struct(profile), [:name, :description, :workspace_base, :worker]) |> Map.new(fn {key, value} -> {to_string(key), value} end)

  defp normalize(attrs) do
    if Enum.all?(Map.keys(attrs), &(is_binary(&1) or is_atom(&1))) do
      attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

      {:ok, attrs}
    else
      {:error, [%{path: "profile", message: "must be an object"}]}
    end
  end

  defp validate(attrs) do
    case Profile.changeset(%Profile{}, attrs) |> Ecto.Changeset.apply_action(:validate) do
      {:ok, _profile} -> :ok
      {:error, changeset} -> {:error, Lanes.errors_for(changeset)}
    end
  end

  defp result_errors({:ok, {:batch, value, _ids}}), do: {:ok, value}
  defp result_errors({:ok, value}), do: {:ok, value}
  defp result_errors({:error, errors}) when is_list(errors), do: {:error, errors}

  defp result_errors({:error, {:workspace_identity_in_use, left, right}}) do
    {:error,
     [
       %{path: "lanes.#{left}.workspace", message: "location conflicts with lane #{right}"},
       %{path: "lanes.#{right}.workspace", message: "location conflicts with lane #{left}"}
     ]}
  end

  defp result_errors({:error, reason}), do: {:error, Lanes.errors_for(reason)}
end
