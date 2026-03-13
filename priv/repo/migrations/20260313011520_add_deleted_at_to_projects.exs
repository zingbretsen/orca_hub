defmodule OrcaHub.Repo.Migrations.AddDeletedAtToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :deleted_at, :utc_datetime
    end
  end
end
