defmodule OrcaHub.Repo.Migrations.AddArchivedAtToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :archived_at, :utc_datetime
    end
  end
end
