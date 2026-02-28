defmodule OrcaHub.MCP.ToolsTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.MCP.Tools
  alias OrcaHub.Feedback

  describe "get_human_feedback" do
    test "creates a feedback request and returns the human's response" do
      state = %{session_id: "test-mcp-session"}

      # Call the tool in a separate process since it blocks waiting for a response
      task =
        Task.async(fn ->
          Tools.call("get_human_feedback", %{"question" => "Should I proceed?"}, state)
        end)

      # Wait briefly for the request to be created
      Process.sleep(100)

      # Find the pending request
      [request] = Feedback.list_pending_requests()
      assert request.question == "Should I proceed?"
      assert request.mcp_session_id == "test-mcp-session"
      assert request.status == "pending"

      # Simulate a human responding
      {:ok, _responded} = Feedback.respond(request.id, "Yes, go ahead")

      # The tool call should now return with the response
      result = Task.await(task)

      assert result == %{
               "content" => [%{"type" => "text", "text" => "Yes, go ahead"}],
               "isError" => false
             }
    end

    test "associates feedback request with a session_id when provided" do
      state = %{session_id: "test-mcp-session"}

      task =
        Task.async(fn ->
          Tools.call(
            "get_human_feedback",
            %{"question" => "Which approach?", "session_id" => nil},
            state
          )
        end)

      Process.sleep(100)

      [request] = Feedback.list_pending_requests()
      assert request.session_id == nil

      {:ok, _} = Feedback.respond(request.id, "Option A")
      Task.await(task)
    end
  end
end
