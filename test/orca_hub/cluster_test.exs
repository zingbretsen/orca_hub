defmodule OrcaHub.ClusterTest do
  @moduledoc """
  Coverage for the node-availability routing helpers — the fix for "never
  automatically re-assign a session to another node; realize the assigned
  node isn't currently available" instead. Before this, `runner_node_for/1`
  and `project_node_for/1` silently substituted `node()` whenever the
  assigned node wasn't in `nodes()` (offline, or an atom this process had
  never seen — `String.to_existing_atom/1` raising), which is how a
  debian-owned session got silently adopted and crashed on the hub during
  the debian agent's restart window.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Cluster
  alias OrcaHub.{Projects, Sessions, Terminals}

  @offline_node :"debian@totally-offline-host"

  describe "runner_node_for/1 — sessions (strict, no nil fallback)" do
    test "a binary runner_node on a currently-connected node resolves to that node atom" do
      {:ok, session} =
        Sessions.create_session(%{directory: "/tmp/x", runner_node: Atom.to_string(node())})

      assert Cluster.runner_node_for(session) == node()
    end

    test "a binary runner_node on an offline/unseen node returns that node AS-IS, never node()" do
      {:ok, session} =
        Sessions.create_session(%{
          directory: "/tmp/x",
          runner_node: Atom.to_string(@offline_node)
        })

      assert Cluster.runner_node_for(session) == @offline_node
      refute Cluster.runner_node_for(session) == node()
    end

    test "a nil runner_node is unassigned — returns nil, not node()" do
      {:ok, session} = Sessions.create_session(%{directory: "/tmp/x"})
      assert session.runner_node == nil
      assert Cluster.runner_node_for(session) == nil
    end

    test "an empty-string runner_node is treated the same as nil" do
      {:ok, session} = Sessions.create_session(%{directory: "/tmp/x", runner_node: ""})
      assert Cluster.runner_node_for(session) == nil
    end
  end

  describe "runner_node_for/1 — non-session entities (terminals) keep nil -> local fallback" do
    test "nil runner_node falls back to this node (not-yet-started state)" do
      {:ok, terminal} = Terminals.create_terminal(%{name: "t", directory: "/tmp/x"})
      assert terminal.runner_node == nil
      assert Cluster.runner_node_for(terminal) == node()
    end

    test "an offline runner_node still returns that node as-is (not silently local)" do
      {:ok, terminal} =
        Terminals.create_terminal(%{
          name: "t",
          directory: "/tmp/x",
          runner_node: Atom.to_string(@offline_node)
        })

      assert Cluster.runner_node_for(terminal) == @offline_node
    end
  end

  describe "project_node_for/1 — nil -> local fallback (\"no clustering configured\")" do
    test "nil node falls back to this node" do
      {:ok, project} = Projects.create_project(%{name: "p", directory: "/tmp/x"})
      assert project.node == nil
      assert Cluster.project_node_for(project) == node()
    end

    test "an offline node returns that node as-is (never silently reassigned to local)" do
      {:ok, project} =
        Projects.create_project(%{
          name: "p2",
          directory: "/tmp/y",
          node: Atom.to_string(@offline_node)
        })

      assert Cluster.project_node_for(project) == @offline_node
    end
  end

  describe "node_available?/1" do
    test "true for the local node" do
      assert Cluster.node_available?(node())
    end

    test "false for a node not currently connected" do
      refute Cluster.node_available?(@offline_node)
    end

    test "false for nil" do
      refute Cluster.node_available?(nil)
    end
  end

  describe "rpc/5 refuses instead of raising" do
    test "nil target returns {:error, :node_unassigned}" do
      assert Cluster.rpc(nil, Kernel, :+, [1, 2]) == {:error, :node_unassigned}
    end

    test "an unavailable target returns {:error, {:node_unavailable, node}}" do
      assert Cluster.rpc(@offline_node, Kernel, :+, [1, 2]) ==
               {:error, {:node_unavailable, @offline_node}}
    end

    test "the local node still executes normally" do
      assert Cluster.rpc(node(), Kernel, :+, [1, 2]) == 3
    end
  end

  describe "node_unavailable_message/1" do
    test "explains an unassigned session" do
      assert Cluster.node_unavailable_message(:node_unassigned) =~ "no assigned node"
    end

    test "explains an offline node, naming it" do
      message = Cluster.node_unavailable_message({:node_unavailable, @offline_node})
      assert message =~ "not currently connected"
    end

    test "unwraps an {:error, reason} tuple the same way" do
      assert Cluster.node_unavailable_message({:error, :node_unassigned}) =~ "no assigned node"
    end

    test "nil for anything else" do
      assert Cluster.node_unavailable_message({:error, "some git error"}) == nil
      assert Cluster.node_unavailable_message(:busy) == nil
    end
  end
end
