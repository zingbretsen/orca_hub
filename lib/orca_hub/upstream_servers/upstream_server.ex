defmodule OrcaHub.UpstreamServers.UpstreamServer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "upstream_servers" do
    field :name, :string
    field :url, :string
    field :headers, :map, default: %{}
    field :enabled, :boolean, default: true
    field :prefix, :string

    timestamps()
  end

  def changeset(server, attrs) do
    server
    |> cast(attrs, [:name, :url, :headers, :enabled, :prefix])
    |> validate_required([:name, :url])
    |> validate_format(:url, ~r{^https?://}, message: "must start with http:// or https://")
    |> unique_constraint(:url)
    |> maybe_generate_prefix()
  end

  defp maybe_generate_prefix(changeset) do
    case get_field(changeset, :prefix) do
      nil ->
        case get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :prefix, name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_"))
        end

      _ ->
        changeset
    end
  end
end
