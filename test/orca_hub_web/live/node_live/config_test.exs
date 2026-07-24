defmodule OrcaHubWeb.NodeLive.ConfigTest do
  @moduledoc """
  LiveView coverage for NodeLive.Show's Backend Configuration section (view,
  create, raw-edit, delete each backend's global config files/dirs).

  Not async: uses the `:orca_hub, :node_config_home` Application env
  override (see `OrcaHub.NodeConfig`) to point the LiveView's rpc calls at a
  tmp "home" directory instead of the real `~/.claude`/`~/.codex`/`~/.pi` —
  global process state, same rationale as `ProjectLive.AgentMemoryTest`.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.ClusterNodes

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

    {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "config-test-node")

    {:ok, home: home, node: n}
  end

  defp open(conn, n) do
    {:ok, view, _html} = live(conn, ~p"/nodes/#{n.id}")
    view
  end

  test "expanding a backend section shows missing entries with a Create affordance", %{
    conn: conn,
    node: n
  } do
    view = open(conn, n)
    html = render_click(view, "toggle_config_section", %{"backend" => "claude"})

    assert html =~ "CLAUDE.md"
    assert html =~ "missing"
    assert html =~ "Create"
  end

  test "creating a top-level file writes it to disk and flips it to existing", %{
    conn: conn,
    node: n,
    home: home
  } do
    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "claude"})

    key = "claude|CLAUDE.md"
    html = render_click(view, "edit_config_entry", %{"key" => key})
    assert html =~ "# Personal instructions"

    html =
      render_submit(view, "save_config_entry", %{"key" => key, "content" => "# my notes\n"})

    assert html =~ "Saved CLAUDE.md"
    assert File.read!(Path.join([home, ".claude", "CLAUDE.md"])) == "# my notes\n"
    refute html =~ "config-editor-claude-CLAUDE.md"
  end

  test "viewing an existing markdown file renders it via the block editor", %{
    conn: conn,
    node: n,
    home: home
  } do
    claude_home = Path.join(home, ".claude")
    File.mkdir_p!(claude_home)
    File.write!(Path.join(claude_home, "CLAUDE.md"), "# Existing notes\n\nSome body text.")

    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "claude"})
    html = render_click(view, "toggle_config_entry", %{"key" => "claude|CLAUDE.md"})

    assert html =~ "Existing notes"
    assert html =~ "Some body text"
  end

  test "deleting an entry removes it from disk", %{conn: conn, node: n, home: home} do
    claude_home = Path.join(home, ".claude")
    File.mkdir_p!(claude_home)
    File.write!(Path.join(claude_home, "settings.json"), "{}\n")

    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "claude"})

    html = render_click(view, "delete_config_entry", %{"key" => "claude|settings.json"})

    assert html =~ "Deleted settings.json"
    refute File.exists?(Path.join(claude_home, "settings.json"))
  end

  test "creating a new file inside a flat dir (agents/)", %{conn: conn, node: n, home: home} do
    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "claude"})
    render_click(view, "toggle_config_dir", %{"backend" => "claude", "path" => "agents"})

    html =
      render_click(view, "new_config_entry", %{"backend" => "claude", "dir_path" => "agents"})

    assert html =~ ~s(name="name")

    html =
      render_submit(view, "save_new_config_entry", %{
        "name" => "reviewer.md",
        "content" => "---\nname: reviewer\n---\n\nReview things.\n"
      })

    assert html =~ "Created agents/reviewer.md"
    assert File.exists?(Path.join([home, ".claude", "agents", "reviewer.md"]))
  end

  test "creating a new skill writes <name>/SKILL.md", %{conn: conn, node: n, home: home} do
    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "claude"})
    render_click(view, "toggle_config_dir", %{"backend" => "claude", "path" => "skills"})
    render_click(view, "new_config_entry", %{"backend" => "claude", "dir_path" => "skills"})

    html =
      render_submit(view, "save_new_config_entry", %{
        "name" => "my-skill",
        "content" => "---\nname: my-skill\n---\n\nDo the thing.\n"
      })

    assert html =~ "Created skills/my-skill/SKILL.md"
    assert File.exists?(Path.join([home, ".claude", "skills", "my-skill", "SKILL.md"]))
  end

  test "codex's skills/ excludes the .system vendor subdirectory", %{
    conn: conn,
    node: n,
    home: home
  } do
    base = Path.join([home, ".codex", "skills"])
    File.mkdir_p!(Path.join(base, ".system"))
    File.write!(Path.join([base, ".system", "SKILL.md"]), "vendor")
    File.mkdir_p!(Path.join(base, "my-skill"))
    File.write!(Path.join([base, "my-skill", "SKILL.md"]), "mine")

    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "codex"})
    html = render_click(view, "toggle_config_dir", %{"backend" => "codex", "path" => "skills"})

    assert html =~ "my-skill"
    refute html =~ ".system"
  end

  test "codex flags AGENTS.override.md conflicts", %{conn: conn, node: n, home: home} do
    codex_home = Path.join(home, ".codex")
    File.mkdir_p!(codex_home)
    File.write!(Path.join(codex_home, "AGENTS.md"), "base")
    File.write!(Path.join(codex_home, "AGENTS.override.md"), "override")

    view = open(conn, n)
    html = render_click(view, "toggle_config_section", %{"backend" => "codex"})

    assert html =~ "AGENTS.override.md active"
  end

  test "pi's trust.json is viewable but has no Edit/Delete affordance", %{
    conn: conn,
    node: n,
    home: home
  } do
    pi_home = Path.join(home, ".pi/agent")
    File.mkdir_p!(pi_home)
    File.write!(Path.join(pi_home, "trust.json"), ~s({"trusted":[]}))

    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "pi"})
    html = render_click(view, "toggle_config_entry", %{"key" => "pi|trust.json"})

    assert html =~ "trusted"
    assert html =~ "View-only"

    refute html =~ ~s(phx-click="edit_config_entry" phx-value-key="pi|trust.json")
    refute html =~ ~s(phx-click="delete_config_entry" phx-value-key="pi|trust.json")
  end

  test "a hub-managed skill dir is badged and read-only in the node config browser", %{
    conn: conn,
    node: n,
    home: home
  } do
    claude_skills = Path.join([home, ".claude", "skills"])
    skill_dir = Path.join(claude_skills, "hub-skill")
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: \"hub-skill\"\n---\n\nBody.")

    File.write!(
      Path.join(claude_skills, ".orca-managed.json"),
      Jason.encode!(%{"skills" => %{"hub-skill" => "deadbeef"}})
    )

    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "claude"})
    html = render_click(view, "toggle_config_dir", %{"backend" => "claude", "path" => "skills"})

    assert html =~ "hub-skill"
    assert html =~ "hub-managed"
    assert html =~ "edit it there instead"

    refute html =~
             ~s(phx-click="edit_config_entry" phx-value-key="claude|skills/hub-skill/SKILL.md")

    refute html =~
             ~s(phx-click="delete_config_entry" phx-value-key="claude|skills/hub-skill/SKILL.md")
  end

  test "an unmanaged (hand-made) skill dir keeps its edit/delete affordances", %{
    conn: conn,
    node: n,
    home: home
  } do
    skill_dir = Path.join([home, ".claude", "skills", "hand-made"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "hand-written content")

    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "claude"})
    html = render_click(view, "toggle_config_dir", %{"backend" => "claude", "path" => "skills"})

    assert html =~ "hand-made"
    refute html =~ "hub-managed"

    assert html =~
             ~s(phx-click="edit_config_entry" phx-value-key="claude|skills/hand-made/SKILL.md")
  end

  test "a crafted key for a blocked file never leaks its content, even if it exists on disk", %{
    conn: conn,
    node: n,
    home: home
  } do
    claude_home = Path.join(home, ".claude")
    File.mkdir_p!(claude_home)
    File.write!(Path.join(claude_home, ".credentials.json"), ~s({"token":"super-secret-value"}))

    view = open(conn, n)
    render_click(view, "toggle_config_section", %{"backend" => "claude"})

    refute render(view) =~ "super-secret-value"

    view_html = render_click(view, "toggle_config_entry", %{"key" => "claude|.credentials.json"})
    refute view_html =~ "super-secret-value"

    edit_html = render_click(view, "edit_config_entry", %{"key" => "claude|.credentials.json"})
    refute edit_html =~ "super-secret-value"
  end
end
