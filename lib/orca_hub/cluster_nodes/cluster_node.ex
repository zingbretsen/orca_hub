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

    timestamps()
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name, :display_name, :first_connected_at, :last_connected_at, :isolated])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
