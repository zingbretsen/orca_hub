defmodule OrcaHubWeb.ProjectLive.MediaPreviewTest do
  @moduledoc """
  ORCAHUB3-77 on the project page's file viewer: selecting an image or
  video previews it (`<img>`/`<video>` pointed at the project's inline
  download route) instead of text-loading it, and it can't be edited or
  saved. A non-media binary stays download-only.
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.Projects

  @png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "PNG-BYTES-MARKER" <> <<0, 255, 254>>
  @mp4 "MP4-BYTES-MARKER" <> <<0, 0, 0, 24, 102, 116, 121, 112, 255>>

  setup do
    dir =
      Path.join(System.tmp_dir!(), "media_preview_project_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(Path.join(dir, "chart.png"), @png)
    File.write!(Path.join(dir, "demo.mp4"), @mp4)
    File.write!(Path.join(dir, "bundle.zip"), <<80, 75, 3, 4, 0, 255, 254, 253>>)
    File.write!(Path.join(dir, "notes.txt"), "plain notes")

    {:ok, project} =
      Projects.create_project(%{
        name: "media-preview-project-#{System.unique_integer([:positive])}",
        directory: dir
      })

    {:ok, project: project, dir: dir}
  end

  test "selecting a .png in the tree previews it with an <img>", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    select_in_tree(view, "chart.png")

    assert [img] = find(view, "img#project-file-media")
    assert_inline_src(attr(img, "src"), project, "chart.png")

    html = render(view)
    refute html =~ "PNG-BYTES-MARKER"
    assert html =~ ~s(href="/projects/#{project.id}/files/download?path=chart.png")
    # Nothing to edit: no Edit/Raw Edit button for a preview.
    refute has_element?(view, ~s(button[phx-click="edit_file"]))
  end

  test "selecting a .mp4 in the tree previews it with a <video>", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    select_in_tree(view, "demo.mp4")

    assert [video] = find(view, "video#project-file-media")
    assert_inline_src(attr(video, "src"), project, "demo.mp4")
    assert attr(video, "preload") == "metadata"
    assert attr(video, "controls") != nil
    assert attr(video, "playsinline") != nil
    refute render(view) =~ "MP4-BYTES-MARKER"
  end

  test "?file= deep-links a media file to its preview", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.id}?file=demo.mp4")

    refute html =~ "MP4-BYTES-MARKER"
    assert [video] = find(view, "video#project-file-media")
    assert_inline_src(attr(video, "src"), project, "demo.mp4")
  end

  test "a non-media binary stays download-only in the tree", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    tree = view |> element("#file-tree") |> render()

    refute tree =~ ~s(phx-value-path="bundle.zip")
    assert tree =~ ~s(title="No preview — download only")
    assert tree =~ ~s(href="/projects/#{project.id}/files/download?path=bundle.zip")
    assert tree =~ ~s(phx-value-path="chart.png")
  end

  test "a previewed file can't be edited or saved over, even by crafted events", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    select_in_tree(view, "demo.mp4")

    render_click(view, "edit_file", %{})
    refute has_element?(view, ~s(textarea[name="content"]))

    render_submit(view, "save_file", %{"content" => "clobbered"})
    assert File.read!(Path.join(dir, "demo.mp4")) == @mp4
  end

  test "switching from a preview back to a text file shows the text", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    select_in_tree(view, "chart.png")
    select_in_tree(view, "notes.txt")

    assert find(view, "#project-file-media") == []
    assert render(view) =~ "plain notes"
  end

  test "a new file started from a preview doesn't keep showing the preview", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    select_in_tree(view, "chart.png")

    render_click(view, "new_file", %{})
    render_submit(view, "save_file", %{"filename" => "fresh.txt", "content" => "fresh text"})

    assert find(view, "#project-file-media") == []
    assert render(view) =~ "fresh text"
  end

  defp select_in_tree(view, path) do
    view
    |> element(~s(#file-tree button[phx-click="select_file"][phx-value-path="#{path}"]))
    |> render_click()
  end

  defp find(view, selector) do
    view |> render() |> Floki.parse_document!() |> Floki.find(selector)
  end

  defp attr(element, name) do
    case Floki.attribute(element, name) do
      [value] -> value
      [] -> nil
    end
  end

  defp assert_inline_src(src, project, path) do
    uri = URI.parse(src)
    assert uri.path == "/projects/#{project.id}/files/download"
    query = URI.decode_query(uri.query)
    assert query["path"] == path
    assert query["disposition"] == "inline"
    assert query["v"] =~ ~r/\A\d+\z/
  end
end
