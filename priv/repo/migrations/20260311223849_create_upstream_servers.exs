defmodule OrcaHub.Repo.Migrations.CreateUpstreamServers do
  use Ecto.Migration

  def change do
    create table(:upstream_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :url, :string, null: false
      add :headers, :map, default: %{}
      add :enabled, :boolean, default: true
      add :prefix, :string

      timestamps()
    end

    create unique_index(:upstream_servers, [:url])
  end
end
