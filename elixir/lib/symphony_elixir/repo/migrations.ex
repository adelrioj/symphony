defmodule SymphonyElixir.Repo.Migrations.CreateLanesAndRuns do
  @moduledoc false
  use Ecto.Migration

  @spec change() :: term()
  def change do
    create table(:lanes) do
      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:enabled, :boolean, null: false, default: false)
      add(:executor, :string, null: false, default: "local", check: %{name: "lanes_executor_check", expr: "executor = 'local'"})
      # Keep this integer to avoid a circular foreign key; lane activation owns this pointer.
      add(:current_version_id, :integer)
      add(:deleted_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lanes, [:slug]))

    create table(:lane_versions) do
      add(:lane_id, references(:lanes, on_delete: :delete_all), null: false)
      add(:front_matter, :text, null: false)
      add(:prompt, :text, null: false)
      add(:note, :string)
      add(:inserted_at, :utc_datetime, null: false)
    end

    create(index(:lane_versions, [:lane_id]))

    create table(:runs) do
      add(:lane_id, references(:lanes), null: false)
      add(:lane_version_id, references(:lane_versions), null: false)
      add(:issue_id, :string, null: false)
      add(:issue_identifier, :string, null: false)
      add(:issue_state, :string)
      add(:attempt_id, :string, null: false)
      add(:attempt, :integer)
      add(:executor, :string, null: false, default: "local")
      add(:worker_ref, :string)
      add(:status, :string, null: false, default: "running")
      add(:started_at, :utc_datetime, null: false)
      add(:finished_at, :utc_datetime)
      add(:turns, :integer, null: false, default: 0)
      add(:input_tokens, :integer, null: false, default: 0)
      add(:output_tokens, :integer, null: false, default: 0)
      add(:cached_tokens, :integer, null: false, default: 0)
    end

    create(unique_index(:runs, [:attempt_id]))
    create(index(:runs, [:lane_id, :started_at]))
    create(index(:runs, [:issue_id]))

    create table(:run_events) do
      add(:run_id, references(:runs, on_delete: :delete_all), null: false)
      add(:at, :utc_datetime_usec, null: false)
      add(:kind, :string, null: false)
      add(:payload, :text, null: false, default: "{}")
    end

    create(index(:run_events, [:run_id, :id]))
  end
end
