defmodule OrcaHub.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @foreign_key_type :binary_id

  schema "sessions" do
    field :directory, :string
    field :claude_session_id, :string
    field :title, :string
    field :status, :string, default: "idle"
    field :model, :string
    field :archived_at, :utc_datetime

    has_many :messages, OrcaHub.Sessions.Message
    belongs_to :issue, OrcaHub.Issues.Issue

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:directory, :claude_session_id, :title, :status, :model, :issue_id, :archived_at])
    |> validate_required([:directory])
    |> validate_inclusion(:status, ~w(idle running error))
  end
end
