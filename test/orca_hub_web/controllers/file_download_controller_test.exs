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

  defp get_resp_content_type(conn) do
    [content_type] = get_resp_header(conn, "content-type")
    content_type |> String.split(";") |> hd()
  end
end
