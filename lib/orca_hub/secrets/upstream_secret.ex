defmodule OrcaHub.Secrets.UpstreamSecret do
  @moduledoc "Schema for an OrcaHub-managed secret, encrypted at rest."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "upstream_secrets" do
    field :key, :string
    field :value_encrypted, :binary

    timestamps()
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:key, :value_encrypted])
    |> validate_required([:key, :value_encrypted])
    |> unique_constraint(:key)
  end
end
