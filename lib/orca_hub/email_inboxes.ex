defmodule OrcaHub.EmailInboxes do
  @moduledoc """
  Context for IMAP mailboxes polled for inbound email triggers.

  This module talks to the database directly and therefore only runs on the
  hub — which is also where the pollers themselves run (see
  `OrcaHub.EmailInbox.Poller`). Agents never poll mailboxes.

  ## Setting up an inbox + email trigger (no UI in v1)

  From `iex` on the hub:

      {:ok, inbox} =
        OrcaHub.EmailInboxes.create_email_inbox(%{
          name: "ops mailbox",
          host: "imap.gmail.com",
          port: 993,
          tls: true,
          username: "ops@example.com",
          # Encrypted at rest with ORCA_SECRETS_KEY; never stored in plaintext.
          password: "an-app-specific-password",
          folder: "INBOX",
          # Optional but recommended: pin your provider's authserv-id.
          trusted_authserv_id: "mx.google.com"
        })

      {:ok, _trigger} =
        OrcaHub.Triggers.create_trigger(%{
          name: "Summarize forwarded mail",
          prompt: "Summarize the email below and file anything actionable.",
          type: "email",
          project_id: project.id,
          email_inbox_id: inbox.id,
          # REQUIRED and must be non-empty. Entries are exact addresses or
          # bare domains, matched case-insensitively.
          sender_allowlist: ["zach@example.com", "trusted-partner.com"],
          # Optional routing when several triggers share one inbox.
          # to_address is an exact (case-insensitive) match against To:/Cc:;
          # subject_pattern is a case-insensitive SUBSTRING, not a regex.
          # A trigger stating both must match both; the most specific
          # matching trigger wins, so a catch-all can share the inbox.
          to_address: "ops+summaries@example.com",
          subject_pattern: "invoice"
        })

  A poller for a newly created inbox starts on the next hub boot
  (`OrcaHub.EmailInboxLoader`); to start one immediately, call
  `OrcaHub.EmailInbox.Poller.start(inbox)`.

  Read `OrcaHub.EmailInbox.Poller`'s moduledoc before wiring an email trigger
  to a real project — it documents the recommended containment setup for a
  session that will be fed third-party content.
  """

  import Ecto.Query

  alias OrcaHub.EmailInboxes.EmailInbox
  alias OrcaHub.Repo

  def list_email_inboxes do
    Repo.all(from i in EmailInbox, order_by: [asc: i.name])
  end

  def list_enabled_email_inboxes do
    Repo.all(from i in EmailInbox, where: i.enabled == true, order_by: [asc: i.name])
  end

  def get_email_inbox!(id), do: Repo.get!(EmailInbox, id)

  def get_email_inbox(id), do: Repo.get(EmailInbox, id)

  def create_email_inbox(attrs) do
    %EmailInbox{}
    |> EmailInbox.changeset(attrs)
    |> Repo.insert()
  end

  def update_email_inbox(%EmailInbox{} = inbox, attrs) do
    inbox
    |> EmailInbox.changeset(attrs)
    |> Repo.update()
  end

  def delete_email_inbox(%EmailInbox{} = inbox), do: Repo.delete(inbox)

  def change_email_inbox(%EmailInbox{} = inbox, attrs \\ %{}) do
    EmailInbox.changeset(inbox, attrs)
  end

  @doc """
  The decrypted mailbox password. Only `OrcaHub.EmailInbox.Poller` (via
  `ImapClient`) may call this — never expose the result to a LiveView, a log
  line, or an MCP tool.
  """
  def password!(%EmailInbox{password_encrypted: encrypted}) when is_binary(encrypted) do
    OrcaHub.Secrets.decrypt(encrypted)
  end

  @doc """
  Commit the poll watermark for `inbox`.

  Bypasses `EmailInbox.changeset/2` deliberately: the poller must be able to
  advance the watermark without re-running password validation on a row whose
  virtual `:password` is (correctly) never loaded.
  """
  def update_watermark(%EmailInbox{} = inbox, attrs) do
    inbox
    |> Ecto.Changeset.cast(attrs, [:last_uid, :uid_validity])
    |> Repo.update()
  end

  @doc """
  Connect, authenticate, and `SELECT` the folder for the (possibly-unsaved)
  connection details in `attrs` — without fetching or mutating any messages
  — then disconnect. Returns `:ok` or `{:error, reason}`. Backs the Settings
  "Test connection" button.

  `attrs` is a map with `:host`, `:port`, `:tls`, `:username`, `:folder`,
  and either:

    * a non-blank `:password` (a freshly typed one, not yet saved), or
    * an `:inbox_id` to resolve the currently-stored password for (the edit
      form leaves `:password` blank to mean "unchanged").

  Resolving the stored password happens entirely here — callers (in
  particular any LiveView) must never call `password!/1` directly; see its
  doc.
  """
  def test_connection(attrs) do
    with {:ok, password} <- resolve_test_password(attrs) do
      attrs
      |> Map.take([:host, :port, :tls, :username, :folder])
      |> Map.put(:password, password)
      |> OrcaHub.EmailInbox.ImapClient.test_connection()
    end
  end

  defp resolve_test_password(%{password: password}) when is_binary(password) and password != "" do
    {:ok, password}
  end

  defp resolve_test_password(%{inbox_id: id}) when is_binary(id) and id != "" do
    case get_email_inbox(id) do
      nil -> {:error, :inbox_not_found}
      inbox -> {:ok, password!(inbox)}
    end
  end

  defp resolve_test_password(_attrs), do: {:error, :password_required}
end
