defmodule OrcaHub.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :directory, :string, null: false
      add :claude_session_id, :string
      add :title, :string
      add :status, :string, null: false, default: "idle"
      add :model, :string

      timestamps()
    end
  end
end
