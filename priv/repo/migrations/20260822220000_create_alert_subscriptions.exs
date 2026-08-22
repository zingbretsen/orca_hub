defmodule OrcaHub.Repo.Migrations.CreateAlertSubscriptions do
  use Ecto.Migration

  def change do
    create table(:alert_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :orchestrator_session_id, :binary_id, null: false
      add :watch_children, :boolean, null: false, default: true
      add :session_ids, {:array, :binary_id}, null: false, default: []
      add :conditions, :map, null: false, default: %{}
      add :cooldown_seconds, :integer, null: false, default: 900
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :naive_datetime_usec, null: false)
    end

    create unique_index(:alert_subscriptions, [:orchestrator_session_id])
  end
end
