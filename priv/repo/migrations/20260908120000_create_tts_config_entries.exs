defmodule OrcaHub.Repo.Migrations.CreateTtsConfigEntries do
  use Ecto.Migration

  # Deliberately NOT seeded. An empty table must mean "fall back to the
  # TTS_* env vars", not "no provider and no models are available" — a fresh
  # DB after this migration has to behave exactly like the pre-migration
  # build. See OrcaHub.TTSConfig for the per-field resolution rules.
  def change do
    create table(:tts_config_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :name, :string, null: false
      add :spec, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    # Same composite uniqueness as pi_config_entries: a model named "active"
    # and the provider row named "active" are unrelated entries.
    create unique_index(:tts_config_entries, [:kind, :name])
  end
end
