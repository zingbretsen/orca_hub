defmodule OrcaHubWeb.SessionLive.IndexDistributedTest do
  @moduledoc """
  `SessionLive.Index`'s `group_sessions/3` only takes its per-node grouping
  branch (the one with the `Cluster.node_name/1` N+1 fix — see
  perf_session_load.md §2) when `Node.list() != []`, so exercising it needs a
  real distributed node the same way cluster_distributed_test.exs does. Kept
  in its own `:distributed`-tagged module for the same reason that file is
  split out: `Node.start/1`/`:peer.start_link/1` is process-wide state that
  would race with the rest of the (async) suite.
  """
  use OrcaHubWeb.ConnCase, async: false

  @moduletag :distributed

  import Phoenix.LiveViewTest

  alias OrcaHub.Sessions

  setup do
    # ClusterNodeTracker writes to the DB from its own process (outside this
    # test's Ecto sandbox checkout) whenever a real :nodeup fires — pause it
    # for the duration, same as cluster_distributed_test.exs.
    Supervisor.terminate_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker)
    on_exit(fn -> Supervisor.restart_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker) end)

    unless Node.alive?() do
      {:ok, hostname} = :inet.gethostname()
      {:ok, _pid} = Node.start(:"session_index_dedup_test@#{hostname}", :shortnames)
    end

    {:ok, peer_pid, _peer_node} =
      :peer.start_link(%{
        name: :"session_index_dedup_peer_#{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      try do
        :peer.stop(peer_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  test "resolves Cluster.node_name/1 once per distinct runner_node, not once per session",
       %{conn: conn} do
    # 5 NEW sessions spread across only 2 distinct (fake) runner nodes, on
    # top of whatever the shared dev DB (see CLAUDE.md "Testing") already
    # has. We assert against the *distinct* node count computed the same
    # way the LiveView does, rather than a hardcoded number, so pre-existing
    # dev-DB sessions don't make this test flaky.
    for i <- 1..3 do
      {:ok, _} =
        Sessions.create_session(%{
          directory: "/tmp/dedup-a-#{i}",
          runner_node: "orca@dedup-fake-a"
        })
    end

    for i <- 1..2 do
      {:ok, _} =
        Sessions.create_session(%{
          directory: "/tmp/dedup-b-#{i}",
          runner_node: "orca@dedup-fake-b"
        })
    end

    tagged_sessions = OrcaHub.Cluster.list_sessions(:manual)
    total_sessions = length(tagged_sessions)

    distinct_runner_nodes =
      tagged_sessions
      |> Enum.map(fn {_node, session} -> session.runner_node || node() end)
      |> Enum.uniq()
      |> length()

    # Sanity check the fixture actually exercises a real N+1 shape (more
    # sessions than distinct nodes) — otherwise the assertion below would
    # pass trivially even without the fix.
    assert total_sessions > distinct_runner_nodes

    :erlang.trace_pattern({OrcaHub.Cluster, :node_name, 1}, [], [])
    :erlang.trace(self(), true, [:call, :set_on_spawn])

    {:ok, _view, _html} = live(conn, ~p"/sessions")

    :erlang.trace(self(), false, [:call, :set_on_spawn])
    :erlang.trace_pattern({OrcaHub.Cluster, :node_name, 1}, false, [])

    # Before the fix, session_node_names built one Cluster.node_name/1 call
    # PER SESSION; the fix resolves it once per DISTINCT runner node.
    assert count_node_name_calls() == distinct_runner_nodes
  end

  defp count_node_name_calls(count \\ 0) do
    receive do
      {:trace, _pid, :call, {OrcaHub.Cluster, :node_name, _args}} ->
        count_node_name_calls(count + 1)
    after
      200 -> count
    end
  end
end
