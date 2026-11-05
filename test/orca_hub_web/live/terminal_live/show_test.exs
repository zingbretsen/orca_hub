defmodule OrcaHubWeb.TerminalLive.ShowTest do
  @moduledoc """
  Coverage for `find_terminal!/1`'s fan-out removal (perf_audit_admin_pages.md
  §2b): the hub+agent topology has ONE database, so `HubRPC.get_terminal/1`
  already resolves correctly regardless of which node asks — fanning the
  lookup out to every connected node and waiting for the slowest was pure
  overhead, not a correctness requirement. These tests pin the two things
  that removal must still get right: the terminal resolves at all, and a
  missing id still raises the same way it did before (`Ecto.NoResultsError`).
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, Terminals}

  setup do
    dir = Path.join(System.tmp_dir!(), "terminal_show_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "terminal-show-test-#{System.unique_integer([:positive])}",
        directory: dir,
        node: to_string(node())
      })

    {:ok, terminal} =
      Terminals.create_terminal(%{name: "t1", directory: dir, project_id: project.id})

    {:ok, terminal: terminal}
  end

  test "mounts and resolves the terminal via a direct HubRPC call", %{
    conn: conn,
    terminal: terminal
  } do
    {:ok, _view, html} = live(conn, ~p"/terminals/#{terminal.id}")
    assert html =~ terminal.name
  end

  test "a terminal owned by a remote (but currently offline) runner_node still resolves", %{
    conn: conn,
    terminal: terminal
  } do
    {:ok, terminal} = Terminals.update_terminal(terminal, %{runner_node: "orca@some-agent"})

    {:ok, _view, html} = live(conn, ~p"/terminals/#{terminal.id}")
    assert html =~ terminal.name
  end

  describe "status follows the runner, not just the row" do
    test "a row left running with no runner shows dead and offers Start, not Stop", %{
      conn: conn,
      terminal: terminal
    } do
      {:ok, terminal} =
        Terminals.update_terminal(terminal, %{
          status: "running",
          runner_node: Atom.to_string(node())
        })

      {:ok, view, _html} = live(conn, ~p"/terminals/#{terminal.id}")

      assert has_element?(view, "span.badge", "dead")
      assert has_element?(view, "button", "Start")
      refute has_element?(view, "button", "Stop")
      refute has_element?(view, "#terminal-#{terminal.id}")
    end

    test "Stop on a terminal whose node is offline says so instead of doing nothing", %{
      conn: conn,
      terminal: terminal
    } do
      {:ok, terminal} =
        Terminals.update_terminal(terminal, %{status: "running", runner_node: "orca@some-agent"})

      {:ok, view, _html} = live(conn, ~p"/terminals/#{terminal.id}")
      assert has_element?(view, "span.badge", "node offline")

      html = view |> element("button", "Stop") |> render_click()

      assert html =~ "is not currently connected"
      assert Terminals.get_terminal(terminal.id).status == "running"
    end

    test "a status broadcast for this terminal updates the page", %{
      conn: conn,
      terminal: terminal
    } do
      {:ok, view, _html} = live(conn, ~p"/terminals/#{terminal.id}")

      {:ok, _} = Terminals.update_terminal(terminal, %{status: "dead"})
      OrcaHub.TerminalRunner.broadcast(terminal.id, {:terminal_exit, 7})

      assert render(view) =~ "Shell exited with code 7."
    end
  end

  test "an unknown id raises Ecto.NoResultsError, same as before the fan-out removal", %{
    conn: conn
  } do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/terminals/#{Ecto.UUID.generate()}")
    end
  end
end
