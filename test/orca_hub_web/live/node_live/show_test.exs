defmodule OrcaHubWeb.NodeLive.ShowTest do
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.ClusterNodes
  alias OrcaHub.Projects
  alias OrcaHub.Sessions

  test "renders the local (connected) node's info without an unavailable banner", %{conn: conn} do
    {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

    {:ok, _} = Projects.create_project(%{name: "p1", directory: "/tmp/p1", node: n.name})
    {:ok, _} = Sessions.create_session(%{directory: "/tmp/s1", runner_node: n.name})

    {:ok, _view, html} = live(conn, ~p"/nodes/#{n.id}")

    assert html =~ "this-node"
    assert html =~ "connected"
    assert html =~ "Backend Configuration"
    assert html =~ "Coming soon"
    refute html =~ "node-unavailable"
  end

  test "shows a clear node-unavailable state for an offline node", %{conn: conn} do
    {:ok, n} = ClusterNodes.upsert_seen("orca@long-gone", "long-gone-node")

    {:ok, _view, html} = live(conn, ~p"/nodes/#{n.id}")

    assert html =~ "long-gone-node"
    assert html =~ "not currently connected"
    assert html =~ "backend-config-node-unavailable"
    refute html =~ "Coming soon"
  end
end
