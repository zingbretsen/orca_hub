defmodule OrcaHub.ApiTokens.ApiToken do
  @moduledoc """
  Schema for a scoped, revocable API token (see `OrcaHub.ApiTokens`).

  Only `token_hash` (a raw SHA-256 digest) is ever persisted — there is no
  column and no code path that stores or returns the plaintext secret.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @scopes ~w(runs:create runs:read runs:tool_result sessions:read tts a2a)
  @pinned_forbidden_scopes ~w(tts a2a)

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :binary
    field :token_prefix, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :session, OrcaHub.Sessions.Session

    timestamps()
  end

  def scopes, do: @scopes

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [
      :name,
      :token_hash,
      :token_prefix,
      :scopes,
      :session_id,
      :expires_at,
      :revoked_at
    ])
    |> validate_required([:name, :token_hash, :scopes])
    |> validate_scopes_nonempty()
    |> validate_scopes_known()
    |> validate_pinned_scopes()
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:session_id)
  end

  # Hand-rolled rather than validate_length/validate_subset: those only run
  # via validate_change, which Ecto skips when the cast value is identical
  # to the field's current value — and an explicit `scopes: []` is identical
  # to this schema's own `[]` default, so it would otherwise silently pass.
  defp validate_scopes_nonempty(changeset) do
    case get_field(changeset, :scopes) do
      scopes when is_list(scopes) and scopes != [] -> changeset
      _ -> add_error(changeset, :scopes, "should have at least 1 item(s)")
    end
  end

  defp validate_scopes_known(changeset) do
    scopes = get_field(changeset, :scopes) || []

    if Enum.all?(scopes, &(&1 in @scopes)) do
      changeset
    else
      add_error(changeset, :scopes, "has an invalid entry")
    end
  end

  # A session-pinned token may only ever act on that one session, so scopes
  # that don't take a session_id at all (tts, a2a) must be rejected up front
  # rather than silently granted-but-unreachable.
  defp validate_pinned_scopes(changeset) do
    session_id = get_field(changeset, :session_id)
    scopes = get_field(changeset, :scopes) || []

    if session_id && Enum.any?(scopes, &(&1 in @pinned_forbidden_scopes)) do
      add_error(
        changeset,
        :scopes,
        "a session-pinned token cannot hold the #{Enum.join(@pinned_forbidden_scopes, "/")} scope"
      )
    else
      changeset
    end
  end
end
