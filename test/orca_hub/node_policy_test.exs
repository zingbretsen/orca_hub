defmodule OrcaHub.NodePolicyTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.ClusterNodes
  alias OrcaHub.NodePolicy

  @local_name Atom.to_string(node())

  defp set_local_isolated(bool) do
    node_row = ClusterNodes.get_by_name(@local_name) || insert_local_row()
    {:ok, updated} = ClusterNodes.update_node(node_row, %{isolated: bool})
    updated
  end

  defp set_local_scrub_session_env(bool) do
    node_row = ClusterNodes.get_by_name(@local_name) || insert_local_row()
    {:ok, updated} = ClusterNodes.update_node(node_row, %{scrub_session_env: bool})
    updated
  end

  defp insert_local_row do
    {:ok, node_row} = ClusterNodes.upsert_seen(@local_name, @local_name)
    node_row
  end

  describe "local_node_isolated?/0" do
    test "false when no nodes row exists for this node yet (fail open)" do
      refute NodePolicy.local_node_isolated?()
    end

    test "false when this node's row is not isolated" do
      set_local_isolated(false)
      refute NodePolicy.local_node_isolated?()
    end

    test "true when this node's row is flagged isolated" do
      set_local_isolated(true)
      assert NodePolicy.local_node_isolated?()
    end
  end

  describe "scrub_session_env?/0" do
    test "false when no nodes row exists for this node yet (fail open)" do
      refute NodePolicy.scrub_session_env?()
    end

    test "false when this node's row does not have the flag set" do
      set_local_scrub_session_env(false)
      refute NodePolicy.scrub_session_env?()
    end

    test "true when this node's row is flagged scrub_session_env" do
      set_local_scrub_session_env(true)
      assert NodePolicy.scrub_session_env?()
    end

    test "independent of the isolated flag" do
      node_row = insert_local_row()
      {:ok, _} = ClusterNodes.update_node(node_row, %{isolated: true, scrub_session_env: false})

      refute NodePolicy.scrub_session_env?()
      assert NodePolicy.local_node_isolated?()
    end
  end

  describe "cross_node_allowed?/1" do
    test "always true for the local node itself, regardless of isolation" do
      set_local_isolated(true)
      assert NodePolicy.cross_node_allowed?(node())
    end

    test "always true for a nil target (unassigned/not clustered)" do
      set_local_isolated(true)
      assert NodePolicy.cross_node_allowed?(nil)
    end

    test "true for a different node when not isolated" do
      set_local_isolated(false)
      assert NodePolicy.cross_node_allowed?(:other@host)
    end

    test "false for a different node when this node is isolated" do
      set_local_isolated(true)
      refute NodePolicy.cross_node_allowed?(:other@host)
    end
  end

  describe "denial_message/1" do
    test "mentions this node and the blocked target" do
      msg = NodePolicy.denial_message(:other@host)
      assert msg =~ Atom.to_string(node())
      assert msg =~ "other@host"
      assert msg =~ "isolated"
    end
  end
end
