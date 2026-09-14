defmodule OrcaHub.Repo.Migrations.AddKindToSessions do
  use Ecto.Migration

  # `kind`: session designation — "session" (default, the ordinary case) or
  # "memory_extraction" (a background child spawned by
  # OrcaHub.MemoryExtraction). Distinct from `triggered` (cron/webhook/email
  # origin) — this is about what the session's ROLE is, not how it started.
  # Backfills existing rows whose title/parent_session_id/orchestrator shape
  # already matches OrcaHub.MemoryExtraction.spawn_child/1's pattern, since
  # those rows predate this column.
  def change do
    alter table(:sessions) do
      add :kind, :string, null: false, default: "session"
    end

    execute(
      """
      UPDATE sessions
      SET kind = 'memory_extraction'
      WHERE title LIKE 'Memory extraction: %'
        AND parent_session_id IS NOT NULL
        AND orchestrator = false
      """,
      ""
    )

    create index(:sessions, [:kind])
  end
end
