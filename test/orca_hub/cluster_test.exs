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
  alias OrcaHub.Sessions.Session

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

  describe "sort_by_priority_then_recency/1 — chronological ordering" do
    # Regression for the 2026-08-08 windowed-feed incident: a bare
    # `Enum.sort_by/2` on a `{priority, updated_at}` tuple compares
    # `%NaiveDateTime{}` ties via default struct/term ordering — fields in
    # ALPHABETICAL order (microsecond before minute/month/second) — not
    # `NaiveDateTime.compare/2`. Two sessions sharing the same (default)
    # priority and the same hour, but with the EARLIER session given the
    # LARGER microsecond component, would sort backwards under that bug.
    #
    # Exercised directly against in-memory structs (not persisted) because
    # `sessions.updated_at` is currently second-precision — persisting
    # would silently truncate the deliberately-inverted microseconds below
    # and mask the bug through the DB round-trip, independent of whether
    # the comparator itself is correct.
    test "same-priority sessions sort earliest-first even when microsecond components are inverted relative to real time" do
      earlier = %Session{id: "earlier", priority: 0, updated_at: ~N[2026-01-01 00:25:45.900000]}
      later = %Session{id: "later", priority: 0, updated_at: ~N[2026-01-01 00:26:02.100000]}

      tagged = [{node(), {later, nil}}, {node(), {earlier, nil}}]

      assert Cluster.sort_by_priority_then_recency(tagged) ==
               [{node(), {earlier, nil}}, {node(), {later, nil}}]
    end

    test "a higher (deferred) priority always sorts after a lower one, regardless of updated_at" do
      low_priority_but_older = %Session{
        id: "low",
        priority: 0,
        updated_at: ~N[2026-01-01 00:00:00.000000]
      }

      high_priority_but_newer = %Session{
        id: "high",
        priority: 1,
        updated_at: ~N[2026-01-01 12:00:00.000000]
      }

      tagged = [
        {node(), {high_priority_but_newer, nil}},
        {node(), {low_priority_but_older, nil}}
      ]

      assert Cluster.sort_by_priority_then_recency(tagged) ==
               [{node(), {low_priority_but_older, nil}}, {node(), {high_priority_but_newer, nil}}]
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

  # Bug: agent->agent messaging was refused whenever the CALLING node's own
  # (possibly partial) view of the mesh didn't include the target, even when
  # the hub could reach it fine — hub+agent is not guaranteed to be a full
  # mesh (confirmed in production: the discord-agent node only ever connects
  # to the hub, never to other agents). rpc/5 now relays through the hub
  # before giving up. These tests don't spin up a real disconnected peer
  # (plain distributed Erlang on one host auto-forms a full mesh — verified
  # by hand: a node started by a peer we're connected to becomes visible to
  # us too), so they instead cover the decision logic around that hub hop.
  # The "acting as an agent with no discoverable hub" case moved to
  # cluster_distributed_test.exs — it mutates the process-wide
  # `:orca_hub, :mode` Application env, same class of cross-test race as the
  # describes already split out there (see that file's moduledoc).
  describe "rpc/5 — hub relay (partial-mesh fallback)" do
    test "acting as the hub itself never relays (nowhere else to ask)" do
      # Default test config IS hub mode - the existing "unavailable target"
      # test above already covers this, this just makes the invariant explicit.
      assert OrcaHub.Mode.hub?()

      assert Cluster.rpc(@offline_node, Kernel, :+, [1, 2]) ==
               {:error, {:node_unavailable, @offline_node}}
    end
  end

  # The two describes that made the test VM a real distributed Erlang node
  # (Node.start/:peer/Node.connect) moved to cluster_distributed_test.exs —
  # that's process-wide state that raced with unrelated async tests
  # elsewhere in the suite. See that file's moduledoc and test_helper.exs
  # for the two-pass mix test / mix test --only distributed split.

  describe "node_unavailable_message/1" do
    test "explains an unassigned session" do
      assert Cluster.node_unavailable_message(:node_unassigned) =~ "no assigned node"
    end

    test "explains an offline node, naming it, and reads as hub-confirmed-down" do
      message = Cluster.node_unavailable_message({:node_unavailable, @offline_node})
      assert message =~ "not currently connected"
    end

    test "explains a check-failed node distinctly from a confirmed-down node" do
      message = Cluster.node_unavailable_message({:node_check_failed, @offline_node})
      assert message =~ "Could not confirm"
      refute message == Cluster.node_unavailable_message({:node_unavailable, @offline_node})
    end

    test "unwraps an {:error, reason} tuple the same way" do
      assert Cluster.node_unavailable_message({:error, :node_unassigned}) =~ "no assigned node"

      assert Cluster.node_unavailable_message({:error, {:node_check_failed, @offline_node}}) =~
               "Could not confirm"
    end

    test "nil for anything else" do
      assert Cluster.node_unavailable_message({:error, "some git error"}) == nil
      assert Cluster.node_unavailable_message(:busy) == nil
    end
  end

  describe "node_unavailable_error?/1" do
    test "true for all three rpc/5 refusal shapes" do
      assert Cluster.node_unavailable_error?({:error, :node_unassigned})
      assert Cluster.node_unavailable_error?({:error, {:node_unavailable, @offline_node}})
      assert Cluster.node_unavailable_error?({:error, {:node_check_failed, @offline_node}})
    end

    test "false for other results" do
      refute Cluster.node_unavailable_error?({:error, {:rpc_undef, {Kernel, :+, 2}}})
      refute Cluster.node_unavailable_error?({:ok, :whatever})
      refute Cluster.node_unavailable_error?(3)
    end
  end

  # A remote node_name/1 resolution is a blocking :erpc call (5s timeout);
  # for a node that's reachable-but-not-answering rather than cleanly
  # refused, that cost is paid PER CALL with no cap — see
  # perf_audit_projects_queue.md §3/§4 (the ymir ghost node), which found
  # deduping call count alone doesn't help when one specific node is always
  # slow. node_name/1 now caches the remote result (real or fallback) for
  # @node_name_cache_ttl_ms so repeat callers within the TTL never re-attempt
  # the erpc call at all.
  describe "node_name/1 — remote resolution is cached" do
    test "the local node bypasses the cache entirely (no erpc cost to cache)" do
      OrcaHub.Backend.Cache.invalidate({:cluster_node_name, node()})
      assert Cluster.node_name(node()) == Cluster.display_name()

      # node_name/1's local-node branch returns display_name() directly
      # without ever calling get_or_run/3 — so this key stays uncached, and
      # a fresh lookup still runs (and returns) its own fun.
      assert OrcaHub.Backend.Cache.get_or_run({:cluster_node_name, node()}, 60_000, fn ->
               :still_uncached
             end) == :still_uncached
    end

    test "a remote/offline node's resolved name is cached under {:cluster_node_name, node}" do
      OrcaHub.Backend.Cache.invalidate({:cluster_node_name, @offline_node})

      name = Cluster.node_name(@offline_node)
      assert name == "totally-offline-host"

      # get_or_run/3 only calls its fun on a cache miss — a fun that flunks
      # proves the entry above is already cached, not a coincidental repeat
      # computation.
      cached =
        OrcaHub.Backend.Cache.get_or_run({:cluster_node_name, @offline_node}, 60_000, fn ->
          flunk("node_name/1 should have populated the cache, not left it to us")
        end)

      assert cached == name
    end
  end

  describe "node_names/1 — batched, deduped node_name/1" do
    test "resolves each distinct node exactly once, keyed by node atom" do
      other = :"debian@totally-offline-host-node-names-test"
      OrcaHub.Backend.Cache.invalidate({:cluster_node_name, other})

      node_map = %{"a" => node(), "b" => node(), "c" => other}
      names = Cluster.node_names(node_map)

      assert map_size(names) == 2
      assert names[node()] == Cluster.node_name(node())
      assert names[other] == "totally-offline-host-node-names-test"
    end

    test "an empty node_map resolves nothing" do
      assert Cluster.node_names(%{}) == %{}
    end
  end
end
