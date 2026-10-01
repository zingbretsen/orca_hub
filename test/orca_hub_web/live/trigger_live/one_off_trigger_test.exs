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

  test "the Ends control sets max_runs or an end date, and show displays N of M runs",
       %{conn: conn} do
    project = project_fixture()
    {:ok, view, _html} = live(conn, ~p"/triggers/new")
    render_click(view, "set_schedule_mode", %{"mode" => "custom"})
    render_click(view, "set_ends_mode", %{"mode" => "after"})

    view
    |> form("form[phx-submit=save_trigger]", %{
      "trigger" => %{
        "project_id" => project.id,
        "name" => "ends-after-ui",
        "prompt" => "p",
        "cron_expression" => "0 9 * * *",
        "max_runs" => "5"
      }
    })
    |> render_submit()

    trigger = Enum.find(Triggers.list_triggers(), &(&1.name == "ends-after-ui"))
    assert trigger.max_runs == 5
    assert trigger.ends_at == nil

    {:ok, _view, html} = live(conn, ~p"/triggers/#{trigger.id}")
    assert html =~ "0 of 5 runs"
    assert html =~ "after 5 runs"

    # Switching the edit form to "On date" replaces max_runs with an end date.
    {:ok, view, _html} = live(conn, ~p"/triggers/#{trigger.id}/edit")
    render_click(view, "set_ends_mode", %{"mode" => "on"})

    view
    |> form("form[phx-submit=save_trigger]", %{
      "trigger" => %{"ends_on_local" => "2099-12-31"}
    })
    |> render_submit()

    trigger = Triggers.get_trigger!(trigger.id)
    assert trigger.max_runs == nil
    assert trigger.ends_at == ~U[2100-01-01 04:59:59Z]

    {:ok, _view, html} = live(conn, ~p"/triggers/#{trigger.id}")
    assert html =~ "on 2099-12-31 23:59 EST"
  end
end
