defmodule OrcaHub.Repo.Migrations.AddNotifyParentToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :notify_parent, :boolean, default: true, null: false
    end
  end
end
