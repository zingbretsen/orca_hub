defmodule OrcaHub.EmailInboxes.EmailInbox do
  @moduledoc """
  Schema for an IMAP mailbox polled for inbound email triggers.

  The mailbox password is accepted as the virtual `:password` field and
  stored only as AES-256-GCM ciphertext in `:password_encrypted` (via
  `OrcaHub.Secrets.encrypt/1`) — plaintext never reaches the database.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "email_inboxes" do
    field :name, :string
    field :host, :string
    field :port, :integer, default: 993
    field :tls, :boolean, default: true
    field :username, :string
    field :password_encrypted, :binary
    # Write-only: cast into :password_encrypted, never persisted or read back.
    field :password, :string, virtual: true, redact: true
    field :folder, :string, default: "INBOX"
    field :enabled, :boolean, default: true
    # Optional authserv-id pin — see OrcaHub.EmailInbox.Security.
    field :trusted_authserv_id, :string
    field :last_uid, :integer, default: 0
    field :uid_validity, :integer

    timestamps()
  end

  def changeset(inbox, attrs) do
    inbox
    |> cast(attrs, [
      :name,
      :host,
      :port,
      :tls,
      :username,
      :folder,
      :enabled,
      :trusted_authserv_id,
      :last_uid,
      :uid_validity
    ])
    # empty_values: [] so an explicit blank password is an error on :password
    # rather than being silently cast to nil and surfacing as a confusing
    # "password_encrypted can't be blank".
    |> cast(attrs, [:password], empty_values: [])
    |> encrypt_password()
    |> validate_required([:name, :host, :port, :username, :password_encrypted, :folder])
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_number(:last_uid, greater_than_or_equal_to: 0)
  end

  defp encrypt_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      "" ->
        add_error(changeset, :password, "can't be blank")

      plaintext ->
        changeset
        |> put_change(:password_encrypted, OrcaHub.Secrets.encrypt(plaintext))
        |> delete_change(:password)
    end
  end
end
