defmodule OrcaHub.ProjectsFileTreeTest do
  @moduledoc """
  ORCAHUB3-76: the file panel must list EVERY regular file, not just ones
  matching the editable-extension allow-list. That allow-list
  (`Projects.editable_file?/1`) is now purely an EDITABILITY predicate —
  whether a file can be opened in the text editor — not a visibility
  filter for `list_dir_entries/3` (the tree) or `list_editable_files/2`
  (the search path).
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Projects
  alias OrcaHub.Projects.Project

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "projects_file_tree_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir, project: %Project{directory: dir}}
  end

  describe "editable_file?/1" do
    test "an allow-listed extension is editable" do
      assert Projects.editable_file?("README.md")
    end

    test "a binary extension is not editable" do
      refute Projects.editable_file?("report.pdf")
      refute Projects.editable_file?("logo.png")
    end

    test "an allow-listed basename with no extension is editable" do
      assert Projects.editable_file?("Dockerfile")
    end

    test "a dotfile with no extension is editable" do
      assert Projects.editable_file?(".gitignore")
    end
  end

  describe "list_dir_entries/3 — the lazy tree path" do
    test "a non-editable file appears in the listing (positive control for ORCAHUB3-76)", %{
      dir: dir,
      project: project
    } do
      File.write!(Path.join(dir, "diagram.png"), <<137, 80, 78, 71, 0, 1, 2, 3>>)
      File.write!(Path.join(dir, "notes.md"), "hi")

      names =
        project
        |> Projects.list_dir_entries("")
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["diagram.png", "notes.md"]
    end

    test "still skips @skip_dirs (node_modules, .git, ...)", %{dir: dir, project: project} do
      File.mkdir_p!(Path.join(dir, "node_modules"))
      File.write!(Path.join([dir, "node_modules", "x.js"]), "noop")
      File.write!(Path.join(dir, "app.js"), "noop")

      names =
        project
        |> Projects.list_dir_entries("")
        |> Enum.map(& &1.name)

      assert names == ["app.js"]
    end

    test "a directory is still a :dir node, not swallowed as a file", %{
      dir: dir,
      project: project
    } do
      File.mkdir_p!(Path.join(dir, "assets"))

      [entry] = Projects.list_dir_entries(project, "")

      assert entry.type == :dir
      assert entry.name == "assets"
    end
  end

  describe "list_editable_files/2 — the search/autocomplete path" do
    test "a non-editable file is included (positive control)", %{dir: dir, project: project} do
      File.write!(Path.join(dir, "archive.zip"), "PK\x03\x04")

      assert "archive.zip" in Projects.list_editable_files(project)
    end

    test "still skips @skip_dirs during the recursive walk", %{dir: dir, project: project} do
      File.mkdir_p!(Path.join(dir, "deps"))
      File.write!(Path.join([dir, "deps", "y.ex"]), "noop")
      File.write!(Path.join(dir, "lib.ex"), "noop")

      assert Projects.list_editable_files(project) == ["lib.ex"]
    end
  end
end
