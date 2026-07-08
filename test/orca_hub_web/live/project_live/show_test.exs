defmodule OrcaHubWeb.ProjectLive.ShowTest do
  @moduledoc """
  Regression for the same node-availability bug as
  SessionLive.ShowTest's "incident regression" describe block: a project
  assigned to an offline node used to have its git_log/git_branch/
  git_worktree_list/git_branches results silently computed on the LOCAL
  node instead (via the old runner_node_for/project_node_for fallback).
  With that fallback removed for an unreachable-but-assigned node,
  Cluster.rpc/5 now returns a clean {:error, ...} tuple instead — this
  covers the mount code that must not choke on that tuple (it used to
  crash rendering `length(@branches)` / `:for={_ <- @worktrees}` etc.
  directly on the raw rpc result).
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.Projects

  setup do
    dir = Path.join(System.tmp_dir!(), "project_show_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "offline-node-project",
        directory: dir,
        node: "debian@totally-offline-host"
      })

    {:ok, project: project}
  end

  test "mount with a project assigned to an offline node does not crash", %{
    conn: conn,
    project: project
  } do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

    assert html =~ "not currently connected"
  end
end
