defmodule OrcaHubWeb.ProjectLive.EditEnvAllowlistTest do
  @moduledoc """
  The project edit modal's env_allowlist field — see
  OrcaHubWeb.NodeLive.ShowTest's "env_allowlist input" describe block for the
  sibling node-level form.
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.Projects

  setup do
    dir = Path.join(System.tmp_dir!(), "project_edit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "edit-env-project", directory: dir})

    {:ok, project: project}
  end

  test "renders the env allow-list field with help text", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/edit")

    assert html =~ "Env allow-list"
    assert html =~ "Scrub session env"
  end

  test "saving parsed entries persists them on the project", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/edit")

    view
    |> form("form", project: %{name: project.name, directory: project.directory})
    |> render_change(%{project: %{env_allowlist: "AWS_*, MY_TOKEN"}})

    view
    |> form("form", project: %{name: project.name, directory: project.directory})
    |> render_submit(%{project: %{env_allowlist: "AWS_*, MY_TOKEN"}})

    assert Projects.get_project(project.id).env_allowlist == ["AWS_*", "MY_TOKEN"]
  end

  test "an invalid entry blocks save and shows an error", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/edit")

    html =
      view
      |> form("form", project: %{name: project.name, directory: project.directory})
      |> render_change(%{project: %{env_allowlist: "bad-entry!"}})

    assert html =~ "invalid entry"

    view
    |> form("form", project: %{name: project.name, directory: project.directory})
    |> render_submit(%{project: %{env_allowlist: "bad-entry!"}})

    assert Projects.get_project(project.id).env_allowlist == []
  end
end
