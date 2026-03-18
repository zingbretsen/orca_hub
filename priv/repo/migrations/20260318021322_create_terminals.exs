defmodule OrcaHub.Repo.Migrations.CreateTerminals do
  use Ecto.Migration

  def change do
    create table(:terminals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :directory, :string, null: false
      add :shell, :string, default: "/bin/bash"
      add :status, :string, default: "stopped"
      add :runner_node, :string
      add :cols, :integer, default: 120
      add :rows, :integer, default: 40
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    create index(:terminals, [:project_id])
  end
end
