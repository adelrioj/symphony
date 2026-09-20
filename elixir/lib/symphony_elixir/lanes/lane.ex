defmodule SymphonyElixir.Lanes.Lane do
  @moduledoc "A lane: one tracker scope, workspace root, prompt, and agent config, run by its own Orchestrator."

  use Ecto.Schema
  import Ecto.Changeset

  @slug_format ~r/^[a-z][a-z0-9-]{1,40}$/
  @executors ["local"]

  @type t :: %__MODULE__{}

  schema "lanes" do
    field(:slug, :string)
    field(:name, :string)
    field(:enabled, :boolean, default: false)
    field(:executor, :string, default: "local")
    field(:execution_profile_id, :integer)
    field(:workspace_subdir, :string, default: ".")
    field(:current_version_id, :integer)
    field(:deleted_at, :utc_datetime)
    belongs_to(:execution_profile, SymphonyElixir.ExecutionProfiles.Profile, define_field: false)
    has_many(:versions, SymphonyElixir.Lanes.LaneVersion)
    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(lane, attrs) do
    lane
    |> cast(attrs, [:slug, :name, :enabled, :executor, :execution_profile_id, :workspace_subdir])
    |> validate_required([:slug, :name, :enabled, :execution_profile_id, :workspace_subdir])
    |> validate_format(:slug, @slug_format, message: "must match ^[a-z][a-z0-9-]{1,40}$")
    |> validate_exclusion(:slug, ["new"])
    |> validate_inclusion(:executor, @executors)
    |> validate_number(:execution_profile_id, greater_than: 0)
    |> validate_length(:workspace_subdir, min: 1)
    |> unique_constraint(:slug)
  end
end
