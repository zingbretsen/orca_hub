defmodule OrcaHubWeb.NodeLive.IndexTest do
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.ClusterNodes

  test "renders the local node as connected and a stale node as offline", %{conn: conn} do
    {:ok, _local} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")
    {:ok, _offline} = ClusterNodes.upsert_seen("orca@long-gone", "long-gone-node")

    {:ok, _view, html} = live(conn, ~p"/nodes")

    assert html =~ "this-node"
    assert html =~ "long-gone-node"
    assert html =~ "connected"
    assert html =~ "offline"
  end

  test "lists connected nodes before offline ones", %{conn: conn} do
    {:ok, _} = ClusterNodes.upsert_seen("orca@long-gone", "long-gone-node")
    {:ok, _} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

    {:ok, _view, html} = live(conn, ~p"/nodes")

    connected_index = :binary.match(html, "this-node") |> elem(0)
    offline_index = :binary.match(html, "long-gone-node") |> elem(0)

    assert connected_index < offline_index
  end

  test "row links to the node's show page", %{conn: conn} do
    {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

    {:ok, _view, html} = live(conn, ~p"/nodes")

    assert html =~ ~p"/nodes/#{n.id}"
  end
end
