defmodule OrcaHub.MCP.Tools.ProjectsTest do
  @moduledoc """
  Coverage for the project MCP tools: `list_projects` (FR 3e2828bc) — which
  lets an agent resolve a project UUID for tools that require one (e.g.
  create_scheduled_trigger/create_webhook_trigger's project_id) — and
  `move_project_directory`, whose defining property is that a bare call
  PREVIEWS rather than moving a real directory on disk.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.MCP.Tools.Projects, as: ProjectsTool
  alias OrcaHub.Projects
  alias OrcaHub.Projects.Project

  defp decode!(%{"isError" => false, "content" => [%{"text" => text}]}), do: Jason.decode!(text)

  defp error_text(%{"isError" => true, "content" => [%{"text" => text}]}), do: text

  defp tmp_project(context) do
    root = Path.join(System.tmp_dir!(), "move_tool_#{System.unique_integer([:positive])}")
    source = Path.join(root, "src")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "marker.txt"), "hello")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "move-tool-#{System.unique_integer([:positive])}",
        directory: source,
        node: Atom.to_string(node())
      })

    Map.merge(context, %{project: project, root: root, source: source})
  end

  describe "list_projects" do
    test "returns id, name, directory, and node for non-deleted projects" do
      {:ok, project} =
        Projects.create_project(%{
          name: "list-projects-test",
          directory: "/tmp/list-projects-test-#{System.unique_integer([:positive])}",
          node: Atom.to_string(node())
        })

      result = ProjectsTool.call("list_projects", %{}, %{})

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      entry = Enum.find(decoded, &(&1["id"] == project.id))
      assert entry != nil
      assert entry["name"] == project.name
      assert entry["directory"] == project.directory
      assert entry["node"] != nil
      refute Map.has_key?(entry, "env_allowlist")
    end

    test "excludes soft-deleted projects" do
      {:ok, project} =
        Projects.create_project(%{
          name: "deleted-projects-test",
          directory: "/tmp/deleted-projects-test-#{System.unique_integer([:positive])}"
        })

      {:ok, deleted_project} = Projects.delete_project(project)

      result = ProjectsTool.call("list_projects", %{}, %{})

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      refute Enum.any?(decoded, &(&1["id"] == deleted_project.id))
    end
  end

  describe "move_project_directory" do
    setup :tmp_project

    test "a bare call is a dry run: it reports the plan and moves nothing", %{
      project: project,
      root: root,
      source: source
    } do
      destination = Path.join(root, "moved")

      result =
        ProjectsTool.call(
          "move_project_directory",
          %{"project_id" => project.id, "new_directory" => destination},
          %{}
        )

      plan = decode!(result)

      assert plan["dry_run"] == true
      assert plan["from"] == source
      assert plan["to"] == destination
      assert plan["blockers"] == []
      assert Enum.any?(plan["projects"], &(&1["id"] == project.id))

      # Nothing happened: the directory is where it was, the destination does
      # not exist, and the row still points at the old path.
      assert File.dir?(source)
      refute File.exists?(destination)
      assert Repo.get!(Project, project.id).directory == source
    end

    test "dry_run: false actually moves the directory and rewrites the row", %{
      project: project,
      root: root,
      source: source
    } do
      destination = Path.join(root, "moved")

      result =
        ProjectsTool.call(
          "move_project_directory",
          %{
            "project_id" => project.id,
            "new_directory" => destination,
            "dry_run" => false
          },
          %{}
        )

      moved = decode!(result)

      assert moved["dry_run"] == false
      assert moved["to"] == destination
      assert moved["sessions"] == 0

      assert Enum.any?(
               moved["projects"],
               &(&1["id"] == project.id and &1["from"] == source and &1["to"] == destination)
             )

      refute File.exists?(source)
      assert File.read!(Path.join(destination, "marker.txt")) == "hello"
      assert Repo.get!(Project, project.id).directory == destination
    end

    test "resolves a project id by hex prefix", %{project: project, root: root, source: source} do
      prefix = String.slice(project.id, 0, 8)

      plan =
        ProjectsTool.call(
          "move_project_directory",
          %{"project_id" => prefix, "new_directory" => Path.join(root, "moved")},
          %{}
        )
        |> decode!()

      assert plan["from"] == source
      assert plan["dry_run"] == true
    end

    test "a non-boolean dry_run is rejected rather than coerced", %{
      project: project,
      root: root,
      source: source
    } do
      result =
        ProjectsTool.call(
          "move_project_directory",
          %{
            "project_id" => project.id,
            "new_directory" => Path.join(root, "moved"),
            "dry_run" => "false"
          },
          %{}
        )

      assert error_text(result) =~ "dry_run must be true or false"
      assert File.dir?(source)
    end

    test "surfaces DirectoryMove's human-readable error verbatim", %{project: project} do
      result =
        ProjectsTool.call(
          "move_project_directory",
          %{"project_id" => project.id, "new_directory" => "relative/path"},
          %{}
        )

      assert error_text(result) =~ "must be an absolute path"
    end

    test "an unknown project id is an error, not a crash" do
      result =
        ProjectsTool.call(
          "move_project_directory",
          %{"project_id" => "nope", "new_directory" => "/tmp/whatever"},
          %{}
        )

      assert %{"isError" => true} = result
    end

    test "the tool is registered on the shared tool list with a destructive description" do
      definition = Enum.find(OrcaHub.MCP.Tools.list(), &(&1["name"] == "move_project_directory"))

      assert definition != nil
      assert definition["description"] =~ "REAL DIRECTORY ON DISK"
      assert definition["description"] =~ "REWRITES DATABASE ROWS"
      assert definition["inputSchema"]["properties"]["dry_run"]["default"] == true
    end
  end
end
