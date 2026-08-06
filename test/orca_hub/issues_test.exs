defmodule OrcaHub.IssuesTest do
  @moduledoc """
  Coverage for `OrcaHub.Issues` — both the original minimal contract (still
  relied on by `OrcaHub.MCP.Tools.FeatureRequests` and `IssueLive`; see the
  module's moduledoc for why those signatures are frozen) and the
  issues_spec.md Phase 1 additions: atomic key allocation (§3.2.2), the
  three-form id resolution (§3.2.4), dedup generalized to `(project_id,
  kind)` (§7), the close-time commit/attempt freeze (§4.2/§4.3, §6.6), and
  the reopen preserve-then-clear sequence (§3.5.1). Key allocation's
  concurrency guarantee is covered separately in
  `OrcaHub.IssuesKeyAllocationTest` (needs a shared, non-async sandbox).
  Tool-level dedup/provenance behavior for the FR board is covered in
  `OrcaHub.MCP.Tools.FeatureRequestsTest`.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{Issues, Projects, Sessions}
  alias OrcaHub.Issues.Issue

  setup do
    dir = Path.join(System.tmp_dir!(), "issues_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "issues-ctx-test",
        directory: dir,
        node: "n1@x",
        key_prefix: unique_key_prefix()
      })

    {:ok, project: project, dir: dir}
  end

  defp unique_key_prefix(base \\ "TP") do
    (base <> Integer.to_string(System.unique_integer([:positive])))
    |> String.slice(0, 10)
  end

  defp init_git_repo(dir) do
    System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
  end

  defp commit_in(dir, filename, message) do
    File.write!(Path.join(dir, filename), filename)
    System.cmd("git", ["add", "."], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", message], cd: dir, stderr_to_stdout: true)
  end

  # Inserts an issue with an explicit, caller-chosen id — used only to make
  # the ambiguous-hex-prefix disambiguation test deterministic (random
  # Ecto.UUID.generate/0 ids won't reliably collide on an 8-char prefix).
  defp insert_issue_with_id(id, project_id, title) do
    %Issue{}
    |> Ecto.Changeset.change(%{id: id, title: title, project_id: project_id, status: "open"})
    |> Repo.insert()
  end

  describe "create_issue/1" do
    test "creates an issue with defaults", %{project: project} do
      assert {:ok, %Issue{} = issue} =
               Issues.create_issue(%{title: "Some friction", project_id: project.id})

      assert issue.title == "Some friction"
      assert issue.status == "open"
      assert issue.kind == "task"
      assert issue.commits == []
      assert issue.attempts == []
    end

    test "requires a title" do
      assert {:error, changeset} = Issues.create_issue(%{})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "allocates a sequential key_number scoped to the project", %{project: project} do
      {:ok, issue_a} = Issues.create_issue(%{title: "first", project_id: project.id})
      {:ok, issue_b} = Issues.create_issue(%{title: "second", project_id: project.id})

      assert issue_a.key_number == 1
      assert issue_b.key_number == 2
      assert Repo.get!(OrcaHub.Projects.Project, project.id).issue_counter == 2
    end

    test "key_number allocation is scoped per project, not global", %{project: project} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "other-key-scope",
          directory: "/tmp/other-key-scope-#{System.unique_integer([:positive])}",
          node: "n1@x",
          key_prefix: unique_key_prefix()
        })

      {:ok, a} = Issues.create_issue(%{title: "a", project_id: project.id})
      {:ok, b} = Issues.create_issue(%{title: "b", project_id: other_project.id})

      assert a.key_number == 1
      assert b.key_number == 1
    end

    test "a changeset failure rolls back the key_number increment too", %{project: project} do
      assert {:ok, issue} = Issues.create_issue(%{title: "ok one", project_id: project.id})
      assert issue.key_number == 1

      # No title -> changeset validation failure inside the same transaction
      # as the increment.
      assert {:error, %Ecto.Changeset{}} =
               Issues.create_issue(%{project_id: project.id, status: "bogus-status"})

      assert Repo.get!(OrcaHub.Projects.Project, project.id).issue_counter == 1

      {:ok, next} = Issues.create_issue(%{title: "next one", project_id: project.id})
      assert next.key_number == 2
    end

    test "without a project_id, key_number stays nil" do
      assert {:ok, issue} = Issues.create_issue(%{title: "keyless"})
      assert issue.key_number == nil
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

  describe "resolve_id/1 — three forms (issues_spec.md §3.2.4)" do
    test "form 1: resolves by full UUID", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "resolve by uuid", project_id: project.id})

      assert {:ok, resolved} = Issues.resolve_id(issue.id)
      assert resolved.id == issue.id
    end

    test "form 1: a well-formed but unknown UUID is a friendly not-found error" do
      assert {:error, message} = Issues.resolve_id(Ecto.UUID.generate())
      assert message =~ "No issue found"
    end

    test "form 2: resolves by rendered key (PREFIX-N)", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "resolve by key", project_id: project.id})
      key = Issues.render_key(Repo.preload(issue, :project))

      assert {:ok, resolved} = Issues.resolve_id(key)
      assert resolved.id == issue.id
    end

    test "form 2: rendered key resolution is case-insensitive on the prefix", %{
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "resolve by key ci", project_id: project.id})
      key = Issues.render_key(Repo.preload(issue, :project))

      assert {:ok, resolved} = Issues.resolve_id(String.downcase(key))
      assert resolved.id == issue.id
    end

    test "form 2: a key referencing a real project but unknown number is a friendly error", %{
      project: project
    } do
      assert {:error, message} = Issues.resolve_id("#{project.key_prefix}-999999")
      assert message =~ "No issue found with key"
    end

    test "form 2 falls through to form 3 when no project has that key_prefix" do
      # "zzzzzzzz-99" matches the rendered-key SHAPE, but no project is
      # named ZZZZZZZZ — per §3.2.4 point 2 this must fall through to
      # hex-prefix resolution rather than returning a bogus "no such key"
      # error. "zzzzzzzz" isn't valid hex either, so the final result
      # should be the generic invalid-id error, not a key-shaped one.
      assert {:error, message} = Issues.resolve_id("zzzzzzzz-99")
      assert message =~ "isn't a valid issue id"
      refute message =~ "No issue found with key"
    end

    test "form 3: resolves by an unambiguous hex prefix", %{project: project} do
      {:ok, issue} =
        Issues.create_issue(%{title: "resolve by hex prefix", project_id: project.id})

      prefix = String.slice(issue.id, 0, 8)

      assert {:ok, resolved} = Issues.resolve_id(prefix)
      assert resolved.id == issue.id
    end

    test "form 3: an ambiguous hex prefix lists every match instead of picking one", %{
      project: project
    } do
      id_a = "aaaaaaaa-1111-4111-8111-111111111111"
      id_b = "aaaaaaaa-2222-4222-8222-222222222222"
      {:ok, _} = insert_issue_with_id(id_a, project.id, "issue a")
      {:ok, _} = insert_issue_with_id(id_b, project.id, "issue b")

      assert {:error, message} = Issues.resolve_id("aaaaaaaa")
      assert message =~ "Multiple issues match"
      assert message =~ id_a
      assert message =~ id_b
    end

    test "form 3: rejects a too-short or non-hex string" do
      assert {:error, message} = Issues.resolve_id("nope")
      assert message =~ "isn't a valid issue id"
    end
  end

  describe "find_similar_open_issue/3 (dedup, issues_spec.md §7)" do
    test "matches via case-insensitive substring, scoped to the same kind", %{project: project} do
      {:ok, existing} =
        Issues.create_issue(%{title: "Fix the login bug", project_id: project.id, kind: "task"})

      assert %Issue{id: id} =
               Issues.find_similar_open_issue(project.id, "task", "fix the login bug urgently")

      assert id == existing.id
    end

    test "matches via >= 60% word-overlap even without substring containment", %{
      project: project
    } do
      {:ok, existing} =
        Issues.create_issue(%{
          title: "search tools blind spot for orca queries",
          project_id: project.id
        })

      assert %Issue{id: id} =
               Issues.find_similar_open_issue(
                 project.id,
                 "task",
                 "orca queries trigger a search tools blind spot"
               )

      assert id == existing.id
    end

    test "does not match a different kind", %{project: project} do
      {:ok, _fr} =
        Issues.create_issue(%{
          title: "Fix the login bug",
          project_id: project.id,
          kind: "feature_request"
        })

      assert Issues.find_similar_open_issue(project.id, "task", "Fix the login bug") == nil
    end

    test "does not match a closed or abandoned issue", %{project: project} do
      {:ok, closed} = Issues.create_issue(%{title: "Fix the login bug", project_id: project.id})
      {:ok, _closed} = Issues.update_issue(closed, %{status: "closed"})

      {:ok, abandoned} =
        Issues.create_issue(%{title: "Fix the login bug too", project_id: project.id})

      {:ok, _abandoned} = Issues.update_issue(abandoned, %{status: "abandoned"})

      assert Issues.find_similar_open_issue(project.id, "task", "Fix the login bug") == nil
    end

    test "does not match an unrelated title", %{project: project} do
      {:ok, _} =
        Issues.create_issue(%{title: "Completely unrelated thing", project_id: project.id})

      assert Issues.find_similar_open_issue(project.id, "task", "Fix the login bug") == nil
    end
  end

  describe "close_issue/2 — close-time freeze (issues_spec.md §4.2/§4.3/§6.6)" do
    test "freezes commits from both attempt sessions and the OrcaHub-Issue trailer", %{
      project: project,
      dir: dir
    } do
      init_git_repo(dir)
      {:ok, issue} = Issues.create_issue(%{title: "Fix the flaky thing", project_id: project.id})
      key = Issues.render_key(Repo.preload(issue, :project))

      {:ok, session} =
        Sessions.create_session(%{directory: dir, project_id: project.id, issue_id: issue.id})

      commit_in(
        dir,
        "a.txt",
        "Fix the flaky thing\n\nOrcaHub-Session: #{session.id}\nOrcaHub-Issue: #{key}"
      )

      assert {:ok, closed} =
               Issues.close_issue(issue, %{
                 outcome: "resolved",
                 resolution: "Landed the fix.",
                 session_id: session.id
               })

      assert closed.status == "closed"
      assert closed.resolution == "Landed the fix."
      assert closed.closed_by_session_id == session.id
      assert %DateTime{} = closed.closed_at

      assert [%{subject: "Fix the flaky thing"}] = closed.commits

      assert [%{session_id: attempt_session_id, status: _, outcome: _}] = closed.attempts
      assert attempt_session_id == session.id
    end

    test "freezes empty commits/attempts when nothing links to the issue", %{
      project: project,
      dir: dir
    } do
      init_git_repo(dir)
      {:ok, issue} = Issues.create_issue(%{title: "no evidence at all", project_id: project.id})

      assert {:ok, closed} =
               Issues.close_issue(issue, %{outcome: "abandoned", resolution: "never got to it"})

      assert closed.status == "abandoned"
      assert closed.commits == []
      assert closed.attempts == []
      assert %DateTime{} = closed.closed_at
    end

    test "sets superseded_by_issue_id when passed", %{project: project} do
      {:ok, old_issue} = Issues.create_issue(%{title: "old approach", project_id: project.id})
      {:ok, new_issue} = Issues.create_issue(%{title: "new approach", project_id: project.id})

      assert {:ok, closed} =
               Issues.close_issue(old_issue, %{
                 outcome: "abandoned",
                 resolution: "superseded by the new approach",
                 superseded_by_issue_id: new_issue.id
               })

      assert closed.superseded_by_issue_id == new_issue.id
    end

    test "requires an outcome", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "x", project_id: project.id})
      assert {:error, :invalid_outcome} = Issues.close_issue(issue, %{resolution: "done"})
    end

    test "requires a resolution", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "x", project_id: project.id})
      assert {:error, :resolution_required} = Issues.close_issue(issue, %{outcome: "resolved"})
    end

    test "rejects an unknown outcome", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "x", project_id: project.id})

      assert {:error, :invalid_outcome} =
               Issues.close_issue(issue, %{outcome: "done", resolution: "x"})
    end
  end

  describe "reopen_issue/2 — preserve-then-clear (issues_spec.md §3.5.1)" do
    test "archives the frozen snapshot into notes before clearing it", %{
      project: project,
      dir: dir
    } do
      init_git_repo(dir)
      {:ok, issue} = Issues.create_issue(%{title: "flaky test", project_id: project.id})

      {:ok, session} =
        Sessions.create_session(%{directory: dir, project_id: project.id, issue_id: issue.id})

      key = Issues.render_key(Repo.preload(issue, :project))
      commit_in(dir, "fix.txt", "Fix flaky test\n\nOrcaHub-Issue: #{key}")

      {:ok, closed} =
        Issues.close_issue(issue, %{
          outcome: "resolved",
          resolution: "Fixed the race.",
          session_id: session.id
        })

      assert {:ok, reopened} = Issues.reopen_issue(closed, session.id)

      assert reopened.status == "open"
      assert reopened.commits == []
      assert reopened.attempts == []
      assert reopened.resolution == nil
      assert reopened.closed_at == nil
      assert reopened.closed_by_session_id == nil

      assert reopened.notes =~ "reopened"
      assert reopened.notes =~ "session #{session.id}"
      assert reopened.notes =~ "Previously closed as resolved"
      assert reopened.notes =~ "session #{session.id}"
      assert reopened.notes =~ "Fixed the race."
      assert reopened.notes =~ "1 commit(s)"
      assert reopened.notes =~ "Fix flaky test"
      assert reopened.notes =~ "1 attempt(s)"
    end

    test "does not clear superseded_by_issue_id on reopen", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "old approach", project_id: project.id})
      {:ok, other} = Issues.create_issue(%{title: "new approach", project_id: project.id})

      {:ok, closed} =
        Issues.close_issue(issue, %{
          outcome: "abandoned",
          resolution: "superseded",
          superseded_by_issue_id: other.id
        })

      assert {:ok, reopened} = Issues.reopen_issue(closed, "some-session-id")
      assert reopened.superseded_by_issue_id == other.id
    end

    test "reopening an issue closed with no evidence still archives a note", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "abandoned early", project_id: project.id})

      {:ok, closed} =
        Issues.close_issue(issue, %{outcome: "abandoned", resolution: "never started"})

      assert {:ok, reopened} = Issues.reopen_issue(closed, "some-session-id")
      assert reopened.notes =~ "Previously closed as abandoned"
      assert reopened.notes =~ "never started"
      assert reopened.notes =~ "0 commit(s)"
      assert reopened.notes =~ "0 attempt(s)"
    end
  end

  describe "list_issues/1" do
    test "defaults to open issues in a project, newest first", %{project: project} do
      {:ok, open_a} = Issues.create_issue(%{title: "open a", project_id: project.id})
      {:ok, closed} = Issues.create_issue(%{title: "closed", project_id: project.id})
      {:ok, _} = Issues.update_issue(closed, %{status: "closed"})

      ids = Issues.list_issues(%{project_id: project.id}) |> Enum.map(& &1.id)

      assert open_a.id in ids
      refute closed.id in ids
    end

    test "kind: \"all\" includes both kinds; a specific kind filters", %{project: project} do
      {:ok, task} = Issues.create_issue(%{title: "a task", project_id: project.id, kind: "task"})

      {:ok, fr} =
        Issues.create_issue(%{
          title: "a request",
          project_id: project.id,
          kind: "feature_request"
        })

      all_ids = Issues.list_issues(%{project_id: project.id, kind: "all"}) |> Enum.map(& &1.id)
      assert task.id in all_ids
      assert fr.id in all_ids

      task_only_ids =
        Issues.list_issues(%{project_id: project.id, kind: "task"}) |> Enum.map(& &1.id)

      assert task.id in task_only_ids
      refute fr.id in task_only_ids
    end

    test "created_by_session_id filters to issues created by that session", %{
      project: project,
      dir: dir
    } do
      {:ok, session} = Sessions.create_session(%{directory: dir, project_id: project.id})
      {:ok, mine} = Issues.create_issue(%{title: "mine", project_id: project.id})
      {:ok, mine} = Issues.update_issue(mine, %{created_by_session_id: session.id})
      {:ok, _other} = Issues.create_issue(%{title: "not mine", project_id: project.id})

      ids =
        Issues.list_issues(%{project_id: project.id, created_by_session_id: session.id})
        |> Enum.map(& &1.id)

      assert ids == [mine.id]
    end
  end
end
