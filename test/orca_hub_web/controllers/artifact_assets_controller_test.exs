defmodule OrcaHubWeb.ArtifactAssetsControllerTest do
  @moduledoc """
  Coverage for `GET /artifacts/:id/assets/:name` (ORCAHUB3-72 slice 2) —
  the route an artifact's own HTML resolves a relative `assets/<name>` src
  against, since the artifact itself is loaded from `src=/artifacts/:id/raw`.
  `async: false` — fixture bytes are written via `OrcaHub.ObjectStore.Local`,
  scoped to a per-test tmp dir set in app env (process-wide state), same as
  `OrcaHub.FilesTest`.
  """
  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.{Artifacts, Files, Projects, Sessions}

  setup do
    store_dir =
      Path.join(
        System.tmp_dir!(),
        "artifact_assets_controller_store_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orca_hub, :file_store_dir, store_dir)

    on_exit(fn ->
      Application.delete_env(:orca_hub, :file_store_dir)
      File.rm_rf(store_dir)
    end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "artifact_assets_controller_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "artifact-assets-controller-test",
        directory: dir,
        node: "n1@x"
      })

    {:ok, session} = Sessions.create_session(%{directory: dir, project_id: project.id})

    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        session_id: session.id,
        name: "with-image",
        content: ~s(<html><body><img src="assets/hero.png"></body></html>)
      })

    {:ok, asset_file} =
      Files.create_file(
        %{
          project_id: project.id,
          session_id: session.id,
          name: "hero.png",
          content_type: "image/png"
        },
        "fake png bytes"
      )

    {:ok, asset} = Artifacts.attach_asset(artifact, asset_file, "hero.png")

    {:ok, artifact: artifact, asset_file: asset_file, asset: asset}
  end

  test "200 with the file's content-type and cache-control, serving its bytes", %{
    conn: conn,
    artifact: artifact
  } do
    conn = get(conn, ~p"/artifacts/#{artifact.id}/assets/hero.png")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    assert conn.resp_body == "fake png bytes"
  end

  test "404 for an unknown asset name on a real artifact", %{conn: conn, artifact: artifact} do
    conn = get(conn, ~p"/artifacts/#{artifact.id}/assets/nope.png")
    assert conn.status == 404
  end

  test "404 for an unknown artifact id", %{conn: conn} do
    conn = get(conn, ~p"/artifacts/#{Ecto.UUID.generate()}/assets/hero.png")
    assert conn.status == 404
  end

  test "404 (not a crash) for a non-uuid artifact id", %{conn: conn} do
    conn = get(conn, ~p"/artifacts/not-a-uuid/assets/hero.png")
    assert conn.status == 404
  end
end
