defmodule OrcaHub.Repo.Migrations.AddInboundEmailIngestion do
  use Ecto.Migration

  # Inbound email ingestion: IMAP-polled mailboxes (`email_inboxes`) that fire
  # `type: "email"` triggers. One migration covers all three tables it touches.
  def change do
    create table(:email_inboxes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, null: false
      add :host, :string, null: false
      add :port, :integer, null: false, default: 993
      add :tls, :boolean, null: false, default: true
      add :username, :string, null: false
      # AES-256-GCM ciphertext from OrcaHub.Secrets.encrypt/1 — the mailbox
      # password is never stored in plaintext. Same at-rest scheme as
      # upstream_secrets.value_encrypted.
      add :password_encrypted, :binary, null: false
      add :folder, :string, null: false, default: "INBOX"
      add :enabled, :boolean, null: false, default: true

      # Optional pin for the authserv-id of the Authentication-Results header
      # we're willing to trust (e.g. "mx.google.com"). Defense in depth on top
      # of "use the top-most A-R header" — see OrcaHub.EmailInbox.Security.
      add :trusted_authserv_id, :string

      # Watermark: the highest IMAP UID already EXAMINED (accepted or
      # rejected). Only meaningful together with uid_validity — IMAP UIDs are
      # unique per UIDVALIDITY generation, so a server-side renumbering makes
      # a stored last_uid meaningless and the poller re-baselines instead.
      add :last_uid, :integer, null: false, default: 0
      add :uid_validity, :integer

      timestamps()
    end

    create index(:email_inboxes, [:enabled])

    alter table(:triggers) do
      # Nilify rather than cascade: deleting an inbox must not silently delete
      # the operator's triggers. A type: "email" trigger with a nil inbox is
      # inert (nothing polls for it) and fails validation on the next update.
      add :email_inbox_id, references(:email_inboxes, type: :binary_id, on_delete: :nilify_all)
      # Non-empty for type: "email" (enforced in Trigger.changeset/2) — an
      # email trigger with an empty allow-list would accept mail from anyone.
      add :sender_allowlist, {:array, :string}, null: false, default: []
      # Routing when several triggers share one inbox.
      add :to_address, :string
      add :subject_pattern, :string
    end

    create index(:triggers, [:email_inbox_id])

    alter table(:sessions) do
      # Persisted so a future reply-into-thread feature doesn't need another
      # migration. Nothing reads these yet — threading is out of scope for v1.
      add :email_message_id, :string
      add :email_in_reply_to, :string
    end
  end
end
