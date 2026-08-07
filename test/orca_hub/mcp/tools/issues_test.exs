defmodule OrcaHub.MCP.Tools.IssuesTest do
  @moduledoc """
  Coverage for `OrcaHub.MCP.Tools.Issues` — the full Phase 2a tool surface
  (issues_spec.md §6): `create_issue`, `list_issues`, `get_issue`,
  `update_issue`, `append_issue_note`, `close_issue`, plus the FR-board
  compat shim (§8).
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.MCP.Tools.Issues, as: IssuesTool
  alias OrcaHub.{Issues, Projects, Repo, Sessions}

  @orca_hub_directory "/home/zach/orca_hub"

  setup do
    dir = Path.join(System.tmp_dir!(), "issues_tool_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "issues-tool-test",
        directory: dir,
        node: "n1@x",
        key_prefix: unique_key_prefix()
      })

    {:ok, caller} = Sessions.create_session(%{directory: dir, project_id: project.id})

    {:ok, project: project, dir: dir, caller: caller, state: state_for(caller.id)}
  end

  defp unique_key_prefix(base \\ "TQ") do
    (base <> Integer.to_string(System.unique_integer([:positive]))) |> String.slice(0, 10)
  end

  defp state_for(session_id), do: %{orca_session_id: session_id}

  defp decode!(%{"content" => [%{"text" => text}]}), do: Jason.decode!(text)

  # ── list/0 ───────────────────────────────────────────────────────────

  describe "list/0" do
    test "exposes the six spec tools with the shared id description" do
      names = IssuesTool.list() |> Enum.map(& &1["name"])

      assert "create_issue" in names
      assert "list_issues" in names
      assert "get_issue" in names
      assert "update_issue" in names
      assert "append_issue_note" in names
      assert "close_issue" in names

      create = Enum.find(IssuesTool.list(), &(&1["name"] == "create_issue"))
      assert create["inputSchema"]["required"] == ["title", "description"]
      assert create["inputSchema"]["properties"]["kind"]["enum"] == ["task", "feature_request"]

      get = Enum.find(IssuesTool.list(), &(&1["name"] == "get_issue"))
      assert get["inputSchema"]["required"] == ["id"]

      close = Enum.find(IssuesTool.list(), &(&1["name"] == "close_issue"))
      assert close["inputSchema"]["required"] == ["id"]
      assert close["inputSchema"]["properties"]["outcome"]["enum"] == ["resolved", "abandoned"]

      update = Enum.find(IssuesTool.list(), &(&1["name"] == "update_issue"))
      assert update["inputSchema"]["properties"]["status"]["enum"] == ["open", "in_progress"]
    end

    test "exposes the five deprecated FR-shim tools with a deprecation-prefixed description" do
      names = IssuesTool.list() |> Enum.map(& &1["name"])

      assert "file_feature_request" in names
      assert "list_feature_requests" in names
      assert "get_feature_request" in names
      assert "append_feature_request_note" in names
      assert "close_feature_request" in names

      fr = Enum.find(IssuesTool.list(), &(&1["name"] == "file_feature_request"))
      assert fr["description"] =~ "[deprecated"
      assert fr["description"] =~ "create_issue"
    end
  end

  # ── create_issue ─────────────────────────────────────────────────────

  describe "create_issue" do
    test "creates a task issue against the caller's own project by default", %{
      state: state,
      project: project
    } do
      result =
        IssuesTool.call("create_issue", %{"title" => "fix the bug", "description" => "d"}, state)

      assert %{"isError" => false} = result
      decoded = decode!(result)

      assert decoded["created"] == true
      assert decoded["deduped"] == false
      assert decoded["kind"] == "task"
      assert decoded["status"] == "open"
      assert is_binary(decoded["key"])
      assert String.starts_with?(decoded["key"], project.key_prefix)

      issue = Issues.get_issue!(decoded["id"])
      assert issue.title == "fix the bug"
      assert issue.project_id == project.id
    end

    test "kind: feature_request against an explicit directory", %{state: state} do
      result =
        IssuesTool.call(
          "create_issue",
          %{
            "title" => "some platform friction",
            "description" => "d",
            "kind" => "feature_request",
            "directory" => @orca_hub_directory
          },
          state
        )

      assert %{"isError" => false} = result
      decoded = decode!(result)
      assert decoded["kind"] == "feature_request"

      issue = Issues.get_issue!(decoded["id"])
      project = Repo.get!(Projects.Project, issue.project_id)
      assert project.directory == @orca_hub_directory
    end

    test "dedups against a similar open issue in the same project+kind instead of creating a new one",
         %{state: state, project: project} do
      first =
        IssuesTool.call(
          "create_issue",
          %{"title" => "flaky trigger test", "description" => "d"},
          state
        )

      first_id = decode!(first)["id"]

      second =
        IssuesTool.call(
          "create_issue",
          %{"title" => "flaky trigger test again", "description" => "d2"},
          state
        )

      decoded = decode!(second)
      assert decoded["deduped"] == true
      assert decoded["created"] == false
      assert decoded["id"] == first_id

      assert Issues.list_issues(%{project_id: project.id, kind: "all", status: "all"})
             |> Enum.count(&(&1.title =~ "flaky trigger test")) == 1
    end

    test "premise and plan are persisted", %{state: state} do
      result =
        IssuesTool.call(
          "create_issue",
          %{"title" => "t", "description" => "d", "premise" => "p", "plan" => "pl"},
          state
        )

      issue = Issues.get_issue!(decode!(result)["id"])
      assert issue.premise == "p"
      assert issue.plan == "pl"
    end

    test "errors on a blank title", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("create_issue", %{"title" => "", "description" => "d"}, state)

      assert msg =~ "title"
    end

    test "errors on an invalid kind", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call(
                 "create_issue",
                 %{"title" => "t", "description" => "d", "kind" => "bogus"},
                 state
               )

      assert msg =~ "kind"
    end

    test "errors when no directory is given and the connection has no linked session" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("create_issue", %{"title" => "t", "description" => "d"}, %{})

      assert msg =~ "directory"
    end
  end

  # ── list_issues ──────────────────────────────────────────────────────

  describe "list_issues" do
    test "defaults to open issues in the caller's own project", %{state: state, project: project} do
      {:ok, _open} = Issues.create_issue(%{title: "open one", project_id: project.id})
      {:ok, closed} = Issues.create_issue(%{title: "closed one", project_id: project.id})
      {:ok, _} = Issues.update_issue(closed, %{status: "closed"})

      result = IssuesTool.call("list_issues", %{}, state)
      decoded = decode!(result)
      titles = Enum.map(decoded["issues"], & &1["title"])

      assert "open one" in titles
      refute "closed one" in titles
    end

    test "kind filters, defaulting to all kinds", %{state: state, project: project} do
      {:ok, _task} = Issues.create_issue(%{title: "a task", project_id: project.id, kind: "task"})

      {:ok, _fr} =
        Issues.create_issue(%{
          title: "a request",
          project_id: project.id,
          kind: "feature_request"
        })

      all = decode!(IssuesTool.call("list_issues", %{}, state))
      assert all["count"] == 2

      only_fr = decode!(IssuesTool.call("list_issues", %{"kind" => "feature_request"}, state))
      assert only_fr["count"] == 1
      assert hd(only_fr["issues"])["kind"] == "feature_request"
    end

    test "mine: true filters to issues created by the calling session", %{
      state: state,
      project: project,
      caller: caller
    } do
      {:ok, _mine} =
        Issues.create_issue(%{
          title: "mine",
          project_id: project.id,
          created_by_session_id: caller.id
        })

      {:ok, _other} = Issues.create_issue(%{title: "not mine", project_id: project.id})

      decoded = decode!(IssuesTool.call("list_issues", %{"mine" => true}, state))
      assert decoded["count"] == 1
      assert hd(decoded["issues"])["title"] == "mine"
    end

    test "all_projects: true lists across every project", %{state: state} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "other-project",
          directory: Path.join(System.tmp_dir!(), "other_#{System.unique_integer([:positive])}"),
          node: "n1@x",
          key_prefix: unique_key_prefix("OQ")
        })

      {:ok, _} = Issues.create_issue(%{title: "elsewhere", project_id: other_project.id})

      decoded =
        decode!(
          IssuesTool.call("list_issues", %{"all_projects" => true, "query" => "elsewhere"}, state)
        )

      assert decoded["count"] == 1
    end
  end

  # ── get_issue ────────────────────────────────────────────────────────

  describe "get_issue" do
    test "returns the full record with live attempts while open", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "gettable", project_id: project.id})

      decoded = decode!(IssuesTool.call("get_issue", %{"id" => issue.id}, state))

      assert decoded["id"] == issue.id
      assert decoded["title"] == "gettable"
      assert decoded["status"] == "open"
      assert decoded["commits"] == []
      assert decoded["attempts"] == []
      assert decoded["superseded_by"] == nil
    end

    test "resolves by the rendered short key (e.g. ORCA-142 style)", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "keyed", project_id: project.id})
      key = "#{project.key_prefix}-#{issue.key_number}"

      decoded = decode!(IssuesTool.call("get_issue", %{"id" => key}, state))
      assert decoded["id"] == issue.id
      assert decoded["key"] == key
    end

    test "resolves by an unambiguous hex id prefix", %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "hex prefix", project_id: project.id})
      prefix = String.slice(issue.id, 0, 8)

      decoded = decode!(IssuesTool.call("get_issue", %{"id" => prefix}, state))
      assert decoded["id"] == issue.id
    end

    test "unknown id returns a friendly error", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("get_issue", %{"id" => Ecto.UUID.generate()}, state)

      assert msg =~ "No issue found"
    end

    test "surfaces a resolved superseded_by summary", %{state: state, project: project} do
      {:ok, replacement} = Issues.create_issue(%{title: "the real fix", project_id: project.id})
      {:ok, old} = Issues.create_issue(%{title: "old attempt", project_id: project.id})

      {:ok, old} =
        Issues.update_issue(old, %{superseded_by_issue_id: replacement.id})

      decoded = decode!(IssuesTool.call("get_issue", %{"id" => old.id}, state))
      assert decoded["superseded_by"]["id"] == replacement.id
      assert decoded["superseded_by"]["title"] == "the real fix"
    end
  end

  # ── update_issue ─────────────────────────────────────────────────────

  describe "update_issue" do
    test "requires at least one field besides id", %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "u", project_id: project.id})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("update_issue", %{"id" => issue.id}, state)

      assert msg =~ "at least one field"
    end

    test "plain field update on an open issue", %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "u", project_id: project.id})

      decoded =
        decode!(IssuesTool.call("update_issue", %{"id" => issue.id, "plan" => "new plan"}, state))

      assert decoded["plan"] == "new plan"
      assert Issues.get_issue!(issue.id).plan == "new plan"
    end

    test "cannot set status to closed/abandoned — directs to close_issue", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "u", project_id: project.id})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("update_issue", %{"id" => issue.id, "status" => "closed"}, state)

      assert msg =~ "close_issue"
    end

    test "resolution is rejected on an open/in_progress issue", %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "u", project_id: project.id})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("update_issue", %{"id" => issue.id, "resolution" => "nope"}, state)

      assert msg =~ "close_issue"
    end

    test "status: open on a closed issue reopens it, archiving the frozen snapshot into notes",
         %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "reopen me", project_id: project.id})

      close_result =
        IssuesTool.call(
          "close_issue",
          %{"id" => issue.id, "outcome" => "resolved", "resolution" => "shipped it"},
          state
        )

      closed_id = decode!(close_result)["id"]
      assert Issues.get_issue!(closed_id).status == "closed"

      decoded =
        decode!(IssuesTool.call("update_issue", %{"id" => closed_id, "status" => "open"}, state))

      assert decoded["status"] == "open"

      reopened = Issues.get_issue!(closed_id)
      assert reopened.resolution == nil
      assert reopened.notes =~ "Previously closed as resolved"
      assert reopened.notes =~ "shipped it"
    end

    test "amends resolution on an already-closed issue, preserving the prior value in notes",
         %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "amend me", project_id: project.id})

      close_result =
        IssuesTool.call(
          "close_issue",
          %{"id" => issue.id, "outcome" => "resolved", "resolution" => "first resolution"},
          state
        )

      closed_id = decode!(close_result)["id"]

      decoded =
        decode!(
          IssuesTool.call(
            "update_issue",
            %{"id" => closed_id, "resolution" => "actually it was this instead"},
            state
          )
        )

      assert decoded["resolution"] == "actually it was this instead"
      amended = Issues.get_issue!(closed_id)
      assert amended.status == "closed"
      assert amended.notes =~ "Prior resolution"
      assert amended.notes =~ "first resolution"
    end

    test "superseded_by resolves the target and rejects self-reference", %{
      state: state,
      project: project
    } do
      {:ok, a} = Issues.create_issue(%{title: "a", project_id: project.id})
      {:ok, b} = Issues.create_issue(%{title: "b", project_id: project.id})

      decoded =
        decode!(IssuesTool.call("update_issue", %{"id" => a.id, "superseded_by" => b.id}, state))

      assert decoded["superseded_by"]["id"] == b.id

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("update_issue", %{"id" => b.id, "superseded_by" => b.id}, state)

      assert msg =~ "cannot supersede itself"
    end
  end

  # ── append_issue_note ────────────────────────────────────────────────

  describe "append_issue_note" do
    test "appends a note with a provenance stamp", %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "n", project_id: project.id})

      decoded =
        decode!(
          IssuesTool.call(
            "append_issue_note",
            %{"id" => issue.id, "note" => "found more evidence"},
            state
          )
        )

      assert decoded["notes"] =~ "found more evidence"
      assert decoded["notes"] =~ "via append_issue_note"
    end

    test "works on a closed issue too", %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "n", project_id: project.id})
      {:ok, closed} = Issues.close_issue(issue, %{outcome: "resolved", resolution: "r"})

      decoded =
        decode!(
          IssuesTool.call(
            "append_issue_note",
            %{"id" => closed.id, "note" => "later evidence"},
            state
          )
        )

      assert decoded["notes"] =~ "later evidence"
    end
  end

  # ── close_issue — two-mode read-back flow (§6.6) ────────────────────

  describe "close_issue" do
    test "bare id returns harvested evidence WITHOUT closing", %{state: state, project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "preview me", project_id: project.id})

      decoded = decode!(IssuesTool.call("close_issue", %{"id" => issue.id}, state))

      assert decoded["id"] == issue.id
      assert decoded["attempts"] == []
      assert is_binary(decoded["instruction"])
      assert decoded["instruction"] =~ "harvested"

      assert Issues.get_issue!(issue.id).status == "open"
    end

    test "id + outcome + resolution closes it and freezes commits/attempts", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "close me", project_id: project.id})

      decoded =
        decode!(
          IssuesTool.call(
            "close_issue",
            %{"id" => issue.id, "outcome" => "resolved", "resolution" => "it shipped"},
            state
          )
        )

      assert decoded["status"] == "closed"
      assert decoded["resolution"] == "it shipped"
      assert decoded["commits"] == []
      assert decoded["attempts"] == []

      closed = Issues.get_issue!(issue.id)
      assert closed.status == "closed"
      assert closed.resolution == "it shipped"
      assert closed.closed_at != nil
      assert closed.closed_by_session_id == state.orca_session_id
    end

    test "resolution is required to actually close — outcome alone errors, does not close", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "half-baked close", project_id: project.id})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("close_issue", %{"id" => issue.id, "outcome" => "resolved"}, state)

      assert msg =~ "resolution"
      assert Issues.get_issue!(issue.id).status == "open"
    end

    test "outcome is required to actually close — resolution alone errors, does not close", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "half-baked close 2", project_id: project.id})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call("close_issue", %{"id" => issue.id, "resolution" => "r"}, state)

      assert msg =~ "outcome"
      assert Issues.get_issue!(issue.id).status == "open"
    end

    test "abandoned outcome closes with status abandoned and still requires a resolution", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "abandon me", project_id: project.id})

      assert %{"isError" => true} =
               IssuesTool.call(
                 "close_issue",
                 %{"id" => issue.id, "outcome" => "abandoned"},
                 state
               )

      decoded =
        decode!(
          IssuesTool.call(
            "close_issue",
            %{
              "id" => issue.id,
              "outcome" => "abandoned",
              "resolution" => "premise turned out to be false"
            },
            state
          )
        )

      assert decoded["status"] == "abandoned"
      assert Issues.get_issue!(issue.id).status == "abandoned"
    end

    test "resolves the target via its rendered short key (e.g. ORCA-142)", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "close via key", project_id: project.id})
      key = "#{project.key_prefix}-#{issue.key_number}"

      decoded =
        decode!(
          IssuesTool.call(
            "close_issue",
            %{"id" => key, "outcome" => "resolved", "resolution" => "done"},
            state
          )
        )

      assert decoded["id"] == issue.id
      assert decoded["key"] == key
      assert Issues.get_issue!(issue.id).status == "closed"
    end

    test "closing an already-closed issue errors and points at update_issue", %{
      state: state,
      project: project
    } do
      {:ok, issue} = Issues.create_issue(%{title: "double close", project_id: project.id})
      {:ok, closed} = Issues.close_issue(issue, %{outcome: "resolved", resolution: "r"})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               IssuesTool.call(
                 "close_issue",
                 %{"id" => closed.id, "outcome" => "resolved", "resolution" => "again"},
                 state
               )

      assert msg =~ "already"
      assert msg =~ "update_issue"
    end

    test "superseded_by sets the structured link when closing", %{state: state, project: project} do
      {:ok, replacement} = Issues.create_issue(%{title: "the successor", project_id: project.id})
      {:ok, issue} = Issues.create_issue(%{title: "superseded", project_id: project.id})

      decoded =
        decode!(
          IssuesTool.call(
            "close_issue",
            %{
              "id" => issue.id,
              "outcome" => "abandoned",
              "resolution" => "covered elsewhere",
              "superseded_by" => replacement.id
            },
            state
          )
        )

      assert decoded["superseded_by"]["id"] == replacement.id
      assert Issues.get_issue!(issue.id).superseded_by_issue_id == replacement.id
    end
  end

  # ── FR-board compat shim (§8) ────────────────────────────────────────

  describe "FR-board compat shim" do
    setup do
      real_project = Projects.get_project_by_directory(@orca_hub_directory)

      refute is_nil(real_project),
             "expected a project registered for #{@orca_hub_directory} in the dev DB"

      {:ok, _} = Projects.delete_project(real_project)

      {:ok, isolated} =
        Projects.create_project(%{
          name: "isolated-orca-hub-#{System.unique_integer([:positive])}",
          directory: @orca_hub_directory,
          node: "n1@x"
        })

      {:ok, fr_project: isolated}
    end

    test "file_feature_request creates a kind: feature_request issue against the OrcaHub project regardless of caller directory",
         %{state: state, fr_project: fr_project} do
      decoded =
        decode!(
          IssuesTool.call(
            "file_feature_request",
            %{"title" => "missing tool", "description" => "d", "category" => "tooling"},
            state
          )
        )

      issue = Issues.get_issue!(decoded["id"])
      assert issue.kind == "feature_request"
      assert issue.project_id == fr_project.id
      assert issue.description =~ "Category: tooling"
    end

    test "list_feature_requests only returns feature_request-kind issues against the OrcaHub project",
         %{state: state, fr_project: fr_project} do
      {:ok, _fr} =
        Issues.create_issue(%{
          title: "a request",
          project_id: fr_project.id,
          kind: "feature_request"
        })

      {:ok, _task} =
        Issues.create_issue(%{title: "a task", project_id: fr_project.id, kind: "task"})

      decoded = decode!(IssuesTool.call("list_feature_requests", %{}, state))
      assert decoded["count"] == 1
      assert hd(decoded["feature_requests"])["title"] == "a request"
    end

    test "get_feature_request delegates straight to get_issue (no agent-filed scope check)", %{
      state: state,
      fr_project: fr_project
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "human filed",
          project_id: fr_project.id,
          kind: "feature_request"
        })

      decoded = decode!(IssuesTool.call("get_feature_request", %{"id" => issue.id}, state))
      assert decoded["id"] == issue.id
    end

    test "append_feature_request_note delegates to append_issue_note", %{
      state: state,
      fr_project: fr_project
    } do
      {:ok, issue} =
        Issues.create_issue(%{title: "n", project_id: fr_project.id, kind: "feature_request"})

      decoded =
        decode!(
          IssuesTool.call(
            "append_feature_request_note",
            %{"id" => issue.id, "note" => "evidence"},
            state
          )
        )

      assert decoded["notes"] =~ "evidence"
    end

    test "close_feature_request closes as resolved with a default resolution when none given", %{
      state: state,
      fr_project: fr_project
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "fixed now",
          project_id: fr_project.id,
          kind: "feature_request"
        })

      decoded = decode!(IssuesTool.call("close_feature_request", %{"id" => issue.id}, state))

      assert decoded["status"] == "closed"
      assert decoded["resolution"] =~ "deprecated close_feature_request"
    end

    test "close_feature_request uses resolution_note verbatim when given", %{
      state: state,
      fr_project: fr_project
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "fixed now 2",
          project_id: fr_project.id,
          kind: "feature_request"
        })

      decoded =
        decode!(
          IssuesTool.call(
            "close_feature_request",
            %{"id" => issue.id, "resolution_note" => "fixed in commit abc123"},
            state
          )
        )

      assert decoded["resolution"] == "fixed in commit abc123"
    end
  end
end
