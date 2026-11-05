defmodule OrcaHubWeb.TriggerLive.ShowTest do
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

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
    refute has_element?(view, "#trigger-sessions .badge-primary", "current")
  end

  describe "session list paging" do
    # insert_all: 1,025 rows through create_session/1 would dominate the run.
    defp seed_trigger_sessions(project, trigger, count) do
      base = ~N[2026-01-01 00:00:00]

      rows =
        for i <- 1..count do
          at = NaiveDateTime.add(base, i * 60, :second)

          %{
            id: Ecto.UUID.generate(),
            directory: project.directory,
            project_id: project.id,
            trigger_id: trigger.id,
            triggered: true,
            title: run_title(i),
            status: "idle",
            inserted_at: at,
            updated_at: at
          }
        end

      {^count, _} = OrcaHub.Repo.insert_all(OrcaHub.Sessions.Session, rows)
      rows
    end

    defp run_title(i), do: "Run #{String.pad_leading(Integer.to_string(i), 4, "0")}"

    defp row_titles(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#trigger-sessions tr a")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))
    end

    test "the first render lists only the newest page, with the total", %{
      conn: conn,
      project: project,
      trigger: trigger
    } do
      seed_trigger_sessions(project, trigger, 1_025)
      page = OrcaHubWeb.TriggerLive.Show.sessions_page_size()

      {:ok, view, html} = live(conn, ~p"/triggers/#{trigger.id}")

      titles = row_titles(view)
      assert length(titles) == page
      assert hd(titles) == run_title(1_025)
      assert List.last(titles) == run_title(1_025 - page + 1)
      assert html =~ ~r/id="trigger-sessions-count"[^>]*>\s*1025\s*</
      assert html =~ "Showing #{page} of 1025"
      assert has_element?(view, "#load-older-sessions")
      # The capped dead render, vs ~986 KB for 1,025 rows before.
      assert byte_size(html) < 200_000
    end

    test "Show older appends the next page until none are left", %{
      conn: conn,
      project: project,
      trigger: trigger
    } do
      page = OrcaHubWeb.TriggerLive.Show.sessions_page_size()
      total = page * 2 + 7
      seed_trigger_sessions(project, trigger, total)

      {:ok, view, _html} = live(conn, ~p"/triggers/#{trigger.id}")

      view |> element("#load-older-sessions") |> render_click()
      assert length(row_titles(view)) == page * 2

      view |> element("#load-older-sessions") |> render_click()
      titles = row_titles(view)

      assert titles == Enum.map(total..1//-1, &run_title/1)
      refute has_element?(view, "#load-older-sessions")
    end

    test "sessions sharing an inserted_at second are neither skipped nor repeated", %{
      conn: conn,
      project: project,
      trigger: trigger
    } do
      page = OrcaHubWeb.TriggerLive.Show.sessions_page_size()
      rows = seed_trigger_sessions(project, trigger, page + 10)

      # Every row in the same second: only the id tiebreak orders them.
      OrcaHub.Repo.update_all(
        from(s in OrcaHub.Sessions.Session, where: s.trigger_id == ^trigger.id),
        set: [inserted_at: ~N[2026-02-01 00:00:00]]
      )

      {:ok, view, _html} = live(conn, ~p"/triggers/#{trigger.id}")
      view |> element("#load-older-sessions") |> render_click()

      titles = row_titles(view)
      assert length(titles) == page + 10
      assert Enum.sort(titles) == Enum.sort(Enum.map(rows, & &1.title))
    end
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
