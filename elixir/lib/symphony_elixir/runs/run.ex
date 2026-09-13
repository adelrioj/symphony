defmodule SymphonyElixir.Runs.Run do
  @moduledoc "One durable agent attempt, retained independently of its lane runtime."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(running done blocked failed turns_exhausted stopped)
  @required_fields ~w(lane_id lane_version_id issue_id issue_identifier attempt_id executor status started_at)a
  @type t :: %__MODULE__{}

  schema "runs" do
    field(:lane_id, :integer)
    field(:lane_version_id, :integer)
    field(:issue_id, :string)
    field(:issue_identifier, :string)
    field(:issue_state, :string)
    field(:attempt_id, :string)
    field(:attempt, :integer)
    field(:executor, :string, default: "local")
    field(:worker_ref, :string)
    field(:status, :string, default: "running")
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
    field(:turns, :integer, default: 0)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:cached_tokens, :integer, default: 0)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :lane_id,
      :lane_version_id,
      :issue_id,
      :issue_identifier,
      :issue_state,
      :attempt_id,
      :attempt,
      :executor,
      :worker_ref,
      :status,
      :started_at,
      :finished_at,
      :turns,
      :input_tokens,
      :output_tokens,
      :cached_tokens
    ])
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:attempt_id)
    |> foreign_key_constraint(:lane_id)
    |> foreign_key_constraint(:lane_version_id)
  end
end
