defmodule OrcaHubWeb.ProjectLive.ArtifactsTest do
  @moduledoc """
  Coverage for the Artifacts section on `ProjectLive.Show` — listed by
  name/kind/version/updated_at, row click navigates to `/artifacts/:id`.
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Artifacts, Projects}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "project_artifacts_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "project-artifacts-test", directory: dir, node: "n1@x"})

    {:ok, project: project}
  end

  test "shows an empty state when the project has no artifacts", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")
    assert html =~ "No artifacts yet."
  end

  test "lists artifacts with name/kind/version and links to the fullscreen viewer", %{
    conn: conn,
    project: project
  } do
    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: "sales-dashboard",
        kind: "html",
        content: "<p>hi</p>"
      })

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

    assert html =~ "sales-dashboard"
    assert html =~ "v1"
    assert html =~ ~s(href="/artifacts/#{artifact.id}")
  end
end
