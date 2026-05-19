defmodule OrcaHub.Repo.Migrations.DropSettings do
  use Ecto.Migration

  def up do
    drop table(:settings)
  end

  def down do
    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text
      timestamps()
    end
  end
end
