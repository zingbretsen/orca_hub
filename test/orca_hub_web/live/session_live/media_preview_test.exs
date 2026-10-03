defmodule OrcaHubWeb.SessionLive.MediaPreviewTest do
  @moduledoc """
  ORCAHUB3-77: images and videos open in the session file panel as a
  preview tab (`<img>`/`<video>` pointed at the inline download route)
  instead of being text-loaded — from the file tree, from a path in the
  message feed, or via the `open_file` tool. Like an artifact's iframe
  (ORCAHUB3-130), the element renders only in the on-screen shell, so a
  `<video>` is never loaded twice.
  """

  # async: false — ensure_runner_started/3 starts a real SessionRunner
  # under the shared OrcaHub.SessionSupervisor (see show_test.exs).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, SessionSupervisor, Sessions}

  # Distinctive bytes, so a test can tell whether they were text-loaded
  # into the page.
  @png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "PNG-BYTES-MARKER" <> <<0, 255, 254>>
  @mp4 "MP4-BYTES-MARKER" <> <<0, 0, 0, 24, 102, 116, 121, 112, 255>>

  setup do
    dir = Path.join(System.tmp_dir!(), "media_preview_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "shots"))
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(Path.join([dir, "shots", "home page.png"]), @png)
    File.write!(Path.join(dir, "clip.mp4"), @mp4)
    File.write!(Path.join(dir, "bundle.zip"), <<80, 75, 3, 4, 0, 255, 254, 253>>)
    File.write!(Path.join(dir, "notes.md"), "# Notes\n")

    {:ok, project} =
      Projects.create_project(%{name: "media-preview-test", directory: dir, node: "n1@x"})

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        project_id: project.id,
        code_exec: false,
        runner_node: Atom.to_string(node())
      })

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id),
        do: SessionSupervisor.stop_session(session.id)
    end)

    {:ok, session: session, dir: dir}
  end

  describe "selecting a media file in the file tree" do
    for layout <- ["desktop", "mobile"] do
      @layout layout
      test "a .png opens an <img> preview pointed at the inline route (#{layout})", %{
        conn: conn,
        session: session
      } do
        view = open_panel(conn, session, @layout)

        select_in_tree(view, @layout, "shots/home page.png")

        assert [img] = media_elements(view, "img")
        assert attr(img, "id") == "media-#{@layout}-#{:erlang.phash2("shots/home page.png")}"
        assert_inline_src(attr(img, "src"), session, "shots/home page.png")

        html = render(view)
        refute html =~ "PNG-BYTES-MARKER"

        assert html =~
                 ~s(href="/sessions/#{session.id}/files/download?path=shots%2Fhome+page.png")
      end

      test "a .mp4 opens a <video controls playsinline preload=metadata> (#{layout})", %{
        conn: conn,
        session: session
      } do
        view = open_panel(conn, session, @layout)

        select_in_tree(view, @layout, "clip.mp4")

        assert [video] = media_elements(view, "video")
        assert_inline_src(attr(video, "src"), session, "clip.mp4")
        assert attr(video, "preload") == "metadata"
        assert attr(video, "controls") != nil
        assert attr(video, "playsinline") != nil
        refute render(view) =~ "MP4-BYTES-MARKER"
      end
    end

    test "the preview renders in the on-screen shell only, never a second hidden <video>", %{
      conn: conn,
      session: session
    } do
      view = open_panel(conn, session, "desktop")
      select_in_tree(view, "desktop", "clip.mp4")

      assert [video] = media_elements(view, "video")
      assert attr(video, "id") =~ "media-desktop-"

      # A breakpoint crossing moves it to the other shell, same src.
      src = attr(video, "src")
      view |> element("#panel-layout") |> render_hook("panel_layout", %{"layout" => "mobile"})

      assert [moved] = media_elements(view, "video")
      assert attr(moved, "id") =~ "media-mobile-"
      assert attr(moved, "src") == src
    end

    test "an unknown layout renders both shells, like an artifact (no blank panel)", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      send(view.pid, {:file_selected, "clip.mp4"})

      assert length(media_elements(view, "video")) == 2
    end

    test "a non-media binary stays download-only: no select button, just the download link", %{
      conn: conn,
      session: session
    } do
      view = open_panel(conn, session, "desktop")
      tree = view |> element("#session-file-tree") |> render()

      refute tree =~ ~s(phx-value-path="bundle.zip")
      assert tree =~ ~s(title="No preview — download only")
      assert tree =~ ~s(href="/sessions/#{session.id}/files/download?path=bundle.zip")

      # Media and text files are selectable.
      assert tree =~ ~s(phx-value-path="clip.mp4")
      assert tree =~ ~s(phx-value-path="notes.md")
    end

    test "a media tab can't be saved over, even by a crafted event", %{
      conn: conn,
      session: session,
      dir: dir
    } do
      view = open_panel(conn, session, "desktop")
      select_in_tree(view, "desktop", "clip.mp4")

      render_hook(view, "save_file", %{"content" => "clobbered"})

      assert File.read!(Path.join(dir, "clip.mp4")) == @mp4
      assert [_video] = media_elements(view, "video")
    end

    test "an overwritten file re-versions the src so the browser re-fetches it", %{
      conn: conn,
      session: session,
      dir: dir
    } do
      view = open_panel(conn, session, "desktop")
      select_in_tree(view, "desktop", "shots/home page.png")
      [img] = media_elements(view, "img")
      before = attr(img, "src")

      later = System.os_time(:second) + 120
      File.touch!(Path.join([dir, "shots", "home page.png"]), later)
      send(view.pid, :poll_file_changes)

      [img] = media_elements(view, "img")
      assert attr(img, "src") != before
      assert_inline_src(attr(img, "src"), session, "shots/home page.png")
    end
  end

  describe "opening a media path from the message feed" do
    test "clicking a Read tool call's .mp4 path opens a preview, not a text load", %{
      conn: conn,
      session: session,
      dir: dir
    } do
      path = Path.join(dir, "clip.mp4")
      tool_use_message(session, "Read", path)

      {:ok, view, _html} = live(with_layout(conn, "desktop"), ~p"/sessions/#{session.id}")

      view
      |> element(~s(button[phx-click="open_file"][phx-value-path="#{path}"]))
      |> render_click()

      # The absolute path inside the session dir is made relative.
      assert [video] = media_elements(view, "video")
      assert_inline_src(attr(video, "src"), session, "clip.mp4")
      refute has_element?(view, "#file-content-desktop")
      refute render(view) =~ "MP4-BYTES-MARKER"
    end

    test "the open_file tool opens a media path as a preview too", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(with_layout(conn, "desktop"), ~p"/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:open_file, "shots/home page.png", nil}
      )

      assert [img] = media_elements(view, "img")
      assert_inline_src(attr(img, "src"), session, "shots/home page.png")
    end

    test "a media path outside the session directory says it can't be previewed", %{
      conn: conn,
      session: session
    } do
      outside = Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.png")
      File.write!(outside, @png)
      on_exit(fn -> File.rm(outside) end)

      {:ok, view, _html} = live(with_layout(conn, "desktop"), ~p"/sessions/#{session.id}")
      render_hook(view, "open_file", %{"path" => outside})

      assert media_elements(view, "img") == []
      html = render(view)
      assert html =~ "outside the working directory, so it can&#39;t be previewed"
      refute html =~ "PNG-BYTES-MARKER"
      # The download route confines to the directory, so no link either.
      refute html =~ "files/download?path=#{URI.encode_www_form(outside)}"
    end

    test "a non-media binary opened from the feed gets a download-only tab, not a crash", %{
      conn: conn,
      session: session,
      dir: dir
    } do
      {:ok, view, _html} = live(with_layout(conn, "desktop"), ~p"/sessions/#{session.id}")
      render_hook(view, "open_file", %{"path" => Path.join(dir, "bundle.zip")})

      html = render(view)
      assert html =~ "isn&#39;t text and has no preview"
      assert html =~ ~s(href="/sessions/#{session.id}/files/download?path=bundle.zip")
      refute has_element?(view, "#file-content-desktop")
    end

    test "a text path from the feed still opens as text", %{conn: conn, session: session} do
      {:ok, view, _html} = live(with_layout(conn, "desktop"), ~p"/sessions/#{session.id}")
      render_hook(view, "open_file", %{"path" => "notes.md"})

      assert render(view) =~ "Notes"
      assert media_elements(view, "img") == []
    end
  end

  defp with_layout(conn, layout), do: put_connect_params(conn, %{"panel_layout" => layout})

  defp open_panel(conn, session, layout) do
    {:ok, view, _html} = live(with_layout(conn, layout), ~p"/sessions/#{session.id}")
    render_click(view, "toggle_file_browser", %{})
    view
  end

  # Clicks the row in the tree of the given shell, which sends the
  # LiveView {:file_selected, path}. A nested path's directory is expanded
  # first, as a user would, unless the tree prefetched it already.
  defp select_in_tree(view, layout, path) do
    tree = if layout == "desktop", do: "#session-file-tree", else: "#mobile-file-tree"
    row = ~s(#{tree} button[phx-click="select_file"][phx-value-path="#{path}"])

    unless has_element?(view, row) do
      view
      |> element("#{tree} summary", Path.dirname(path))
      |> render_click()
    end

    view |> element(row) |> render_click()
  end

  defp media_elements(view, tag) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(~s(#{tag}[id^="media-"]))
  end

  defp attr(element, name) do
    case Floki.attribute(element, name) do
      [value] -> value
      [] -> nil
    end
  end

  defp assert_inline_src(src, session, path) do
    uri = URI.parse(src)
    assert uri.path == "/sessions/#{session.id}/files/download"
    query = URI.decode_query(uri.query)
    assert query["path"] == path
    assert query["disposition"] == "inline"
    assert query["v"] =~ ~r/\A\d+\z/
  end

  defp tool_use_message(session, name, path) do
    {:ok, _} =
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "toolu_media_#{System.unique_integer([:positive])}",
                "name" => name,
                "input" => %{"file_path" => path}
              }
            ]
          }
        }
      })
  end
end
