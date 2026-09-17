defmodule OrcaHubWeb.ProjectLive.MoveDirectoryTest do
  @moduledoc """
  The project page's "Move / rename directory" action, and the footgun it
  replaces.

  Editing `project.directory` in the edit form used to rewrite ONE database
  column: nothing moved on disk and every session/terminal/job row under the
  old path was silently left dangling. The edit form no longer renders that
  field, and — more importantly — `save_project` drops a `directory` key out
  of the submitted params, so a hand-crafted event cannot corrupt it either.

  The move itself is deliberately two-step: Preview
  (`Projects.plan_directory_move/2`, mutates nothing) and then a separate
  confirm click (`Projects.move_directory/3`).
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Jobs.Job
  alias OrcaHub.Projects
  alias OrcaHub.Projects.Project
  alias OrcaHub.Repo
  alias OrcaHub.Sessions.Session
  alias OrcaHub.Terminals.Terminal

  setup do
    root = Path.join(System.tmp_dir!(), "project_move_#{System.unique_integer([:positive])}")
    source = Path.join(root, "src")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "marker.txt"), "hello")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "move-ui-#{System.unique_integer([:positive])}",
        directory: source,
        node: Atom.to_string(node())
      })

    {:ok, project: project, root: root, source: source, destination: Path.join(root, "moved")}
  end

  defp open_move_panel(view) do
    view |> element("button[phx-click=toggle_move_panel]") |> render_click()
    view
  end

  defp preview(view, destination) do
    view
    |> form("form[phx-submit=preview_move]", move: %{destination: destination})
    |> render_submit()

    render_async(view)
  end

  defp session(directory, attrs) do
    Repo.insert!(
      struct(
        %Session{directory: directory, status: "idle", runner_node: to_string(node())},
        attrs
      )
    )
  end

  defp terminal(directory, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Terminal{
          name: "t-#{System.unique_integer([:positive])}",
          directory: directory,
          status: "stopped",
          runner_node: to_string(node())
        },
        attrs
      )
    )
  end

  defp job(directory, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Job{
          directory: directory,
          command: "true",
          status: "succeeded",
          runner_node: to_string(node())
        },
        attrs
      )
    )
  end

  describe "the edit form no longer writes the directory" do
    test "renders the directory read-only, with a pointer to the move action", %{
      conn: conn,
      project: project,
      source: source
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/edit")

      refute html =~ ~s(name="project[directory]")
      assert html =~ source
      assert html =~ "Move / rename directory"
    end

    test "a submitted directory param is ignored — the column is unchanged", %{
      conn: conn,
      project: project,
      source: source
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/edit")

      # Exactly what a hand-crafted client can send: the form has no such
      # input, so this bypasses the UI entirely.
      render_submit(view, "save_project", %{
        "project" => %{"name" => "renamed-by-form", "directory" => "/tmp/somewhere-else"}
      })

      reloaded = Repo.get!(Project, project.id)

      assert reloaded.name == "renamed-by-form"
      assert reloaded.directory == source
    end

    test "a directory param is ignored while validating too", %{
      conn: conn,
      project: project,
      source: source
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/edit")

      html =
        render_change(view, "validate_project", %{
          "project" => %{"name" => "still-editing", "directory" => "/tmp/somewhere-else"}
        })

      refute html =~ "/tmp/somewhere-else"
      assert html =~ source
      assert Repo.get!(Project, project.id).directory == source
    end
  end

  describe "preview" do
    test "reports the destination, node and affected row counts", %{
      conn: conn,
      project: project,
      source: source,
      destination: destination
    } do
      session(source, %{})
      session(Path.join(source, "nested"), %{})
      terminal(source)
      job(source)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      html = view |> open_move_panel() |> preview(destination)

      assert html =~ source
      assert html =~ destination
      assert html =~ "2 session row(s)"
      assert html =~ "1 terminal row(s)"
      assert html =~ "1 job row(s)"
      assert html =~ "1 project row(s)"

      # A preview mutates nothing.
      assert File.dir?(source)
      refute File.exists?(destination)
      assert Repo.get!(Project, project.id).directory == source
    end

    test "lists every other project row dragged along by the move", %{
      conn: conn,
      project: project,
      source: source,
      destination: destination
    } do
      nested_dir = Path.join(source, ".worktrees/feature")
      File.mkdir_p!(nested_dir)

      {:ok, nested} =
        Projects.create_project(%{
          name: "nested-worktree",
          directory: nested_dir,
          node: Atom.to_string(node())
        })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      html = view |> open_move_panel() |> preview(destination)

      assert html =~ "2 project row(s)"
      assert html =~ nested.name
      assert html =~ Path.join(destination, ".worktrees/feature")
      assert html =~ "other project row(s) live under this directory"
    end

    test "shows blockers verbatim and disables the confirm button", %{
      conn: conn,
      project: project,
      source: source,
      destination: destination
    } do
      live_session = session(source, %{status: "running", title: "mid-turn worker"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      html = view |> open_move_panel() |> preview(destination)

      # Verbatim: WHICH session, not "1 session is busy".
      assert html =~ "session mid-turn worker (#{live_session.id}) is running"
      assert html =~ "Move anyway"

      assert [button] =
               html |> Floki.parse_document!() |> Floki.find("button[phx-click=confirm_move]")

      assert Floki.attribute(button, "disabled") != []
    end

    test "editing the destination after a preview drops the preview", %{
      conn: conn,
      project: project,
      destination: destination
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      html = view |> open_move_panel() |> preview(destination)
      assert html =~ "This is what will happen"

      html =
        view
        |> form("form[phx-submit=preview_move]", move: %{destination: destination <> "-other"})
        |> render_change()

      refute html =~ "This is what will happen"
    end

    test "a project whose node is offline says so, and does not offer another node", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      {:ok, offline} =
        Projects.create_project(%{
          name: "offline-move",
          directory: source,
          node: "orca@totally-offline-host"
        })

      {:ok, view, _html} = live(conn, ~p"/projects/#{offline.id}")

      html = view |> open_move_panel() |> preview(destination)

      # The framing says the node is down and that there is nothing to retry
      # elsewhere (the text is wrapped in the template, so match fragments).
      assert html =~ "That project&#39;s node is down"
      assert html =~ "never re-assigns a"
      assert html =~ "nothing to retry elsewhere"
      # ...and DirectoryMove's own message is shown verbatim underneath.
      assert html =~ "not currently connected"
      refute File.exists?(destination)
    end
  end

  describe "confirm" do
    test "moves the directory on disk and rewrites the rows", %{
      conn: conn,
      project: project,
      source: source,
      destination: destination
    } do
      moved_session = session(Path.join(source, "sub"), %{})
      moved_terminal = terminal(source)
      moved_job = job(source)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view |> open_move_panel() |> preview(destination)

      render_click(view, "confirm_move", %{})
      html = render_async(view)

      assert html =~ "Moved"
      assert html =~ destination

      refute File.exists?(source)
      assert File.read!(Path.join(destination, "marker.txt")) == "hello"

      assert Repo.get!(Project, project.id).directory == destination
      assert Repo.get!(Session, moved_session.id).directory == Path.join(destination, "sub")
      assert Repo.get!(Terminal, moved_terminal.id).directory == destination
      assert Repo.get!(Job, moved_job.id).directory == destination
    end

    test "is refused while blockers stand and force is not ticked", %{
      conn: conn,
      project: project,
      source: source,
      destination: destination
    } do
      session(source, %{status: "running"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view |> open_move_panel() |> preview(destination)

      html = render_click(view, "confirm_move", %{})

      assert html =~ "Live work is using this directory"
      assert File.dir?(source)
      refute File.exists?(destination)
      assert Repo.get!(Project, project.id).directory == source
    end

    test "goes through once force is ticked, and the blockers become warnings", %{
      conn: conn,
      project: project,
      source: source,
      destination: destination
    } do
      session(source, %{status: "running"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view |> open_move_panel() |> preview(destination)
      render_click(view, "toggle_move_force", %{})

      render_click(view, "confirm_move", %{})
      html = render_async(view)

      assert html =~ "Moved"
      assert html =~ "forced past blocker"
      assert Repo.get!(Project, project.id).directory == destination
      assert File.dir?(destination)
    end

    test "refuses to move anything before a preview has been run", %{
      conn: conn,
      project: project,
      source: source,
      destination: destination
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      html =
        view
        |> open_move_panel()
        |> render_click("confirm_move", %{})

      assert html =~ "Preview the move first"
      assert File.dir?(source)
      refute File.exists?(destination)
    end
  end

  describe "post-move side effects" do
    # `OrcaHub.Projects.MoveSideEffects` cannot fail the move — by the time it
    # runs the directory has moved and the rows are rewritten — so it reports
    # problems as notes in the SAME `side_effects` list, prefixed "WARNING: ".
    # Rendering the list flat would show "Claude's history was NOT migrated"
    # as an ordinary success bullet. A LiveView test cannot inject a
    # `move_result` assign, so the classification the template branches on is
    # asserted directly.
    test "WARNING: notes are separated from the ordinary ones" do
      done = "Renamed Claude's history/memory directory /a -> /b."
      repointed = "Repointed 3 memory-service memories from project slug -a to -b."
      orphaned = "WARNING: Claude's history/memory directory was NOT migrated — it exists."
      unfinished = "WARNING: the memory-service migration for /a -> /b did not finish."

      notes = [done, orphaned, repointed, unfinished]

      assert OrcaHubWeb.ProjectLive.Show.side_effect_problems(notes) == [orphaned, unfinished]
      assert OrcaHubWeb.ProjectLive.Show.side_effect_notes(notes) == [done, repointed]
    end

    test "no side effects at all is a normal outcome, not a problem" do
      assert OrcaHubWeb.ProjectLive.Show.side_effect_problems([]) == []
      assert OrcaHubWeb.ProjectLive.Show.side_effect_notes([]) == []
    end
  end
end
