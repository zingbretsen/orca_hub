defmodule OrcaHubWeb.TerminalLive.IndexTest do
  @moduledoc """
  Coverage for the per-terminal `Cluster.node_name/1` N+1 fix
  (perf_audit_admin_pages.md §2) — same bug class already fixed on Sessions
  Index (a456865). `Cluster.node_names/1` is resolved unconditionally in
  mount/refresh_terminals (not gated behind `@clustered`, since a
  terminal's `runner_node` field is real data regardless of whether any
  peer is currently connected), so no real distributed peer is needed to
  exercise it — a plain fake node atom is enough.
  """

  # async: false — Cluster.list_terminals/0 goes through Cluster.fan_out/4,
  # which calls :erpc.call/5 even for the local node; the spawned erpc
  # process needs the shared sandbox connection async: true (per-test manual
  # ownership) doesn't extend to (same reasoning as terminal_channel_test.exs).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Terminals

  test "resolves Cluster.node_name/1 once per distinct runner_node, not once per terminal",
       %{conn: conn} do
    # 5 NEW terminals spread across only 2 distinct (fake) runner nodes we
    # fully control — this asserts against those two known atoms directly
    # rather than deriving "distinct nodes" from whatever else happens to be
    # in the shared dev DB, so the test isn't coupled to unrelated
    # pre-existing rows (or to NodeFilter.on_mount's own separate,
    # already-once-per-connected-node Cluster.node_info() call for the local
    # node, which the trace below would also pick up).
    suffix = System.unique_integer([:positive])
    fake_a = :"orca@dedup-fake-a-#{suffix}"
    fake_b = :"orca@dedup-fake-b-#{suffix}"

    for i <- 1..3 do
      {:ok, _} =
        Terminals.create_terminal(%{
          name: "dedup-a-#{suffix}-#{i}",
          directory: "/tmp/dedup-term-a-#{suffix}-#{i}",
          runner_node: Atom.to_string(fake_a)
        })
    end

    for i <- 1..2 do
      {:ok, _} =
        Terminals.create_terminal(%{
          name: "dedup-b-#{suffix}-#{i}",
          directory: "/tmp/dedup-term-b-#{suffix}-#{i}",
          runner_node: Atom.to_string(fake_b)
        })
    end

    # node_name/1 is called from node_names/1 INSIDE the same module
    # (Cluster) — an intra-module ("local") call, which :erlang.trace_pattern
    # only observes when the :local flag is passed.
    :erlang.trace_pattern({OrcaHub.Cluster, :node_name, 1}, [], [:local])
    :erlang.trace(self(), true, [:call, :set_on_spawn])

    {:ok, _view, _html} = live(conn, ~p"/terminals")

    :erlang.trace(self(), false, [:call, :set_on_spawn])
    :erlang.trace_pattern({OrcaHub.Cluster, :node_name, 1}, false, [])

    # Before the fix, the template built one Cluster.node_name/1 call PER
    # TERMINAL row — 3 calls for fake_a's terminals, 2 for fake_b's; the fix
    # (Cluster.node_names/1) resolves each exactly once.
    assert count_node_name_calls_for([fake_a, fake_b]) == 2
  end

  defp count_node_name_calls_for(target_nodes, count \\ 0) do
    receive do
      {:trace, _pid, :call, {OrcaHub.Cluster, :node_name, [arg]}} ->
        if arg in target_nodes,
          do: count_node_name_calls_for(target_nodes, count + 1),
          else: count_node_name_calls_for(target_nodes, count)
    after
      200 -> count
    end
  end
end
