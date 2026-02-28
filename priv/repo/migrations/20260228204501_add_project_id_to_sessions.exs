defmodule OrcaHub.Repo.Migrations.AddProjectIdToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:sessions, [:project_id])

    # Backfill: match sessions to projects by directory
    execute(
      """
      UPDATE sessions SET project_id = projects.id
      FROM projects
      WHERE sessions.directory = projects.directory
        AND sessions.project_id IS NULL
      """,
      ""
    )
  end
end
