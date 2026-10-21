defmodule OrcaHubWeb.SessionLive.SidebarTest do
  @moduledoc """
  The session page's desktop sidebar (`OrcaHubWeb.SessionLive.Sidebar`).

  At `lg:` the sidebar holds all of the session chrome. Below it, the old
  header, chip, modal and stacked panels do. Both layouts are in the DOM at
  once and CSS shows one, so what these tests can check is the server half:
  the sidebar carries the chrome as labeled rows, it renders the shared
  panels in its own sections, the controls fire the same events, its
  context flips while a side panel is open, and the doubled DOM never
  repeats an id. The layout itself was checked in a real browser.
  """

  # async: false for the same reason as session_live/show_test.exs: visiting
  # the page starts a real SessionRunner under the shared supervisor.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{Artifacts, Projects, SessionSupervisor, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "session_sidebar_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  defp create_session(dir, attrs \\ %{}) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(
          %{
            directory: dir,
            backend: "claude",
            code_exec: false,
            orchestrator: false,
            runner_node: Atom.to_string(node())
          },
          attrs
        )
      )

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id),
        do: SessionSupervisor.stop_session(session.id)
    end)

    session
  end

  defp put_todos(session) do
    {:ok, _} =
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "toolu_todos",
                "name" => "TodoWrite",
                "input" => %{
                  "todos" => [
                    %{"content" => "Write the sidebar", "status" => "completed"},
                    %{"content" => "Check it in a browser", "status" => "in_progress"}
                  ]
                }
              }
            ]
          }
        }
      })
  end

  defp put_memory_event(session) do
    Sessions.persist_system_event(session.id, %{
      "type" => "system",
      "subtype" => "memory_injected",
      "memory_ids" => ["mem-1"],
      "hooks" => ["a sidebar hook"],
      "pinned_count" => 1,
      "recalled_count" => 0
    })
  end

  describe "the sidebar" do
    test "is desktop-only and carries the chrome the header hides there", %{conn: conn, dir: dir} do
      session = create_session(dir, %{title: "Sidebar subject"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      sidebar = view |> element("#session-sidebar") |> render()
      [class] = sidebar |> Floki.parse_fragment!() |> Floki.attribute("class")

      # Shown at `lg:` only, never in the phone voice view...
      assert class =~ "hidden"
      assert class =~ "lg:flex"
      assert class =~ "voice-view:hidden"
      # ...where the header it replaces is hidden instead.
      assert has_element?(view, ~s(header[class~="lg:hidden"]))

      assert sidebar =~ "Sidebar subject"
      assert sidebar =~ ~s(href="/sessions")
      # The full directory, not the phone header's basename.
      assert sidebar =~ dir
      assert has_element?(view, "#session-sidebar dd", "none")

      # Actions are labeled rows, not an icon strip.
      for label <- [
            "Browse files",
            "Open terminal",
            "Heartbeat",
            "MCP servers",
            "Orchestrator mode",
            "Memory extraction",
            "Attach to...",
            "Copy session ID",
            "Archive"
          ] do
        assert has_element?(view, "#session-sidebar button, #session-sidebar summary", label),
               "no sidebar row labeled #{inspect(label)}"
      end
    end

    test "shows the progress note as text, not only as a tooltip", %{conn: conn, dir: dir} do
      session =
        create_session(dir, %{
          progress_phase: "implementing",
          progress_note: "writing the migration"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#session-sidebar .badge", "implementing")
      assert has_element?(view, "#session-sidebar p", "writing the migration")
    end

    test "links the parent and states the orchestrator badge", %{conn: conn, dir: dir} do
      parent = create_session(dir, %{title: "Orchestrator Prime", orchestrator: true})
      session = create_session(dir, %{parent_session_id: parent.id, orchestrator: true})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(
               view,
               ~s(#session-sidebar a[href="/sessions/#{parent.id}"]),
               "Orchestrator Prime"
             )

      assert has_element?(view, "#session-sidebar .badge", "orchestrator")
      assert has_element?(view, "#session-sidebar button", "Detach from orchestrator")
    end

    test "edits the title in place", %{conn: conn, dir: dir} do
      session = create_session(dir, %{title: "Old title"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#session-sidebar h1[phx-click=edit_title]") |> render_click()
      assert has_element?(view, "#sidebar-title-form")

      view |> element("#sidebar-title-form") |> render_submit(%{"title" => "New title"})

      assert Sessions.get_session!(session.id).title == "New title"
      refute has_element?(view, "#sidebar-title-form")
      assert has_element?(view, "#session-sidebar h1", "New title")
    end

    test "its action rows fire the header's events", %{conn: conn, dir: dir} do
      session = create_session(dir)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#session-sidebar button[phx-click=toggle_orchestrator]") |> render_click()

      assert Sessions.get_session!(session.id).orchestrator
      assert has_element?(view, "#session-sidebar button[phx-click=toggle_orchestrator]", "on")
    end
  end

  describe "panel sections" do
    test "render their list inside the sidebar, sharing the stacked panel's state", %{
      conn: conn,
      dir: dir
    } do
      session = create_session(dir)
      put_todos(session)
      put_memory_event(session)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#sidebar-tasks button", "1/2")
      refute has_element?(view, "#sidebar-tasks-panel")

      view |> element("#sidebar-tasks button[phx-click=toggle_todos]") |> render_click()

      assert has_element?(view, "#sidebar-tasks-panel", "Check it in a browser")
      # The same open state drives the copy stacked above the feed, which
      # only shows below `lg:`.
      assert has_element?(view, ~s(#todos-panel[class~="lg:hidden"]), "Check it in a browser")

      view |> element("#sidebar-memories button[phx-click=toggle_memories]") |> render_click()
      assert has_element?(view, "#sidebar-memories-panel", "a sidebar hook")
    end

    test "opening an artifact from the sidebar opens it in the file panel", %{
      conn: conn,
      dir: dir
    } do
      {:ok, project} =
        Projects.create_project(%{name: "sidebar-artifacts", directory: dir, node: "n1@x"})

      session = create_session(dir, %{project_id: project.id})

      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          session_id: session.id,
          name: "sidebar-dashboard",
          kind: "html",
          content: "<p>hi</p>"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#sidebar-artifacts button[phx-click=toggle_artifacts]") |> render_click()

      view
      |> element(
        ~s(#sidebar-artifacts-panel button[phx-click=open_session_artifact][phx-value-id="#{artifact.id}"])
      )
      |> render_click()

      assert has_element?(view, ~s([data-resize-panel="right"]), "sidebar-dashboard")
    end
  end

  describe "the collapsed rail" do
    test "carries the everyday chrome as icons, titled with the expanded rows' labels", %{
      conn: conn,
      dir: dir
    } do
      session = create_session(dir, %{claude_session_id: "native-abc"})
      put_todos(session)
      put_memory_event(session)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      for {id, label} <- [
            {"rail-tasks", "Tasks"},
            {"rail-memories", "Memories"},
            {"rail-files", "Browse files"},
            {"rail-terminal", "Open terminal"},
            {"rail-resume", "Resume in terminal"},
            {"rail-heartbeat", "Heartbeat"},
            {"rail-mcp", "MCP servers"},
            {"rail-archive", "Archive"}
          ] do
        assert has_element?(view, ~s(#session-sidebar-rail button##{id}[title="#{label}"])),
               "no rail icon #{id} titled #{inspect(label)}"
      end

      # Panels show only with content, with their count; the Tasks count is
      # done/total, as the header's was.
      assert has_element?(view, "#rail-tasks .badge", "1/2")
      assert has_element?(view, "#rail-memories .badge", "1")
      refute has_element?(view, "#rail-artifacts")
      refute has_element?(view, "#rail-tool-policy")
      # Idle: nothing to stop. Not archived: no unarchive.
      refute has_element?(view, "#rail-stop")
      refute has_element?(view, "#rail-unarchive")
      # The rarely used settings stay in the expanded sidebar.
      refute has_element?(view, "#session-sidebar-rail [phx-click=toggle_orchestrator]")
      refute has_element?(view, "#session-sidebar-rail [phx-click=cycle_memory_extract]")
    end

    test "a tool icon fires the same event and lights up while its panel is open", %{
      conn: conn,
      dir: dir
    } do
      session = create_session(dir)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute has_element?(view, "#rail-files.text-primary")

      view |> element("#rail-files") |> render_click()

      assert has_element?(view, "#rail-files.text-primary")
      assert has_element?(view, ~s(#session-sidebar[data-sidebar-context="panel"]))
    end

    test "a panel icon opens a flyout with that panel's list, one at a time", %{
      conn: conn,
      dir: dir
    } do
      session = create_session(dir)
      put_todos(session)
      put_memory_event(session)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute has_element?(view, "#rail-flyout")
      refute has_element?(view, "#session-sidebar-rail[phx-click-away]")

      view |> element("#rail-tasks") |> render_click()

      assert has_element?(view, "#rail-flyout", "Check it in a browser")
      assert has_element?(view, ~s(#rail-flyout[data-anchor="rail-tasks"]))
      assert has_element?(view, "#rail-tasks.text-primary")
      # Its own state: the expanded section and the stacked panel stay shut.
      refute has_element?(view, "#sidebar-tasks-panel")
      refute has_element?(view, "#todos-panel")
      # While open, the rail closes it on a click outside or on Escape.
      assert has_element?(view, "#session-sidebar-rail[phx-click-away]")
      assert has_element?(view, ~s(#session-sidebar-rail[phx-window-keydown="close_rail_flyout"]))

      # Another icon swaps it; the same icon again closes it.
      view |> element("#rail-memories") |> render_click()
      assert has_element?(view, "#rail-flyout", "a sidebar hook")
      refute has_element?(view, "#rail-flyout", "Check it in a browser")

      view |> element("#rail-memories") |> render_click()
      refute has_element?(view, "#rail-flyout")

      view |> element("#rail-tasks") |> render_click()
      view |> element("#session-sidebar-rail") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#rail-flyout")

      # Expanding the sidebar with a flyout open closes it as well.
      view |> element("#rail-tasks") |> render_click()

      assert has_element?(
               view,
               ~s(#rail-icons button[aria-label="Expand sidebar"][phx-click*="close_rail_flyout"])
             )

      render_click(view, "close_rail_flyout")
      refute has_element?(view, "#rail-flyout")

      # An unknown panel is ignored.
      render_click(view, "rail_flyout", %{"panel" => "nope"})
      refute has_element?(view, "#rail-flyout")
    end

    test "opening an artifact from its flyout opens the file panel and closes the flyout", %{
      conn: conn,
      dir: dir
    } do
      {:ok, project} =
        Projects.create_project(%{name: "rail-artifacts", directory: dir, node: "n1@x"})

      session = create_session(dir, %{project_id: project.id})

      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          session_id: session.id,
          name: "rail-dashboard",
          kind: "html",
          content: "<p>hi</p>"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#rail-artifacts .badge", "1")
      view |> element("#rail-artifacts") |> render_click()

      view
      |> element(
        ~s(#rail-flyout button[phx-click=open_session_artifact][phx-value-id="#{artifact.id}"])
      )
      |> render_click()

      refute has_element?(view, "#rail-flyout")
      assert has_element?(view, ~s([data-resize-panel="right"]), "rail-dashboard")
    end

    test "archiving from the rail is two clicks, through its flyout", %{conn: conn, dir: dir} do
      session = create_session(dir)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("#rail-archive") |> render_click()
      assert has_element?(view, "#rail-flyout button", "Archive without extracting memories")

      {:error, {:live_redirect, %{to: path}}} =
        view |> element("#rail-flyout button[phx-click=archive]") |> render_click()

      assert path =~ "/sessions?"
      refute is_nil(Sessions.get_session!(session.id).archived_at)
    end
  end

  test "its context flips to \"panel\" while a file or terminal panel is open", %{
    conn: conn,
    dir: dir
  } do
    session = create_session(dir)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    assert has_element?(view, ~s(#session-sidebar[data-sidebar-context="chat"]))

    render_click(view, "toggle_file_browser")
    assert has_element?(view, ~s(#session-sidebar[data-sidebar-context="panel"]))

    render_click(view, "close_file_panel")
    assert has_element?(view, ~s(#session-sidebar[data-sidebar-context="chat"]))
  end

  # daisyUI locks <html> (overflow hidden, scrollbar-gutter stable) behind
  # any checked .modal-toggle, displayed or not, so the phone sheet's
  # checkbox left an empty gutter beside the desktop panel.
  test "the phone file sheet's toggle is unchecked on the desktop layout", %{
    conn: conn,
    dir: dir
  } do
    session = create_session(dir)

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"panel_layout" => "desktop"})
      |> live(~p"/sessions/#{session.id}")

    render_click(view, "toggle_file_browser")
    assert has_element?(view, "#file-panel-modal")
    refute has_element?(view, "#file-panel-modal[checked]")

    view |> element("#panel-layout") |> render_hook("panel_layout", %{"layout" => "mobile"})
    assert has_element?(view, "#file-panel-modal[checked]")
  end

  # Both layouts are in the DOM at once. A repeated id breaks hooks
  # (CopyToClipboard, the pickers) and LiveView's patching alike, so render
  # with every panel, picker and form the sidebar can show at once.
  test "the doubled chrome never repeats an element id", %{conn: conn, dir: dir} do
    {:ok, project} =
      Projects.create_project(%{name: "sidebar-ids", directory: dir, node: "n1@x"})

    parent = create_session(dir, %{title: "Parent", orchestrator: true})

    session =
      create_session(dir, %{
        project_id: project.id,
        parent_session_id: parent.id,
        claude_session_id: "native-abc",
        tool_denylist: ["retire_memory"],
        progress_phase: "implementing",
        progress_note: "a note"
      })

    put_todos(session)
    put_memory_event(session)

    {:ok, _} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        session_id: session.id,
        name: "ids-dashboard",
        kind: "html",
        content: "<p>hi</p>"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    for event <- ~w(toggle_todos toggle_artifacts toggle_tool_policy toggle_memories edit_title) do
      render_click(view, event)
    end

    render_click(view, "open_mobile_actions")
    # A third copy of the artifact list, in the rail's flyout.
    render_click(view, "rail_flyout", %{"panel" => "artifacts"})

    ids =
      view
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("[id]")
      |> Enum.flat_map(&Floki.attribute(&1, "id"))

    assert "sidebar-copy-session-id" in ids
    assert "sidebar-title-form" in ids
    assert "sidebar-tool-policy-panel" in ids
    assert "rail-flyout" in ids
    assert "rail-tool-policy" in ids

    duplicates = ids |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)
    assert duplicates == []
  end
end
