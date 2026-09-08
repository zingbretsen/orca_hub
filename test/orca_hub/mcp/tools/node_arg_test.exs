defmodule OrcaHub.MCP.Tools.NodeArgTest do
  @moduledoc """
  ORCAHUB3-73: `resolve/1` matched only against the LOCAL `Cluster.nodes/0`.
  Agent nodes are deliberately unmeshed with each other (only with the hub),
  so an agent could never target a sibling agent by `node` even though the
  hub's own view includes it and `Cluster.rpc/5`'s hub-relay exists for
  exactly this case.

  async: false — mutates the global `:orca_hub, :mode` app env, same
  rationale as `OrcaHubWeb.AgentModeGateTest`.
  """

  use ExUnit.Case, async: false

  alias OrcaHub.MCP.Tools.NodeArg

  setup do
    prev_mode = Application.get_env(:orca_hub, :mode, :hub)
    prev_fetcher = Application.get_env(:orca_hub, :node_arg_hub_nodes_fetcher)

    on_exit(fn ->
      Application.put_env(:orca_hub, :mode, prev_mode)

      if prev_fetcher do
        Application.put_env(:orca_hub, :node_arg_hub_nodes_fetcher, prev_fetcher)
      else
        Application.delete_env(:orca_hub, :node_arg_hub_nodes_fetcher)
      end
    end)

    :ok
  end

  describe "nil/empty" do
    test "resolves to this node" do
      assert {:ok, n} = NodeArg.resolve(nil)
      assert n == node()

      assert {:ok, n} = NodeArg.resolve("")
      assert n == node()
    end
  end

  describe "local match" do
    test "resolves the local node by name" do
      assert {:ok, n} = NodeArg.resolve(Atom.to_string(node()))
      assert n == node()
    end
  end

  describe "unknown name, never in the cluster" do
    test "never creates an atom for a garbage name" do
      garbage = "totally-fake-node-#{System.unique_integer([:positive])}@nowhere"
      refute garbage in Enum.map(:erlang.registered(), &Atom.to_string/1)

      assert {:error, message} = NodeArg.resolve(garbage)
      assert message =~ "Unknown or disconnected node"

      # String.to_existing_atom/1 raises if resolve/1 ever grew the atom
      # table for this input.
      assert_raise ArgumentError, fn -> String.to_existing_atom(garbage) end
    end

    test "hub mode: error text says 'not connected from this node'" do
      Application.put_env(:orca_hub, :mode, :hub)

      assert {:error, message} =
               NodeArg.resolve("totally-fake-node-#{System.unique_integer([:positive])}")

      assert message =~ "Not connected from this node"
    end
  end

  describe "agent mode, hub relay" do
    setup do
      Application.put_env(:orca_hub, :mode, :agent)
      :ok
    end

    test "ORCAHUB3-73: resolves a name present only in the hub's node list" do
      sibling = :"gb10@192.168.1.77"

      Application.put_env(:orca_hub, :node_arg_hub_nodes_fetcher, fn ->
        {:ok, [node(), sibling]}
      end)

      assert {:ok, ^sibling} = NodeArg.resolve("gb10@192.168.1.77")
    end

    test "a name absent from both the local AND hub lists errors as 'not connected anywhere'" do
      Application.put_env(:orca_hub, :node_arg_hub_nodes_fetcher, fn ->
        {:ok, [node(), :"gb10@192.168.1.77"]}
      end)

      assert {:error, message} = NodeArg.resolve("really-nowhere@nope")
      assert message =~ "Not connected anywhere in the cluster"
    end

    test "a hub lookup failure falls back to the local-only error" do
      Application.put_env(:orca_hub, :node_arg_hub_nodes_fetcher, fn -> :error end)

      assert {:error, message} = NodeArg.resolve("gb10@192.168.1.77")
      assert message =~ "Not connected from this node"
    end

    test "still never creates an atom for a name absent everywhere" do
      garbage = "totally-fake-agent-name-#{System.unique_integer([:positive])}@nowhere"

      Application.put_env(:orca_hub, :node_arg_hub_nodes_fetcher, fn ->
        {:ok, [node()]}
      end)

      assert {:error, _} = NodeArg.resolve(garbage)
      assert_raise ArgumentError, fn -> String.to_existing_atom(garbage) end
    end
  end
end
