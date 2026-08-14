defmodule OrcaHubWeb.TriggerLive.ShowTest do
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, Sessions, Triggers}

  setup do
    dir = Path.join(System.tmp_dir!(), "trigger_show_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "trigger show project", directory: dir})

    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "Show page trigger",
        prompt: "Check things",
        cron_expression: "0 9 * * *",
        project_id: project.id
      })

    %{project: project, trigger: trigger}
  end

  defp create_session(project, trigger, overrides) do
    attrs =
      Map.merge(
        %{directory: project.directory, project_id: project.id, trigger_id: trigger.id},
        overrides
      )

    {:ok, session} = Sessions.create_session(attrs)
    session
  end

  test "renders trigger details and its sessions, including archived ones", %{
    conn: conn,
    project: project,
    trigger: trigger
  } do
    live_session = create_session(project, trigger, %{title: "Live one"})
    archived = create_session(project, trigger, %{title: "Old one"})
    {:ok, _} = Sessions.archive_session(archived)

    {:ok, _view, html} = live(conn, ~p"/triggers/#{trigger.id}")

    assert html =~ trigger.name
    assert html =~ project.name
    assert html =~ trigger.cron_expression
    assert html =~ "Live one"
    assert html =~ "Old one"
    assert html =~ "archived"
    assert html =~ live_session.id
  end

  test "flags the currently reused session", %{conn: conn, project: project, trigger: trigger} do
    session = create_session(project, trigger, %{title: "Reused one"})
    {:ok, trigger} = Triggers.update_trigger(trigger, %{reuse_session: true})
    {:ok, trigger} = Triggers.update_trigger(trigger, %{last_session_id: session.id})

    {:ok, view, html} = live(conn, ~p"/triggers/#{trigger.id}")

    assert html =~ "current"
    assert has_element?(view, "#trigger-sessions", "Reused one")
  end

  test "rotate session clears last_session_id without touching the old session", %{
    conn: conn,
    project: project,
    trigger: trigger
  } do
    session = create_session(project, trigger, %{title: "Reused one", status: "idle"})
    {:ok, trigger} = Triggers.update_trigger(trigger, %{reuse_session: true})
    {:ok, trigger} = Triggers.update_trigger(trigger, %{last_session_id: session.id})

    {:ok, view, _html} = live(conn, ~p"/triggers/#{trigger.id}")

    html = view |> element("button", "Rotate session") |> render_click()

    assert html =~ "Session rotated"

    reloaded = Triggers.get_trigger!(trigger.id)
    assert reloaded.last_session_id == nil

    reloaded_session = Sessions.get_session!(session.id)
    assert reloaded_session.archived_at == nil
    assert reloaded_session.status == "idle"

    # The old session must stay listed and reachable, just no longer flagged current.
    assert has_element?(view, "#trigger-sessions", "Reused one")
  end

  test "hides rotate when reuse_session is false", %{
    conn: conn,
    project: project,
    trigger: trigger
  } do
    _session = create_session(project, trigger, %{title: "One-off"})

    {:ok, view, _html} = live(conn, ~p"/triggers/#{trigger.id}")

    refute has_element?(view, "button", "Rotate session")
    assert has_element?(view, "*", "Only reused sessions can be rotated.")
  end

  test "hides rotate when reuse_session is true but nothing has fired yet", %{
    conn: conn,
    trigger: trigger
  } do
    {:ok, trigger} = Triggers.update_trigger(trigger, %{reuse_session: true})

    {:ok, view, _html} = live(conn, ~p"/triggers/#{trigger.id}")

    refute has_element?(view, "button", "Rotate session")
    assert has_element?(view, "*", "hasn't fired")
  end
end
