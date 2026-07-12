defmodule OrcaHub.Sessions.SessionInteraction do
  @moduledoc """
  Schema for a directed cross-session interaction edge — e.g. one session
  messaging another via the `send_message_to_session` MCP tool. Distinct
  from `sessions.parent_session_id`, which only captures spawn
  relationships. `kind` future-proofs for other edge kinds later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_interactions" do
    field :kind, :string, default: "message"

    belongs_to :sender_session, OrcaHub.Sessions.Session, foreign_key: :sender_session_id
    belongs_to :recipient_session, OrcaHub.Sessions.Session, foreign_key: :recipient_session_id

    timestamps()
  end

  def changeset(interaction, attrs) do
    interaction
    # :inserted_at is castable so the backfill task can stamp an edge with
    # its original message timestamp instead of "now".
    |> cast(attrs, [:sender_session_id, :recipient_session_id, :kind, :inserted_at])
    |> validate_required([:sender_session_id, :recipient_session_id, :kind])
    # Declaring these lets a bad id (e.g. an unresolved sender prefix)
    # surface as {:error, changeset} instead of raising Ecto.ConstraintError
    # — the send_message_to_session tool records this edge best-effort and
    # must not blow up (or, in a sandboxed test transaction, poison it) on
    # a foreign-key violation.
    |> foreign_key_constraint(:sender_session_id)
    |> foreign_key_constraint(:recipient_session_id)
  end
end
