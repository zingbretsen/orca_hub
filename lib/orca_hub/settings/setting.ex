defmodule OrcaHub.Settings.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}

  schema "settings" do
    field :value, :string
    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
  end
end
