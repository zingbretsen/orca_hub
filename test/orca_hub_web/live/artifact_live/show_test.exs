defmodule OrcaHubWeb.ArtifactLive.ShowTest do
  @moduledoc """
  Coverage for the fullscreen artifact viewer at `/artifacts/:id`: renders
  the sandboxed iframe, the viewport-width toggle, and live-reloads on
  `{:artifact_updated, ...}`.
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Artifacts, Projects}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "artifact_live_show_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "artifact-live-show-test", directory: dir, node: "n1@x"})

    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: "fullscreen-me",
        kind: "html",
        content: "<p>hi</p>"
      })

    {:ok, project: project, artifact: artifact}
  end

  test "renders the sandboxed iframe pointed at the raw url", %{conn: conn, artifact: artifact} do
    {:ok, _view, html} = live(conn, ~p"/artifacts/#{artifact.id}")

    assert html =~ "/artifacts/#{artifact.id}/raw?v=#{artifact.version}"
    assert html =~ ~s(sandbox="allow-scripts")
    refute html =~ "allow-same-origin"
    assert html =~ artifact.name
  end

  test "redirects to /projects with a flash for an unknown id", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(conn, ~p"/artifacts/#{Ecto.UUID.generate()}")
  end

  test "set_viewport constrains the iframe width", %{conn: conn, artifact: artifact} do
    {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

    html = render_click(view, "set_viewport", %{"viewport" => "mobile"})
    assert html =~ "width: 375px"

    html = render_click(view, "set_viewport", %{"viewport" => "full"})
    assert html =~ "width: 100%;"
  end

  test "live-reloads on {:artifact_updated, ...} broadcast", %{
    conn: conn,
    project: project,
    artifact: artifact
  } do
    {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

    {:ok, updated} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: artifact.name,
        content: "<p>updated</p>"
      })

    html = render(view)
    assert html =~ "/artifacts/#{artifact.id}/raw?v=#{updated.version}"
  end
end
