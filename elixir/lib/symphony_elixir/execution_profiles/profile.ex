defmodule SymphonyElixir.ExecutionProfiles.Profile do
  @moduledoc "A persisted execution environment shared by one or more lanes."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "execution_profiles" do
    field(:name, :string)
    field(:description, :string)
    field(:workspace_base, :string)
    field(:worker, :map, default: %{})
    field(:repair_error, :string)
    has_many(:lanes, SymphonyElixir.Lanes.Lane, foreign_key: :execution_profile_id)
    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :description, :workspace_base, :worker, :repair_error])
    |> validate_required([:name, :workspace_base])
    |> validate_change(:name, fn :name, name ->
      if String.trim(name) == "", do: [name: "must not be blank"], else: []
    end)
    |> validate_change(:workspace_base, fn :workspace_base, base ->
      if String.trim(base) == "", do: [workspace_base: "must not be blank"], else: []
    end)
    |> validate_change(:worker, fn :worker, value ->
      if is_map(value), do: [], else: [worker: "must be an object"]
    end)
    |> unique_constraint(:name)
  end
end
