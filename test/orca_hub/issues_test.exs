defmodule OrcaHub.IssuesTest do
  @moduledoc """
  Coverage for the minimal Issues context reintroduced to back the
  `file_feature_request` MCP tool (see `OrcaHub.Issues` moduledoc — the full
  feature was removed in `3ebb3fe`; only create/get/list-open/append-note
  survive here). Tool-level dedup/provenance behavior is covered in
  `OrcaHub.MCP.Tools.FeatureRequestsTest`.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{Issues, Projects}
  alias OrcaHub.Issues.Issue

  setup do
    dir = Path.join(System.tmp_dir!(), "issues_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "issues-ctx-test", directory: dir, node: "n1@x"})

    {:ok, project: project}
  end

  describe "create_issue/1" do
    test "creates an issue with defaults", %{project: project} do
      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(%{title: "Some friction", project_id: project.id})

      assert issue.title == "Some friction"
      assert issue.status == "open"
    end

    test "requires a title" do
      assert {:error, changeset} = Issues.create_issue(%{})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "rejects an unknown status", %{project: project} do
      assert {:error, changeset} =
               Issues.create_issue(%{title: "x", project_id: project.id, status: "bogus"})

      assert "is invalid" in errors_on(changeset).status
    end
  end

  describe "get_issue/1 and get_issue!/1" do
    test "fetches an existing issue", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "x", project_id: project.id})

      assert Issues.get_issue(issue.id).id == issue.id
      assert Issues.get_issue!(issue.id).id == issue.id
    end

    test "get_issue/1 returns nil for a missing id" do
      assert Issues.get_issue(Ecto.UUID.generate()) == nil
    end

    test "get_issue!/1 raises for a missing id" do
      assert_raise Ecto.NoResultsError, fn -> Issues.get_issue!(Ecto.UUID.generate()) end
    end
  end

  describe "list_open_issues_for_project/1" do
    test "excludes closed issues and issues from other projects", %{project: project} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "other-project",
          directory: "/tmp/other-#{System.unique_integer([:positive])}",
          node: "n1@x"
        })

      {:ok, open_issue} = Issues.create_issue(%{title: "open one", project_id: project.id})
      {:ok, closed_issue} = Issues.create_issue(%{title: "closed one", project_id: project.id})
      {:ok, _} = Issues.update_issue(closed_issue, %{status: "closed"})
      {:ok, _} = Issues.create_issue(%{title: "elsewhere", project_id: other_project.id})

      ids = Issues.list_open_issues_for_project(project.id) |> Enum.map(& &1.id)

      assert ids == [open_issue.id]
    end
  end

  describe "append_note/2" do
    test "sets notes when previously empty", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "x", project_id: project.id})

      assert {:ok, updated} = Issues.append_note(issue, "first note")
      assert updated.notes == "first note"
    end

    test "appends to existing notes separated by a blank line", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "x", project_id: project.id, notes: "first"})

      assert {:ok, updated} = Issues.append_note(issue, "second")
      assert updated.notes == "first\n\nsecond"
    end
  end
end
