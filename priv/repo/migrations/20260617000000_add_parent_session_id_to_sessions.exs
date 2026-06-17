defmodule OrcaHub.Repo.Migrations.AddParentSessionIdToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :parent_session_id,
          references(:sessions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:sessions, [:parent_session_id])
  end
end
