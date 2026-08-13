defmodule OrcaHub.EmailInboxesTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.EmailInboxes

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "ops mailbox",
        host: "imap.example.com",
        username: "ops@example.com",
        password: "hunter2"
      },
      overrides
    )
  end

  describe "create_email_inbox/1" do
    test "applies the schema defaults" do
      assert {:ok, inbox} = EmailInboxes.create_email_inbox(valid_attrs())
      assert inbox.port == 993
      assert inbox.tls == true
      assert inbox.folder == "INBOX"
      assert inbox.enabled == true
      assert inbox.last_uid == 0
      assert is_nil(inbox.uid_validity)
    end

    test "stores the password encrypted, never in plaintext" do
      assert {:ok, inbox} = EmailInboxes.create_email_inbox(valid_attrs())

      refute inbox.password_encrypted == "hunter2"
      refute String.contains?(inbox.password_encrypted, "hunter2")
      # The virtual field is dropped after encryption, so it can't be
      # accidentally logged off a loaded struct.
      assert is_nil(inbox.password)
      assert EmailInboxes.password!(inbox) == "hunter2"
    end

    test "requires a password" do
      assert {:error, changeset} =
               EmailInboxes.create_email_inbox(Map.delete(valid_attrs(), :password))

      assert %{password_encrypted: _} = errors_on(changeset)
    end

    test "rejects a blank password" do
      assert {:error, changeset} = EmailInboxes.create_email_inbox(valid_attrs(%{password: ""}))
      assert %{password: _} = errors_on(changeset)
    end

    test "rejects an out-of-range port" do
      assert {:error, changeset} = EmailInboxes.create_email_inbox(valid_attrs(%{port: 70_000}))
      assert %{port: _} = errors_on(changeset)
    end
  end

  describe "update_watermark/2" do
    test "advances last_uid and uid_validity without touching the password" do
      {:ok, inbox} = EmailInboxes.create_email_inbox(valid_attrs())

      # Simulates the poller's reload path: the virtual :password is never
      # populated on a row read back from the DB, so the watermark commit
      # must not run password validation.
      reloaded = EmailInboxes.get_email_inbox!(inbox.id)

      assert {:ok, updated} =
               EmailInboxes.update_watermark(reloaded, %{last_uid: 42, uid_validity: 99})

      assert updated.last_uid == 42
      assert updated.uid_validity == 99
      assert EmailInboxes.password!(updated) == "hunter2"
    end
  end

  describe "test_connection/1" do
    test "requires a password when there is neither a fresh one nor an inbox to resolve" do
      assert {:error, :password_required} =
               EmailInboxes.test_connection(%{
                 host: "127.0.0.1",
                 port: 1,
                 tls: false,
                 username: "ops@example.com",
                 password: "",
                 folder: "INBOX"
               })
    end

    test "reports a missing inbox distinctly from a missing password" do
      assert {:error, :inbox_not_found} =
               EmailInboxes.test_connection(%{
                 host: "127.0.0.1",
                 port: 1,
                 tls: false,
                 username: "ops@example.com",
                 password: "",
                 folder: "INBOX",
                 inbox_id: Ecto.UUID.generate()
               })
    end

    test "resolves the stored password when the form field is left blank" do
      {:ok, inbox} = EmailInboxes.create_email_inbox(valid_attrs(%{port: 1}))

      # Port 1 refuses the connection immediately — proving resolution got
      # past :password_required / :inbox_not_found and actually attempted to
      # dial out with the decrypted stored password.
      assert {:error, {:connect_failed, _}} =
               EmailInboxes.test_connection(%{
                 host: "127.0.0.1",
                 port: 1,
                 tls: false,
                 username: inbox.username,
                 password: "",
                 folder: "INBOX",
                 inbox_id: inbox.id
               })
    end

    test "a freshly typed password is used as-is, without needing an inbox_id" do
      assert {:error, {:connect_failed, _}} =
               EmailInboxes.test_connection(%{
                 host: "127.0.0.1",
                 port: 1,
                 tls: false,
                 username: "ops@example.com",
                 password: "hunter2",
                 folder: "INBOX"
               })
    end
  end

  describe "list_enabled_email_inboxes/0" do
    test "excludes disabled inboxes" do
      {:ok, _enabled} = EmailInboxes.create_email_inbox(valid_attrs(%{name: "enabled one"}))

      {:ok, disabled} =
        EmailInboxes.create_email_inbox(valid_attrs(%{name: "disabled one", enabled: false}))

      names = Enum.map(EmailInboxes.list_enabled_email_inboxes(), & &1.name)
      assert "enabled one" in names
      refute disabled.name in names
    end
  end
end
