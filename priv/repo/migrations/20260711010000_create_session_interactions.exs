defmodule OrcaHub.Repo.Migrations.CreateSessionInteractions do
  use Ecto.Migration

  # Structural record of cross-session messaging (the send_message_to_session
  # MCP tool) — sessions.parent_session_id only captures spawn relationships,
  # this captures "session A messaged session B" edges for the session graph
  # feature. `kind` future-proofs the table for other edge kinds beyond
  # "message" without a schema change.
  def change do
    create table(:session_interactions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sender_session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :recipient_session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false, default: "message"

      timestamps()
    end

    create index(:session_interactions, [:sender_session_id])
    create index(:session_interactions, [:recipient_session_id])
  end
end
