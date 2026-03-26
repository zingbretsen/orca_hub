defmodule OrcaHub.Repo.Migrations.AddUpstreamServerAssociations do
  use Ecto.Migration

  def change do
    # Add global field to upstream_servers
    alter table(:upstream_servers) do
      add :global, :boolean, default: true
    end

    # Create project_upstream_servers join table
    create table(:project_upstream_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :upstream_server_id, references(:upstream_servers, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:project_upstream_servers, [:project_id, :upstream_server_id])

    # Create session_upstream_servers join table
    create table(:session_upstream_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :upstream_server_id, references(:upstream_servers, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:session_upstream_servers, [:session_id, :upstream_server_id])
  end
end
