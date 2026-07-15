defmodule OrcaHub.Projects.Project do
  @moduledoc "Schema for a project."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :directory, :string
    field :deleted_at, :utc_datetime
    field :node, :string
    # Extension to OrcaHub.Env's strict_env/2 base allow-list, combined with
    # the owning node's own env_allowlist — see
    # OrcaHub.NodePolicy.extra_env_allowlist/1. Only relevant when the node
    # also has scrub_session_env enabled. Same entry grammar as
    # OrcaHub.ClusterNodes.ClusterNode#env_allowlist (exact name or NAME*).
    field :env_allowlist, {:array, :string}, default: []

    has_many :sessions, OrcaHub.Sessions.Session

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :directory, :deleted_at, :node, :env_allowlist])
    |> validate_required([:name, :directory])
    |> OrcaHub.ClusterNodes.ClusterNode.validate_env_allowlist()
  end
end
