defmodule OrcaHub.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :directory, :string
    field :deleted_at, :utc_datetime

    has_many :issues, OrcaHub.Issues.Issue
    has_many :sessions, OrcaHub.Sessions.Session

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :directory, :deleted_at])
    |> validate_required([:name, :directory])
  end
end
