defmodule OrcaHubWeb.ArtifactViewControllerTest do
  @moduledoc """
  Coverage for the token-scoped artifact routes (ORCAHUB3-128),
  `GET /api/artifacts/view/:token/{raw,assets/:name}`. They sit under /api,
  which Authelia bypasses, so the signed token is the only thing standing
  between the internet and an artifact. Also covers HTTP Range on BOTH asset
  routes (the token one and the old `/artifacts/:id/assets/:name`).
  `async: false` for the same reason as ArtifactAssetsControllerTest: the
  object store root is process-wide app env.
  """
  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.{Artifacts, Files, Projects, Sessions}
  alias OrcaHubWeb.ArtifactURL

  @video_bytes for i <- 0..999, into: <<>>, do: <<rem(i, 256)>>

  setup do
    store_dir =
      Path.join(
        System.tmp_dir!(),
        "artifact_view_controller_store_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orca_hub, :file_store_dir, store_dir)

    on_exit(fn ->
      Application.delete_env(:orca_hub, :file_store_dir)
      File.rm_rf(store_dir)
    end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "artifact_view_controller_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "artifact-view-controller-test",
        directory: dir,
        node: "n1@x"
      })

    {:ok, session} = Sessions.create_session(%{directory: dir, project_id: project.id})

    artifact = save_artifact!(project, session, "gallery")
    other = save_artifact!(project, session, "other")

    attach!(artifact, "hero.png", "image/png", "fake png bytes")
    attach!(artifact, "clip.mp4", "video/mp4", @video_bytes)
    attach!(other, "secret.png", "image/png", "other artifact's bytes")

    {:ok, artifact: artifact, other: other, token: ArtifactURL.mint(artifact.id)}
  end

  defp save_artifact!(project, session, name) do
    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        session_id: session.id,
        name: name,
        content: ~s(<html><body><img src="assets/hero.png"></body></html>)
      })

    artifact
  end

  defp attach!(artifact, name, content_type, bytes) do
    {:ok, file} =
      Files.create_file(
        %{
          project_id: artifact.project_id,
          session_id: artifact.session_id,
          name: name,
          content_type: content_type
        },
        bytes
      )

    {:ok, _} = Artifacts.attach_asset(artifact, file, name)
    file
  end

  describe "GET /api/artifacts/view/:token/raw" do
    test "a valid token serves the same bytes and headers as /artifacts/:id/raw", %{
      conn: conn,
      artifact: artifact,
      token: token
    } do
      view = get(conn, ~p"/api/artifacts/view/#{token}/raw?v=#{artifact.version}")
      old = get(build_conn(), ~p"/artifacts/#{artifact.id}/raw?v=#{artifact.version}")

      assert view.status == 200
      assert view.resp_body == old.resp_body
      assert view.resp_body == Artifacts.Render.body(artifact)
      assert get_resp_header(view, "content-type") == get_resp_header(old, "content-type")
      assert get_resp_header(view, "content-security-policy") == ["sandbox allow-scripts"]
      assert get_resp_header(view, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(view, "referrer-policy") == ["strict-origin-when-cross-origin"]
    end

    test "the path ArtifactURL.raw_path/1 builds is the one served", %{
      conn: conn,
      artifact: artifact
    } do
      conn = get(conn, ArtifactURL.raw_path(artifact))
      assert conn.status == 200
      assert conn.resp_body == Artifacts.Render.body(artifact)
    end

    test "a tampered token is a bare 404", %{conn: conn, token: token, other: other} do
      [proto, _payload, sig] = String.split(token, ".")
      [_, other_payload, _] = String.split(ArtifactURL.mint(other.id), ".")
      forged = Enum.join([proto, other_payload, sig], ".")

      conn = get(conn, ~p"/api/artifacts/view/#{forged}/raw")
      assert conn.status == 404
      assert conn.resp_body == "Artifact not found"
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    end

    test "an expired token is a bare 404", %{conn: conn, artifact: artifact} do
      old = System.system_time(:second) - ArtifactURL.max_age_seconds() - 3600
      token = ArtifactURL.mint(artifact.id, now: old)

      conn = get(conn, ~p"/api/artifacts/view/#{token}/raw")
      assert conn.status == 404
      assert conn.resp_body == "Artifact not found"
    end

    test "max_age is read from app env at verify time", %{conn: conn, artifact: artifact} do
      two_hours_ago = System.system_time(:second) - 2 * 3600
      token = ArtifactURL.mint(artifact.id, now: two_hours_ago)

      Application.put_env(:orca_hub, :artifact_url_max_age_seconds, 3600)
      on_exit(fn -> Application.delete_env(:orca_hub, :artifact_url_max_age_seconds) end)

      assert get(conn, ~p"/api/artifacts/view/#{token}/raw").status == 404
    end

    test "garbage and a valid token for a deleted artifact are the same bare 404", %{
      conn: conn,
      artifact: artifact
    } do
      token = ArtifactURL.mint(artifact.id)
      {:ok, _} = Artifacts.delete_artifact(artifact)

      deleted = get(conn, ~p"/api/artifacts/view/#{token}/raw")
      garbage = get(build_conn(), ~p"/api/artifacts/view/not-a-token/raw")

      for c <- [deleted, garbage] do
        assert c.status == 404
        assert c.resp_body == "Artifact not found"
      end
    end
  end

  describe "GET /api/artifacts/view/:token/assets/:name" do
    test "a valid token serves the asset's bytes with CSP sandbox, nosniff, CORS and no-referrer",
         %{conn: conn, token: token} do
      conn = get(conn, ~p"/api/artifacts/view/#{token}/assets/hero.png")

      assert conn.status == 200
      assert conn.resp_body == "fake png bytes"
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
      assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "the URL ArtifactURL.asset_url/2 builds is the one served", %{
      conn: conn,
      artifact: artifact
    } do
      %URI{path: path} = URI.parse(ArtifactURL.asset_url(artifact.id, "hero.png"))
      conn = get(conn, path)

      assert conn.status == 200
      assert conn.resp_body == "fake png bytes"
    end

    test "a token for artifact A cannot read an asset attached only to artifact B", %{
      conn: conn,
      token: token,
      other: other
    } do
      conn = get(conn, ~p"/api/artifacts/view/#{token}/assets/secret.png")
      assert conn.status == 404
      assert conn.resp_body == "Artifact not found"

      # ...while B's own token can.
      b =
        get(build_conn(), ~p"/api/artifacts/view/#{ArtifactURL.mint(other.id)}/assets/secret.png")

      assert b.status == 200
      assert b.resp_body == "other artifact's bytes"
    end

    test "an asset name not attached to the artifact is a 404", %{conn: conn, token: token} do
      conn = get(conn, ~p"/api/artifacts/view/#{token}/assets/nope.png")
      assert conn.status == 404
      assert conn.resp_body == "Artifact not found"
    end

    test "a tampered or expired token is a 404 even for a real asset name", %{
      conn: conn,
      artifact: artifact,
      token: token
    } do
      [proto, payload, sig] = String.split(token, ".")
      tampered = Enum.join([proto, payload, String.reverse(sig)], ".")
      old = System.system_time(:second) - ArtifactURL.max_age_seconds() - 3600
      expired = ArtifactURL.mint(artifact.id, now: old)

      for t <- [tampered, expired] do
        c = get(conn, ~p"/api/artifacts/view/#{t}/assets/hero.png")
        assert c.status == 404
        assert c.resp_body == "Artifact not found"
      end
    end

    test "an HTML asset is served under a script-less CSP sandbox", %{
      conn: conn,
      artifact: artifact,
      token: token
    } do
      attach!(artifact, "evil.html", "text/html", "<script>fetch('/api/v1/sessions')</script>")

      conn = get(conn, ~p"/api/artifacts/view/#{token}/assets/evil.html")

      assert conn.status == 200
      assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  describe "HTTP Range on asset routes" do
    setup %{artifact: artifact, token: token} do
      {:ok,
       paths: [
         ~p"/api/artifacts/view/#{token}/assets/clip.mp4",
         ~p"/artifacts/#{artifact.id}/assets/clip.mp4"
       ]}
    end

    defp ranged(path, range) do
      build_conn() |> put_req_header("range", range) |> get(path)
    end

    test "bytes=a-b is a 206 with exactly that window and a Content-Range", %{paths: paths} do
      for path <- paths do
        conn = ranged(path, "bytes=10-19")

        assert conn.status == 206
        assert conn.resp_body == binary_part(@video_bytes, 10, 10)
        assert get_resp_header(conn, "content-range") == ["bytes 10-19/1000"]
        assert get_resp_header(conn, "accept-ranges") == ["bytes"]
        assert get_resp_header(conn, "content-type") |> hd() =~ "video/mp4"
        assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      end
    end

    test "Safari's opening probe, bytes=0-1, is a two-byte 206", %{paths: paths} do
      for path <- paths do
        conn = ranged(path, "bytes=0-1")

        assert conn.status == 206
        assert conn.resp_body == binary_part(@video_bytes, 0, 2)
        assert get_resp_header(conn, "content-range") == ["bytes 0-1/1000"]
      end
    end

    test "bytes=a- runs to the end", %{paths: paths} do
      for path <- paths do
        conn = ranged(path, "bytes=990-")

        assert conn.status == 206
        assert conn.resp_body == binary_part(@video_bytes, 990, 10)
        assert get_resp_header(conn, "content-range") == ["bytes 990-999/1000"]
      end
    end

    test "bytes=-n is the last n bytes, and a suffix longer than the file is all of it", %{
      paths: paths
    } do
      for path <- paths do
        conn = ranged(path, "bytes=-5")
        assert conn.status == 206
        assert conn.resp_body == binary_part(@video_bytes, 995, 5)
        assert get_resp_header(conn, "content-range") == ["bytes 995-999/1000"]

        conn = ranged(path, "bytes=-5000")
        assert conn.status == 206
        assert conn.resp_body == @video_bytes
        assert get_resp_header(conn, "content-range") == ["bytes 0-999/1000"]
      end
    end

    test "an end past the file is clamped to the last byte", %{paths: paths} do
      for path <- paths do
        conn = ranged(path, "bytes=995-5000")

        assert conn.status == 206
        assert conn.resp_body == binary_part(@video_bytes, 995, 5)
        assert get_resp_header(conn, "content-range") == ["bytes 995-999/1000"]
      end
    end

    test "a start at or past the end, or a zero-length suffix, is a 416 with bytes */size", %{
      paths: paths
    } do
      for path <- paths, range <- ["bytes=1000-", "bytes=5000-6000", "bytes=-0"] do
        conn = ranged(path, range)

        assert conn.status == 416, "#{path} #{range}"
        assert get_resp_header(conn, "content-range") == ["bytes */1000"]
        assert conn.resp_body == ""
      end
    end

    test "no Range, a multi-range, an inverted range or a non-bytes unit is a full 200", %{
      paths: paths
    } do
      for path <- paths do
        conn = get(build_conn(), path)
        assert conn.status == 200
        assert conn.resp_body == @video_bytes
        assert get_resp_header(conn, "accept-ranges") == ["bytes"]
        assert get_resp_header(conn, "content-range") == []

        for range <- ["bytes=0-1, 5-6", "bytes=20-10", "items=0-1", "bytes=-", "garbage"] do
          conn = ranged(path, range)
          assert conn.status == 200, "#{path} #{range}"
          assert conn.resp_body == @video_bytes
          assert get_resp_header(conn, "content-range") == []
        end
      end
    end

    test "the token route's Range responses keep their CORS and referrer headers", %{
      paths: [token_path | _]
    } do
      conn = ranged(token_path, "bytes=0-1")

      assert conn.status == 206
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end
end
