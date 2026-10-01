defmodule OrcaHub.Repo.Migrations.AddBackendModelToTriggers do
  use Ecto.Migration

  # Per-trigger backend/model pin, stamped onto every session the trigger
  # CREATES (OrcaHub.TriggerExecutor.session_attrs/1). nil = inherit the
  # project's/node's default, exactly as before this column existed.
  def change do
    alter table(:triggers) do
      add :backend, :string
      add :model, :string
    end
  end
end
