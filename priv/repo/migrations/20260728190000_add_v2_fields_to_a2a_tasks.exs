defmodule OrcaHub.Repo.Migrations.AddV2FieldsToA2ATasks do
  use Ecto.Migration

  # A2A v2 (docs/a2a.md): client-defined tools + schema-validated structured
  # results, layered on top of the v1 task model. `client_tools`/
  # `result_schema`/`max_validation_attempts` are declared once at session
  # creation and inherited by every task in the conversation (copy-forward at
  # continuation-task creation — see OrcaHub.A2ATasks.create_task/1);
  # `validation_attempts`/`pending_tool_call`/`result` are per-task, mirroring
  # api_runs' identical columns (see AddClientToolsToApiRuns and the original
  # api_runs migration).
  def change do
    alter table(:a2a_tasks) do
      add :client_tools, {:array, :map}
      add :result_schema, :map
      add :max_validation_attempts, :integer, null: false, default: 3
      add :validation_attempts, :integer, null: false, default: 0
      add :pending_tool_call, :map
      add :result, :map
    end
  end
end
