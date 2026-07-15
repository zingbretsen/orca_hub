defmodule OrcaHub.ClusterNodes.ClusterNode do
  @moduledoc "Schema for a known cluster node (currently or previously connected)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "nodes" do
    field :name, :string
    field :display_name, :string
    field :first_connected_at, :utc_datetime
    field :last_connected_at, :utc_datetime
    field :isolated, :boolean, default: false
    # When true, sessions/terminals spawned on this node get a strict
    # allow-list environment instead of the full BEAM environment — see
    # OrcaHub.NodePolicy.scrub_session_env?/0 and OrcaHub.Env.strict_env/1.
    field :scrub_session_env, :boolean, default: false
    # Per-node defaults applied by OrcaHub.Sessions.create_session/1 when the
    # caller's attrs don't already specify that field. nil means "no default,
    # fall back to existing behavior" (see Sessions moduledoc for the
    # backend/model pairing rule).
    field :default_backend, :string
    field :default_model, :string

    timestamps()
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :name,
      :display_name,
      :first_connected_at,
      :last_connected_at,
      :isolated,
      :scrub_session_env,
      :default_backend,
      :default_model
    ])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
