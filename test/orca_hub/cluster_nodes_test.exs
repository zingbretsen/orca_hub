defmodule OrcaHub.ClusterNodesTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.ClusterNodes
  alias OrcaHub.Projects
  alias OrcaHub.Sessions

  describe "upsert_seen/2" do
    test "inserts a new row with first and last connected timestamps set" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")

      assert node.name == "orca@a"
      assert node.display_name == "a"
      assert node.first_connected_at
      assert node.last_connected_at
    end

    test "preserves first_connected_at across repeated calls, bumps last_connected_at" do
      {:ok, first} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, second} = ClusterNodes.upsert_seen("orca@a", "a (renamed)")

      assert second.first_connected_at == first.first_connected_at
      assert second.display_name == "a (renamed)"
      assert DateTime.compare(second.last_connected_at, first.last_connected_at) in [:eq, :gt]

      assert ClusterNodes.list_nodes() |> Enum.count(&(&1.name == "orca@a")) == 1
    end
  end

  describe "touch_last_connected/1" do
    test "bumps last_connected_at without touching display_name" do
      {:ok, _} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, touched} = ClusterNodes.touch_last_connected("orca@a")

      assert touched.display_name == "a"
      assert touched.last_connected_at
    end

    test "creates a row if none exists yet" do
      {:ok, node} = ClusterNodes.touch_last_connected("orca@ghost")
      assert node.name == "orca@ghost"
    end
  end

  describe "backfill_node/2" do
    test "inserts a row without connected timestamps" do
      {:ok, node} = ClusterNodes.backfill_node("orca@inferred", "inferred")

      assert node.name == "orca@inferred"
      assert node.first_connected_at == nil
      assert node.last_connected_at == nil
    end

    test "does not overwrite an existing row" do
      {:ok, _} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.backfill_node("orca@a", "should not apply")

      assert ClusterNodes.get_by_name("orca@a").display_name == "a"
    end
  end

  describe "distinct_session_and_project_node_names/0" do
    test "collects distinct node names from sessions and projects, ignoring blanks" do
      {:ok, _} =
        Projects.create_project(%{name: "p1", directory: "/tmp/p1", node: "orca@proj-node"})

      {:ok, _} =
        Sessions.create_session(%{directory: "/tmp/s1", runner_node: "orca@session-node"})

      {:ok, _} = Sessions.create_session(%{directory: "/tmp/s2", runner_node: nil})

      names = ClusterNodes.distinct_session_and_project_node_names()

      assert "orca@proj-node" in names
      assert "orca@session-node" in names
      refute nil in names
      refute "" in names
    end
  end

  describe "count_sessions_for_node/1 and count_projects_for_node/1" do
    test "counts only rows assigned to the given node" do
      {:ok, _} =
        Projects.create_project(%{name: "p1", directory: "/tmp/p1", node: "orca@a"})

      {:ok, _} =
        Projects.create_project(%{name: "p2", directory: "/tmp/p2", node: "orca@b"})

      {:ok, _} = Sessions.create_session(%{directory: "/tmp/s1", runner_node: "orca@a"})
      {:ok, _} = Sessions.create_session(%{directory: "/tmp/s2", runner_node: "orca@a"})
      {:ok, _} = Sessions.create_session(%{directory: "/tmp/s3", runner_node: "orca@b"})

      assert ClusterNodes.count_projects_for_node("orca@a") == 1
      assert ClusterNodes.count_sessions_for_node("orca@a") == 2
      assert ClusterNodes.count_sessions_for_node("orca@b") == 1
      assert ClusterNodes.count_sessions_for_node("orca@nonexistent") == 0
    end
  end
end
