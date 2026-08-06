defmodule OrcaHub.Repo.Migrations.AddIssueFieldsAndBackfill do
  @moduledoc """
  Adds the new `issues` columns from issues_spec.md §3.1/§3.2/§12 (`kind`,
  `plan`, `resolution`, `premise`, `commits`, `attempts`,
  `created_by_session_id`, `closed_by_session_id`, `closed_at`,
  `superseded_by_issue_id`, `key_number`), plus two idempotent backfills:

  1. Existing `[agent-fr] `-titled rows get `kind = 'feature_request'` and
     the prefix stripped from `title`. Strips ALL leading repetitions of
     the prefix (`(\\[agent-fr\\] )+`), not just one — two live prod rows
     (`54319e58...`, `9c67507c...`) carry a doubled `"[agent-fr] [agent-fr] "`
     prefix (an upstream filing bug, not touched here), and the spec's
     literal single-pass `regexp_replace` would leave one layer behind.
     Idempotent: the `WHERE title LIKE '[agent-fr] %'` guard means a
     second run matches nothing, since the first run already stripped it.

  2. `key_number` is backfilled per project (`ROW_NUMBER() OVER (PARTITION
     BY project_id ORDER BY inserted_at, id)`), then each project's
     `issue_counter` is synced to at least that max — guarded with
     `WHERE key_number IS NULL` (so a re-run never renumbers already-keyed
     issues) and `GREATEST(current, computed)` on the counter sync (so a
     re-run can never LOWER a counter that's already moved past the
     backfilled max because live `create_issue` calls happened in
     between) — both are deliberately more defensive than the spec's
     literal SQL, which assumes a single, uninterrupted run.

  Pre-migration check confirmed (2026-08-06, prod): 0 issues with
  `project_id IS NULL` — the "orphan issue can't get a key_number" edge
  case flagged in §12 does not apply to current data. The migration
  still leaves any such row's `key_number` NULL rather than erroring, in
  case one exists by the time this actually runs.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :kind, :string, null: false, default: "task"
      add :plan, :text
      add :resolution, :text
      add :premise, :text
      add :commits, {:array, :map}, null: false, default: []
      add :attempts, {:array, :map}, null: false, default: []
      add :created_by_session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :closed_by_session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :closed_at, :utc_datetime
      add :superseded_by_issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
      add :key_number, :integer
    end

    flush()

    execute """
            UPDATE issues
            SET kind = 'feature_request',
                title = regexp_replace(title, '^(\\[agent-fr\\] )+', '')
            WHERE title LIKE '[agent-fr] %'
            """,
            ""

    execute """
            UPDATE issues i
            SET key_number = sub.rn
            FROM (
              SELECT id, ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY inserted_at, id) AS rn
              FROM issues
              WHERE project_id IS NOT NULL AND key_number IS NULL
            ) sub
            WHERE i.id = sub.id
            """,
            ""

    execute """
            UPDATE projects p
            SET issue_counter = GREATEST(
              p.issue_counter,
              COALESCE((SELECT MAX(key_number) FROM issues i WHERE i.project_id = p.id), 0)
            )
            """,
            ""

    create unique_index(:issues, [:project_id, :key_number])
  end

  def down do
    drop_if_exists unique_index(:issues, [:project_id, :key_number])

    alter table(:issues) do
      remove :kind
      remove :plan
      remove :resolution
      remove :premise
      remove :commits
      remove :attempts
      remove :created_by_session_id
      remove :closed_by_session_id
      remove :closed_at
      remove :superseded_by_issue_id
      remove :key_number
    end
  end
end
