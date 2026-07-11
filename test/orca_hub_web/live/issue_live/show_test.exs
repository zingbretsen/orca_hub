defmodule OrcaHubWeb.IssueLive.ShowTest do
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Issues, Projects}

  setup do
    dir = Path.join(System.tmp_dir!(), "issue_show_test_#{System.unique_integer([:positive])}")

    {:ok, project} =
      Projects.create_project(%{name: "issue-show-test", directory: dir, node: "n1@x"})

    {:ok, project: project}
  end

  test "renders title, status, description (with provenance block), and notes", %{
    conn: conn,
    project: project
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "[agent-fr] Something broke",
        project_id: project.id,
        description: "The pain point.\n\n---\nSession: abc123\nCategory: tooling",
        notes: "Saw it again today."
      })

    {:ok, _view, html} = live(conn, ~p"/issues/#{issue.id}")

    assert html =~ "Something broke"
    assert html =~ "open"
    assert html =~ "The pain point."
    assert html =~ "Session: abc123"
    assert html =~ "Category: tooling"
    assert html =~ "Saw it again today."
  end

  test "omits the notes section when there are no notes", %{conn: conn, project: project} do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "No notes yet",
        project_id: project.id,
        description: "d"
      })

    {:ok, _view, html} = live(conn, ~p"/issues/#{issue.id}")

    refute html =~ "Notes</h3>"
  end

  test "raises Ecto.NoResultsError for a missing issue id", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/issues/#{Ecto.UUID.generate()}")
    end
  end
end
