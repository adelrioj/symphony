defmodule SymphonyElixir.LaneInstructionMigrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.{CLI, Lanes, Repo, Workflow}
  alias SymphonyElixir.Lanes.{Lane, LaneVersion}

  @bonbons "bonbons-delivery"
  @chorus "chorus-delivery"
  @image_prefix "/opt/symphony/procedures/v1/"
  @common "Reviewed Common: call mcp__symphony__read_procedure for the selected section.\n"
  @worker_digest "sha256:" <> String.duplicate("a", 64)

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous_root = Application.fetch_env(:symphony_elixir, :data_root)
    previous_lock = System.get_env("SYMPHONY_CONTROLLER_LOCK_REQUIRED")
    System.delete_env("SYMPHONY_CONTROLLER_LOCK_REQUIRED")

    on_exit(fn ->
      case previous_root do
        {:ok, value} -> Application.put_env(:symphony_elixir, :data_root, value)
        :error -> Application.delete_env(:symphony_elixir, :data_root)
      end

      if previous_lock,
        do: System.put_env("SYMPHONY_CONTROLLER_LOCK_REQUIRED", previous_lock),
        else: System.delete_env("SYMPHONY_CONTROLLER_LOCK_REQUIRED")
    end)

    pid = start_supervised!({Repo, name: nil, database: Path.join(root, "symphony.sqlite3")})
    Repo.put_dynamic_repo(pid)
    :ok = Repo.migrate()

    Repo.query!(
      "INSERT INTO execution_profiles (id, name, workspace_base, worker, inserted_at, updated_at) " <>
        "VALUES (1, 'Migration fixture', ?, '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      [root]
    )

    bonbons = insert_lane(@bonbons, enabled: true)
    chorus = insert_lane(@chorus, deleted_at: ~U[2026-11-01 12:00:00Z])
    unrelated = insert_lane("unrelated")
    bonbons_inline = insert_legacy_version(bonbons, "Inline Bonbons procedure and report text.\n")
    bonbons_image = insert_legacy_version(bonbons, "Use Read on one image file below `#{@image_prefix}#{@bonbons}/`.\n")
    chorus_image = insert_legacy_version(chorus, "Read from `#{@image_prefix}#{@chorus}/`.\n")
    chorus_inline = insert_legacy_version(chorus, "Inline Chorus procedure text.\n")
    other = insert_legacy_version(unrelated, "Unrelated legacy prompt.\n")

    bundled =
      Repo.insert!(%LaneVersion{
        lane_id: bonbons.id,
        front_matter: bonbons_inline.front_matter,
        prompt: "Already versioned Common",
        procedures: procedures(@bonbons)
      })

    Repo.update_all(from(lane in Lane, where: lane.id == ^bonbons.id), set: [current_version_id: bonbons_image.id])
    Repo.update_all(from(lane in Lane, where: lane.id == ^chorus.id), set: [current_version_id: chorus_inline.id])
    Repo.update_all(from(lane in Lane, where: lane.id == ^unrelated.id), set: [current_version_id: other.id])

    entries = [
      entry(@bonbons, bonbons_inline, "reviewed-inline"),
      entry(@bonbons, bonbons_image, "image"),
      entry(@chorus, chorus_image, "image"),
      entry(@chorus, chorus_inline, "reviewed-inline")
    ]

    {:ok, lanes: [bonbons.id, chorus.id], entries: entries, bundled: bundled, other: other}
  end

  test "migrates current and historical versions of both lanes, including deleted lanes", context do
    %{entries: entries, bundled: bundled, other: other, lanes: lane_ids} = context
    before = database_state()
    routes = Enum.map(lane_ids, &lane_route/1)

    assert {:ok, "migrated lane instruction versions: 4\n"} = invoke(context, entries)

    after_migration = database_state()
    assert after_migration.lanes == before.lanes
    assert Enum.map(lane_ids, &lane_route/1) == routes

    Enum.each(entries, fn entry ->
      id = entry["version_id"]
      original = Enum.find(before.versions, &(&1.id == id))
      migrated = Repo.get!(LaneVersion, id)
      assert migrated == %{original | prompt: entry["prompt"], procedures: entry["procedures"]}
    end)

    assert Repo.get!(LaneVersion, bundled.id) == bundled
    assert Repo.get!(LaneVersion, other.id) == other
    assert {:ok, "migrated lane instruction versions: 0\n"} = invoke(context, [])
    assert database_state() == after_migration
  end

  test "validates every manifest entry and exact legacy coverage before issuing an update", context do
    %{entries: [bonbons_inline, bonbons_image, chorus_image, chorus_inline] = entries, bundled: bundled, other: other} =
      context

    Repo.query!("""
    CREATE TRIGGER reject_instruction_writes BEFORE UPDATE OF prompt, procedures ON lane_versions
    BEGIN SELECT RAISE(ABORT, 'must validate before issuing any update'); END
    """)

    before = database_state()
    prefix = [bonbons_inline, bonbons_image, chorus_image]
    with_chorus = fn entry -> prefix ++ [entry] end
    with_image = fn entry -> [bonbons_inline, entry, chorus_image, chorus_inline] end
    missing_report = Map.update!(bonbons_inline, "procedures", &Map.delete(&1, "error-reporting"))

    cases = [
      {:missing_versions, prefix},
      {:duplicate_version, entries ++ [bonbons_inline]},
      {:unexpected_version, entries ++ [entry(@bonbons, bundled, "reviewed-inline")]},
      {:unexpected_version, entries ++ [Map.put(chorus_inline, "version_id", 99_999)]},
      {:invalid_version, entries ++ [entry("unrelated", other, "reviewed-inline")]},
      {:source_prompt_mismatch,
       with_chorus.(Map.put(chorus_inline, "source_prompt_sha256", String.duplicate("a", 64)))},
      {:source_kind_mismatch, with_chorus.(Map.put(chorus_inline, "source", bonbons_image["source"]))},
      {:source_kind_mismatch, with_image.(Map.put(bonbons_image, "source", chorus_inline["source"]))},
      {:invalid_source, with_chorus.(put_in(chorus_inline, ["source", "reference"], " \n"))},
      {:invalid_source, with_image.(put_in(bonbons_image, ["source", "worker_digest"], "sha256:bad"))},
      {:invalid_procedures, with_chorus.(put_in(chorus_inline, ["procedures", "error-reporting"], "Extra section"))},
      {:invalid_procedures, [missing_report, bonbons_image, chorus_image, chorus_inline]},
      {:invalid_procedures, with_chorus.(put_in(chorus_inline, ["procedures", "qa"], " \n"))},
      {:invalid_procedures,
       with_chorus.(put_in(chorus_inline, ["procedures", "bug"], "Read /opt/symphony/procedures/v1/old.md"))},
      {:invalid_procedures, with_chorus.(put_in(chorus_inline, ["procedures", "qa"], "Review {{ issue.identifier }}"))},
      {:invalid_prompt, with_chorus.(Map.update!(chorus_inline, "prompt", &(&1 <> "{% if issue.state %}")))},
      {:invalid_prompt, with_chorus.(Map.put(chorus_inline, "prompt", "No replacement loader"))}
    ]

    for {reason, manifest_entries} <- cases do
      expected_error = "lane instruction migration failed: #{reason}"
      assert {{:error, ^expected_error}, ""} = invoke(context, manifest_entries)
      assert database_state() == before
    end
  end

  test "rejects duplicate JSON keys without reporting manifest values", context do
    encoded = Jason.encode!(%{"versions" => context.entries})
    duplicate = String.replace(encoded, ~s("qa":"QA text"), ~s("qa":"private duplicate","qa":"QA text"), global: false)
    before = database_state()

    assert {{:error, "lane instruction migration failed: duplicate_manifest_key"}, ""} = invoke_json(context, duplicate)
    assert database_state() == before
  end

  test "rejects an incompatible historical override before updating any bundle", context do
    [_, historical | _] = context.entries
    version = Repo.get!(LaneVersion, historical["version_id"])
    agent = %{"backend" => "claude", "backend_by_state" => %{"In Review" => "omp"}}
    config = %{"tracker" => %{"kind" => "memory"}, "agent" => agent}
    Repo.update!(Ecto.Changeset.change(version, front_matter: Workflow.encode_config(config)))

    before = database_state()

    assert {{:error, "lane instruction migration failed: incompatible_agent_backend"}, ""} =
             invoke(context, context.entries)

    assert database_state() == before
  end

  test "rolls back the entire migration if a version update fails", context do
    [first, second | _] = context.entries

    Repo.query!("""
    CREATE TRIGGER reject_one_instruction_write BEFORE UPDATE ON lane_versions
    WHEN NEW.id = #{second["version_id"]}
    BEGIN SELECT RAISE(ABORT, 'private database message'); END
    """)

    before = database_state()
    assert {{:error, "lane instruction migration failed: database_error"}, ""} = invoke(context, context.entries)
    assert database_state() == before
    assert Repo.get!(LaneVersion, first["version_id"]).procedures == %{}
  end

  test "rejects partial input before upgrading a pre-procedures database", context do
    Repo.delete!(context.bundled)
    Repo.query!("ALTER TABLE lane_versions DROP COLUMN procedures")
    Repo.query!("DELETE FROM schema_migrations WHERE version = ?", [20_261_119_000_001])

    prompts = "SELECT id, prompt FROM lane_versions ORDER BY id"
    before = Repo.query!(prompts).rows
    partial = Enum.drop(context.entries, -1)

    assert {{:error, "lane instruction migration failed: missing_versions"}, ""} = invoke(context, partial)
    assert %{num_rows: 0} = Repo.query!("SELECT 1 FROM pragma_table_info('lane_versions') WHERE name = 'procedures'")
    assert Repo.query!(prompts).rows == before

    assert {:ok, "migrated lane instruction versions: 4\n"} = invoke(context, context.entries)
    assert {:ok, "migrated lane instruction versions: 0\n"} = invoke(context, [])
  end

  test "requires an explicit data root and respects the managed offline fence", %{tmp_dir: root} do
    args = ["lanes", "migrate-instructions", Path.join(root, "manifest.json")]
    guarded = deps(fn -> flunk("database startup reached before argument or lock validation") end)
    assert {:error, usage} = CLI.evaluate(args, guarded)
    assert usage =~ "symphony lanes migrate-instructions <manifest.json> --data-root <dir>"

    System.put_env("SYMPHONY_CONTROLLER_LOCK_REQUIRED", "1")
    assert {:error, "maintenance_required"} = CLI.evaluate(args ++ ["--data-root", root], guarded)
  end

  defp insert_lane(slug, attrs \\ []) do
    Repo.insert!(struct!(Lane, [slug: slug, name: slug, execution_profile_id: 1, workspace_subdir: slug] ++ attrs))
  end

  defp insert_legacy_version(lane, prompt) do
    [[id]] =
      Repo.query!(
        "INSERT INTO lane_versions (lane_id, front_matter, prompt, note, inserted_at) " <>
          "VALUES (?, ?, ?, 'history note', CURRENT_TIMESTAMP) RETURNING id",
        [lane.id, "tracker:\n  kind: memory\nagent:\n  backend: claude\n", prompt]
      ).rows

    Repo.get!(LaneVersion, id)
  end

  defp procedures(slug) do
    common = %{"qa" => "QA text", "bug" => "Bug text", "deliver" => "Deliver text"}
    if slug == @bonbons, do: Map.put(common, "error-reporting", "Error Reporting text"), else: common
  end

  defp entry(lane, version, source_kind) do
    source =
      case source_kind do
        "image" -> %{"kind" => "image", "worker_digest" => @worker_digest}
        "reviewed-inline" -> %{"kind" => "reviewed-inline", "reference" => "internal-review-123"}
      end

    %{
      "lane" => lane,
      "version_id" => version.id,
      "source_prompt_sha256" => :crypto.hash(:sha256, version.prompt) |> Base.encode16(case: :lower),
      "source" => source,
      "prompt" => @common,
      "procedures" => procedures(lane)
    }
  end

  defp lane_route(id) do
    lane = Repo.get!(Lane, id)
    assert {:ok, %{settings: settings, workflow: workflow}} = Lanes.resolve_lane(lane, nil, :structure)
    {settings.tracker.kind, settings.workspace.root, workflow.config}
  end

  defp database_state do
    %{
      lanes: Repo.all(from(lane in Lane, order_by: lane.id)),
      versions: Repo.all(from(version in LaneVersion, order_by: version.id))
    }
  end

  defp invoke(context, entries), do: invoke_json(context, Jason.encode!(%{"versions" => entries}))

  defp invoke_json(%{tmp_dir: root}, json) do
    path = Path.join(root, "manifest.json")
    File.write!(path, json)

    with_io(fn -> CLI.evaluate(["lanes", "migrate-instructions", path, "--data-root", root], deps()) end)
  end

  defp deps(start_repo \\ fn -> :ok end) do
    %{
      ensure_all_started: fn -> flunk("offline migration must not start the controller") end,
      start_repo: start_repo,
      import_lane: fn _, _ -> flunk("offline migration must not create a new version") end,
      export_lane: fn _ -> flunk("offline migration must not export a version") end,
      operator_token: fn -> flunk("offline migration must not access the operator token") end,
      write_output: &IO.write/1
    }
  end
end
