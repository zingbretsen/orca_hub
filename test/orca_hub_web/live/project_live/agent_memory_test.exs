defmodule OrcaHubWeb.ProjectLive.AgentMemoryTest do
  @moduledoc """
  LiveView coverage for the "Agent Memory" section on ProjectLive.Show —
  review/edit/delete for the three memory sources (Claude Code, the shared
  AGENTS.md "Project memory" section, Codex native memories).

  Not async: uses the `:orca_hub, :agent_memory_home` Application env
  override (see `OrcaHub.AgentMemory.claude_memory_dir/2` and
  `codex_memories_dir/1`) to point the LiveView's rpc calls at a tmp "home"
  directory instead of the real `~/.claude`/`~/.codex` — that's global
  process state, so this file can't safely run concurrently with itself or
  reuse the app-wide default while other tests might also touch it.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{AgentMemory, Projects}

  setup do
    original_home = Application.get_env(:orca_hub, :agent_memory_home)

    home =
      Path.join(System.tmp_dir!(), "agent_memory_home_#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    Application.put_env(:orca_hub, :agent_memory_home, home)

    on_exit(fn ->
      if original_home,
        do: Application.put_env(:orca_hub, :agent_memory_home, original_home),
        else: Application.delete_env(:orca_hub, :agent_memory_home)

      File.rm_rf(home)
    end)

    project_dir =
      Path.join(System.tmp_dir!(), "agent_memory_project_#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)
    on_exit(fn -> File.rm_rf(project_dir) end)

    {:ok, project} = Projects.create_project(%{name: "memory-project", directory: project_dir})

    {:ok, project: project, project_dir: project_dir, home: home}
  end

  defp memory_dir(project_dir, home),
    do: AgentMemory.claude_memory_dir(project_dir, home_dir: home)

  test "renders the Agent Memory section with all three groups", %{
    conn: conn,
    project: project
  } do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

    assert html =~ "Agent Memory"
    assert html =~ "Claude Code"
    assert html =~ "Shared AGENTS.md"
    assert html =~ "Codex (native)"
    assert html =~ "No Claude Code memory directory found on this node."
    assert html =~ "Codex built-in memories not enabled on this node."
    assert html =~ "pi has no memory store of its own"
  end

  test "an offline project node disables the section instead of crashing", %{conn: conn} do
    dir =
      Path.join(System.tmp_dir!(), "agent_memory_offline_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "offline-memory-project",
        directory: dir,
        node: "debian@totally-offline-host"
      })

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

    assert html =~ "not currently connected"
    assert html =~ "Agent memory review is disabled"
  end

  describe "Claude Code memories" do
    setup %{project_dir: project_dir, home: home} do
      memory_dir = memory_dir(project_dir, home)
      File.mkdir_p!(memory_dir)

      File.write!(Path.join(memory_dir, "foo.md"), """
      ---
      name: foo
      description: "A feedback note"
      metadata:
        type: feedback
      ---

      Body for foo.
      """)

      File.write!(Path.join(memory_dir, "MEMORY.md"), """
      # Memory Index

      - [foo.md](foo.md) - A feedback note
      """)

      :ok
    end

    test "lists memories with name/type/description and edits raw content", %{
      conn: conn,
      project: project,
      project_dir: project_dir,
      home: home
    } do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "foo"
      assert html =~ "feedback"
      assert html =~ "A feedback note"

      view
      |> element("#claude-memory-edit-foo\\.md")
      |> render_click()

      assert has_element?(view, "#claude-memory-editor-foo\\.md")

      view
      |> element("#claude-memory-foo\\.md form")
      |> render_submit(%{
        "filename" => "foo.md",
        "content" => "---\nname: foo\n---\nUpdated body."
      })

      memory_dir = memory_dir(project_dir, home)
      assert File.read!(Path.join(memory_dir, "foo.md")) == "---\nname: foo\n---\nUpdated body."
    end

    test "deleting a memory removes the file and its MEMORY.md index line", %{
      conn: conn,
      project: project,
      project_dir: project_dir,
      home: home
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("#claude-memory-delete-foo\\.md")
      |> render_click()

      memory_dir = memory_dir(project_dir, home)
      refute File.exists?(Path.join(memory_dir, "foo.md"))
      refute File.read!(Path.join(memory_dir, "MEMORY.md")) =~ "foo.md"

      refute has_element?(view, "#claude-memory-foo\\.md")
    end

    test "expanding a memory renders its rendered content", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      refute render(view) =~ "Body for foo."

      view
      |> element("[phx-click=toggle_claude_memory][phx-value-filename='foo.md']")
      |> render_click()

      assert render(view) =~ "Body for foo."
    end

    test "expanding a memory renders it as tap-to-edit blocks, not raw markdown", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("[phx-click=toggle_claude_memory][phx-value-filename='foo.md']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(phx-value-scope="claude_memory")
      assert html =~ ~s(phx-value-key="foo.md")
      assert has_element?(view, ~s([phx-click=edit_block][phx-value-key="foo.md"]))
    end

    test "editing a body block persists the change and leaves frontmatter byte-identical", %{
      conn: conn,
      project: project,
      project_dir: project_dir,
      home: home
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("[phx-click=toggle_claude_memory][phx-value-filename='foo.md']")
      |> render_click()

      view
      |> element(~s([phx-click=edit_block][phx-value-key="foo.md"][phx-value-index="0"]))
      |> render_click()

      assert has_element?(view, "#claude-memory-block-foo\\.md-editor-0")

      view
      |> element("form[phx-submit=save_block]")
      |> render_submit(%{"content" => "Updated body for foo."})

      memory_dir = memory_dir(project_dir, home)
      content = File.read!(Path.join(memory_dir, "foo.md"))

      assert content == """
             ---
             name: foo
             description: "A feedback note"
             metadata:
               type: feedback
             ---

             Updated body for foo.\
             """

      refute content =~ "Body for foo."
    end

    test "deleting the only body block leaves frontmatter intact with no body", %{
      conn: conn,
      project: project,
      project_dir: project_dir,
      home: home
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("[phx-click=toggle_claude_memory][phx-value-filename='foo.md']")
      |> render_click()

      view
      |> element(~s([phx-click=delete_block][phx-value-key="foo.md"][phx-value-index="0"]))
      |> render_click()

      memory_dir = memory_dir(project_dir, home)
      content = File.read!(Path.join(memory_dir, "foo.md"))

      assert content == """
             ---
             name: foo
             description: "A feedback note"
             metadata:
               type: feedback
             ---\
             """

      refute content =~ "Body for foo."
    end
  end

  describe "Claude memory frontmatter round-trip with multiple body blocks" do
    setup %{project_dir: project_dir, home: home} do
      memory_dir = memory_dir(project_dir, home)
      File.mkdir_p!(memory_dir)

      File.write!(Path.join(memory_dir, "multi.md"), """
      ---
      name: multi
      description: "Has two body paragraphs"
      metadata:
        type: project
      ---

      First paragraph.

      Second paragraph.
      """)

      File.write!(Path.join(memory_dir, "MEMORY.md"), """
      # Memory Index

      - [multi.md](multi.md) - Has two body paragraphs
      """)

      :ok
    end

    test "editing one body block leaves the other block and the frontmatter untouched", %{
      conn: conn,
      project: project,
      project_dir: project_dir,
      home: home
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("[phx-click=toggle_claude_memory][phx-value-filename='multi.md']")
      |> render_click()

      view
      |> element(~s([phx-click=edit_block][phx-value-key="multi.md"][phx-value-index="1"]))
      |> render_click()

      view
      |> element("form[phx-submit=save_block]")
      |> render_submit(%{"content" => "Updated second paragraph."})

      memory_dir = memory_dir(project_dir, home)
      content = File.read!(Path.join(memory_dir, "multi.md"))

      assert content =~ "name: multi"
      assert content =~ "type: project"
      assert content =~ "First paragraph."
      assert content =~ "Updated second paragraph."
      refute content =~ "Second paragraph.\n"
    end
  end

  describe "Claude MEMORY.md index" do
    setup %{project_dir: project_dir, home: home} do
      memory_dir = memory_dir(project_dir, home)
      File.mkdir_p!(memory_dir)

      File.write!(Path.join(memory_dir, "foo.md"), """
      ---
      name: foo
      ---

      Body for foo.
      """)

      File.write!(Path.join(memory_dir, "MEMORY.md"), """
      # Memory Index

      - [foo.md](foo.md) - A note
      """)

      :ok
    end

    test "toggling the index open renders it as tap-to-edit blocks", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")

      refute html =~ ~s(phx-value-scope="claude_index")

      view
      |> element("#claude-index-toggle")
      |> render_click()

      html = render(view)
      assert html =~ ~s(phx-value-scope="claude_index")
      assert html =~ "Memory Index"
    end

    test "editing a block in the index persists via AgentMemory.save_claude_index", %{
      conn: conn,
      project: project,
      project_dir: project_dir,
      home: home
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("#claude-index-toggle")
      |> render_click()

      view
      |> element(~s([phx-click=edit_block][phx-value-scope="claude_index"][phx-value-index="1"]))
      |> render_click()

      view
      |> element("form[phx-submit=save_block]")
      |> render_submit(%{"content" => "- [foo.md](foo.md) - Updated note"})

      memory_dir = memory_dir(project_dir, home)
      content = File.read!(Path.join(memory_dir, "MEMORY.md"))
      assert content =~ "Updated note"
      refute content =~ "- A note"
    end

    test "Raw Edit still opens the whole-file textarea", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("#claude-index-toggle")
      |> render_click()

      view
      |> element("#claude-index-raw-edit")
      |> render_click()

      assert has_element?(view, "#claude-index-editor")
    end
  end

  describe "AGENTS.md project memory" do
    setup %{project_dir: project_dir} do
      File.write!(Path.join(project_dir, "AGENTS.md"), """
      # AGENTS

      ## Project memory

      - First fact.
      - Second fact.
      """)

      :ok
    end

    test "lists bullets and edits one in place", %{
      conn: conn,
      project: project,
      project_dir: project_dir
    } do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "First fact."
      assert html =~ "Second fact."

      view
      |> element("#agents-md-edit-0")
      |> render_click()

      view
      |> element("#agents-md-memory-0 form")
      |> render_submit(%{"index" => "0", "text" => "Updated first fact."})

      content = File.read!(Path.join(project_dir, "AGENTS.md"))
      assert content =~ "Updated first fact."
      refute content =~ "First fact."
      assert content =~ "Second fact."
    end

    test "deleting a bullet removes only that line", %{
      conn: conn,
      project: project,
      project_dir: project_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("#agents-md-delete-0")
      |> render_click()

      content = File.read!(Path.join(project_dir, "AGENTS.md"))
      refute content =~ "First fact."
      assert content =~ "Second fact."
    end
  end

  describe "Codex native memories" do
    setup %{home: home} do
      dir = AgentMemory.codex_memories_dir(home_dir: home)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "note.md"), "A codex note.")
      :ok
    end

    test "lists and edits Codex memory files", %{conn: conn, project: project, home: home} do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "note.md"

      view
      |> element("#codex-memory-edit-note\\.md")
      |> render_click()

      view
      |> element("#codex-memory-note\\.md form")
      |> render_submit(%{"filename" => "note.md", "content" => "Updated codex note."})

      dir = AgentMemory.codex_memories_dir(home_dir: home)
      assert File.read!(Path.join(dir, "note.md")) == "Updated codex note."
    end

    test "deleting a Codex memory removes the file", %{conn: conn, project: project, home: home} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("#codex-memory-delete-note\\.md")
      |> render_click()

      dir = AgentMemory.codex_memories_dir(home_dir: home)
      refute File.exists?(Path.join(dir, "note.md"))
    end

    test "renders the global-scope caption", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "not scoped to this project"
    end

    test "expanding a Codex memory renders it as tap-to-edit blocks", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      refute render(view) =~ "A codex note."

      view
      |> element("[phx-click=toggle_codex_memory][phx-value-filename='note.md']")
      |> render_click()

      html = render(view)
      assert html =~ "A codex note."
      assert html =~ ~s(phx-value-scope="codex_memory")
      assert html =~ ~s(phx-value-key="note.md")
    end

    test "editing a block in an expanded Codex memory persists via AgentMemory.save_codex_memory",
         %{conn: conn, project: project, home: home} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("[phx-click=toggle_codex_memory][phx-value-filename='note.md']")
      |> render_click()

      view
      |> element(~s([phx-click=edit_block][phx-value-key="note.md"][phx-value-index="0"]))
      |> render_click()

      view
      |> element("form[phx-submit=save_block]")
      |> render_submit(%{"content" => "Updated codex note via block edit."})

      dir = AgentMemory.codex_memories_dir(home_dir: home)
      assert File.read!(Path.join(dir, "note.md")) == "Updated codex note via block edit."
    end

    test "deleting a block in an expanded Codex memory persists the removal", %{
      conn: conn,
      project: project,
      home: home
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      view
      |> element("[phx-click=toggle_codex_memory][phx-value-filename='note.md']")
      |> render_click()

      view
      |> element(~s([phx-click=delete_block][phx-value-key="note.md"][phx-value-index="0"]))
      |> render_click()

      dir = AgentMemory.codex_memories_dir(home_dir: home)
      assert File.read!(Path.join(dir, "note.md")) == ""
    end

    test "groups and badges subdirectory files", %{conn: conn, project: project, home: home} do
      dir = AgentMemory.codex_memories_dir(home_dir: home)
      rollout_dir = Path.join(dir, "rollout_summaries")
      File.mkdir_p!(rollout_dir)
      File.write!(Path.join(rollout_dir, "2026-07-08.md"), "A rollout summary.")

      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "rollout_summaries/2026-07-08.md"
      assert html =~ "rollout summary"

      # Slash in the relative path is swapped for "--" in DOM ids.
      assert has_element?(view, "#codex-memory-edit-rollout_summaries--2026-07-08\\.md")

      view
      |> element("#codex-memory-edit-rollout_summaries--2026-07-08\\.md")
      |> render_click()

      view
      |> element("#codex-memory-rollout_summaries--2026-07-08\\.md form")
      |> render_submit(%{
        "filename" => "rollout_summaries/2026-07-08.md",
        "content" => "Updated rollout summary."
      })

      assert File.read!(Path.join(rollout_dir, "2026-07-08.md")) == "Updated rollout summary."
    end

    test "groups and badges the nested extensions/<name>/<file> shape", %{
      conn: conn,
      project: project,
      home: home
    } do
      dir = AgentMemory.codex_memories_dir(home_dir: home)
      ad_hoc_dir = Path.join([dir, "extensions", "ad_hoc"])
      File.mkdir_p!(ad_hoc_dir)
      File.write!(Path.join(ad_hoc_dir, "instructions.md"), "Ad-hoc extension notes.")

      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "extensions/ad_hoc/instructions.md"
      assert html =~ "extension"

      view
      |> element("#codex-memory-delete-extensions--ad_hoc--instructions\\.md")
      |> render_click()

      refute File.exists?(Path.join(ad_hoc_dir, "instructions.md"))
    end
  end

  describe "Codex feature-flag messaging when the dir doesn't exist yet" do
    test "says 'not enabled' when no config.toml is present", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "Codex built-in memories not enabled on this node."
      refute html =~ "none have been consolidated yet"
    end

    test "says 'enabled, none consolidated yet' when the feature flag is on but the memories dir is missing",
         %{conn: conn, project: project, home: home} do
      codex_dir = Path.join(home, ".codex")
      File.mkdir_p!(codex_dir)

      File.write!(Path.join(codex_dir, "config.toml"), """
      [features]
      memories = true
      """)

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~
               "Codex memories are enabled on this node, but none have been consolidated yet."

      refute html =~ "not enabled on this node."
    end
  end
end
