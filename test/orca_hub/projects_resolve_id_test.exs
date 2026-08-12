defmodule OrcaHub.ProjectsResolveIdTest do
  @moduledoc """
  Coverage for `OrcaHub.Projects.resolve_id/1` — added for start_session's
  `project_id` arg (see `OrcaHub.MCP.Tools.Sessions`), which needs to accept
  a full UUID or a hex prefix without ever handing raw caller text straight
  to `Repo.get`/`get_project`, which raises `Ecto.Query.CastError` on
  non-UUID input. Mirrors `OrcaHub.IssuesTest`'s "resolve_id/1" coverage
  shape for `OrcaHub.Issues.resolve_id/1`.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Projects
  alias OrcaHub.Projects.Project

  defp unique_dir do
    Path.join(System.tmp_dir!(), "projects_resolve_id_test_#{System.unique_integer([:positive])}")
  end

  defp create_project!(attrs) do
    {:ok, project} =
      Projects.create_project(
        Map.merge(
          %{
            name: "resolve-id-test-#{System.unique_integer([:positive])}",
            directory: unique_dir()
          },
          attrs
        )
      )

    project
  end

  defp insert_project_with_id!(id, name) do
    {:ok, project} =
      %Project{}
      |> Ecto.Changeset.change(%{id: id, name: name, directory: unique_dir()})
      |> Repo.insert()

    project
  end

  describe "resolve_id/1 — full UUID" do
    test "resolves an existing project by its exact id" do
      project = create_project!(%{})

      assert {:ok, resolved} = Projects.resolve_id(project.id)
      assert resolved.id == project.id
    end

    test "a well-formed but non-existent UUID returns a friendly error, not a raise" do
      assert {:error, message} = Projects.resolve_id(Ecto.UUID.generate())
      assert message =~ "No project found"
    end

    test "excludes a soft-deleted project" do
      project = create_project!(%{})
      {:ok, deleted} = Projects.delete_project(project)

      assert {:error, message} = Projects.resolve_id(deleted.id)
      assert message =~ "No project found"
    end
  end

  describe "resolve_id/1 — hex prefix" do
    test "resolves via an unambiguous hex prefix (>= 8 chars)" do
      project = create_project!(%{})
      prefix = String.slice(String.replace(project.id, "-", ""), 0, 8)

      assert {:ok, resolved} = Projects.resolve_id(prefix)
      assert resolved.id == project.id
    end

    test "is case-insensitive" do
      project = create_project!(%{})
      prefix = String.slice(String.replace(project.id, "-", ""), 0, 8)

      assert {:ok, resolved} = Projects.resolve_id(String.upcase(prefix))
      assert resolved.id == project.id
    end

    test "a prefix matching no project returns a friendly error" do
      assert {:error, message} = Projects.resolve_id("aaaaaaaa")
      assert message =~ "No project found"
    end

    test "an ambiguous hex prefix lists every match instead of picking one" do
      id_a = "aaaaaaaa-1111-4111-8111-111111111111"
      id_b = "aaaaaaaa-2222-4222-8222-222222222222"
      insert_project_with_id!(id_a, "project a")
      insert_project_with_id!(id_b, "project b")

      assert {:error, message} = Projects.resolve_id("aaaaaaaa")
      assert message =~ "Multiple projects match"
      assert message =~ id_a
      assert message =~ id_b
    end

    test "a prefix shorter than 8 hex chars is rejected as invalid, not queried" do
      assert {:error, message} = Projects.resolve_id("abc123")
      assert message =~ "isn't a valid project id"
    end

    test "excludes a soft-deleted project from prefix matching" do
      project = create_project!(%{})
      {:ok, deleted} = Projects.delete_project(project)
      prefix = String.slice(String.replace(deleted.id, "-", ""), 0, 8)

      assert {:error, message} = Projects.resolve_id(prefix)
      assert message =~ "No project found"
    end
  end

  describe "resolve_id/1 — garbage input never raises" do
    test "arbitrary non-hex text is rejected with a friendly error, not an Ecto.Query.CastError" do
      assert {:error, message} = Projects.resolve_id("not-a-real-project-id at all!")
      assert message =~ "isn't a valid project id"
    end

    test "a non-string argument is rejected with a friendly error" do
      assert {:error, message} = Projects.resolve_id(nil)
      assert message =~ "must be a string"
    end
  end
end
