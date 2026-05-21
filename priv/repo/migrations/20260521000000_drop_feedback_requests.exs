defmodule OrcaHub.Repo.Migrations.DropFeedbackRequests do
  use Ecto.Migration

  def up do
    drop table(:feedback_requests)
  end

  def down do
    create table(:feedback_requests) do
      add :question, :text, null: false
      add :response, :text
      add :status, :string, null: false, default: "pending"
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :mcp_session_id, :string

      timestamps()
    end

    create index(:feedback_requests, [:status])
    create index(:feedback_requests, [:session_id])
  end
end
