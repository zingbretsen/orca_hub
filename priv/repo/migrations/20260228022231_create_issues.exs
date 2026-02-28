defmodule OrcaHub.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  def change do
    create table(:issues, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "open"

      timestamps()
    end

    alter table(:sessions) do
      add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
