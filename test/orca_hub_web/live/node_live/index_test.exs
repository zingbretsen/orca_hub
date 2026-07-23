defmodule OrcaHubWeb.NodeLive.IndexTest do
  @moduledoc """
  Not async: the "update all backends" sweep tests mutate the same
  process-wide Application env seams as `OrcaHub.BackendInstallerTest`
  (fixture CLI executables + fake commands) to drive the sweep
  deterministically instead of shelling out to the real claude/codex/pi CLIs.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.ClusterNodes

  test "renders the local node as connected and a stale node as offline", %{conn: conn} do
    {:ok, _local} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")
    {:ok, _offline} = ClusterNodes.upsert_seen("orca@long-gone", "long-gone-node")

    {:ok, _view, html} = live(conn, ~p"/nodes")

    assert html =~ "this-node"
    assert html =~ "long-gone-node"
    assert html =~ "connected"
    assert html =~ "offline"
  end

  test "lists connected nodes before offline ones", %{conn: conn} do
    {:ok, _} = ClusterNodes.upsert_seen("orca@long-gone", "long-gone-node")
    {:ok, _} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

    {:ok, _view, html} = live(conn, ~p"/nodes")

    connected_index = :binary.match(html, "this-node") |> elem(0)
    offline_index = :binary.match(html, "long-gone-node") |> elem(0)

    assert connected_index < offline_index
  end

  test "row links to the node's show page", %{conn: conn} do
    {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

    {:ok, _view, html} = live(conn, ~p"/nodes")

    assert html =~ ~p"/nodes/#{n.id}"
  end

  test "shows a badge for dial-enabled nodes", %{conn: conn} do
    {:ok, _} = ClusterNodes.create_node(%{name: "orca@dialed", dial: true})

    {:ok, _view, html} = live(conn, ~p"/nodes")

    assert html =~ "dials"
  end

  describe "add node form" do
    test "hidden until the Add node button is clicked", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/nodes")

      refute html =~ "add-node-form"
    end

    test "clicking Add node reveals the form, defaulting dial to checked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes")

      html = render_click(view, "show_add_node_form")

      assert html =~ "add-node-form"

      assert [dial_checkbox] =
               Regex.run(
                 ~r/<input type="checkbox"[^>]*name="cluster_node\[dial\]"[^>]*>/,
                 html
               )

      assert dial_checkbox =~ "checked"
    end

    test "cancel hides the form again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes")

      render_click(view, "show_add_node_form")
      html = render_click(view, "cancel_add_node_form")

      refute html =~ "add-node-form"
    end

    test "submitting creates the node and shows it in the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes")

      render_click(view, "show_add_node_form")

      html =
        view
        |> form("#add-node-form form", %{
          "cluster_node" => %{"name" => "orca@gb10", "display_name" => "GB10", "dial" => "true"}
        })
        |> render_submit()

      assert ClusterNodes.get_by_name("orca@gb10").dial
      assert html =~ "GB10"
      refute html =~ "add-node-form"
    end

    test "a duplicate name surfaces a friendly validation error instead of crashing", %{
      conn: conn
    } do
      {:ok, _} = ClusterNodes.create_node(%{name: "orca@dup", dial: true})

      {:ok, view, _html} = live(conn, ~p"/nodes")

      render_click(view, "show_add_node_form")

      html =
        view
        |> form("#add-node-form form", %{"cluster_node" => %{"name" => "orca@dup"}})
        |> render_submit()

      assert html =~ "has already been taken"
    end

    test "an invalid name shape surfaces a friendly validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes")

      render_click(view, "show_add_node_form")

      html =
        view
        |> form("#add-node-form form", %{"cluster_node" => %{"name" => "not-a-node-name"}})
        |> render_submit()

      assert html =~ "must look like basename@host"
    end
  end

  describe "update all backends sweep" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "node_index_sweep_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      claude = fixture_script(tmp_dir, "claude", "2.1.205 (Claude Code)")
      codex = fixture_script(tmp_dir, "codex", "codex-cli 0.142.6")
      pi = fixture_script(tmp_dir, "pi", "0.80.4")
      npm = fixture_script(tmp_dir, "npm", "9.9.9")

      original = %{
        commands: Application.get_env(:orca_hub, :backend_installer_commands),
        npm_executable: Application.get_env(:orca_hub, :npm_executable),
        claude_executable: Application.get_env(:orca_hub, :claude_executable),
        codex_executable: Application.get_env(:orca_hub, :codex_executable),
        pi_executable: Application.get_env(:orca_hub, :pi_executable)
      }

      Application.put_env(:orca_hub, :claude_executable, claude)
      Application.put_env(:orca_hub, :codex_executable, codex)
      Application.put_env(:orca_hub, :pi_executable, pi)
      Application.put_env(:orca_hub, :npm_executable, npm)

      Application.put_env(:orca_hub, :backend_installer_commands, %{
        {:claude, :update} => "echo claude-updated",
        {:codex, :update} => "false",
        {:pi, :update} => "echo pi-updated"
      })

      on_exit(fn ->
        File.rm_rf(tmp_dir)
        restore_env(:backend_installer_commands, original.commands)
        restore_env(:npm_executable, original.npm_executable)
        restore_env(:claude_executable, original.claude_executable)
        restore_env(:codex_executable, original.codex_executable)
        restore_env(:pi_executable, original.pi_executable)
      end)

      :ok
    end

    test "skips an offline node without contacting it, and updates the local node's backends",
         %{conn: conn} do
      {:ok, _local} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")
      {:ok, offline} = ClusterNodes.upsert_seen("orca@long-gone", "long-gone-node")

      {:ok, view, _html} = live(conn, ~p"/nodes")

      html = view |> element("#sweep-update-all") |> render_click()

      # Offline node is skipped synchronously — never contacted.
      for backend <- [:claude, :codex, :pi] do
        assert html =~ "backend-sweep-cell-#{offline.id}-#{backend}"
      end

      assert html =~ "skipped — node unavailable"

      # Local node's cells start out pending, then flip once its status
      # fetch (async) resolves and dispatches the update jobs.
      render_async(view)

      html = eventually_render(view, &(&1 =~ "backend-sweep-summary"))

      assert html =~ "done — 2.1.205"
      assert html =~ "exit code 1"
      assert html =~ "done — 0.80.4"

      # This dev-DB-backed test suite may have accumulated other offline node
      # rows from unrelated prior runs (see test-db-config notes) — those all
      # add to the skipped count non-deterministically, so only the
      # updated/failed counts (driven solely by this test's one connected
      # node) are asserted exactly.
      assert html =~ ~r/2 updated, 1 failed, \d+ skipped/

      refute html =~ "loading-spinner"
      refute has_element?(view, "#sweep-update-all[disabled]")
    end
  end

  defp fixture_script(tmp_dir, name, output) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/sh\necho \"#{output}\"\n")
    File.chmod!(path, 0o755)
    path
  end

  defp restore_env(key, nil), do: Application.delete_env(:orca_hub, key)
  defp restore_env(key, value), do: Application.put_env(:orca_hub, key, value)

  # The sweep's PubSub-driven cell transitions land in the LiveView process
  # independently of our test process calling render/1 — poll instead of
  # asserting immediately (same rationale as backend_installer_test.exs's
  # `eventually/2`, applied to rendered HTML instead of a local predicate).
  defp eventually_render(view, match_fun, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually_render(view, match_fun, deadline)
  end

  defp do_eventually_render(view, match_fun, deadline) do
    html = render(view)

    cond do
      match_fun.(html) ->
        html

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        do_eventually_render(view, match_fun, deadline)

      true ->
        flunk("condition not met within timeout; last render:\n#{html}")
    end
  end
end
