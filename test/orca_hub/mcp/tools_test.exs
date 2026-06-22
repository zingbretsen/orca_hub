defmodule OrcaHub.MCP.ToolsTest do
  use OrcaHub.DataCase

  alias OrcaHub.{Projects, Sessions}
  alias OrcaHub.MCP.Tools

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", directory: "/tmp/test-mcp-tools"})
    %{project: project}
  end

  defp create_session(project, overrides) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(%{directory: project.directory, project_id: project.id}, overrides)
      )

    session
  end

  describe "list/1 tool visibility (cached orchestrator status)" do
    test "orchestrator sessions see every tool" do
      names = Tools.list(%{orchestrator: true}) |> Enum.map(& &1["name"])

      assert "start_session" in names
      assert "search_sessions" in names
      assert "send_message_to_session" in names
    end

    test "regular sessions see only the regular tool set" do
      names = Tools.list(%{orchestrator: false}) |> Enum.map(& &1["name"])

      assert "send_message_to_session" in names
      assert "open_file" in names
      refute "start_session" in names
      refute "search_sessions" in names
    end
  end

  describe "call/3 permission enforcement (cached orchestrator status)" do
    test "regular sessions are denied orchestrator-only tools" do
      result = Tools.call("start_session", %{}, %{orchestrator: false})
      assert %{"isError" => true} = result

      [%{"text" => text}] = result["content"]
      assert text =~ "only available to orchestrator sessions"
    end

    test "regular sessions may use regular tools (not denied by permission check)" do
      # The call passes the permission gate and enters the tool body (which may
      # itself fail on missing args). We only assert it is NOT permission-denied.
      result =
        try do
          Tools.call("send_message_to_session", %{}, %{orchestrator: false})
        rescue
          _ -> :entered_tool_body
        end

      case result do
        %{"isError" => true, "content" => [%{"text" => text}]} ->
          refute text =~ "only available to orchestrator sessions"

        _ ->
          :ok
      end
    end
  end

  describe "resolve_orchestrator/2" do
    test "returns true for an orchestrator session", %{project: project} do
      session = create_session(project, %{orchestrator: true})
      assert Tools.resolve_orchestrator(session.id) == true
    end

    test "returns false for a regular session", %{project: project} do
      session = create_session(project, %{orchestrator: false})
      assert Tools.resolve_orchestrator(session.id) == false
    end

    test "returns false (without crashing) for a nil session id" do
      assert Tools.resolve_orchestrator(nil) == false
    end

    test "returns false for an unknown session id" do
      assert Tools.resolve_orchestrator(Ecto.UUID.generate()) == false
    end
  end
end
