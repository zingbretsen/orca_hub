defmodule OrcaHub.Repo.Migrations.CreatePiConfigEntries do
  use Ecto.Migration

  def change do
    create table(:pi_config_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :name, :string, null: false
      add :spec, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    # Names are unique PER KIND — a provider "openai" and a settings key
    # "openai" are unrelated entries.
    create unique_index(:pi_config_entries, [:kind, :name])
  end
end
