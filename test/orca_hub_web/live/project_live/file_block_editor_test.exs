defmodule OrcaHubWeb.ProjectLive.FileBlockEditorTest do
  @moduledoc """
  Regression coverage for the project file viewer's tap-to-edit/delete
  markdown block editing (`BlockEditor.block_editor`, scope
  `"project_file"`) — this behavior predates the Agent Memory block-editing
  generalization (see `OrcaHubWeb.ProjectLive.AgentMemoryTest`) and must
  keep working unchanged after that refactor.
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.Projects

  setup do
    dir = Path.join(System.tmp_dir!(), "file_block_editor_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(Path.join(dir, "NOTES.md"), """
    First paragraph.

    Second paragraph.
    """)

    {:ok, project} = Projects.create_project(%{name: "block-editor-project", directory: dir})

    {:ok, project: project, dir: dir}
  end

  test "viewing a markdown file renders it as tap-to-edit blocks", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}?file=NOTES.md")

    assert html =~ "First paragraph."
    assert html =~ "Second paragraph."
    assert html =~ ~s(phx-click="edit_block")
    assert html =~ ~s(phx-value-scope="project_file")
  end

  test "editing a block persists the change via Projects.save_file", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=NOTES.md")

    view
    |> element(~s([phx-click=edit_block][phx-value-index="0"]))
    |> render_click()

    assert has_element?(view, "#file-block-editor-0")

    view
    |> element("form[phx-submit=save_block]")
    |> render_submit(%{"content" => "Updated first paragraph."})

    content = File.read!(Path.join(dir, "NOTES.md"))
    assert content =~ "Updated first paragraph."
    assert content =~ "Second paragraph."
    refute content =~ "First paragraph."
  end

  test "deleting a block persists the removal via Projects.save_file", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=NOTES.md")

    view
    |> element(~s([phx-click=delete_block][phx-value-index="0"]))
    |> render_click()

    content = File.read!(Path.join(dir, "NOTES.md"))
    refute content =~ "First paragraph."
    assert content =~ "Second paragraph."
  end
end
