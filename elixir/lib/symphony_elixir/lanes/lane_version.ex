defmodule SymphonyElixir.Lanes.LaneVersion do
  @moduledoc "Immutable snapshot of lane configuration, Common prompt, and procedure sections."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "lane_versions" do
    belongs_to(:lane, SymphonyElixir.Lanes.Lane)
    field(:front_matter, :string, default: "", redact: true)
    field(:prompt, :string, default: "", redact: true)
    field(:procedures, :map, default: %{}, redact: true)
    field(:note, :string)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    cast(version, attrs, [:front_matter, :prompt, :procedures, :note], empty_values: [])
  end
end
