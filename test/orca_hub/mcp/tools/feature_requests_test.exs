defmodule OrcaHub.MCP.Tools.FeatureRequestsTest do
  @moduledoc """
  Coverage for the `file_feature_request` MCP tool. Always files against the
  project registered for the OrcaHub codebase's own directory
  (`/home/zach/orca_hub`) regardless of the calling session — this suite
  relies on that project already existing in the dev DB (see
  `OrcaHub.MCP.Tools.FeatureRequests` moduledoc for why it's hardcoded
  rather than derived from the caller). Every write here runs inside the
  DataCase sandbox transaction and is rolled back after the test, including
  the "no project registered" case, which soft-deletes that real row for
  the duration of a single test.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.MCP.Tools.FeatureRequests, as: FeatureRequestsTool
  alias OrcaHub.Issues.Issue
  alias OrcaHub.{Issues, Projects, Repo}

  @orca_hub_directory "/home/zach/orca_hub"

  setup do
    project = Projects.get_project_by_directory(@orca_hub_directory)

    refute is_nil(project),
           "expected a project registered for #{@orca_hub_directory} in the dev DB " <>
             "(file_feature_request hardcodes this directory) — this suite depends on it existing"

    {:ok, project: project}
  end

  defp unique_id, do: Ecto.UUID.generate()
  defp state_for(session_id), do: %{orca_session_id: session_id}

  defp file_request(title) do
    FeatureRequestsTool.call(
      "file_feature_request",
      %{"title" => title, "description" => "d"},
      state_for(unique_id())
    )
    |> then(fn %{"content" => [%{"text" => body}]} -> Jason.decode!(body) end)
  end

  # The read tools (list/get/append) resolve against whatever project is
  # currently registered for @orca_hub_directory — in the shared dev DB that
  # project already carries real accumulated history (and other concurrent
  # sessions may be filing against it too), so list_feature_requests' cap
  # and status-count assertions would be flaky against it. Swap in a fresh,
  # empty project under the same directory for the duration of each test
  # here — rolled back by DataCase's transaction, same technique the "no
  # project registered" test below uses.
  defp isolate_orca_hub_project(%{project: real_project}) do
    {:ok, _} = Projects.delete_project(real_project)

    {:ok, isolated} =
      Projects.create_project(%{
        name: "isolated-orca-hub-#{System.unique_integer([:positive])}",
        directory: @orca_hub_directory,
        node: "n1@x"
      })

    {:ok, project: isolated}
  end

  describe "list/0" do
    test "exposes file_feature_request with title/description required, category optional" do
      tool = Enum.find(FeatureRequestsTool.list(), &(&1["name"] == "file_feature_request"))

      assert tool["inputSchema"]["required"] == ["title", "description"]
      assert Map.has_key?(tool["inputSchema"]["properties"], "category")
    end

    test "exposes list_feature_requests, get_feature_request, append_feature_request_note" do
      names = FeatureRequestsTool.list() |> Enum.map(& &1["name"])

      assert "list_feature_requests" in names
      assert "get_feature_request" in names
      assert "append_feature_request_note" in names

      get_tool = Enum.find(FeatureRequestsTool.list(), &(&1["name"] == "get_feature_request"))
      assert get_tool["inputSchema"]["required"] == ["id"]

      append_tool =
        Enum.find(FeatureRequestsTool.list(), &(&1["name"] == "append_feature_request_note"))

      assert append_tool["inputSchema"]["required"] == ["id", "note"]
    end

    test "exposes close_feature_request with only id required, resolution_note optional" do
      names = FeatureRequestsTool.list() |> Enum.map(& &1["name"])
      assert "close_feature_request" in names

      tool = Enum.find(FeatureRequestsTool.list(), &(&1["name"] == "close_feature_request"))
      assert tool["inputSchema"]["required"] == ["id"]
      assert Map.has_key?(tool["inputSchema"]["properties"], "resolution_note")
    end
  end

  describe "call/3 validation" do
    test "errors on a missing title" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{"description" => "d"},
                 state_for(unique_id())
               )

      assert msg =~ "title"
    end

    test "errors on an empty description" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{"title" => "t", "description" => ""},
                 state_for(unique_id())
               )

      assert msg =~ "description"
    end
  end

  describe "call/3 happy path" do
    test "creates an issue prefixed [agent-fr], with a provenance block appended to the description",
         %{project: project} do
      session_id = unique_id()

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{
                   "title" => "Unique friction title #{System.unique_integer([:positive])}",
                   "description" => "Hit a wall trying to do X.",
                   "category" => "tooling"
                 },
                 state_for(session_id)
               )

      result = Jason.decode!(body)
      assert result["created"] == true
      assert result["deduped"] == false
      assert String.starts_with?(result["title"], "[agent-fr] ")
      assert result["url"] == "/issues/#{result["id"]}"

      issue = Issues.get_issue!(result["id"])
      assert issue.project_id == project.id
      assert issue.status == "open"
      assert issue.description =~ "Hit a wall trying to do X."
      assert issue.description =~ "Session: #{session_id}"
      assert issue.description =~ "Category: tooling"
    end

    test "defaults category to uncategorized when omitted" do
      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{
                   "title" => "No category title #{System.unique_integer([:positive])}",
                   "description" => "desc"
                 },
                 state_for(unique_id())
               )

      %{"id" => id} = Jason.decode!(body)
      issue = Issues.get_issue!(id)
      assert issue.description =~ "Category: uncategorized"
    end

    test "records \"unknown\" for the session when the MCP connection has no linked session" do
      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{
                   "title" => "Unlinked session title #{System.unique_integer([:positive])}",
                   "description" => "desc"
                 },
                 %{orca_session_id: nil}
               )

      %{"id" => id} = Jason.decode!(body)
      issue = Issues.get_issue!(id)
      assert issue.description =~ "Session: unknown"
    end
  end

  describe "call/3 dedup" do
    test "does not create a duplicate for a near-identical open agent-filed title", %{
      project: project
    } do
      title = "Dedup target #{System.unique_integer([:positive])}"

      assert %{"content" => [%{"text" => first_body}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{"title" => title, "description" => "first description"},
                 state_for(unique_id())
               )

      %{"id" => first_id} = Jason.decode!(first_body)

      assert %{"isError" => false, "content" => [%{"text" => second_body}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{"title" => title, "description" => "second description, same topic"},
                 state_for(unique_id())
               )

      result = Jason.decode!(second_body)
      assert result["created"] == false
      assert result["deduped"] == true
      assert result["id"] == first_id
      assert result["message"] =~ "append_feature_request_note"

      open_titled =
        project.id
        |> Issues.list_open_issues_for_project()
        |> Enum.filter(&(&1.title == "[agent-fr] " <> title))

      assert length(open_titled) == 1
    end

    test "creates a new issue when the title is unrelated to any existing open one" do
      unique = System.unique_integer([:positive])

      FeatureRequestsTool.call(
        "file_feature_request",
        %{"title" => "Broken dashboard export button #{unique}", "description" => "d1"},
        state_for(unique_id())
      )

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{"title" => "Missing dark mode toggle #{unique}", "description" => "d2"},
                 state_for(unique_id())
               )

      result = Jason.decode!(body)
      assert result["created"] == true
      assert result["deduped"] == false
    end

    test "does not dedup against a closed issue with the same title" do
      title = "Reopened-style friction #{System.unique_integer([:positive])}"

      %{"content" => [%{"text" => first_body}]} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{"title" => title, "description" => "d1"},
          state_for(unique_id())
        )

      %{"id" => first_id} = Jason.decode!(first_body)
      Issues.get_issue!(first_id) |> Issues.update_issue(%{status: "closed"})

      assert %{"isError" => false, "content" => [%{"text" => second_body}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{"title" => title, "description" => "d2"},
                 state_for(unique_id())
               )

      result = Jason.decode!(second_body)
      assert result["created"] == true
      assert result["id"] != first_id
    end

    test "does not dedup against a human-filed issue lacking the agent-fr prefix", %{
      project: project
    } do
      title = "Human filed issue #{System.unique_integer([:positive])}"
      {:ok, _human_issue} = Issues.create_issue(%{title: title, project_id: project.id})

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{"title" => title, "description" => "d"},
                 state_for(unique_id())
               )

      result = Jason.decode!(body)
      assert result["created"] == true
    end
  end

  describe "call/3 list_feature_requests" do
    setup :isolate_orca_hub_project

    test "defaults to open, agent-filed issues only" do
      unique = System.unique_integer([:positive])

      # Deliberately dissimilar titles (only the trailing number is shared) —
      # the fuzzy dedup in file_feature_request would otherwise fold these
      # into a single issue via its word-overlap heuristic.
      %{"content" => [%{"text" => first_body}]} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{"title" => "Broken export dialog #{unique}", "description" => "d1"},
          state_for(unique_id())
        )

      %{"content" => [%{"text" => second_body}]} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{"title" => "Missing keyboard shortcut #{unique}", "description" => "d2"},
          state_for(unique_id())
        )

      %{"id" => first_id} = Jason.decode!(first_body)
      %{"id" => second_id} = Jason.decode!(second_body)

      %{"id" => closed_id} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{"title" => "Slow database migration #{unique}", "description" => "d3"},
          state_for(unique_id())
        )
        |> then(fn %{"content" => [%{"text" => body}]} -> Jason.decode!(body) end)

      Issues.get_issue!(closed_id) |> Issues.update_issue(%{status: "closed"})

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call("list_feature_requests", %{}, state_for(unique_id()))

      %{"feature_requests" => requests} = Jason.decode!(body)
      ids = Enum.map(requests, & &1["id"])

      assert first_id in ids
      assert second_id in ids
      refute closed_id in ids
    end

    test "status: \"all\" includes closed issues, status: \"closed\" filters to only closed" do
      unique = System.unique_integer([:positive])

      %{"id" => id} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{"title" => "List status filter #{unique}", "description" => "d"},
          state_for(unique_id())
        )
        |> then(fn %{"content" => [%{"text" => body}]} -> Jason.decode!(body) end)

      Issues.get_issue!(id) |> Issues.update_issue(%{status: "closed"})

      %{"content" => [%{"text" => all_body}]} =
        FeatureRequestsTool.call(
          "list_feature_requests",
          %{"status" => "all"},
          state_for(unique_id())
        )

      assert id in (Jason.decode!(all_body)["feature_requests"] |> Enum.map(& &1["id"]))

      %{"content" => [%{"text" => closed_body}]} =
        FeatureRequestsTool.call(
          "list_feature_requests",
          %{"status" => "closed"},
          state_for(unique_id())
        )

      closed_ids = Jason.decode!(closed_body)["feature_requests"] |> Enum.map(& &1["id"])
      assert id in closed_ids

      %{"content" => [%{"text" => open_body}]} =
        FeatureRequestsTool.call(
          "list_feature_requests",
          %{"status" => "open"},
          state_for(unique_id())
        )

      refute id in (Jason.decode!(open_body)["feature_requests"] |> Enum.map(& &1["id"]))
    end

    test "excludes human-filed issues", %{project: project} do
      title = "Human filed for listing #{System.unique_integer([:positive])}"
      {:ok, human_issue} = Issues.create_issue(%{title: title, project_id: project.id})

      assert %{"content" => [%{"text" => body}]} =
               FeatureRequestsTool.call("list_feature_requests", %{}, state_for(unique_id()))

      ids = Jason.decode!(body)["feature_requests"] |> Enum.map(& &1["id"])
      refute human_issue.id in ids
    end
  end

  describe "call/3 get_feature_request" do
    setup :isolate_orca_hub_project

    test "returns full title/description/status/notes for an agent-filed issue" do
      %{"id" => id} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{
            "title" => "Get target #{System.unique_integer([:positive])}",
            "description" => "the pain point"
          },
          state_for(unique_id())
        )
        |> then(fn %{"content" => [%{"text" => body}]} -> Jason.decode!(body) end)

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => id},
                 state_for(unique_id())
               )

      result = Jason.decode!(body)
      assert result["id"] == id
      assert result["status"] == "open"
      assert result["description"] =~ "the pain point"
    end

    test "errors on a missing id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call("get_feature_request", %{}, state_for(unique_id()))

      assert msg =~ "id"
    end

    test "errors for an unknown id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => Ecto.UUID.generate()},
                 state_for(unique_id())
               )

      assert msg =~ "No agent-filed feature request found"
    end

    test "errors for a human-filed issue (out of scope)", %{project: project} do
      title = "Human filed for get #{System.unique_integer([:positive])}"
      {:ok, human_issue} = Issues.create_issue(%{title: title, project_id: project.id})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => human_issue.id},
                 state_for(unique_id())
               )

      assert msg =~ "No agent-filed feature request found"
    end
  end

  describe "call/3 id prefix resolution" do
    setup :isolate_orca_hub_project

    test "resolves an 8-char id prefix the same as the full id" do
      %{"id" => id} = file_request("Prefix hit target #{System.unique_integer([:positive])}")
      short_id = String.slice(id, 0, 8)

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => short_id},
                 state_for(unique_id())
               )

      assert Jason.decode!(body)["id"] == id
    end

    test "resolves an 8-char prefix for append_feature_request_note and close_feature_request too" do
      %{"id" => id} =
        file_request("Prefix append/close target #{System.unique_integer([:positive])}")

      short_id = String.slice(id, 0, 8)

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "append_feature_request_note",
                 %{"id" => short_id, "note" => "via prefix"},
                 state_for(unique_id())
               )

      assert Jason.decode!(body)["id"] == id

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "close_feature_request",
                 %{"id" => short_id},
                 state_for(unique_id())
               )

      assert Jason.decode!(body)["id"] == id
    end

    test "a full uuid still works unchanged" do
      %{"id" => id} = file_request("Full uuid target #{System.unique_integer([:positive])}")

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => id},
                 state_for(unique_id())
               )

      assert Jason.decode!(body)["id"] == id
    end

    test "errors with a friendly message for an unknown prefix" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => "deadbeef"},
                 state_for(unique_id())
               )

      assert msg =~ "No feature request found with id starting \"deadbeef\""
    end

    test "errors with a friendly message (not a raw Ecto exception) for garbage input" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => "not-a-uuid"},
                 state_for(unique_id())
               )

      assert msg =~ "isn't a valid feature request id"
    end

    test "errors with a friendly message for a too-short prefix" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => "abc123"},
                 state_for(unique_id())
               )

      assert msg =~ "isn't a valid feature request id"
    end

    test "errors listing the matching ids/titles when a prefix is ambiguous", %{
      project: project
    } do
      shared_prefix = "aaaaaaaa"

      {:ok, issue_a} =
        %Issue{id: shared_prefix <> "-0000-4000-8000-000000000001"}
        |> Issue.changeset(%{
          title: "[agent-fr] Ambiguous prefix A",
          project_id: project.id,
          status: "open"
        })
        |> Repo.insert()

      {:ok, issue_b} =
        %Issue{id: shared_prefix <> "-0000-4000-8000-000000000002"}
        |> Issue.changeset(%{
          title: "[agent-fr] Ambiguous prefix B",
          project_id: project.id,
          status: "open"
        })
        |> Repo.insert()

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "get_feature_request",
                 %{"id" => shared_prefix},
                 state_for(unique_id())
               )

      assert msg =~ "Multiple feature requests match"
      assert msg =~ issue_a.id
      assert msg =~ issue_b.id
    end
  end

  describe "call/3 append_feature_request_note" do
    setup :isolate_orca_hub_project

    test "appends a note with provenance to an agent-filed issue" do
      session_id = unique_id()

      %{"id" => id} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{
            "title" => "Append target #{System.unique_integer([:positive])}",
            "description" => "d"
          },
          state_for(unique_id())
        )
        |> then(fn %{"content" => [%{"text" => body}]} -> Jason.decode!(body) end)

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "append_feature_request_note",
                 %{"id" => id, "note" => "saw this again"},
                 state_for(session_id)
               )

      result = Jason.decode!(body)
      assert result["notes"] =~ "saw this again"
      assert result["notes"] =~ "append_feature_request_note"
      assert result["notes"] =~ "Session: #{session_id}"

      issue = Issues.get_issue!(id)
      assert issue.notes == result["notes"]
    end

    test "errors on a missing id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "append_feature_request_note",
                 %{"note" => "x"},
                 state_for(unique_id())
               )

      assert msg =~ "id"
    end

    test "errors on an empty note" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "append_feature_request_note",
                 %{"id" => Ecto.UUID.generate(), "note" => ""},
                 state_for(unique_id())
               )

      assert msg =~ "note"
    end

    test "errors for an unknown id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "append_feature_request_note",
                 %{"id" => Ecto.UUID.generate(), "note" => "x"},
                 state_for(unique_id())
               )

      assert msg =~ "No agent-filed feature request found"
    end
  end

  describe "call/3 close_feature_request" do
    setup :isolate_orca_hub_project

    test "closes an agent-filed issue with no resolution note" do
      %{"id" => id} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{
            "title" => "Close target #{System.unique_integer([:positive])}",
            "description" => "d"
          },
          state_for(unique_id())
        )
        |> then(fn %{"content" => [%{"text" => body}]} -> Jason.decode!(body) end)

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "close_feature_request",
                 %{"id" => id},
                 state_for(unique_id())
               )

      result = Jason.decode!(body)
      assert result["id"] == id
      assert result["status"] == "closed"

      issue = Issues.get_issue!(id)
      assert issue.status == "closed"
      refute issue.notes
    end

    test "appends a resolution note with provenance before closing" do
      session_id = unique_id()

      %{"id" => id} =
        FeatureRequestsTool.call(
          "file_feature_request",
          %{
            "title" => "Close with note #{System.unique_integer([:positive])}",
            "description" => "d"
          },
          state_for(unique_id())
        )
        |> then(fn %{"content" => [%{"text" => body}]} -> Jason.decode!(body) end)

      assert %{"isError" => false, "content" => [%{"text" => body}]} =
               FeatureRequestsTool.call(
                 "close_feature_request",
                 %{"id" => id, "resolution_note" => "Fixed in abc1234"},
                 state_for(session_id)
               )

      result = Jason.decode!(body)
      assert result["status"] == "closed"

      issue = Issues.get_issue!(id)
      assert issue.status == "closed"
      assert issue.notes =~ "Fixed in abc1234"
      assert issue.notes =~ "Session: #{session_id}"
    end

    test "errors on a missing id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call("close_feature_request", %{}, state_for(unique_id()))

      assert msg =~ "id"
    end

    test "errors for an unknown id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "close_feature_request",
                 %{"id" => Ecto.UUID.generate()},
                 state_for(unique_id())
               )

      assert msg =~ "No agent-filed feature request found"
    end

    test "errors for a human-filed issue (out of scope)", %{project: project} do
      title = "Human filed for close #{System.unique_integer([:positive])}"
      {:ok, human_issue} = Issues.create_issue(%{title: title, project_id: project.id})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "close_feature_request",
                 %{"id" => human_issue.id},
                 state_for(unique_id())
               )

      assert msg =~ "No agent-filed feature request found"
    end
  end

  describe "call/3 when no project is registered for the OrcaHub directory" do
    test "returns a clear error and does not create an issue", %{project: project} do
      before_count = length(Issues.list_open_issues_for_project(project.id))
      {:ok, _} = Projects.delete_project(project)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               FeatureRequestsTool.call(
                 "file_feature_request",
                 %{
                   "title" => "Title while unregistered #{System.unique_integer([:positive])}",
                   "description" => "d"
                 },
                 state_for(unique_id())
               )

      assert msg =~ @orca_hub_directory
      assert msg =~ "not"
      assert length(Issues.list_open_issues_for_project(project.id)) == before_count
    end
  end
end
