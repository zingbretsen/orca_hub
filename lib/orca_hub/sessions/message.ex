defmodule OrcaHub.Sessions.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :data, :map

    belongs_to :session, OrcaHub.Sessions.Session

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:session_id, :data])
    |> validate_required([:session_id, :data])
  end
end
