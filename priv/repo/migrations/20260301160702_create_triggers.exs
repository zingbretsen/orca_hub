defmodule OrcaHub.Repo.Migrations.CreateTriggers do
  use Ecto.Migration

  def change do
    create table(:triggers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :prompt, :text, null: false
      add :cron_expression, :string, null: false
      add :reuse_session, :boolean, default: false, null: false
      add :archive_on_complete, :boolean, default: false, null: false
      add :enabled, :boolean, default: true, null: false
      add :last_session_id, :binary_id
      add :last_fired_at, :utc_datetime

      timestamps()
    end

    create index(:triggers, [:project_id])

    alter table(:sessions) do
      add :triggered, :boolean, default: false, null: false
    end
  end
end
