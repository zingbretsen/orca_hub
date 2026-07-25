defmodule OrcaHub.Sessions.Message do
  @moduledoc "Schema for a message belonging to a session."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :data, :map

    belongs_to :session, OrcaHub.Sessions.Session

    # usec precision: see the widen_message_timestamps_to_microseconds
    # migration's moduledoc — "most recent message" queries have no
    # secondary tiebreaker beyond inserted_at.
    timestamps(type: :naive_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:session_id, :data])
    |> validate_required([:session_id, :data])
  end
end
