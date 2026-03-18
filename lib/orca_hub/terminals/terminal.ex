defmodule OrcaHub.Terminals.Terminal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "terminals" do
    field :name, :string
    field :directory, :string
    field :shell, :string, default: "/bin/bash"
    field :status, :string, default: "stopped"
    field :runner_node, :string
    field :cols, :integer, default: 120
    field :rows, :integer, default: 40

    belongs_to :project, OrcaHub.Projects.Project

    timestamps()
  end

  def changeset(terminal, attrs) do
    terminal
    |> cast(attrs, [:name, :directory, :shell, :status, :runner_node, :cols, :rows, :project_id])
    |> validate_required([:name, :directory])
    |> validate_inclusion(:status, ~w(stopped running dead))
  end
end
