defmodule OrcaHub.Repo.Migrations.CreateNodes do
  use Ecto.Migration

  # Tracks every Erlang node that has ever connected to the cluster (or been
  # referenced by a session/project's node field), for the /nodes UI. Rows
  # are created by `OrcaHub.ClusterNodeTracker` (hub-only). Hub-only table;
  # agents read via HubRPC.
  def change do
    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :display_name, :string
      add :first_connected_at, :utc_datetime
      add :last_connected_at, :utc_datetime

      timestamps()
    end

    create unique_index(:nodes, [:name])
  end
end
