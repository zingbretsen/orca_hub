defmodule OrcaHub.MCP.Tools.HeartbeatTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.HubRPC
  alias OrcaHub.MCP.Tools.Heartbeat, as: HeartbeatTool

  defp unique_id, do: Ecto.UUID.generate()

  defp state_for(session_id), do: %{orca_session_id: session_id}

  describe "list/0" do
    test "schedule_heartbeat exposes the watch-list properties" do
      [schedule_tool, _cancel_tool] = HeartbeatTool.list()

      assert schedule_tool["name"] == "schedule_heartbeat"

      properties = schedule_tool["inputSchema"]["properties"]

      assert %{"type" => "array", "items" => %{"type" => "string"}} =
               properties["watch_session_ids"]

      assert %{"type" => "boolean"} = properties["watch_children"]
      assert %{"type" => "boolean"} = properties["only_if_changed"]
    end
  end

  describe "call/3 schedule_heartbeat" do
    test "errors when no OrcaHub session is linked" do
      assert %{"isError" => true} =
               HeartbeatTool.call("schedule_heartbeat", %{}, %{orca_session_id: nil})
    end

    test "errors on a non-integer interval without scheduling" do
      id = unique_id()

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call(
                 "schedule_heartbeat",
                 %{"interval_seconds" => "not a number", "message" => "hi"},
                 state_for(id)
               )

      assert msg =~ "interval_seconds"
      assert HubRPC.get_heartbeat(id) == nil
    end

    test "errors on an empty message without scheduling" do
      id = unique_id()

      assert %{"isError" => true} =
               HeartbeatTool.call(
                 "schedule_heartbeat",
                 %{"interval_seconds" => 30, "message" => ""},
                 state_for(id)
               )

      assert HubRPC.get_heartbeat(id) == nil
    end

    test "defaults watch options to empty/false when omitted" do
      id = unique_id()
      on_exit(fn -> HubRPC.cancel_heartbeat(id) end)

      assert %{"isError" => false} =
               HeartbeatTool.call(
                 "schedule_heartbeat",
                 %{"interval_seconds" => 30, "message" => "check in"},
                 state_for(id)
               )

      assert %{watch_session_ids: [], watch_children: false, only_if_changed: false} =
               HubRPC.get_heartbeat(id)
    end

    test "wires watch_session_ids/watch_children/only_if_changed through to the heartbeat" do
      id = unique_id()
      other_id = unique_id()
      on_exit(fn -> HubRPC.cancel_heartbeat(id) end)

      assert %{"isError" => false} =
               HeartbeatTool.call(
                 "schedule_heartbeat",
                 %{
                   "interval_seconds" => 30,
                   "message" => "check in",
                   "watch_session_ids" => [other_id],
                   "watch_children" => true,
                   "only_if_changed" => true
                 },
                 state_for(id)
               )

      assert %{watch_session_ids: [^other_id], watch_children: true, only_if_changed: true} =
               HubRPC.get_heartbeat(id)
    end

    test "drops non-string entries from watch_session_ids and ignores a non-list value" do
      id = unique_id()
      other_id = unique_id()
      on_exit(fn -> HubRPC.cancel_heartbeat(id) end)

      HeartbeatTool.call(
        "schedule_heartbeat",
        %{
          "interval_seconds" => 30,
          "message" => "check in",
          "watch_session_ids" => [other_id, 123, nil, %{}]
        },
        state_for(id)
      )

      assert %{watch_session_ids: [^other_id]} = HubRPC.get_heartbeat(id)

      id2 = unique_id()
      on_exit(fn -> HubRPC.cancel_heartbeat(id2) end)

      HeartbeatTool.call(
        "schedule_heartbeat",
        %{"interval_seconds" => 30, "message" => "check in", "watch_session_ids" => "oops"},
        state_for(id2)
      )

      assert %{watch_session_ids: []} = HubRPC.get_heartbeat(id2)
    end
  end

  describe "call/3 cancel_heartbeat" do
    test "errors when no OrcaHub session is linked" do
      assert %{"isError" => true} =
               HeartbeatTool.call("cancel_heartbeat", %{}, %{orca_session_id: nil})
    end

    test "reports nothing to cancel when no heartbeat is active" do
      id = unique_id()

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call("cancel_heartbeat", %{}, state_for(id))

      assert msg =~ "No active heartbeat"
    end

    test "cancels an active heartbeat" do
      id = unique_id()

      HeartbeatTool.call(
        "schedule_heartbeat",
        %{"interval_seconds" => 30, "message" => "check in"},
        state_for(id)
      )

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call("cancel_heartbeat", %{}, state_for(id))

      assert msg =~ "cancelled"
      assert HubRPC.get_heartbeat(id) == nil
    end
  end
end
