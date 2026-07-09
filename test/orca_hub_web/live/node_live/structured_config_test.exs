defmodule OrcaHubWeb.NodeLive.StructuredConfigTest do
  @moduledoc """
  LiveView coverage for the Structured/Raw toggle on `:json` catalog
  entries in `NodeLive.Show`'s Backend Configuration section (see
  `OrcaHubWeb.NodeLive.ConfigTest` for the raw-edit/create/delete coverage
  this builds on). Same tmp-`:node_config_home` isolation rationale as
  that module.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.ClusterNodes

  setup do
    original_home = Application.get_env(:orca_hub, :node_config_home)
    home = Path.join(System.tmp_dir!(), "struct_node_home_#{System.unique_integer([:positive])}")
    claude_home = Path.join(home, ".claude")
    File.mkdir_p!(claude_home)
    Application.put_env(:orca_hub, :node_config_home, home)

    File.write!(Path.join(claude_home, "settings.json"), """
    {
      "permissions": {"allow": ["Bash(git *)", "Read"]},
      "flag": true
    }
    """)

    on_exit(fn ->
      if original_home,
        do: Application.put_env(:orca_hub, :node_config_home, original_home),
        else: Application.delete_env(:orca_hub, :node_config_home)

      File.rm_rf(home)
    end)

    {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "struct-config-test-node")

    {:ok, home: home, node: n}
  end

  defp open_expanded(conn, n) do
    {:ok, view, _html} = live(conn, ~p"/nodes/#{n.id}")
    render_click(view, "toggle_config_section", %{"backend" => "claude"})
    html = render_click(view, "toggle_config_entry", %{"key" => "claude|settings.json"})
    {view, html}
  end

  test "a valid .json entry defaults to Structured and renders its tree", %{conn: conn, node: n} do
    {_view, html} = open_expanded(conn, n)

    assert html =~ "Structured"
    assert html =~ "Raw"
    assert html =~ "permissions"
    assert html =~ "allow"
    refute html =~ "Parse error"
  end

  test "editing a leaf value persists through NodeConfig.write_entry", %{
    conn: conn,
    node: n,
    home: home
  } do
    {view, _html} = open_expanded(conn, n)

    path = OrcaHub.ConfigFile.encode_path(["flag"])

    html =
      render_click(view, "edit_value", %{
        "scope" => "node_config",
        "key" => "claude|settings.json",
        "path" => path
      })

    assert html =~ ~s(name="value")

    render_submit(view, "save_value", %{
      "scope" => "node_config",
      "key" => "claude|settings.json",
      "path" => path,
      "value_type" => "boolean",
      "value" => "false"
    })

    content = File.read!(Path.join([home, ".claude", "settings.json"]))
    assert content =~ ~s("flag": false)
  end

  test "deleting an array element persists the removal and keeps siblings", %{
    conn: conn,
    node: n,
    home: home
  } do
    {view, _html} = open_expanded(conn, n)
    allow_path = OrcaHub.ConfigFile.encode_path(["permissions", "allow", 0])

    render_click(view, "delete_key", %{
      "scope" => "node_config",
      "key" => "claude|settings.json",
      "path" => allow_path
    })

    content = File.read!(Path.join([home, ".claude", "settings.json"]))
    refute content =~ "Bash(git *)"
    assert content =~ "Read"
  end

  test "adding a key to a nested object persists at the end, preserving order", %{
    conn: conn,
    node: n,
    home: home
  } do
    {view, _html} = open_expanded(conn, n)
    perm_path = OrcaHub.ConfigFile.encode_path(["permissions"])

    render_submit(view, "add_key", %{
      "scope" => "node_config",
      "key" => "claude|settings.json",
      "path" => perm_path,
      "name" => "deny",
      "value_type" => "string",
      "value" => "Write"
    })

    content = File.read!(Path.join([home, ".claude", "settings.json"]))
    {:ok, tree} = OrcaHub.ConfigFile.parse(:json, content)
    permissions = OrcaHub.ConfigFile.get_node(tree, ["permissions"])
    assert Enum.map(permissions.entries, fn {k, _} -> k end) == ["allow", "deny"]
    assert OrcaHub.ConfigFile.get_node(tree, ["permissions", "deny"]).value == "Write"
  end

  test "cancel closes the edit form without writing to disk", %{conn: conn, node: n, home: home} do
    {view, _html} = open_expanded(conn, n)
    path = OrcaHub.ConfigFile.encode_path(["flag"])

    render_click(view, "edit_value", %{
      "scope" => "node_config",
      "key" => "claude|settings.json",
      "path" => path
    })

    html =
      render_click(view, "cancel", %{"scope" => "node_config", "key" => "claude|settings.json"})

    refute html =~ ~s(phx-submit="save_value")
    content = File.read!(Path.join([home, ".claude", "settings.json"]))
    assert content =~ ~s("flag": true)
  end

  test "switching to Raw shows the untouched raw text with no structured tree", %{
    conn: conn,
    node: n
  } do
    {view, _html} = open_expanded(conn, n)

    html =
      render_click(view, "toggle_view_mode", %{
        "scope" => "node_config",
        "key" => "claude|settings.json",
        "mode" => "raw"
      })

    assert html =~ "permissions"
    assert html =~ "<pre"
  end

  test "malformed JSON degrades to Raw-only with the parse error surfaced, never crashes", %{
    conn: conn,
    node: n,
    home: home
  } do
    File.write!(Path.join([home, ".claude", "settings.json"]), "{ not valid json")

    view = fn ->
      {:ok, view, _html} = live(conn, ~p"/nodes/#{n.id}")
      render_click(view, "toggle_config_section", %{"backend" => "claude"})
      view
    end

    view = view.()
    html = render_click(view, "toggle_config_entry", %{"key" => "claude|settings.json"})

    assert html =~ "Parse error"
    assert html =~ "not valid json"
    assert Process.alive?(view.pid)
  end
end
