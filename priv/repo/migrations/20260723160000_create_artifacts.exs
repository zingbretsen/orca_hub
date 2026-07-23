defmodule OrcaHub.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  # Backing table for the Artifacts feature (agent-generated rich HTML/SVG/
  # markdown, rendered client-side in a sandboxed iframe — see
  # OrcaHub.Artifacts and OrcaHub.MCP.Tools.Artifacts). `data` is unused in
  # phase 1; reserved for a phase-2 live-data channel.
  def change do
    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :session_id, :binary_id
      add :name, :string, null: false
      add :kind, :string, null: false, default: "html"
      add :content, :text
      add :data, :map, null: false, default: %{}
      add :version, :integer, null: false, default: 1

      timestamps()
    end

    create unique_index(:artifacts, [:project_id, :name])
    create index(:artifacts, [:session_id])
  end
end
