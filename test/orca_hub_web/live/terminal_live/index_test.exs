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

  alias OrcaHub.{Projects, Terminals}

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

  describe "pinning" do
    test "pinning a terminal moves it into the Pinned section", %{conn: conn} do
      suffix = System.unique_integer([:positive])

      {:ok, terminal} =
        Terminals.create_terminal(%{
          name: "Pin Test #{suffix}",
          directory: "/tmp/pin-term-#{suffix}"
        })

      {:ok, view, html} = live(conn, ~p"/terminals")

      # Initially the terminal should just appear on the page (no project)
      assert html =~ terminal.name
      refute html =~ "Pinned"

      # Pin the terminal
      html = render_click(view, "pin", %{"id" => terminal.id})

      # Now it should appear in the Pinned section
      assert html =~ "Pinned"
      assert html =~ ~r{hero-star-solid.*text-warning}
      assert html =~ terminal.name
    end

    test "unpinning returns a terminal to its project group", %{conn: conn} do
      suffix = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{
          name: "unpin-term-#{suffix}",
          directory: "/tmp/unpin-term-proj-#{suffix}"
        })

      {:ok, terminal} =
        Terminals.create_terminal(%{
          name: "Unpin Test #{suffix}",
          directory: "/tmp/unpin-term-#{suffix}",
          project_id: project.id
        })

      # Pin first
      {:ok, view, _html} = live(conn, ~p"/terminals")
      html = render_click(view, "pin", %{"id" => terminal.id})
      assert html =~ "Pinned"

      # Unpin
      html = render_click(view, "unpin", %{"id" => terminal.id})

      # Should no longer be in Pinned section
      refute html =~ "Pinned"
      # Should appear under its project group
      assert html =~ project.name
      assert html =~ terminal.name
    end
  end

  describe "grouping" do
    test "terminals render under the right project heading", %{conn: conn} do
      suffix = System.unique_integer([:positive])

      {:ok, project_a} =
        Projects.create_project(%{
          name: "term-group-a-#{suffix}",
          directory: "/tmp/term-group-a-#{suffix}"
        })

      {:ok, project_b} =
        Projects.create_project(%{
          name: "term-group-b-#{suffix}",
          directory: "/tmp/term-group-b-#{suffix}"
        })

      {:ok, _terminal_a} =
        Terminals.create_terminal(%{
          name: "Terminal A #{suffix}",
          directory: "/tmp/term-a-#{suffix}",
          project_id: project_a.id
        })

      {:ok, _terminal_b} =
        Terminals.create_terminal(%{
          name: "Terminal B #{suffix}",
          directory: "/tmp/term-b-#{suffix}",
          project_id: project_b.id
        })

      {:ok, _view, html} = live(conn, ~p"/terminals")

      # Both project names should be present
      assert html =~ project_a.name
      assert html =~ project_b.name
      assert html =~ "Terminal A #{suffix}"
      assert html =~ "Terminal B #{suffix}"
    end
  end
end
