defmodule OrcaHubWeb.FileDownloadControllerTest do
  @moduledoc """
  ORCAHUB3-76: `GET /projects/:id/files/download` and
  `GET /sessions/:id/files/download`. The security surface is
  `path` — the project/session `directory` (trusted root) and target node
  are always resolved server-side from the `:id`, never from the client —
  so the negative controls here are the point of the test file, not an
  afterthought.
  """
  use OrcaHubWeb.ConnCase, async: true

  alias OrcaHub.{Projects, Sessions}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "file_download_controller_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "file-download-test-#{System.unique_integer([:positive])}",
        directory: dir
      })

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        project_id: project.id,
        runner_node: Atom.to_string(node())
      })

    {:ok, dir: dir, project: project, session: session}
  end

  describe "GET /projects/:id/files/download" do
    test "downloads a regular file's exact bytes, with a content-disposition header", %{
      conn: conn,
      dir: dir,
      project: project
    } do
      File.write!(Path.join(dir, "notes.txt"), "hello world")

      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=notes.txt")

      assert conn.status == 200
      assert conn.resp_body == "hello world"
      assert get_resp_content_type(conn) == "text/plain"

      assert get_resp_header(conn, "content-disposition") |> hd() ==
               "attachment; filename=\"notes.txt\""

      # ORCAHUB3-75: agent-writable bytes on the app origin stay inert.
      assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "downloads a non-editable (binary) file — the whole point of ORCAHUB3-76", %{
      conn: conn,
      dir: dir,
      project: project
    } do
      binary = <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>
      File.write!(Path.join(dir, "diagram.png"), binary)

      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=diagram.png")

      assert conn.status == 200
      assert conn.resp_body == binary
      assert get_resp_content_type(conn) == "image/png"
    end

    test "a file spanning more than one 1MB chunk streams back intact", %{
      conn: conn,
      dir: dir,
      project: project
    } do
      big = String.duplicate("a", 2 * 1024 * 1024 + 17)
      File.write!(Path.join(dir, "big.txt"), big)

      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=big.txt")

      assert conn.status == 200
      assert byte_size(conn.resp_body) == byte_size(big)
      assert conn.resp_body == big
    end

    test "a nested file resolves relative to the project root", %{
      conn: conn,
      dir: dir,
      project: project
    } do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join([dir, "sub", "nested.txt"]), "nested")

      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=sub/nested.txt")

      assert conn.status == 200
      assert conn.resp_body == "nested"
    end

    test "404 for an unknown project id", %{conn: conn} do
      conn = get(conn, ~p"/projects/#{Ecto.UUID.generate()}/files/download?path=x.txt")
      assert conn.status == 404
    end

    test "400 for a `..` traversal attempt (negative control)", %{
      conn: conn,
      dir: dir,
      project: project
    } do
      secret = Path.join(System.tmp_dir!(), "secret_#{System.unique_integer([:positive])}.txt")
      File.write!(secret, "top secret")
      on_exit(fn -> File.rm(secret) end)

      rel = Path.join("..", Path.basename(secret))
      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=#{rel}")

      assert conn.status == 400
      refute conn.resp_body =~ "top secret"
      # sanity: prove the escape WOULD have worked without confinement
      assert File.read!(Path.join(dir, rel)) == "top secret"
    end

    test "400 for an absolute path outside the root (negative control)", %{
      conn: conn,
      project: project
    } do
      outside = Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.txt")
      File.write!(outside, "top secret")
      on_exit(fn -> File.rm(outside) end)

      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=#{outside}")

      assert conn.status == 400
      refute conn.resp_body =~ "top secret"
    end

    test "400 for a symlink pointing outside the root (negative control)", %{
      conn: conn,
      dir: dir,
      project: project
    } do
      outside =
        Path.join(System.tmp_dir!(), "outside_target_#{System.unique_integer([:positive])}.txt")

      File.write!(outside, "top secret")
      on_exit(fn -> File.rm(outside) end)
      File.ln_s!(outside, Path.join(dir, "escape.txt"))

      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=escape.txt")

      assert conn.status == 400
      refute conn.resp_body =~ "top secret"
    end

    test "400 for a directory passed as path (negative control)", %{
      conn: conn,
      dir: dir,
      project: project
    } do
      File.mkdir_p!(Path.join(dir, "subdir"))

      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=subdir")

      assert conn.status == 400
    end

    test "400 when path is missing", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.id}/files/download")
      assert conn.status == 400
    end

    test "404 when the path does not exist", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.id}/files/download?path=nope.txt")
      assert conn.status == 404
    end
  end

  describe "GET /sessions/:id/files/download" do
    test "downloads a file from the session's own directory", %{
      conn: conn,
      dir: dir,
      session: session
    } do
      File.write!(Path.join(dir, "log.txt"), "session bytes")

      conn = get(conn, ~p"/sessions/#{session.id}/files/download?path=log.txt")

      assert conn.status == 200
      assert conn.resp_body == "session bytes"
    end

    test "404 for an unknown session id", %{conn: conn} do
      conn = get(conn, ~p"/sessions/#{Ecto.UUID.generate()}/files/download?path=x.txt")
      assert conn.status == 404
    end

    test "400 for `..` traversal out of the session directory (negative control)", %{
      conn: conn,
      dir: dir,
      session: session
    } do
      secret =
        Path.join(System.tmp_dir!(), "session_secret_#{System.unique_integer([:positive])}.txt")

      File.write!(secret, "top secret")
      on_exit(fn -> File.rm(secret) end)

      rel = Path.join("..", Path.basename(secret))
      conn = get(conn, ~p"/sessions/#{session.id}/files/download?path=#{rel}")

      assert conn.status == 400
      refute conn.resp_body =~ "top secret"
      assert File.read!(Path.join(dir, rel)) == "top secret"
    end

    test "503 (not a crash) when the session has no assigned node", %{
      conn: conn,
      dir: dir,
      project: project
    } do
      {:ok, unassigned} = Sessions.create_session(%{directory: dir, project_id: project.id})

      conn = get(conn, ~p"/sessions/#{unassigned.id}/files/download?path=x.txt")

      assert conn.status == 503
    end
  end

  # ORCAHUB3-77: the file viewers' image/video previews.
  describe "?disposition=inline" do
    setup %{dir: dir} do
      # 1000 distinct-ish bytes, so a wrong offset can't pass by accident.
      video = for i <- 0..999, into: <<>>, do: <<rem(i * 7, 256)>>
      File.write!(Path.join(dir, "clip.mp4"), video)
      File.write!(Path.join(dir, "shot.png"), <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>)
      {:ok, video: video}
    end

    test "serves an allow-listed image inline, keeping the sandbox and nosniff headers", %{
      conn: conn,
      session: session
    } do
      conn = get(conn, inline_path(session, "shot.png"))

      assert conn.status == 200
      assert conn.resp_body == <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="shot.png")]
      assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-length") == ["11"]
    end

    test "serves an allow-listed video inline, on the project route too", %{
      conn: conn,
      project: project,
      video: video
    } do
      conn =
        get(
          conn,
          ~p"/projects/#{project.id}/files/download?#{[path: "clip.mp4", disposition: "inline"]}"
        )

      assert conn.status == 200
      assert conn.resp_body == video
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="clip.mp4")]
      assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
      assert get_resp_header(conn, "content-length") == ["1000"]
    end

    test "SVG is previewable — inline, and the sandbox CSP keeps its scripts dead", %{
      conn: conn,
      dir: dir,
      session: session
    } do
      File.write!(Path.join(dir, "chart.svg"), ~s(<svg xmlns="http://www.w3.org/2000/svg"/>))

      conn = get(conn, inline_path(session, "chart.svg"))

      assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="chart.svg")]
      assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    for {name, type} <- [
          {"page.html", "text/html"},
          {"doc.pdf", "application/pdf"},
          {"notes.txt", "text/plain"},
          {"blob.bin", "application/octet-stream"}
        ] do
      @name name
      test "a non-media #{type} file still gets attachment (negative control)", %{
        conn: conn,
        dir: dir,
        session: session
      } do
        File.write!(Path.join(dir, @name), "<script>alert(1)</script>")

        conn = get(conn, inline_path(session, @name))

        assert conn.status == 200

        assert get_resp_header(conn, "content-disposition") == [
                 ~s(attachment; filename="#{@name}")
               ]

        assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
        # Not a preview response, so no ranges either.
        assert get_resp_header(conn, "accept-ranges") == []
      end
    end

    test "a non-media file ignores Range, returning the whole file", %{
      conn: conn,
      dir: dir,
      session: session
    } do
      File.write!(Path.join(dir, "page.html"), "0123456789")

      conn =
        conn
        |> put_req_header("range", "bytes=2-4")
        |> get(inline_path(session, "page.html"))

      assert conn.status == 200
      assert conn.resp_body == "0123456789"
    end

    test "a plain download (no disposition) of a media file stays attachment and ignores Range",
         %{conn: conn, session: session, video: video} do
      conn =
        conn
        |> put_req_header("range", "bytes=0-9")
        |> get(~p"/sessions/#{session.id}/files/download?path=clip.mp4")

      assert conn.status == 200
      assert conn.resp_body == video
      assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="clip.mp4")]
      assert get_resp_header(conn, "accept-ranges") == []
    end

    test "inline still confines the path (negative control)", %{conn: conn, session: session} do
      outside = Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.png")
      File.write!(outside, "top secret")
      on_exit(fn -> File.rm(outside) end)

      conn = get(conn, inline_path(session, outside))

      assert conn.status == 400
      refute conn.resp_body =~ "top secret"
    end
  end

  describe "Range requests on an inline preview" do
    setup %{dir: dir} do
      video = for i <- 0..999, into: <<>>, do: <<rem(i * 7, 256)>>
      File.write!(Path.join(dir, "clip.mp4"), video)
      {:ok, video: video}
    end

    test "bytes=a-b returns 206 with exactly that slice", %{conn: conn} = ctx do
      conn = ranged(conn, ctx, "bytes=100-199")

      assert conn.status == 206
      assert conn.resp_body == binary_part(ctx.video, 100, 100)
      assert get_resp_header(conn, "content-range") == ["bytes 100-199/1000"]
      assert get_resp_header(conn, "content-length") == ["100"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="clip.mp4")]
      assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "bytes=0-1 (iOS Safari's probe) returns the first two bytes and the total", ctx do
      conn = ranged(ctx.conn, ctx, "bytes=0-1")

      assert conn.status == 206
      assert conn.resp_body == binary_part(ctx.video, 0, 2)
      assert get_resp_header(conn, "content-range") == ["bytes 0-1/1000"]
      assert get_resp_header(conn, "content-length") == ["2"]
    end

    test "open-ended bytes=a- runs to the end of the file", ctx do
      conn = ranged(ctx.conn, ctx, "bytes=900-")

      assert conn.status == 206
      assert conn.resp_body == binary_part(ctx.video, 900, 100)
      assert get_resp_header(conn, "content-range") == ["bytes 900-999/1000"]
      assert get_resp_header(conn, "content-length") == ["100"]
    end

    test "bytes=0- on a small file is the whole file, as a 206", ctx do
      conn = ranged(ctx.conn, ctx, "bytes=0-")

      assert conn.status == 206
      assert conn.resp_body == ctx.video
      assert get_resp_header(conn, "content-range") == ["bytes 0-999/1000"]
      assert get_resp_header(conn, "content-length") == ["1000"]
    end

    test "suffix bytes=-n returns the last n bytes", ctx do
      conn = ranged(ctx.conn, ctx, "bytes=-50")

      assert conn.status == 206
      assert conn.resp_body == binary_part(ctx.video, 950, 50)
      assert get_resp_header(conn, "content-range") == ["bytes 950-999/1000"]
      assert get_resp_header(conn, "content-length") == ["50"]
    end

    test "a suffix longer than the file returns the whole file", ctx do
      conn = ranged(ctx.conn, ctx, "bytes=-5000")

      assert conn.status == 206
      assert conn.resp_body == ctx.video
      assert get_resp_header(conn, "content-range") == ["bytes 0-999/1000"]
    end

    test "a last-byte past the end is clamped to the file size", ctx do
      conn = ranged(ctx.conn, ctx, "bytes=990-5000")

      assert conn.status == 206
      assert conn.resp_body == binary_part(ctx.video, 990, 10)
      assert get_resp_header(conn, "content-range") == ["bytes 990-999/1000"]
      assert get_resp_header(conn, "content-length") == ["10"]
    end

    for header <- ["bytes=1000-", "bytes=5000-6000", "bytes=-0"] do
      @header header
      test "an unsatisfiable range (#{header}) is a 416 with the size", ctx do
        conn = ranged(ctx.conn, ctx, @header)

        assert conn.status == 416
        assert get_resp_header(conn, "content-range") == ["bytes */1000"]
        assert get_resp_header(conn, "content-disposition") == []
        refute conn.resp_body =~ binary_part(ctx.video, 0, 10)
      end
    end

    test "any range on an empty file is a 416", %{conn: conn, dir: dir, session: session} do
      File.write!(Path.join(dir, "empty.mp4"), "")

      conn =
        conn
        |> put_req_header("range", "bytes=0-")
        |> get(inline_path(session, "empty.mp4"))

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */0"]
    end

    for header <- ["bytes=0-1,5-6", "bytes=5-2", "items=0-1", "bytes=-", "bytes=abc"] do
      @header header
      test "a multi-range or malformed range (#{header}) is ignored: 200, whole file", ctx do
        conn = ranged(ctx.conn, ctx, @header)

        assert conn.status == 200
        assert conn.resp_body == ctx.video
        assert get_resp_header(conn, "content-length") == ["1000"]
        assert get_resp_header(conn, "content-range") == []
      end
    end

    test "If-Range is ignored along with its Range — we send no validators, so it can't match",
         ctx do
      conn =
        ctx.conn
        |> put_req_header("if-range", ~s("some-etag"))
        |> ranged(ctx, "bytes=0-1")

      assert conn.status == 200
      assert conn.resp_body == ctx.video
    end

    test "a range spanning more than one 1MB rpc chunk comes back intact", %{
      conn: conn,
      dir: dir,
      session: session
    } do
      big = for i <- 0..(3 * 1024 * 1024 - 1), into: <<>>, do: <<rem(i, 251)>>
      File.write!(Path.join(dir, "big.mp4"), big)
      first = 1024 * 1024 - 10

      conn =
        conn
        |> put_req_header("range", "bytes=#{first}-")
        |> get(inline_path(session, "big.mp4"))

      assert conn.status == 206
      assert conn.resp_body == binary_part(big, first, byte_size(big) - first)

      assert get_resp_header(conn, "content-range") == [
               "bytes #{first}-#{byte_size(big) - 1}/#{byte_size(big)}"
             ]
    end

    test "an open-ended range on a file bigger than one 206 is clamped to a short 206", %{
      conn: conn,
      dir: dir,
      session: session
    } do
      # One byte past the 8MB per-response clamp. A sparse file: only the
      # size matters here.
      size = 8 * 1024 * 1024 + 1
      path = Path.join(dir, "long.mp4")
      {:ok, file} = :file.open(path, [:write, :binary])
      {:ok, _} = :file.position(file, size - 1)
      :ok = :file.write(file, <<1>>)
      :ok = :file.close(file)

      conn =
        conn
        |> put_req_header("range", "bytes=0-")
        |> get(inline_path(session, "long.mp4"))

      assert conn.status == 206
      assert byte_size(conn.resp_body) == 8 * 1024 * 1024
      assert get_resp_header(conn, "content-range") == ["bytes 0-#{8 * 1024 * 1024 - 1}/#{size}"]
      assert get_resp_header(conn, "content-length") == ["#{8 * 1024 * 1024}"]
    end
  end

  describe "the whole-file size cap" do
    setup %{dir: dir} do
      # A sparse file one byte over the 200MB cap.
      size = 200 * 1024 * 1024 + 1
      path = Path.join(dir, "huge.mp4")
      {:ok, file} = :file.open(path, [:write, :binary])
      {:ok, _} = :file.position(file, size - 1)
      :ok = :file.write(file, <<7>>)
      :ok = :file.close(file)
      {:ok, size: size}
    end

    test "still refuses a whole-file read over 200MB with a 413", %{conn: conn, session: session} do
      assert get(conn, inline_path(session, "huge.mp4")).status == 413
      assert get(conn, ~p"/sessions/#{session.id}/files/download?path=huge.mp4").status == 413
    end

    test "but a ranged preview read can reach past it", %{
      conn: conn,
      session: session,
      size: size
    } do
      conn =
        conn
        |> put_req_header("range", "bytes=-1")
        |> get(inline_path(session, "huge.mp4"))

      assert conn.status == 206
      assert conn.resp_body == <<7>>
      assert get_resp_header(conn, "content-range") == ["bytes #{size - 1}-#{size - 1}/#{size}"]
    end
  end

  defp inline_path(session, path),
    do: ~p"/sessions/#{session.id}/files/download?#{[path: path, disposition: "inline"]}"

  defp ranged(conn, %{session: session}, range) do
    conn
    |> put_req_header("range", range)
    |> get(inline_path(session, "clip.mp4"))
  end

  defp get_resp_content_type(conn) do
    [content_type] = get_resp_header(conn, "content-type")
    content_type |> String.split(";") |> hd()
  end
end
