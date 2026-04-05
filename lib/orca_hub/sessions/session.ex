defmodule OrcaHub.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @foreign_key_type :binary_id

  schema "sessions" do
    field :directory, :string
    field :claude_session_id, :string
    field :title, :string
    field :status, :string, default: "ready"
    field :model, :string
    field :archived_at, :utc_datetime
    field :triggered, :boolean, default: false
    field :priority, :integer, default: 0
    field :runner_node, :string
    field :orchestrator, :boolean, default: false

    has_many :messages, OrcaHub.Sessions.Message
    belongs_to :issue, OrcaHub.Issues.Issue
    belongs_to :project, OrcaHub.Projects.Project

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:directory, :claude_session_id, :title, :status, :model, :issue_id, :project_id, :archived_at, :triggered, :priority, :runner_node, :orchestrator])
    |> validate_required([:directory])
    |> validate_inclusion(:status, ~w(ready idle running waiting error compacting))
  end
end
