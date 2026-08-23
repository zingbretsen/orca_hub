defmodule OrcaHubWeb.NodeFilterTest do
  @moduledoc """
  Tests for the NodeFilter on_mount hook.

  This module tests the global node filtering functionality.
  """
  use OrcaHubWeb.ConnCase, async: true

  alias OrcaHubWeb.NodeFilter

  describe "selected_node_names/1" do
    test "returns empty list for :all" do
      assert NodeFilter.selected_node_names(:all) == []
    end

    test "returns list of names for MapSet" do
      set = MapSet.new(["node1", "node2"])
      assert NodeFilter.selected_node_names(set) == ["node1", "node2"]
    end
  end

  describe "node_selected?/2" do
    test ":all always returns true" do
      assert NodeFilter.node_selected?(:all, "any-node") == true
    end

    test "MapSet checks membership" do
      set = MapSet.new(["node1", "node2"])
      assert NodeFilter.node_selected?(set, "node1") == true
      assert NodeFilter.node_selected?(set, "node3") == false
    end
  end

  # NOTE: node_filter_visible (set in NodeFilter.on_mount/4 based on
  # length(Cluster.node_info()) > 1) is NOT covered by tests.
  #
  # Reason: Cluster.node_info() depends on Node.list() which returns
  # actual connected distributed Erlang nodes. Testing this would require
  # starting real distributed nodes (Node.start/Node.connect), which
  # requires async: false and causes cross-test race conditions. The
  # existing cluster_distributed_test.exs was split out for exactly this
  # reason - see that file's moduledoc. The on_mount hook's other assigns
  # (node_filter, node_filter_nodes, node_modal_open) are tested above.
end
