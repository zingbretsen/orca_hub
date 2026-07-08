defmodule OrcaHub.Repo.Migrations.CreateApiRuns do
  use Ecto.Migration

  # Backing table for the Agent Runs API (docs/api.md): POST /api/v1/runs
  # creates a row here alongside its session, GET /api/v1/runs/:id drives it
  # through running -> completed/failed/timed_out purely on poll (no
  # background monitor process — see OrcaHub.ApiRuns / ApiRunController).
  def change do
    create table(:api_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false, default: "running"
      add :result, :map
      add :result_text, :text
      add :error, :text
      add :result_schema, :map
      add :timeout_seconds, :integer, null: false, default: 3600
      add :validation_attempts, :integer, null: false, default: 0
      add :max_validation_attempts, :integer, null: false, default: 3

      timestamps()
    end

    create index(:api_runs, [:session_id])
  end
end
