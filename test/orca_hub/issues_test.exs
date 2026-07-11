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

  describe "list_issues_for_project/1" do
    test "includes closed issues and excludes issues from other projects", %{project: project} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "other-project-2",
          directory: "/tmp/other-#{System.unique_integer([:positive])}",
          node: "n1@x"
        })

      {:ok, open_issue} = Issues.create_issue(%{title: "open one", project_id: project.id})
      {:ok, closed_issue} = Issues.create_issue(%{title: "closed one", project_id: project.id})
      {:ok, _} = Issues.update_issue(closed_issue, %{status: "closed"})
      {:ok, _} = Issues.create_issue(%{title: "elsewhere", project_id: other_project.id})

      ids = Issues.list_issues_for_project(project.id) |> Enum.map(& &1.id)

      assert Enum.sort(ids) == Enum.sort([open_issue.id, closed_issue.id])
    end
  end

  describe "list_issues_by_id_prefix/1" do
    test "matches issues whose id starts with the given prefix", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "prefix match", project_id: project.id})
      prefix = String.slice(issue.id, 0, 8)

      ids = Issues.list_issues_by_id_prefix(prefix) |> Enum.map(& &1.id)

      assert issue.id in ids
    end

    test "returns an empty list when nothing matches the prefix" do
      assert Issues.list_issues_by_id_prefix("deadbeef") == []
    end
  end

  describe "list_issues/0" do
    test "returns open issues before closed issues", %{project: project} do
      {:ok, open_a} = Issues.create_issue(%{title: "open a", project_id: project.id})
      {:ok, closed} = Issues.create_issue(%{title: "closed", project_id: project.id})
      {:ok, _} = Issues.update_issue(closed, %{status: "closed"})
      {:ok, open_b} = Issues.create_issue(%{title: "open b", project_id: project.id})

      ids =
        Issues.list_issues()
        |> Enum.map(& &1.id)
        |> Enum.filter(&(&1 in [open_a.id, closed.id, open_b.id]))

      closed_index = Enum.find_index(ids, &(&1 == closed.id))
      assert Enum.find_index(ids, &(&1 == open_a.id)) < closed_index
      assert Enum.find_index(ids, &(&1 == open_b.id)) < closed_index
    end
  end

  describe "close_issue/1 and reopen_issue/1" do
    test "closes an open issue", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "x", project_id: project.id})

      assert {:ok, closed} = Issues.close_issue(issue)
      assert closed.status == "closed"
    end

    test "reopens a closed issue", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "x", project_id: project.id, status: "closed"})

      assert {:ok, reopened} = Issues.reopen_issue(issue)
      assert reopened.status == "open"
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
