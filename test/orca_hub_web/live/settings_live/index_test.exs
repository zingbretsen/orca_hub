defmodule OrcaHubWeb.SettingsLive.IndexTest do
  @moduledoc """
  LiveView coverage for the Email Inboxes CRUD on the Settings page
  (`OrcaHub.EmailInboxes`-backed) — the UI added on top of the 6667fff
  inbound-email-ingestion backend, which shipped with no UI at all.

  In particular: the password field must never render back into the edit
  form once saved — see `OrcaHub.EmailInboxes.EmailInbox` moduledoc.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.EmailInboxes

  defp valid_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "ops mailbox",
        "host" => "imap.example.com",
        "port" => "993",
        "tls" => "true",
        "username" => "ops@example.com",
        "password" => "hunter2",
        "folder" => "INBOX",
        "enabled" => "true"
      },
      overrides
    )
  end

  defp inbox_fixture(overrides) do
    {:ok, inbox} =
      EmailInboxes.create_email_inbox(
        Map.merge(
          %{
            name: "fixture inbox",
            host: "imap.example.com",
            username: "ops@example.com",
            password: "hunter2"
          },
          overrides
        )
      )

    inbox
  end

  describe "index" do
    test "lists email inboxes with connection details and badges", %{conn: conn} do
      inbox_fixture(%{name: "ops mailbox"})

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "ops mailbox"
      assert html =~ "ops@example.com@imap.example.com:993/INBOX"
      assert html =~ "TLS"
      assert html =~ "no authserv-id pin"
    end

    test "shows an empty state with no inboxes", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "No email inboxes configured."
    end
  end

  describe "create" do
    test "creates an inbox from the form and stores the password encrypted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/email-inboxes/new")

      html =
        view
        |> form("form[phx-submit=save_inbox]", %{"email_inbox" => valid_params()})
        |> render_submit()

      assert html =~ "Email inbox saved"
      assert html =~ "ops mailbox"
      refute html =~ "hunter2"

      inbox = Enum.find(EmailInboxes.list_email_inboxes(), &(&1.name == "ops mailbox"))
      assert inbox
      refute inbox.password_encrypted == "hunter2"
      refute String.contains?(inbox.password_encrypted, "hunter2")
      assert EmailInboxes.password!(inbox) == "hunter2"
    end

    test "shows a validation error and does not create the inbox", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/email-inboxes/new")

      html =
        view
        |> form("form[phx-submit=save_inbox]", %{
          "email_inbox" => valid_params(%{"password" => ""})
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute Enum.any?(EmailInboxes.list_email_inboxes(), &(&1.name == "ops mailbox"))
    end
  end

  describe "edit" do
    test "never renders the stored password back into the form", %{conn: conn} do
      inbox = inbox_fixture(%{name: "editable inbox"})

      {:ok, _view, html} = live(conn, ~p"/settings/email-inboxes/#{inbox.id}/edit")

      assert html =~ "Edit Email Inbox"
      assert html =~ ~s(type="password")
      refute html =~ "hunter2"
    end

    test "updates fields and leaves the password unchanged when left blank", %{conn: conn} do
      inbox = inbox_fixture(%{name: "editable inbox"})

      {:ok, view, _html} = live(conn, ~p"/settings/email-inboxes/#{inbox.id}/edit")

      html =
        view
        |> form("form[phx-submit=save_inbox]", %{
          "email_inbox" => %{
            "name" => "renamed inbox",
            "host" => inbox.host,
            "port" => "993",
            "tls" => "true",
            "username" => inbox.username,
            "password" => "",
            "folder" => "INBOX"
          }
        })
        |> render_submit()

      assert html =~ "Email inbox saved"
      assert html =~ "renamed inbox"

      updated = EmailInboxes.get_email_inbox!(inbox.id)
      assert updated.name == "renamed inbox"
      assert EmailInboxes.password!(updated) == "hunter2"
    end

    test "changes the password when a new one is typed", %{conn: conn} do
      inbox = inbox_fixture(%{name: "editable inbox"})

      {:ok, view, _html} = live(conn, ~p"/settings/email-inboxes/#{inbox.id}/edit")

      view
      |> form("form[phx-submit=save_inbox]", %{
        "email_inbox" => %{
          "name" => inbox.name,
          "host" => inbox.host,
          "port" => "993",
          "tls" => "true",
          "username" => inbox.username,
          "password" => "new-password",
          "folder" => "INBOX"
        }
      })
      |> render_submit()

      updated = EmailInboxes.get_email_inbox!(inbox.id)
      assert EmailInboxes.password!(updated) == "new-password"
    end
  end

  describe "toggle and delete" do
    test "toggle flips enabled without opening the form", %{conn: conn} do
      inbox = inbox_fixture(%{name: "toggle inbox"})
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_click(view, "toggle_inbox", %{"id" => inbox.id})

      assert html =~ "disabled"
      refute EmailInboxes.get_email_inbox!(inbox.id).enabled
    end

    test "delete removes the inbox", %{conn: conn} do
      inbox = inbox_fixture(%{name: "doomed inbox"})
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_click(view, "delete_inbox", %{"id" => inbox.id})

      assert html =~ "Email inbox deleted"
      refute html =~ "doomed inbox"
      assert EmailInboxes.get_email_inbox(inbox.id) == nil
    end
  end

  describe "test connection" do
    test "requires a host before attempting a connection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/email-inboxes/new")

      html = render_click(view, "test_inbox_connection", %{})

      assert html =~ "Host is required to test the connection."
    end

    test "reports a friendly error instead of crashing on a refused connection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/email-inboxes/new")

      view
      |> form("form[phx-submit=save_inbox]", %{
        "email_inbox" => valid_params(%{"host" => "127.0.0.1", "port" => "1"})
      })
      |> render_change()

      html = render_click(view, "test_inbox_connection", %{})

      assert html =~ "Connection test failed"
    end

    test "resolves the stored password on an edit form left blank", %{conn: conn} do
      inbox = inbox_fixture(%{name: "editable inbox", host: "127.0.0.1", port: 1})

      {:ok, view, _html} = live(conn, ~p"/settings/email-inboxes/#{inbox.id}/edit")

      html = render_click(view, "test_inbox_connection", %{})

      # Port 1 refuses the connection — proving the blank password field
      # resolved to the stored one and a real connection attempt was made,
      # rather than failing with "password required".
      assert html =~ "Connection test failed"
      refute html =~ "Enter a password"
    end
  end
end
