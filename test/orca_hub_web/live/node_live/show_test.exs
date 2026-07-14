defmodule OrcaHubWeb.NodeLive.ShowTest do
  @moduledoc """
  Not async: mounting NodeLive.Show for a connected node now always loads
  `OrcaHub.NodeConfig` catalogs, which (absent an override) resolve against
  the real `~/.claude`/`~/.codex`/`~/.pi` — same rationale as
  `ProjectLive.AgentMemoryTest`. See `config_test.exs` for the Backend
  Configuration section's own behavior.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.ClusterNodes
  alias OrcaHub.Projects
  alias OrcaHub.Sessions

  setup do
    original_home = Application.get_env(:orca_hub, :node_config_home)
    home = Path.join(System.tmp_dir!(), "node_config_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    Application.put_env(:orca_hub, :node_config_home, home)

    on_exit(fn ->
      if original_home,
        do: Application.put_env(:orca_hub, :node_config_home, original_home),
        else: Application.delete_env(:orca_hub, :node_config_home)

      File.rm_rf(home)
    end)

    :ok
  end

  test "renders the local (connected) node's info without an unavailable banner", %{conn: conn} do
    {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

    {:ok, _} = Projects.create_project(%{name: "p1", directory: "/tmp/p1", node: n.name})
    {:ok, _} = Sessions.create_session(%{directory: "/tmp/s1", runner_node: n.name})

    {:ok, _view, html} = live(conn, ~p"/nodes/#{n.id}")

    assert html =~ "this-node"
    assert html =~ "connected"
    assert html =~ "Backend Configuration"
    assert html =~ "config-section-claude"
    assert html =~ "config-section-codex"
    assert html =~ "config-section-pi"
    refute html =~ "node-unavailable"
  end

  test "shows a clear node-unavailable state for an offline node", %{conn: conn} do
    {:ok, n} = ClusterNodes.upsert_seen("orca@long-gone", "long-gone-node")

    {:ok, _view, html} = live(conn, ~p"/nodes/#{n.id}")

    assert html =~ "long-gone-node"
    assert html =~ "not currently connected"
    assert html =~ "backend-config-node-unavailable"
    refute html =~ "config-section-claude"
  end

  describe "default backend/model controls" do
    test "with no defaults set, both controls render as '(no default)'", %{conn: conn} do
      {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

      {:ok, _view, html} = live(conn, ~p"/nodes/#{n.id}")

      assert html =~ "Default backend"
      assert html =~ "Default model"
      assert html =~ "(no default)"
    end

    test "updating default_backend persists and re-renders the selection", %{conn: conn} do
      {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

      {:ok, view, _html} = live(conn, ~p"/nodes/#{n.id}")

      html = render_change(view, "update_default_backend", %{"default_backend" => "claude"})

      assert html =~ ~s(value="claude" selected)
      assert ClusterNodes.get_by_name(n.name).default_backend == "claude"
    end

    test "clearing default_backend back to blank persists nil", %{conn: conn} do
      {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")
      {:ok, n} = ClusterNodes.update_node(n, %{default_backend: "claude"})

      {:ok, view, _html} = live(conn, ~p"/nodes/#{n.id}")

      render_change(view, "update_default_backend", %{"default_backend" => ""})

      assert ClusterNodes.get_by_name(n.name).default_backend == nil
    end

    test "default model renders as a select of Claude models when the default backend is claude",
         %{conn: conn} do
      {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")
      {:ok, n} = ClusterNodes.update_node(n, %{default_backend: "claude"})

      {:ok, _view, html} = live(conn, ~p"/nodes/#{n.id}")

      assert html =~ "claude-sonnet-5"
    end

    test "updating default_model persists", %{conn: conn} do
      {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")
      {:ok, n} = ClusterNodes.update_node(n, %{default_backend: "claude"})

      {:ok, view, _html} = live(conn, ~p"/nodes/#{n.id}")

      render_change(view, "update_default_model", %{"default_model" => "claude-sonnet-5"})

      assert ClusterNodes.get_by_name(n.name).default_model == "claude-sonnet-5"
    end

    test "default model renders as free text when the default backend is codex", %{conn: conn} do
      {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

      {:ok, n} =
        ClusterNodes.update_node(n, %{default_backend: "codex", default_model: "gpt-5.5"})

      {:ok, _view, html} = live(conn, ~p"/nodes/#{n.id}")

      assert html =~ ~s(name="default_model")
      assert html =~ ~s(type="text")
      assert html =~ "gpt-5.5"
    end
  end
end
