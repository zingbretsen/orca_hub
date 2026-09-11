defmodule OrcaHub.HubRPCTest do
  @moduledoc """
  Coverage for `HubRPC.call/4`'s per-call `:timeout` option — added so a
  single known-slow hub call (e.g. `memory_duplicates/1`, ORCAHUB3-XX) can
  get a bigger erpc budget without raising the default for every other call.

  The fast tests below run every pass and only exercise the hub-mode local
  `apply/3` branch (where `opts` is accepted but has nothing to bound). The
  `:distributed` test proves the option actually reaches `:erpc.call/5` on
  the agent branch — tagged and excluded by default like every other real
  cross-node test (see `cluster_distributed_test.exs`), run with
  `mix test --only distributed`.
  """
  use ExUnit.Case, async: false

  alias OrcaHub.HubRPC

  describe "call/3 and call/4 — hub mode (local apply, no erpc involved)" do
    test "call/3 (no opts) still calls locally and returns the result" do
      assert HubRPC.call(Kernel, :+, [1, 2]) == 3
    end

    test "call/4 with a custom timeout still calls locally (option only consulted on the agent/erpc branch)" do
      assert HubRPC.call(Kernel, :+, [1, 2], timeout: 1) == 3
    end
  end

  describe "call/4 — agent mode (erpc), :distributed" do
    @describetag :distributed

    setup do
      Supervisor.terminate_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker)
      on_exit(fn -> Supervisor.restart_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker) end)

      unless Node.alive?() do
        {:ok, hostname} = :inet.gethostname()
        {:ok, _pid} = Node.start(:"hub_rpc_test@#{hostname}", :shortnames)
      end

      {:ok, peer_pid, peer_node} =
        :peer.start_link(%{name: :"hub_rpc_timeout_peer_#{System.unique_integer([:positive])}"})

      on_exit(fn ->
        try do
          :peer.stop(peer_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      # Load OrcaHub's code onto the peer so it can play the hub role — it
      # needs OrcaHub.Mode loaded to answer find_hub_node/0's discovery call
      # (same setup as cluster_distributed_test.exs's hub-relay test).
      # OrcaHub.Mode.hub?/0 defaults to :hub since this bare peer has no
      # ORCA_MODE config of its own — exactly what we want here.
      :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
      assert :erpc.call(peer_node, OrcaHub.Mode, :hub?, [], 5_000)

      Application.put_env(:orca_hub, :mode, :agent)
      on_exit(fn -> Application.delete_env(:orca_hub, :mode) end)

      %{peer_node: peer_node}
    end

    test "a custom :timeout shorter than a slow call raises an erpc timeout" do
      assert_raise ErlangError, ~r/timeout/, fn ->
        HubRPC.call(:timer, :sleep, [2_000], timeout: 100)
      end
    end

    test "the same slow call succeeds under a longer custom timeout" do
      assert HubRPC.call(:timer, :sleep, [200], timeout: 5_000) == :ok
    end
  end
end
