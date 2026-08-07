defmodule OrcaHubWeb.IssueLive.IndexTest do
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Issues, Projects}

  setup do
    dir = Path.join(System.tmp_dir!(), "issue_index_test_#{System.unique_integer([:positive])}")

    {:ok, project} =
      Projects.create_project(%{
        name: "issue-index-test",
        directory: dir,
        node: "n1@x",
        key_prefix: unique_key_prefix()
      })

    {:ok, project: project}
  end

  defp unique_key_prefix(base \\ "IDX") do
    (base <> Integer.to_string(System.unique_integer([:positive]))) |> String.slice(0, 10)
  end

  test "lists issues with short key, kind, and status", %{conn: conn, project: project} do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Missing thing",
        project_id: project.id,
        description: "pain",
        kind: "feature_request"
      })

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ issue.title
    assert html =~ Issues.render_key(issue)
    assert html =~ "open"
    assert html =~ "feature_request"
  end

  test "kind filter narrows the list to the selected kind", %{conn: conn, project: project} do
    {:ok, task} = Issues.create_issue(%{title: "A task", project_id: project.id, kind: "task"})

    {:ok, fr} =
      Issues.create_issue(%{
        title: "A feature request",
        project_id: project.id,
        kind: "feature_request"
      })

    {:ok, view, html} = live(conn, ~p"/issues")
    assert html =~ task.title
    assert html =~ fr.title

    html = view |> element("button", "Feature request") |> render_click()

    refute html =~ task.title
    assert html =~ fr.title
  end

  test "status filter defaults to showing everything, including closed", %{
    conn: conn,
    project: project
  } do
    {:ok, closed} = Issues.create_issue(%{title: "Closed issue", project_id: project.id})
    {:ok, _} = Issues.update_issue(closed, %{status: "closed"})
    {:ok, open} = Issues.create_issue(%{title: "Open issue", project_id: project.id})

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ closed.title
    assert html =~ open.title
  end

  test "status filter narrows to just the selected status", %{conn: conn, project: project} do
    {:ok, closed} = Issues.create_issue(%{title: "Closed issue", project_id: project.id})
    {:ok, _} = Issues.update_issue(closed, %{status: "closed"})
    {:ok, open} = Issues.create_issue(%{title: "Open issue", project_id: project.id})

    {:ok, view, _html} = live(conn, ~p"/issues")

    html = view |> element("button", "Open") |> render_click()

    assert html =~ open.title
    refute html =~ closed.title
  end

  test "closed issues render with dimmed styling", %{conn: conn, project: project} do
    {:ok, closed} = Issues.create_issue(%{title: "Dimmed issue", project_id: project.id})
    {:ok, _} = Issues.update_issue(closed, %{status: "closed"})

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ "opacity-50"
  end

  test "row links to the issue's show page via its short key", %{conn: conn, project: project} do
    {:ok, issue} = Issues.create_issue(%{title: "Linked issue", project_id: project.id})

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ ~p"/issues/#{Issues.render_key(issue)}"
  end

  test "an issue without a project key_prefix falls back to linking by id", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "issue_index_nokey_#{System.unique_integer([:positive])}")
    {:ok, project} = Projects.create_project(%{name: "no-prefix", directory: dir, node: "n1@x"})
    {:ok, issue} = Issues.create_issue(%{title: "Keyless issue", project_id: project.id})

    {:ok, _view, html} = live(conn, ~p"/issues")

    assert html =~ ~p"/issues/#{issue.id}"
  end
end
