defmodule OrcaHub.Repo.Migrations.AddOriginalNodeToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :original_node, :string
    end

    # Backfill existing sessions: set original_node = runner_node where runner_node exists
    execute(
      "UPDATE sessions SET original_node = runner_node WHERE runner_node IS NOT NULL",
      "UPDATE sessions SET original_node = NULL"
    )
  end
end
