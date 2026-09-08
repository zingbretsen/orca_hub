defmodule OrcaHub.Repo.Migrations.CreateFiles do
  use Ecto.Migration

  # Backing tables for the cross-node file store (ORCAHUB3-72). `files` rows
  # are hub-owned metadata only — bytes live in the configured
  # OrcaHub.ObjectStore, addressed by `object_key`. `project_id` is nilify:
  # an unscoped (project-less) upload should keep existing rather than
  # cascade-delete when its project goes away. `session_id` is a plain
  # field, like Artifact.session_id — the creating session, no association,
  # so a deleted session doesn't take its files with it.
  #
  # `file_shares` is the explicit-visibility grant table: a row shares one
  # file with either a session or a project (never neither). It cascades
  # with its file (a deleted file's shares are meaningless), but does NOT
  # reference sessions/projects by FK — sharee rows are plain ids so a
  # later session/project deletion doesn't need to touch this table.
  def change do
    create table(:files, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :session_id, :binary_id

      add :name, :string, null: false
      add :content_type, :string
      add :size_bytes, :integer, null: false
      add :sha256, :string, null: false
      add :object_key, :string, null: false

      timestamps()
    end

    create index(:files, [:project_id])
    create index(:files, [:session_id])

    create table(:file_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :file_id, references(:files, type: :binary_id, on_delete: :delete_all), null: false
      add :project_id, :binary_id
      add :session_id, :binary_id
      add :shared_by_session_id, :binary_id

      timestamps()
    end

    create index(:file_shares, [:file_id])
    create index(:file_shares, [:session_id])
    create index(:file_shares, [:project_id])
  end
end
