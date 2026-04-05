defmodule OrcaHub.Repo.Migrations.AddOrchestratorToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :orchestrator, :boolean, default: false, null: false
    end
  end
end
