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

  @orca_send_script "<script>window.orca = { send: function(payload) { " <>
                      "window.parent.postMessage({type: \"orca:send\", payload: payload}, \"*\"); } };</script>"

  test "serves html content as text/html, prefixed with the (empty-data) ORCA_DATA script and the orca.send shim",
       %{
         conn: conn,
         project: project
       } do
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

    assert conn.resp_body ==
             "<script>window.ORCA_DATA = {};</script>" <>
               @orca_send_script <> "<html><body><h1>Hi</h1></body></html>"
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

    assert conn.resp_body ==
             "<script>window.ORCA_DATA = {};</script>" <> @orca_send_script <> "<p>v1</p>"
  end

  describe "ORCA_DATA injection (live-data channel)" do
    test "injects window.ORCA_DATA immediately after an opening <head> tag", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "with-head",
          kind: "html",
          content: "<html><head><title>T</title></head><body>Hi</body></html>"
        })

      {:ok, artifact} = Artifacts.update_artifact_data(artifact, %{"count" => 3})

      conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")

      assert conn.resp_body ==
               "<html><head><script>window.ORCA_DATA = {\"count\":3};</script>" <>
                 @orca_send_script <>
                 "<title>T</title></head><body>Hi</body></html>"
    end

    test "matches a <head> tag with attributes too", %{conn: conn, project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "head-with-attrs",
          kind: "html",
          content: ~s(<html><head lang="en"></head><body></body></html>)
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")

      assert conn.resp_body ==
               ~s(<html><head lang="en"><script>window.ORCA_DATA = {};</script>) <>
                 @orca_send_script <> ~s(</head><body></body></html>)
    end

    test "prepends window.ORCA_DATA when there's no <head> tag at all", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "no-head",
          kind: "html",
          content: "<p>hi</p>"
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")

      assert conn.resp_body ==
               "<script>window.ORCA_DATA = {};</script>" <> @orca_send_script <> "<p>hi</p>"
    end

    test "reflects the artifact's current data, not what it was saved with", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "live-data",
          kind: "html",
          content: "<p>hi</p>"
        })

      {:ok, artifact} = Artifacts.update_artifact_data(artifact, %{"n" => 1})
      conn1 = get(conn, ~p"/artifacts/#{artifact.id}/raw")
      assert conn1.resp_body =~ "{\"n\":1}"

      {:ok, artifact} = Artifacts.update_artifact_data(artifact, %{"n" => 2})
      conn2 = get(build_conn(), ~p"/artifacts/#{artifact.id}/raw")
      assert conn2.resp_body =~ "{\"n\":2}"
    end

    test "escapes </script> inside a data value so it can't break out of the injected tag", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "escape-test",
          kind: "html",
          content: "<html><head></head><body></body></html>"
        })

      payload = %{"evil" => "</script><script>alert(1)</script>"}
      {:ok, artifact} = Artifacts.update_artifact_data(artifact, payload)

      conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")
      body = conn.resp_body

      # Exactly two <script>/</script> pairs — ORCA_DATA + the orca.send
      # shim we inject. If the payload's literal "</script>" had survived
      # unescaped, this would be 4.
      assert length(String.split(body, "<script>")) == 3
      assert length(String.split(body, "</script>")) == 3

      [_, injected_json] = Regex.run(~r/window\.ORCA_DATA = (.*?);<\/script>/, body)
      assert Jason.decode!(injected_json) == payload
    end

    test "svg content is never touched by data injection", %{conn: conn, project: project} do
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"><circle r="5"/></svg>)

      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "svg-no-inject",
          kind: "svg",
          content: svg
        })

      {:ok, artifact} = Artifacts.update_artifact_data(artifact, %{"n" => 1})

      conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")
      assert conn.resp_body == svg
    end
  end

  describe "orca.send shim injection" do
    test "injected for html content, right after the ORCA_DATA script", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "send-shim-html",
          kind: "html",
          content: "<p>hi</p>"
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")

      assert conn.resp_body =~ @orca_send_script
      assert conn.resp_body =~ "window.orca = { send: function(payload)"
      assert conn.resp_body =~ ~s({type: "orca:send", payload: payload})
    end

    test "NOT injected for svg content", %{conn: conn, project: project} do
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"><circle r="5"/></svg>)

      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "send-shim-svg",
          kind: "svg",
          content: svg
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")
      refute conn.resp_body =~ "window.orca"
    end

    test "NOT injected for markdown content", %{conn: conn, project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "send-shim-markdown",
          kind: "markdown",
          content: "# Title"
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")
      refute conn.resp_body =~ "window.orca"
    end
  end

  defp get_resp_content_type(conn) do
    [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    content_type |> String.split(";") |> hd()
  end
end
