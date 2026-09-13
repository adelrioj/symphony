defmodule SymphonyElixir.Lanes.LaneVersion do
  @moduledoc "Immutable snapshot of a lane's WORKFLOW.md: raw YAML front matter plus raw prompt body."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "lane_versions" do
    belongs_to(:lane, SymphonyElixir.Lanes.Lane)
    field(:front_matter, :string, default: "")
    field(:prompt, :string, default: "")
    field(:note, :string)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    cast(version, attrs, [:front_matter, :prompt, :note], empty_values: [])
  end
end
