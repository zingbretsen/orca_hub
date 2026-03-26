defmodule OrcaHub.UpstreamServers.ProjectUpstreamServer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "project_upstream_servers" do
    belongs_to :project, OrcaHub.Projects.Project
    belongs_to :upstream_server, OrcaHub.UpstreamServers.UpstreamServer

    timestamps()
  end

  def changeset(project_upstream_server, attrs) do
    project_upstream_server
    |> cast(attrs, [:project_id, :upstream_server_id])
    |> validate_required([:project_id, :upstream_server_id])
    |> unique_constraint([:project_id, :upstream_server_id])
  end
end
