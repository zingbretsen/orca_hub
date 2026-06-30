defmodule OrcaHub.NodeCredentials.NodeCredential do
  @moduledoc "Schema for a per-node Claude Code OAuth token."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "node_credentials" do
    field :node_name, :string
    field :oauth_token, :string

    timestamps()
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:node_name, :oauth_token])
    |> validate_required([:node_name, :oauth_token])
    |> unique_constraint(:node_name)
  end
end
