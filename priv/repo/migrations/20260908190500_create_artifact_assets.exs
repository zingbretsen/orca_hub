defmodule OrcaHub.Repo.Migrations.CreateArtifactAssets do
  use Ecto.Migration

  # Backs ORCAHUB3-72's slice 2: lets an artifact's HTML reference a file
  # from the cross-node file store (`OrcaHub.Files`) by a relative URL,
  # e.g. <img src="assets/hero.png">, served at GET /artifacts/:id/assets/:name.
  # `name` is unique per artifact (not globally) since it's scoped by the
  # artifact id in the URL path. Both FKs cascade: an asset row is meaningless
  # once either its artifact or its underlying file is gone.
  def change do
    create table(:artifact_assets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :artifact_id, references(:artifacts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :file_id, references(:files, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false

      timestamps()
    end

    create unique_index(:artifact_assets, [:artifact_id, :name])
    create index(:artifact_assets, [:file_id])
  end
end
