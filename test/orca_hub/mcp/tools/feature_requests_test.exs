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
  alias OrcaHub.{Issues, Projects}

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

  describe "list/0" do
    test "exposes file_feature_request with title/description required, category optional" do
      [tool] = FeatureRequestsTool.list()

      assert tool["name"] == "file_feature_request"
      assert tool["inputSchema"]["required"] == ["title", "description"]
      assert Map.has_key?(tool["inputSchema"]["properties"], "category")
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
      assert result["message"] =~ "append_note"

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
