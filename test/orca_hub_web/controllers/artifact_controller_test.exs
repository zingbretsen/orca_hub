defmodule OrcaHubWeb.ArtifactControllerTest do
  @moduledoc """
  Coverage for `GET /artifacts/:id/raw` — content-type by kind, markdown
  rendered server-side to minimal HTML, no app layout (a bare `send_resp`,
  so there's nothing to assert an absence of beyond the raw body itself).
  """
  use OrcaHubWeb.ConnCase, async: true

  alias OrcaHub.{Artifacts, Projects}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "artifact_controller_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "artifact-controller-test", directory: dir, node: "n1@x"})

    {:ok, project: project}
  end

  test "404 for an unknown id", %{conn: conn} do
    conn = get(conn, ~p"/artifacts/#{Ecto.UUID.generate()}/raw")
    assert conn.status == 404
  end

  test "404 (not a crash) for a non-uuid id", %{conn: conn} do
    conn = get(conn, ~p"/artifacts/not-a-uuid/raw")
    assert conn.status == 404
  end

  test "serves html content as text/html verbatim", %{conn: conn, project: project} do
    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: "html-artifact",
        kind: "html",
        content: "<html><body><h1>Hi</h1></body></html>"
      })

    conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")

    assert conn.status == 200
    assert get_resp_content_type(conn) == "text/html"
    assert conn.resp_body == "<html><body><h1>Hi</h1></body></html>"
  end

  test "serves svg content as image/svg+xml verbatim", %{conn: conn, project: project} do
    svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"><circle r="5"/></svg>)

    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: "svg-artifact",
        kind: "svg",
        content: svg
      })

    conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")

    assert conn.status == 200
    assert get_resp_content_type(conn) == "image/svg+xml"
    assert conn.resp_body == svg
  end

  test "renders markdown content to minimal HTML as text/html", %{conn: conn, project: project} do
    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: "markdown-artifact",
        kind: "markdown",
        content: "# Title\n\nSome **bold** text."
      })

    conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")

    assert conn.status == 200
    assert get_resp_content_type(conn) == "text/html"
    assert conn.resp_body =~ "<h1>"
    assert conn.resp_body =~ "Title</h1>"
    assert conn.resp_body =~ "<strong>bold</strong>"
    assert conn.resp_body =~ "<!doctype html>"
  end

  test "the ?v= cache-buster query param doesn't affect content", %{conn: conn, project: project} do
    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: "versioned-artifact",
        kind: "html",
        content: "<p>v1</p>"
      })

    conn = get(conn, ~p"/artifacts/#{artifact.id}/raw?v=#{artifact.version}")
    assert conn.status == 200
    assert conn.resp_body == "<p>v1</p>"
  end

  defp get_resp_content_type(conn) do
    [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    content_type |> String.split(";") |> hd()
  end
end
