defmodule OrcaHub.Repo.Migrations.AddProgressToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :progress_phase, :string
      add :progress_note, :string
      add :progress_updated_at, :utc_datetime
    end
  end
end
