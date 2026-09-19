defmodule OrcaHubWeb.SessionLive.IndexArchiveTest do
  @moduledoc """
  Cascading archive coverage for the `/sessions` index: archiving a session
  (single or bulk-selected) also archives every unarchived descendant in its
  spawn subtree, skips a still-running/waiting descendant without pruning
  the rest of its subtree, and the 5-second undo toast restores the exact
  set that was actually archived — not just the one session that was
  clicked.
  """

  # async: false — `archive`/`archive_selected` route through
  # `Cluster.stop_session/2`, which looks the session up in
  # `OrcaHub.SessionRegistry` and needs the DB sandbox in shared mode (same
  # rationale as index_test.exs/show_test.exs).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Sessions

  defp create!(attrs) do
    {:ok, session} =
      Sessions.create_session(Map.merge(%{runner_node: Atom.to_string(node())}, attrs))

    session
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "index_archive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    root = create!(%{directory: dir, status: "idle"})
    child = create!(%{directory: dir, status: "idle", parent_session_id: root.id})
    grandchild = create!(%{directory: dir, status: "idle", parent_session_id: child.id})

    %{dir: dir, root: root, child: child, grandchild: grandchild}
  end

  test "clicking archive on the root cascades into every descendant", %{
    conn: conn,
    root: root,
    child: child,
    grandchild: grandchild
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions")

    render_click(view, "archive", %{"id" => root.id})

    refute is_nil(Sessions.get_session!(root.id).archived_at)
    refute is_nil(Sessions.get_session!(child.id).archived_at)
    refute is_nil(Sessions.get_session!(grandchild.id).archived_at)
  end

  test "a running descendant is skipped without pruning its own idle children", %{
    conn: conn,
    root: root,
    child: child,
    grandchild: grandchild
  } do
    {:ok, _} = Sessions.update_session(child, %{status: "running"})

    {:ok, view, _html} = live(conn, ~p"/sessions")
    render_click(view, "archive", %{"id" => root.id})

    refute is_nil(Sessions.get_session!(root.id).archived_at)
    assert Sessions.get_session!(child.id).archived_at == nil
    refute is_nil(Sessions.get_session!(grandchild.id).archived_at)
  end

  test "the undo toast restores the root plus every cascaded descendant", %{
    conn: conn,
    root: root,
    child: child,
    grandchild: grandchild
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions")

    html = render_click(view, "archive", %{"id" => root.id})
    assert html =~ "Session + 2 children archived"

    render_click(view, "undo_archive")

    assert Sessions.get_session!(root.id).archived_at == nil
    assert Sessions.get_session!(child.id).archived_at == nil
    assert Sessions.get_session!(grandchild.id).archived_at == nil
  end

  test "the ?undo[] query param (as set by SessionLive.Show's archive redirect) also restores the full set",
       %{conn: conn, root: root, child: child, grandchild: grandchild} do
    Sessions.archive_session(root)
    Sessions.archive_session(child)
    Sessions.archive_session(grandchild)

    {:ok, view, _html} =
      live(conn, ~p"/sessions?#{[undo: [root.id, child.id, grandchild.id]]}")

    render_click(view, "undo_archive")

    assert Sessions.get_session!(root.id).archived_at == nil
    assert Sessions.get_session!(child.id).archived_at == nil
    assert Sessions.get_session!(grandchild.id).archived_at == nil
  end

  test "archive_selected dedupes a selection that includes both an ancestor and its descendant",
       %{conn: conn, root: root, child: child, grandchild: grandchild} do
    {:ok, view, _html} = live(conn, ~p"/sessions")

    render_click(view, "toggle_session", %{"id" => root.id})
    render_click(view, "toggle_session", %{"id" => grandchild.id})

    render_click(view, "archive_selected")

    # root's cascade already covers grandchild — archived exactly once each,
    # not double-archived via two independent cascades.
    refute is_nil(Sessions.get_session!(root.id).archived_at)
    refute is_nil(Sessions.get_session!(child.id).archived_at)
    refute is_nil(Sessions.get_session!(grandchild.id).archived_at)
  end
end
