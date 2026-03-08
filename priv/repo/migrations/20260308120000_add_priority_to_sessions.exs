defmodule OrcaHub.Repo.Migrations.AddPriorityToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :priority, :integer, default: 0, null: false
    end
  end
end
