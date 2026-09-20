# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule SymphonyElixir.ExecutionProfiles do
  @moduledoc "Persistence and serialized publication for reusable execution profiles."

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.ExecutionProfiles.Profile
  alias SymphonyElixir.{Lanes, LaneStore, Repo}
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
    with {:ok, attrs} <- normalize(attrs) do
      attrs = Map.put_new(attrs, "workspace_base", %SymphonyElixir.Config.Schema.Workspace{}.root)

      with :ok <- validate(attrs),
           :ok <- Configuration.validate_profile(attrs) do
        LaneStore.mutate(
          nil,
          fn _check ->
            case Repo.insert(Profile.changeset(%Profile{}, attrs)) do
              {:ok, profile} -> {:ok, {:batch, profile, []}}
              {:error, changeset} -> {:error, Lanes.errors_for(changeset)}
            end
          end,
          nil
        )
        |> result_errors()
        |> broadcast_result()
      end
    end
  end

  def create(_attrs), do: {:error, [%{path: "profile", message: "must be an object"}]}

  @spec update(Profile.t(), map()) :: {:ok, Profile.t()} | {:error, [Lanes.error()]}
  def update(%Profile{id: id}, attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize(attrs) do
      case Repo.get(Profile, id) do
        nil ->
          {:error, [%{path: "profile", message: "not found"}]}

        profile ->
          full_attrs = profile_attrs(profile) |> Map.merge(attrs)

          with :ok <- validate(full_attrs),
               :ok <- Configuration.validate_profile(full_attrs) do
            LaneStore.mutate(
              nil,
              fn _check ->
                case Repo.get(Profile, id) do
                  nil ->
                    {:error, [%{path: "profile", message: "not found"}]}

                  profile ->
                    case Repo.update(Profile.changeset(profile, attrs)) do
                      {:ok, updated} -> {:ok, {:batch, updated, linked_lane_ids(updated)}}
                      {:error, changeset} -> {:error, Lanes.errors_for(changeset)}
                    end
                end
              end,
              nil
            )
            |> result_errors()
            |> broadcast_result()
          end
      end
    end
  end

  def update(%Profile{}, _attrs), do: {:error, [%{path: "profile", message: "must be an object"}]}

  @spec delete(Profile.t()) :: :ok | {:error, [Lanes.error()]}
  def delete(%Profile{id: id}) do
    LaneStore.mutate(
      nil,
      fn _check ->
        case Repo.get(Profile, id) do
          nil ->
            {:ok, {:batch, :ok, []}}

          profile ->
            if linked_lane_ids(profile) == [] do
              case Repo.delete(profile) do
                {:ok, _} -> {:ok, {:batch, :ok, []}}
                {:error, changeset} -> {:error, Lanes.errors_for(changeset)}
              end
            else
              {:error, [%{path: "lanes", message: "profile is still referenced by lanes"}]}
            end
        end
      end,
      nil
    )
    |> case do
      {:ok, :ok} ->
        ObservabilityPubSub.broadcast_profiles()
        :ok

      {:error, errors} when is_list(errors) ->
        {:error, errors}

      {:error, reason} ->
        {:error, Lanes.errors_for(reason)}
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
