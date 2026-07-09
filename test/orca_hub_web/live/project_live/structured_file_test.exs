defmodule OrcaHubWeb.ProjectLive.StructuredFileTest do
  @moduledoc """
  LiveView coverage for the Structured/Raw toggle over `.json` files in the
  project file viewer (scope `"project_file"`) — sibling of
  `OrcaHubWeb.ProjectLive.FileBlockEditorTest` for markdown files.
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.Projects

  setup do
    dir =
      Path.join(System.tmp_dir!(), "struct_file_project_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(Path.join(dir, "settings.json"), """
    {
      "permissions": {"allow": ["Bash(git *)", "Read"]},
      "flag": true
    }
    """)

    {:ok, project} = Projects.create_project(%{name: "struct-file-project", directory: dir})

    {:ok, project: project, dir: dir}
  end

  test "viewing a .json file defaults to Structured and renders its tree", %{
    conn: conn,
    project: project
  } do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}?file=settings.json")

    assert html =~ "Structured"
    assert html =~ "Raw"
    assert html =~ "permissions"
    assert html =~ "allow"
    refute html =~ "Parse error"
  end

  test "editing a leaf value persists via Projects.save_file", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=settings.json")
    path = OrcaHub.ConfigFile.encode_path(["flag"])

    html =
      render_click(view, "edit_value", %{"scope" => "project_file", "key" => "", "path" => path})

    assert html =~ ~s(name="value")

    render_submit(view, "save_value", %{
      "scope" => "project_file",
      "key" => "",
      "path" => path,
      "value_type" => "boolean",
      "value" => "false"
    })

    content = File.read!(Path.join(dir, "settings.json"))
    assert content =~ ~s("flag": false)
  end

  test "deleting an array element persists the removal via Projects.save_file", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=settings.json")
    allow_path = OrcaHub.ConfigFile.encode_path(["permissions", "allow", 0])

    render_click(view, "delete_key", %{
      "scope" => "project_file",
      "key" => "",
      "path" => allow_path
    })

    content = File.read!(Path.join(dir, "settings.json"))
    refute content =~ "Bash(git *)"
    assert content =~ "Read"
  end

  test "adding a key persists at the end of the object, preserving order", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=settings.json")
    perm_path = OrcaHub.ConfigFile.encode_path(["permissions"])

    render_submit(view, "add_key", %{
      "scope" => "project_file",
      "key" => "",
      "path" => perm_path,
      "name" => "deny",
      "value_type" => "string",
      "value" => "Write"
    })

    content = File.read!(Path.join(dir, "settings.json"))
    {:ok, tree} = OrcaHub.ConfigFile.parse(:json, content)
    permissions = OrcaHub.ConfigFile.get_node(tree, ["permissions"])
    assert Enum.map(permissions.entries, fn {k, _} -> k end) == ["allow", "deny"]
  end

  test "cancel closes the edit form without writing to disk", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=settings.json")
    path = OrcaHub.ConfigFile.encode_path(["flag"])

    render_click(view, "edit_value", %{"scope" => "project_file", "key" => "", "path" => path})
    html = render_click(view, "cancel", %{"scope" => "project_file", "key" => ""})

    refute html =~ ~s(phx-submit="save_value")
    content = File.read!(Path.join(dir, "settings.json"))
    assert content =~ ~s("flag": true)
  end

  test "switching to Raw shows the untouched raw text", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=settings.json")

    html =
      render_click(view, "toggle_view_mode", %{
        "scope" => "project_file",
        "key" => "",
        "mode" => "raw"
      })

    assert html =~ "permissions"
    assert html =~ "<pre"
  end

  test "a non-.json file never shows the Structured/Raw toggle", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    File.write!(Path.join(dir, "notes.txt"), "just some plain text")
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}?file=notes.txt")

    refute html =~ "Structured"
  end

  test "malformed JSON degrades to Raw-only with the parse error surfaced, never crashes", %{
    conn: conn,
    project: project,
    dir: dir
  } do
    File.write!(Path.join(dir, "broken.json"), "{ not valid json")
    {:ok, view, html} = live(conn, ~p"/projects/#{project.id}?file=broken.json")

    assert html =~ "Parse error"
    assert html =~ "not valid json"
    assert Process.alive?(view.pid)
  end

  describe ".toml files" do
    setup %{dir: dir} do
      File.write!(Path.join(dir, "config.toml"), """
      # config
      zeta = 1

      [alpha]
      nested = true
      """)

      :ok
    end

    test "viewing a .toml file defaults to Structured and renders its tree", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}?file=config.toml")

      assert html =~ "Structured"
      assert html =~ "alpha"
      assert html =~ "nested"
      refute html =~ "Parse error"
    end

    test "editing a leaf value persists via Projects.save_file", %{
      conn: conn,
      project: project,
      dir: dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=config.toml")
      path = OrcaHub.ConfigFile.encode_path(["zeta"])

      render_click(view, "edit_value", %{"scope" => "project_file", "key" => "", "path" => path})

      render_submit(view, "save_value", %{
        "scope" => "project_file",
        "key" => "",
        "path" => path,
        "value_type" => "number",
        "value" => "2"
      })

      content = File.read!(Path.join(dir, "config.toml"))
      assert content =~ "zeta = 2"
      assert content =~ "# config"
    end

    test "deleting a table removes it, preserving the rest", %{
      conn: conn,
      project: project,
      dir: dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=config.toml")
      path = OrcaHub.ConfigFile.encode_path(["alpha"])

      render_click(view, "delete_key", %{"scope" => "project_file", "key" => "", "path" => path})

      content = File.read!(Path.join(dir, "config.toml"))
      refute content =~ "[alpha]"
      assert content =~ "zeta = 1"
    end
  end

  describe ".yml files" do
    setup %{dir: dir} do
      File.write!(Path.join(dir, "config.yml"), """
      # config
      zeta: 1

      alpha:
        nested: true
      """)

      :ok
    end

    test "viewing a .yml file defaults to Structured and renders its tree", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}?file=config.yml")

      assert html =~ "Structured"
      assert html =~ "alpha"
      assert html =~ "nested"
      refute html =~ "Parse error"
    end

    test "editing a leaf value persists via Projects.save_file", %{
      conn: conn,
      project: project,
      dir: dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=config.yml")
      path = OrcaHub.ConfigFile.encode_path(["zeta"])

      render_click(view, "edit_value", %{"scope" => "project_file", "key" => "", "path" => path})

      render_submit(view, "save_value", %{
        "scope" => "project_file",
        "key" => "",
        "path" => path,
        "value_type" => "number",
        "value" => "2"
      })

      content = File.read!(Path.join(dir, "config.yml"))
      assert content =~ "zeta: 2"
      assert content =~ "# config"
    end

    test "deleting a mapping key removes its child block, preserving the rest", %{
      conn: conn,
      project: project,
      dir: dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}?file=config.yml")
      path = OrcaHub.ConfigFile.encode_path(["alpha"])

      render_click(view, "delete_key", %{"scope" => "project_file", "key" => "", "path" => path})

      content = File.read!(Path.join(dir, "config.yml"))
      refute content =~ "nested"
      assert content =~ "zeta: 1"
    end
  end
end
