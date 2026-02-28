defmodule OrcaHub.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :directory, :string

    has_many :issues, OrcaHub.Issues.Issue

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :directory])
    |> validate_required([:name, :directory])
  end
end
