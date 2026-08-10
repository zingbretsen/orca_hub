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
      assert %{"type" => "integer"} = properties["interval_minutes"]
      assert schedule_tool["inputSchema"]["required"] == ["message"]
      assert schedule_tool["description"] =~ "ScheduleWakeup"
    end

    test "cancel_heartbeat exposes an optional session_id" do
      [_schedule_tool, cancel_tool] = HeartbeatTool.list()

      assert cancel_tool["name"] == "cancel_heartbeat"
      assert %{"type" => "string"} = cancel_tool["inputSchema"]["properties"]["session_id"]
      refute Map.has_key?(cancel_tool["inputSchema"], "required")
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

    test "converts a positive interval_minutes alias to seconds" do
      id = unique_id()
      on_exit(fn -> HubRPC.cancel_heartbeat(id) end)

      assert %{"isError" => false} =
               HeartbeatTool.call(
                 "schedule_heartbeat",
                 %{"interval_minutes" => 2, "message" => "check in"},
                 state_for(id)
               )

      assert %{interval_seconds: 120} = HubRPC.get_heartbeat(id)
    end

    test "prefers interval_seconds when both interval units are given" do
      id = unique_id()
      on_exit(fn -> HubRPC.cancel_heartbeat(id) end)

      assert %{"isError" => false} =
               HeartbeatTool.call(
                 "schedule_heartbeat",
                 %{"interval_seconds" => 45, "interval_minutes" => 2, "message" => "check in"},
                 state_for(id)
               )

      assert %{interval_seconds: 45} = HubRPC.get_heartbeat(id)
    end

    test "enforces the 30-second minimum after resolving the interval" do
      id = unique_id()

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call(
                 "schedule_heartbeat",
                 %{"interval_seconds" => 29, "interval_minutes" => 2, "message" => "check in"},
                 state_for(id)
               )

      assert msg =~ "at least 30 seconds"
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

    test "an explicit session_id matching the caller's own id cancels the caller's heartbeat" do
      id = unique_id()

      HeartbeatTool.call(
        "schedule_heartbeat",
        %{"interval_seconds" => 30, "message" => "check in"},
        state_for(id)
      )

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call("cancel_heartbeat", %{"session_id" => id}, state_for(id))

      assert msg =~ "cancelled"
      assert HubRPC.get_heartbeat(id) == nil
    end
  end

  describe "call/3 cancel_heartbeat — parent/child permission (item 3, ORCAHUB3-26)" do
    alias OrcaHub.Sessions

    defp fixture_session(attrs) do
      dir =
        Path.join(System.tmp_dir!(), "heartbeat-tool-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} = Sessions.create_session(Map.merge(%{directory: dir}, attrs))
      session
    end

    test "a parent can cancel its direct child's heartbeat" do
      parent = fixture_session(%{})
      child = fixture_session(%{parent_session_id: parent.id})

      HeartbeatTool.call(
        "schedule_heartbeat",
        %{"interval_seconds" => 30, "message" => "check in"},
        state_for(child.id)
      )

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call(
                 "cancel_heartbeat",
                 %{"session_id" => child.id},
                 state_for(parent.id)
               )

      assert msg =~ "cancelled"
      assert msg =~ child.id
      assert HubRPC.get_heartbeat(child.id) == nil
    end

    test "a session cannot cancel an unrelated session's heartbeat" do
      caller = fixture_session(%{})
      unrelated = fixture_session(%{})

      HeartbeatTool.call(
        "schedule_heartbeat",
        %{"interval_seconds" => 30, "message" => "check in"},
        state_for(unrelated.id)
      )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call(
                 "cancel_heartbeat",
                 %{"session_id" => unrelated.id},
                 state_for(caller.id)
               )

      assert msg =~ "Permission denied"
      # Untouched - still active.
      refute HubRPC.get_heartbeat(unrelated.id) == nil
      HubRPC.cancel_heartbeat(unrelated.id)
    end

    test "a grandparent cannot cancel a grandchild's heartbeat (parent/child only, not full ancestry)" do
      grandparent = fixture_session(%{})
      parent = fixture_session(%{parent_session_id: grandparent.id})
      child = fixture_session(%{parent_session_id: parent.id})

      HeartbeatTool.call(
        "schedule_heartbeat",
        %{"interval_seconds" => 30, "message" => "check in"},
        state_for(child.id)
      )

      assert %{"isError" => true} =
               HeartbeatTool.call(
                 "cancel_heartbeat",
                 %{"session_id" => child.id},
                 state_for(grandparent.id)
               )

      refute HubRPC.get_heartbeat(child.id) == nil
      HubRPC.cancel_heartbeat(child.id)
    end

    test "cancelling a heartbeat for a nonexistent target session errors" do
      caller = fixture_session(%{})

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call(
                 "cancel_heartbeat",
                 %{"session_id" => Ecto.UUID.generate()},
                 state_for(caller.id)
               )

      assert msg =~ "not found"
    end

    test "cancelling a child's heartbeat when it has none reports nothing to cancel" do
      parent = fixture_session(%{})
      child = fixture_session(%{parent_session_id: parent.id})

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               HeartbeatTool.call(
                 "cancel_heartbeat",
                 %{"session_id" => child.id},
                 state_for(parent.id)
               )

      assert msg =~ "No active heartbeat"
    end
  end
end
