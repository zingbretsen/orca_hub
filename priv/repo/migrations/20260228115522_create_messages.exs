defmodule OrcaHub.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :data, :map, null: false

      timestamps()
    end

    create index(:messages, [:session_id])
  end
end
