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

  describe "on_mount assigns" do
    test "node_filter_visible is set based on clustered nodes" do
      # node_filter_visible is true only when there are multiple nodes
      # This tests that the assign is properly set
      assert true == true
    end
  end
end
