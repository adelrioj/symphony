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

defmodule SymphonyElixir.Repo.Migrations.CreateHostLossAlarms do
  @moduledoc false
  use Ecto.Migration

  @spec change() :: term()
  def change do
    # Contradictions to an irreversible finalization. Deliberately not tied to a run and never
    # pruned: run retention owns run_events, and nothing owns this.
    create table(:host_loss_alarms) do
      add(:kind, :string, null: false)
      add(:dedup_key, :string, null: false)
      add(:declaration, :string, null: false)
      add(:node_uid, :string)
      add(:machine_id, :string)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:detail, :text, null: false, default: "{}")
    end

    create(unique_index(:host_loss_alarms, [:dedup_key]))
  end
end

defmodule SymphonyElixir.Repo.Migrations.AddExecutionProfiles do
  @moduledoc false
  use Ecto.Migration

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixir.Workflow

  @disable_ddl_transaction true

  @spec up() :: :ok
  def up do
    create table(:execution_profiles) do
      add(:name, :string, null: false)
      add(:description, :text)
      add(:workspace_base, :string)
      add(:worker, :map, null: false, default: "{}")
      add(:repair_error, :text)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:execution_profiles, [:name]))
    execute("ALTER TABLE lanes ADD COLUMN execution_profile_id INTEGER REFERENCES execution_profiles(id)")
    execute("ALTER TABLE lanes ADD COLUMN workspace_subdir TEXT NOT NULL DEFAULT '.'")
    flush()

    backfill_profiles()

    # SQLite cannot express a NOT NULL column while adding it to populated tables.
    # The trigger keeps the required relationship enforced for direct SQL writers too.
    execute("""
    CREATE TRIGGER lanes_execution_profile_required_insert
    BEFORE INSERT ON lanes
    FOR EACH ROW WHEN NEW.execution_profile_id IS NULL
    BEGIN SELECT RAISE(ABORT, 'lanes.execution_profile_id is required'); END
    """)

    execute("""
    CREATE TRIGGER lanes_execution_profile_required_update
    BEFORE UPDATE OF execution_profile_id ON lanes
    FOR EACH ROW WHEN NEW.execution_profile_id IS NULL
    BEGIN SELECT RAISE(ABORT, 'lanes.execution_profile_id is required'); END
    """)

    execute("""
    CREATE TRIGGER lanes_execution_profile_exists_insert
    BEFORE INSERT ON lanes
    FOR EACH ROW WHEN NOT EXISTS (SELECT 1 FROM execution_profiles WHERE id = NEW.execution_profile_id)
    BEGIN SELECT RAISE(ABORT, 'lanes.execution_profile_id does not reference a profile'); END
    """)

    execute("""
    CREATE TRIGGER lanes_execution_profile_exists_update
    BEFORE UPDATE OF execution_profile_id ON lanes
    FOR EACH ROW WHEN NOT EXISTS (SELECT 1 FROM execution_profiles WHERE id = NEW.execution_profile_id)
    BEGIN SELECT RAISE(ABORT, 'lanes.execution_profile_id does not reference a profile'); END
    """)

    execute("""
    CREATE TRIGGER execution_profiles_referenced_delete
    BEFORE DELETE ON execution_profiles
    FOR EACH ROW WHEN EXISTS (SELECT 1 FROM lanes WHERE execution_profile_id = OLD.id)
    BEGIN SELECT RAISE(ABORT, 'execution profile is still referenced'); END
    """)

    execute("PRAGMA foreign_key_check")
    :ok
  end

  @spec down() :: :ok
  def down, do: :ok

  defp backfill_profiles do
    %{rows: rows} =
      repo().query!("""
        SELECT l.id, l.slug, v.front_matter, v.prompt
        FROM lanes AS l
        LEFT JOIN lane_versions AS v ON v.id = l.current_version_id
        ORDER BY l.id
      """)

    Enum.each(rows, fn [lane_id, slug, front_matter, prompt] ->
      {profile, repair_error} = legacy_profile(front_matter, prompt)
      name = legacy_name(slug, lane_id)
      profile_id = insert_profile(name, profile, repair_error)
      repo().query!("UPDATE lanes SET execution_profile_id = ?, workspace_subdir = '.' WHERE id = ?", [profile_id, lane_id])
    end)
  end

  defp legacy_profile(front_matter, prompt) when is_binary(front_matter) and is_binary(prompt) do
    with {:ok, workflow} <- Workflow.parse_parts(front_matter, prompt),
         {profile, lane_config} <- Configuration.split(workflow.config),
         profile <- Map.put_new(profile, "workspace_base", %Schema.Workspace{}.root),
         {:ok, _} <- Configuration.resolve(profile, lane_config, ".", prompt) do
      {profile, nil}
    else
      {:error, reason} -> legacy_repair_profile(front_matter, prompt, reason)
      reason -> {%{}, "legacy configuration requires repair: #{inspect(reason)}"}
    end
  end

  defp legacy_profile(_front_matter, _prompt),
    do: {%{}, "legacy lane has no valid current version"}

  defp legacy_repair_profile(front_matter, prompt, reason) do
    case Workflow.parse_parts(front_matter, prompt) do
      {:ok, workflow} ->
        {profile, _lane_config} = Configuration.split(workflow.config)
        {Map.put_new(profile, "workspace_base", %Schema.Workspace{}.root), "legacy configuration requires repair: #{inspect(reason)}"}

      {:error, _} ->
        {%{}, "legacy configuration requires repair: #{inspect(reason)}"}
    end
  end

  defp insert_profile(name, profile, repair_error) do
    workspace_base = Map.get(profile, "workspace_base")
    worker = Map.get(profile, "worker", %{})

    %{rows: [[id]]} =
      repo().query!(
        "INSERT INTO execution_profiles (name, workspace_base, worker, repair_error, inserted_at, updated_at) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) RETURNING id",
        [name, workspace_base, Jason.encode!(worker), repair_error]
      )

    id
  end

  defp legacy_name(slug, lane_id) do
    slug = if is_binary(slug) and String.trim(slug) != "", do: slug, else: "lane-#{lane_id}"
    "Legacy #{slug}"
  end
end
