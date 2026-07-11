defmodule OrcaHub.Repo.Migrations.AddErrorDetailToSessions do
  use Ecto.Migration

  # Concise capture of the CLI's launch/exit failure (last stderr/output lines,
  # or a turn-level error message), surfaced on `search_sessions` and the UI so
  # an orchestrator doesn't have to infer the cause from a short session
  # lifetime alone. Cleared whenever a later run succeeds.
  def change do
    alter table(:sessions) do
      add :error_detail, :text
    end
  end
end
