defmodule OrcaHub.ClusterDistributedTest do
  @moduledoc """
  Split out of cluster_test.exs: these tests make the test VM itself a real
  distributed Erlang node (via Node.start/:peer/Node.connect) to reproduce
  genuine cross-node behavior. That's process-wide state — while it's in
  effect, unrelated async tests elsewhere in the suite (e.g.
  ProjectLive.StructuredFileTest, Backend.ClaudeTest) can observe a VM that's
  suddenly "alive" with extra nodes in Node.list(), and fail with
  "No hub node found in cluster" or {:erpc, :noconnection} depending on
  scheduling luck.

  Kept in a separate `async: false` module tagged `:distributed` so it never
  runs concurrently with the rest of the suite — see test_helper.exs for the
  two-pass `mix test` / `mix test --only distributed` split.

  Run with CLUSTER_NODES and CLUSTER_DNS_QUERY unset (see mix-test-env docs)
  — otherwise libcluster's already-configured static/DNS strategy could
  attempt to connect this ad hoc node to a real cluster member.
  """
  use OrcaHub.DataCase, async: false

  @moduletag :distributed

  alias OrcaHub.Cluster

  @offline_node :"debian@totally-offline-host"

  describe "rpc/5 — connected node running an older release (rolling deploy / version skew)" do
    setup do
      # ClusterNodeTracker writes to the DB (from its own process, outside
      # this test's Ecto sandbox checkout) whenever a real :nodeup fires —
      # pause it for the duration so the Node.start/:peer connection below
      # doesn't crash it.
      Supervisor.terminate_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker)
      on_exit(fn -> Supervisor.restart_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker) end)

      unless Node.alive?() do
        {:ok, hostname} = :inet.gethostname()
        {:ok, _pid} = Node.start(:"cluster_rpc_test@#{hostname}", :shortnames)
      end

      {:ok, peer_pid, peer_node} =
        :peer.start_link(%{name: :"cluster_rpc_undef_peer_#{System.unique_integer([:positive])}"})

      on_exit(fn ->
        try do
          :peer.stop(peer_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      %{peer_node: peer_node}
    end

    test "a connected node lacking the called function returns {:error, {:rpc_undef, mfa}} instead of crashing the caller",
         %{peer_node: peer_node} do
      # The peer is a bare node with no OrcaHub code loaded — same as a
      # connected cluster node that hasn't been redeployed with a newly
      # added function yet (e.g. BackendInstaller.running_backends/0,
      # which crashed NodeLive.Index's mount in production: :erpc.call
      # raised :undef uncaught, so every socket reconnect re-crashed —
      # the classic "page keeps refreshing" symptom).
      assert Cluster.rpc(peer_node, OrcaHub.BackendInstaller, :running_backends, [], 2_000) ==
               {:error, {:rpc_undef, {OrcaHub.BackendInstaller, :running_backends, 0}}}
    end

    test "relays through the hub, preserving {:node_unavailable, target} once the hub also fails to reach it",
         %{peer_node: peer_node} do
      # Load OrcaHub's code onto the peer so it can play the hub role: it
      # needs OrcaHub.Cluster/OrcaHub.Mode to answer the relayed attempt_rpc
      # call. (OrcaHub.Mode.hub?/0 defaults to :hub since this bare peer has
      # no ORCA_MODE config of its own - exactly what we want here.)
      :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
      assert :erpc.call(peer_node, OrcaHub.Mode, :hub?, [], 5_000)

      Application.put_env(:orca_hub, :mode, :agent)
      on_exit(fn -> Application.delete_env(:orca_hub, :mode) end)

      # @offline_node is unreachable by construction (never started anywhere)
      # so both this node's direct attempt AND the hub's relayed attempt fail
      # the same way - proving the round trip (agent -> hub -> attempt_rpc)
      # actually executes, without requiring a genuinely-partitioned third
      # node (unreproducible on one host - plain distributed Erlang
      # auto-forms a full mesh, verified by hand).
      assert Cluster.rpc(@offline_node, Kernel, :+, [1, 2]) ==
               {:error, {:node_unavailable, @offline_node}}
    end
  end

  describe "rpc/5 — hub relay (partial-mesh fallback)" do
    test "acting as an agent with no discoverable hub returns {:error, {:node_check_failed, n}}, distinct from a hub-confirmed-down node" do
      # Moved from cluster_test.exs: this mutates the process-wide
      # `:orca_hub, :mode` Application env, which raced with unrelated
      # async tests (e.g. ProjectLive.ShowTest calling Mode.hub_node/0 and
      # hitting find_hub_node/0's "No hub node found in cluster" raise mid
      # mutation) whenever it ran concurrently in the async:true suite.
      Application.put_env(:orca_hub, :mode, :agent)
      on_exit(fn -> Application.delete_env(:orca_hub, :mode) end)

      assert Cluster.rpc(@offline_node, Kernel, :+, [1, 2]) ==
               {:error, {:node_check_failed, @offline_node}}
    end
  end

  describe "rpc/5 — Node.connect heals a stale/dropped view of a still-reachable node" do
    setup do
      Supervisor.terminate_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker)
      on_exit(fn -> Supervisor.restart_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker) end)

      unless Node.alive?() do
        {:ok, hostname} = :inet.gethostname()
        {:ok, _pid} = Node.start(:"cluster_rpc_heal_test@#{hostname}", :shortnames)
      end

      # connection: :standard_io keeps the peer's control channel off the
      # distributed connection itself, so disconnecting the distributed link
      # (below) drops OUR view of it without killing the peer - simulating a
      # stale/partial mesh view rather than a genuinely dead node.
      {:ok, peer_pid, peer_node} =
        :peer.start_link(%{
          name: :"cluster_rpc_heal_peer_#{System.unique_integer([:positive])}",
          connection: :standard_io
        })

      on_exit(fn ->
        try do
          :peer.stop(peer_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      assert Node.connect(peer_node)
      %{peer_node: peer_node}
    end

    test "reconnects and completes the call instead of refusing or relaying",
         %{peer_node: peer_node} do
      assert peer_node in Node.list()
      Node.disconnect(peer_node)
      refute peer_node in Node.list()

      # attempt_rpc/5's Node.connect/1 call should silently re-establish the
      # connection before ever falling back to a hub relay - the underlying
      # network path never went away, only this node's view of it did.
      assert Cluster.rpc(peer_node, :erlang, :node, [], 2_000) == peer_node
    end
  end
end
