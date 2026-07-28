defmodule OrcaHub.Repo.Migrations.CreateA2ATasks do
  use Ecto.Migration

  # Backing table for the inbound A2A (Agent2Agent) v0.3.0 server surface
  # (docs/a2a.md). Deliberately a separate table from api_runs — a dedicated,
  # minimal task model for the A2A wire contract (states
  # submitted/working/completed/failed/canceled) rather than the
  # runs API's schema-validation/client-tools machinery. tasks/get drives
  # this forward purely on poll (no background monitor process), mirroring
  # OrcaHub.ApiRuns / ApiRunController.
  def change do
    create table(:a2a_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false, default: "submitted"
      add :error, :text
      add :result_text, :text
      add :baseline_message_count, :integer, null: false, default: 0
      add :timeout_seconds, :integer, null: false, default: 3600

      timestamps()
    end

    create index(:a2a_tasks, [:session_id])
  end
end
