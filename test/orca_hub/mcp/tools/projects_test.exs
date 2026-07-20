defmodule OrcaHub.MCP.Tools.ProjectsTest do
  @moduledoc """
  Coverage for the `list_projects` MCP tool (FR 3e2828bc) — lets an agent
  resolve a project UUID for tools that require one (e.g.
  create_scheduled_trigger/create_webhook_trigger's project_id).
  """

  use OrcaHub.DataCase, async: true

  alias OrcaHub.MCP.Tools.Projects, as: ProjectsTool
  alias OrcaHub.Projects

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
end
