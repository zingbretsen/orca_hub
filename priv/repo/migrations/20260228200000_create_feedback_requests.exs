defmodule OrcaHub.Repo.Migrations.CreateFeedbackRequests do
  use Ecto.Migration

  def change do
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
