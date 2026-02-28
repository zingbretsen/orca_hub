defmodule OrcaHub.Issues.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "issues" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "open"

    belongs_to :project, OrcaHub.Projects.Project, type: :binary_id
    has_many :sessions, OrcaHub.Sessions.Session

    timestamps()
  end

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :description, :status, :project_id])
    |> validate_required([:title])
    |> validate_inclusion(:status, ~w(open in_progress closed))
  end
end
