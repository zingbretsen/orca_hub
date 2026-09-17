defmodule OrcaHub.Repo.Migrations.CreateAsrConfigEntries do
  use Ecto.Migration

  # Its own table rather than sharing tts_config_entries: the two configs
  # have nothing in common but four column names, and one table would mean
  # a delete/rename on either side silently reaching into the other.
  #
  # Deliberately NOT seeded. An empty table must mean "fall back to the
  # ASR_* env vars", not "no transcription service is configured" — a fresh
  # DB after this migration has to behave exactly like the pre-migration
  # build. See OrcaHub.ASRConfig for the per-field resolution rules.
  def change do
    create table(:asr_config_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :name, :string, null: false
      add :spec, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:asr_config_entries, [:kind, :name])
  end
end
