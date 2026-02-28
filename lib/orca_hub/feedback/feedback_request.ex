defmodule OrcaHub.Feedback.FeedbackRequest do
  use Ecto.Schema
  import Ecto.Changeset

  schema "feedback_requests" do
    field :question, :string
    field :response, :string
    field :status, :string, default: "pending"
    field :mcp_session_id, :string

    belongs_to :session, OrcaHub.Sessions.Session, type: :binary_id

    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:question, :response, :status, :session_id, :mcp_session_id])
    |> validate_required([:question, :status])
  end
end
