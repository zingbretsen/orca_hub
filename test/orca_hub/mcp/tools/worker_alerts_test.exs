defmodule OrcaHub.MCP.Tools.WorkerAlertsTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.HubRPC
  alias OrcaHub.MCP.Tools.WorkerAlerts

  defp unique_id, do: Ecto.UUID.generate()

  defp state_for(session_id), do: %{orca_session_id: session_id}

  describe "list/0" do
    test "exposes all three tools with sensible schemas" do
      [set_tool, cancel_tool, get_tool] = WorkerAlerts.list()

      assert set_tool["name"] == "set_worker_alerts"
      assert set_tool["inputSchema"]["required"] == []

      properties = set_tool["inputSchema"]["properties"]
      assert %{"type" => "boolean"} = properties["watch_children"]
      assert %{"type" => "array", "items" => %{"type" => "string"}} = properties["session_ids"]
      assert %{"type" => "object"} = properties["conditions"]
      assert %{"type" => "integer"} = properties["cooldown_seconds"]
      assert %{"type" => "boolean"} = properties["enabled"]

      assert cancel_tool["name"] == "cancel_worker_alerts"
      assert get_tool["name"] == "get_worker_alerts"
    end
  end

  describe "call/3 set_worker_alerts" do
    test "errors when no OrcaHub session is linked" do
      assert %{"isError" => true} =
               WorkerAlerts.call("set_worker_alerts", %{}, %{orca_session_id: nil})
    end

    test "applies sensible defaults when called with no args" do
      id = unique_id()

      assert %{"isError" => false} = WorkerAlerts.call("set_worker_alerts", %{}, state_for(id))

      assert %{
               watch_children: true,
               session_ids: [],
               conditions: %{"churn" => true, "stall" => true},
               cooldown_seconds: 900,
               enabled: true
             } = HubRPC.get_alert_subscription(id)
    end

    test "wires explicit args through" do
      id = unique_id()
      other_id = unique_id()

      assert %{"isError" => false} =
               WorkerAlerts.call(
                 "set_worker_alerts",
                 %{
                   "watch_children" => false,
                   "session_ids" => [other_id],
                   "conditions" => %{"progress_stale" => 20, "no_commit_for" => 45},
                   "cooldown_seconds" => 300,
                   "enabled" => false
                 },
                 state_for(id)
               )

      assert %{
               watch_children: false,
               session_ids: [^other_id],
               conditions: %{"progress_stale" => 20, "no_commit_for" => 45},
               cooldown_seconds: 300,
               enabled: false
             } = HubRPC.get_alert_subscription(id)
    end

    test "drops malformed conditions entries and non-string session_ids" do
      id = unique_id()
      other_id = unique_id()

      WorkerAlerts.call(
        "set_worker_alerts",
        %{
          "session_ids" => [other_id, 123, nil],
          "conditions" => %{"churn" => "not a bool", "stall" => true, "unknown" => 1}
        },
        state_for(id)
      )

      assert %{session_ids: [^other_id], conditions: %{"stall" => true}} =
               HubRPC.get_alert_subscription(id)
    end

    test "upserts in place — one config per orchestrator" do
      id = unique_id()

      WorkerAlerts.call(
        "set_worker_alerts",
        %{"cooldown_seconds" => 600},
        state_for(id)
      )

      WorkerAlerts.call(
        "set_worker_alerts",
        %{"cooldown_seconds" => 120},
        state_for(id)
      )

      assert %{cooldown_seconds: 120} = HubRPC.get_alert_subscription(id)
    end
  end

  describe "call/3 cancel_worker_alerts" do
    test "errors when no OrcaHub session is linked" do
      assert %{"isError" => true} =
               WorkerAlerts.call("cancel_worker_alerts", %{}, %{orca_session_id: nil})
    end

    test "reports nothing to cancel when no subscription is active" do
      id = unique_id()

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               WorkerAlerts.call("cancel_worker_alerts", %{}, state_for(id))

      assert msg =~ "No active"
    end

    test "cancels an active subscription" do
      id = unique_id()
      WorkerAlerts.call("set_worker_alerts", %{}, state_for(id))

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               WorkerAlerts.call("cancel_worker_alerts", %{}, state_for(id))

      assert msg =~ "cancelled"
      assert HubRPC.get_alert_subscription(id) == nil
    end
  end

  describe "call/3 get_worker_alerts" do
    test "errors when no OrcaHub session is linked" do
      assert %{"isError" => true} =
               WorkerAlerts.call("get_worker_alerts", %{}, %{orca_session_id: nil})
    end

    test "reports no configuration when none is set" do
      id = unique_id()

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               WorkerAlerts.call("get_worker_alerts", %{}, state_for(id))

      assert msg =~ "No worker-alert subscription"
    end

    test "shows the current configuration as JSON" do
      id = unique_id()

      WorkerAlerts.call("set_worker_alerts", %{"cooldown_seconds" => 300}, state_for(id))

      assert %{"isError" => false, "content" => [%{"text" => msg}]} =
               WorkerAlerts.call("get_worker_alerts", %{}, state_for(id))

      assert %{"cooldown_seconds" => 300, "conditions" => %{"churn" => true, "stall" => true}} =
               Jason.decode!(msg)
    end
  end
end
