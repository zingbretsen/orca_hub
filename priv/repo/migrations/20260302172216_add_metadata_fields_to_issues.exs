defmodule OrcaHub.Repo.Migrations.AddMetadataFieldsToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :approaches_tried, :text
      add :notes, :text
    end
  end
end
