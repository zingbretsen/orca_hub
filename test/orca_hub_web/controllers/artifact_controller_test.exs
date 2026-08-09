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

  # Regression guard for the `/artifacts` index route added alongside
  # `ArtifactLive.Index` — that route lives in a DIFFERENT scope
  # (`:browser`/live_session) than this one (`:artifact_raw`), and the two
  # have a different path-segment count (`/artifacts` vs `/artifacts/:id/raw`),
  # but assert explicitly that route precedence still resolves `/raw` to
  # this controller rather than to the LiveView.
  test "still serves raw bytes at /artifacts/:id/raw now that /artifacts (index) also exists", %{
    conn: conn,
    project: project
  } do
    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: "route-precedence",
        content: "<p>still raw</p>"
      })

    conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    assert conn.resp_body =~ "<p>still raw</p>"
  end

  test "404 (not a crash) for a non-uuid id", %{conn: conn} do
    conn = get(conn, ~p"/artifacts/not-a-uuid/raw")
    assert conn.status == 404
  end

  @orca_send_script "<script>window.orca = { " <>
                      "send: function(payload) { window.parent.postMessage({type: \"orca:send\", payload: payload}, \"*\"); }, " <>
                      "setState: function(patch) { window.parent.postMessage({type: \"orca:state\", patch: patch}, \"*\"); }, " <>
                      "getState: function() { return (window.ORCA_DATA && window.ORCA_DATA._user_state) || {}; } " <>
                      "};</script>"

  # Verbatim copy of ArtifactController's @persist_shim, wrapped in its
  # <script> tag — kept as an exact duplicate (like @orca_send_script above)
  # so these tests pin the actual injected bytes rather than a loose
  # substring match.
  @persist_shim_script "<script>" <>
                         """
                         (function() {
                           function valueOf(el) {
                             return (el.type === "checkbox" || el.type === "radio") ? el.checked : el.value;
                           }
                           function applyValue(el, v) {
                             if (el.type === "checkbox" || el.type === "radio") {
                               el.checked = !!v;
                             } else {
                               el.value = v;
                             }
                           }
                           function applyState(state) {
                             state = state || {};
                             document.querySelectorAll("[data-orca-persist]").forEach(function(el) {
                               var key = el.getAttribute("data-orca-persist");
                               if (Object.prototype.hasOwnProperty.call(state, key)) applyValue(el, state[key]);
                             });
                           }
                           var pendingPatch = {};
                           var debounceTimer = null;
                           function flush() {
                             if (debounceTimer) { clearTimeout(debounceTimer); debounceTimer = null; }
                             if (Object.keys(pendingPatch).length === 0) return;
                             var patch = pendingPatch;
                             pendingPatch = {};
                             window.orca.setState(patch);
                           }
                           function wire(el) {
                             var key = el.getAttribute("data-orca-persist");
                             el.addEventListener("change", function() {
                               var patch = {};
                               patch[key] = valueOf(el);
                               window.orca.setState(patch);
                             });
                             el.addEventListener("input", function() {
                               pendingPatch[key] = valueOf(el);
                               if (debounceTimer) clearTimeout(debounceTimer);
                               debounceTimer = setTimeout(flush, 300);
                             });
                           }
                           document.addEventListener("DOMContentLoaded", function() {
                             applyState(window.ORCA_DATA && window.ORCA_DATA._user_state);
                             document.querySelectorAll("[data-orca-persist]").forEach(wire);
                           });
                           window.addEventListener("pagehide", flush);
                           window.addEventListener("message", function(e) {
                             if (e.data && e.data.type === "orca:data") applyState(e.data.data && e.data.data._user_state);
                           });
                         })();
                         """ <> "</script>"

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
               @orca_send_script <>
               @persist_shim_script <> "<html><body><h1>Hi</h1></body></html>"
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
             "<script>window.ORCA_DATA = {};</script>" <>
               @orca_send_script <> @persist_shim_script <> "<p>v1</p>"
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
                 @persist_shim_script <>
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
                 @orca_send_script <> @persist_shim_script <> ~s(</head><body></body></html>)
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
               "<script>window.ORCA_DATA = {};</script>" <>
                 @orca_send_script <> @persist_shim_script <> "<p>hi</p>"
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

      # Exactly three <script>/</script> pairs — ORCA_DATA + the orca.send
      # shim + the auto-persist shim we inject. If the payload's literal
      # "</script>" had survived unescaped, this would be 5.
      assert length(String.split(body, "<script>")) == 4
      assert length(String.split(body, "</script>")) == 4

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
      assert conn.resp_body =~ @persist_shim_script
      assert conn.resp_body =~ "window.orca = { send: function(payload)"
      assert conn.resp_body =~ ~s({type: "orca:send", payload: payload})
      assert conn.resp_body =~ "setState: function(patch)"
      assert conn.resp_body =~ "getState: function()"
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
      refute conn.resp_body =~ "data-orca-persist"
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
      refute conn.resp_body =~ "data-orca-persist"
    end
  end

  describe "GET /artifacts/:id/download" do
    test "404 for an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/artifacts/#{Ecto.UUID.generate()}/download")
      assert conn.status == 404
    end

    test "html download has attachment disposition, .html filename, and a body identical to /raw",
         %{conn: conn, project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "my dashboard",
          kind: "html",
          content: "<html><body><h1>Hi</h1></body></html>"
        })

      raw_conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")
      download_conn = get(build_conn(), ~p"/artifacts/#{artifact.id}/download")

      assert download_conn.status == 200
      assert get_resp_content_type(download_conn) == "text/html"
      assert download_conn.resp_body == raw_conn.resp_body

      assert Plug.Conn.get_resp_header(download_conn, "content-disposition") == [
               "attachment; filename=\"my-dashboard.html\""
             ]
    end

    test "svg download uses image/svg+xml and a .svg filename", %{conn: conn, project: project} do
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"><circle r="5"/></svg>)

      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "my-icon",
          kind: "svg",
          content: svg
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/download")

      assert conn.status == 200
      assert get_resp_content_type(conn) == "image/svg+xml"
      assert conn.resp_body == svg

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"my-icon.svg\""
             ]
    end

    test "markdown downloads the rendered HTML doc (matching /raw), not the raw markdown", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "readme",
          kind: "markdown",
          content: "# Title\n\nSome **bold** text."
        })

      raw_conn = get(conn, ~p"/artifacts/#{artifact.id}/raw")
      download_conn = get(build_conn(), ~p"/artifacts/#{artifact.id}/download")

      assert get_resp_content_type(download_conn) == "text/html"
      assert download_conn.resp_body == raw_conn.resp_body
      assert download_conn.resp_body =~ "<h1>"

      assert Plug.Conn.get_resp_header(download_conn, "content-disposition") == [
               "attachment; filename=\"readme.html\""
             ]
    end

    test "a name with spaces/slashes/quotes is sanitized into a safe filename", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: ~s(weird "name"/with\\ spaces & slashes),
          kind: "html",
          content: "<p>hi</p>"
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/download")

      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/^attachment; filename="[A-Za-z0-9._-]+\.html"$/
    end

    test "a name that already ends in the right extension isn't double-appended", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "already-named.html",
          kind: "html",
          content: "<p>hi</p>"
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/download")

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"already-named.html\""
             ]
    end

    test "falls back to artifact-<id> when sanitizing strips the name to nothing", %{
      conn: conn,
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "???///",
          kind: "html",
          content: "<p>hi</p>"
        })

      conn = get(conn, ~p"/artifacts/#{artifact.id}/download")

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"artifact-#{artifact.id}.html\""
             ]
    end
  end

  defp get_resp_content_type(conn) do
    [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    content_type |> String.split(";") |> hd()
  end
end
