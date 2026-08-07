defmodule OrcaHubWeb.TriggerLive.IndexTest do
  @moduledoc """
  Coverage for the per-trigger `Cluster.node_name/1` N+1 fix
  (perf_audit_admin_pages.md §1) — same bug class already fixed on Sessions
  Index (a456865). `Cluster.node_names/1` is resolved unconditionally in
  mount/handle_event (not gated behind `@clustered`, since a project's
  `node` field is real data regardless of whether any peer is currently
  connected), so no real distributed peer is needed to exercise it — a
  plain fake node atom is enough.
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, Triggers}

  test "resolves Cluster.node_name/1 once per distinct node, not once per trigger",
       %{conn: conn} do
    # 5 NEW triggers (via their project's node) spread across only 2
    # distinct (fake) nodes we fully control — this asserts against those
    # two known atoms directly rather than deriving "distinct nodes" from
    # whatever else happens to be in the shared dev DB, so the test isn't
    # coupled to unrelated pre-existing rows (or to NodeFilter.on_mount's
    # own separate, already-once-per-connected-node Cluster.node_info() call
    # for the local node, which the trace below would also pick up).
    suffix = System.unique_integer([:positive])
    fake_a = :"orca@dedup-fake-a-#{suffix}"
    fake_b = :"orca@dedup-fake-b-#{suffix}"

    for i <- 1..3 do
      {:ok, project} =
        Projects.create_project(%{
          name: "dedup-trig-a-#{suffix}-#{i}",
          directory: "/tmp/dedup-trig-a-#{suffix}-#{i}",
          node: Atom.to_string(fake_a)
        })

      {:ok, _} =
        Triggers.create_trigger(%{
          name: "dedup-a-#{suffix}-#{i}",
          prompt: "hi",
          type: "webhook",
          project_id: project.id
        })
    end

    for i <- 1..2 do
      {:ok, project} =
        Projects.create_project(%{
          name: "dedup-trig-b-#{suffix}-#{i}",
          directory: "/tmp/dedup-trig-b-#{suffix}-#{i}",
          node: Atom.to_string(fake_b)
        })

      {:ok, _} =
        Triggers.create_trigger(%{
          name: "dedup-b-#{suffix}-#{i}",
          prompt: "hi",
          type: "webhook",
          project_id: project.id
        })
    end

    # node_name/1 is called from node_names/1 INSIDE the same module
    # (Cluster) — an intra-module ("local") call, which :erlang.trace_pattern
    # only observes when the :local flag is passed.
    :erlang.trace_pattern({OrcaHub.Cluster, :node_name, 1}, [], [:local])
    :erlang.trace(self(), true, [:call, :set_on_spawn])

    {:ok, _view, _html} = live(conn, ~p"/triggers")

    :erlang.trace(self(), false, [:call, :set_on_spawn])
    :erlang.trace_pattern({OrcaHub.Cluster, :node_name, 1}, false, [])

    # Before the fix, the template built one Cluster.node_name/1 call PER
    # TRIGGER row — 3 calls for fake_a's triggers, 2 for fake_b's; the fix
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
