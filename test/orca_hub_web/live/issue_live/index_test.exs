defmodule OrcaHubWeb.IssueLive.IndexTest do
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Issues, Projects}

  setup do
    dir = Path.join(System.tmp_dir!(), "issue_index_test_#{System.unique_integer([:positive])}")

    {:ok, project} =
      Projects.create_project(%{name: "issue-index-test", directory: dir, node: "n1@x"})

    {:ok, project: project}
  end

  test "lists issues with title, status, category, and inserted_at", %{
    conn: conn,
    project: project
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "[agent-fr] Missing thing",
        project_id: project.id,
        description: "pain\n\n---\nCategory: tooling\n"
      })

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ issue.title
    assert html =~ "open"
    assert html =~ "tooling"
  end

  test "shows a dash when no category is parseable", %{conn: conn, project: project} do
    {:ok, _issue} =
      Issues.create_issue(%{
        title: "Human filed, no category",
        project_id: project.id,
        description: "just a description"
      })

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ "Human filed, no category"
    assert html =~ "—"
  end

  test "lists open issues before closed issues", %{conn: conn, project: project} do
    {:ok, closed} = Issues.create_issue(%{title: "Closed issue", project_id: project.id})
    {:ok, _} = Issues.update_issue(closed, %{status: "closed"})
    {:ok, _open} = Issues.create_issue(%{title: "Open issue", project_id: project.id})

    {:ok, _view, html} = live(conn, ~p"/issues")

    open_index = :binary.match(html, "Open issue") |> elem(0)
    closed_index = :binary.match(html, "Closed issue") |> elem(0)

    assert open_index < closed_index
  end

  test "closed issues render with dimmed styling", %{conn: conn, project: project} do
    {:ok, closed} = Issues.create_issue(%{title: "Dimmed issue", project_id: project.id})
    {:ok, _} = Issues.update_issue(closed, %{status: "closed"})

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ "opacity-50"
  end

  test "row links to the issue's show page", %{conn: conn, project: project} do
    {:ok, issue} = Issues.create_issue(%{title: "Linked issue", project_id: project.id})

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ ~p"/issues/#{issue.id}"
  end
end
