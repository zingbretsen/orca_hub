defmodule OrcaHub.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :body, :text
      add :enabled, :boolean, null: false, default: true
      add :backends, {:array, :string}, null: false, default: ["claude", "codex", "pi"]

      timestamps()
    end

    create unique_index(:skills, [:name])
  end
end
