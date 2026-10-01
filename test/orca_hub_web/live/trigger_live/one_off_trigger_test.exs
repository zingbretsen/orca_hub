defmodule OrcaHubWeb.TriggerLive.OneOffTriggerTest do
  @moduledoc """
  LiveView coverage for one-off (`type: "once"`) triggers: the form's
  datetime-local input (America/New_York local time -> UTC run_at), and the
  pending/fired state on the index and show pages.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, Repo, Triggers}

  defp project_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{
        name: "one-off-ui-proj-#{suffix}",
        directory: "/tmp/one-off-ui-#{suffix}"
      })

    project
  end

  test "creates a one-off trigger from a local datetime", %{conn: conn} do
    project = project_fixture()
    {:ok, view, _html} = live(conn, ~p"/triggers/new")

    html = render_click(view, "set_trigger_type", %{"type" => "once"})
    assert html =~ "Fire at (America/New_York)"
    refute html =~ "set_schedule_mode"

    view
    |> form("form[phx-submit=save_trigger]", %{
      "trigger" => %{
        "project_id" => project.id,
        "name" => "Cancel coach subscription",
        "prompt" => "Use send_notification to remind me.",
        "run_at_local" => "2099-12-15T09:00"
      }
    })
    |> render_submit()

    trigger = Enum.find(Triggers.list_triggers(), &(&1.name == "Cancel coach subscription"))
    assert trigger.type == "once"
    assert trigger.run_at == ~U[2099-12-15 14:00:00Z]
    assert trigger.enabled
  end

  test "a past local datetime is rejected with an error", %{conn: conn} do
    project = project_fixture()
    {:ok, view, _html} = live(conn, ~p"/triggers/new")
    render_click(view, "set_trigger_type", %{"type" => "once"})

    html =
      view
      |> form("form[phx-submit=save_trigger]", %{
        "trigger" => %{
          "project_id" => project.id,
          "name" => "Too late",
          "prompt" => "p",
          "run_at_local" => "2020-01-01T09:00"
        }
      })
      |> render_submit()

    assert html =~ "must be in the future"
    refute Enum.find(Triggers.list_triggers(), &(&1.name == "Too late"))
  end

  test "index and show display pending, then fired", %{conn: conn} do
    project = project_fixture()

    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "one-off-display",
        prompt: "p",
        type: "once",
        run_at: ~U[2099-12-15 14:00:00Z],
        project_id: project.id
      })

    {:ok, _view, html} = live(conn, ~p"/triggers")
    assert html =~ "once at 2099-12-15 09:00 EST"
    assert html =~ "pending"

    {:ok, _view, html} = live(conn, ~p"/triggers/#{trigger.id}")
    assert html =~ "Runs at"
    assert html =~ "2099-12-15 09:00 EST"
    assert html =~ "pending"

    trigger
    |> Ecto.Changeset.change(enabled: false, last_fired_at: ~U[2099-12-15 14:00:05Z])
    |> Repo.update!()

    {:ok, _view, html} = live(conn, ~p"/triggers/#{trigger.id}")
    assert html =~ "fired"
    refute html =~ "Fire now"
  end
end
