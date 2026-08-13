defmodule OrcaHubWeb.TriggerLive.EmailTriggerTest do
  @moduledoc """
  LiveView coverage for the `type: "email"` branch of the trigger form — the
  UI added on top of the 6667fff inbound-email-ingestion backend
  (`OrcaHub.Triggers.Trigger`'s `email_inbox_id`/`sender_allowlist`/
  `to_address`/`subject_pattern` fields), which shipped with no UI.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{EmailInboxes, Projects, Triggers}

  defp project_fixture(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(
        Map.merge(
          %{name: "email-trigger-proj-#{suffix}", directory: "/tmp/email-trigger-#{suffix}"},
          overrides
        )
      )

    project
  end

  defp inbox_fixture(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    {:ok, inbox} =
      EmailInboxes.create_email_inbox(
        Map.merge(
          %{
            name: "inbox-#{suffix}",
            host: "imap.example.com",
            username: "ops@example.com",
            password: "hunter2"
          },
          overrides
        )
      )

    inbox
  end

  test "switching to the email type shows the inbox picker and allow-list field", %{conn: conn} do
    inbox_fixture(%{name: "pickable inbox"})
    {:ok, view, _html} = live(conn, ~p"/triggers/new")

    html = render_click(view, "set_trigger_type", %{"type" => "email"})

    assert html =~ "Inbox"
    assert html =~ "pickable inbox"
    assert html =~ "Sender allow-list"
    refute html =~ "set_schedule_mode"
  end

  test "fields common to every trigger type stay visible for the email type", %{conn: conn} do
    inbox_fixture()
    {:ok, view, _html} = live(conn, ~p"/triggers/new")

    html = render_click(view, "set_trigger_type", %{"type" => "email"})

    assert html =~ "Project"
    assert html =~ "Prompt"
    assert html =~ "Reuse previous session"
    assert html =~ "Hide from queue when done"
    assert html =~ "accumulates into one long-running session"
  end

  test "prompts to configure an inbox first when none exist", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/triggers/new")

    html = render_click(view, "set_trigger_type", %{"type" => "email"})

    assert html =~ "No email inboxes configured yet."
  end

  test "creates an email trigger with a parsed sender allow-list", %{conn: conn} do
    project = project_fixture()
    inbox = inbox_fixture()

    {:ok, view, _html} = live(conn, ~p"/triggers/new")
    render_click(view, "set_trigger_type", %{"type" => "email"})

    html =
      view
      |> form("form[phx-submit=save_trigger]", %{
        "trigger" => %{
          "project_id" => project.id,
          "name" => "Summarize inbound mail",
          "prompt" => "Summarize this email.",
          "email_inbox_id" => inbox.id,
          "sender_allowlist" => "zach@example.com, trusted-partner.com",
          "to_address" => "ops@example.com",
          "subject_pattern" => "invoice"
        }
      })
      |> render_submit()

    assert html =~ "Summarize inbound mail"

    trigger = Enum.find(Triggers.list_triggers(), &(&1.name == "Summarize inbound mail"))
    assert trigger.type == "email"
    assert trigger.email_inbox_id == inbox.id
    assert trigger.sender_allowlist == ["zach@example.com", "trusted-partner.com"]
    assert trigger.to_address == "ops@example.com"
    assert trigger.subject_pattern == "invoice"
  end

  test "accepts a newline-separated allow-list too", %{conn: conn} do
    project = project_fixture()
    inbox = inbox_fixture()

    {:ok, view, _html} = live(conn, ~p"/triggers/new")
    render_click(view, "set_trigger_type", %{"type" => "email"})

    view
    |> form("form[phx-submit=save_trigger]", %{
      "trigger" => %{
        "project_id" => project.id,
        "name" => "Newline allow-list",
        "prompt" => "hi",
        "email_inbox_id" => inbox.id,
        "sender_allowlist" => "zach@example.com\ntrusted-partner.com"
      }
    })
    |> render_submit()

    trigger = Enum.find(Triggers.list_triggers(), &(&1.name == "Newline allow-list"))
    assert trigger.sender_allowlist == ["zach@example.com", "trusted-partner.com"]
  end

  test "surfaces the empty-allow-list validation error instead of a 500", %{conn: conn} do
    project = project_fixture()
    inbox = inbox_fixture()

    {:ok, view, _html} = live(conn, ~p"/triggers/new")
    render_click(view, "set_trigger_type", %{"type" => "email"})

    html =
      view
      |> form("form[phx-submit=save_trigger]", %{
        "trigger" => %{
          "project_id" => project.id,
          "name" => "No allow-list",
          "prompt" => "hi",
          "email_inbox_id" => inbox.id,
          "sender_allowlist" => ""
        }
      })
      |> render_submit()

    assert html =~ "must contain at least one address or domain for an email trigger"
    refute Enum.any?(Triggers.list_triggers(), &(&1.name == "No allow-list"))
  end

  test "index shows the inbox name and sender count for an email trigger", %{conn: conn} do
    project = project_fixture()
    inbox = inbox_fixture(%{name: "shown inbox"})

    {:ok, _trigger} =
      Triggers.create_trigger(%{
        name: "email trigger row",
        prompt: "hi",
        type: "email",
        project_id: project.id,
        email_inbox_id: inbox.id,
        sender_allowlist: ["a@example.com", "b@example.com"]
      })

    {:ok, _view, html} = live(conn, ~p"/triggers")

    assert html =~ "email trigger row"
    assert html =~ "shown inbox"
    assert html =~ "2 allowed sender"
  end
end
