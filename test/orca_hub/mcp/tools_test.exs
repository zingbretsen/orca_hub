defmodule OrcaHub.MCP.ToolsTest do
  use OrcaHub.DataCase

  alias OrcaHub.MCP.Tools

  describe "list/1 tool visibility (role carried on connection state)" do
    test "orchestrator connections see every tool" do
      names = Tools.list(%{orchestrator: true}) |> Enum.map(& &1["name"])

      assert "start_session" in names
      assert "search_sessions" in names
      assert "send_message_to_session" in names
      assert "open_file" in names
    end

    test "regular connections see only the regular tool set" do
      names = Tools.list(%{orchestrator: false}) |> Enum.map(& &1["name"])

      assert "send_message_to_session" in names
      assert "open_file" in names
      refute "start_session" in names
      refute "search_sessions" in names
    end

    test "an absent role defaults to a regular connection" do
      names = Tools.list(%{orca_session_id: "abc"}) |> Enum.map(& &1["name"])

      assert "send_message_to_session" in names
      refute "start_session" in names
    end
  end

  describe "call/3 dispatch (no role gate)" do
    test "unknown tool names return an error result" do
      result = Tools.call("not_a_real_tool", %{}, %{orchestrator: false})
      assert %{"isError" => true} = result

      [%{"text" => text}] = result["content"]
      assert text =~ "Unknown tool"
    end

    test "known orchestrator tools are dispatched even for a regular connection" do
      # No role gate on call/3: the tool enters its own body (which may fail on
      # missing args/linkage) — but is never rejected as permission-denied.
      result =
        try do
          Tools.call("start_session", %{}, %{orchestrator: false, orca_session_id: nil})
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
end
