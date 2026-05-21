defmodule OrcaHub.MCP.Tools.Heartbeat do
  @moduledoc """
  MCP tools for scheduling and cancelling periodic session heartbeats.
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.HubRPC

  def list do
    [
      %{
        "name" => "schedule_heartbeat",
        "description" =>
          "Schedule periodic heartbeat messages to your session. Use this when you're orchestrating other sessions or waiting for external events and need to periodically wake up to check status. The heartbeat will send the specified message to your session at the given interval. Only one heartbeat can be active per session - calling this again updates the existing heartbeat. Call cancel_heartbeat when you're done with your task.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "interval_seconds" => %{
              "type" => "integer",
              "description" =>
                "Interval between heartbeats in seconds. Minimum 30 seconds, no maximum."
            },
            "message" => %{
              "type" => "string",
              "description" =>
                "The message to send to your session on each heartbeat. This should instruct you what to check or do when woken up."
            }
          },
          "required" => ["interval_seconds", "message"]
        }
      },
      %{
        "name" => "cancel_heartbeat",
        "description" =>
          "Cancel the active heartbeat for your session. Call this when you no longer need periodic wake-ups, such as when the orchestration task has completed or the event you were waiting for has occurred.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      }
    ]
  end

  def call("schedule_heartbeat", args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      session_id ->
        do_schedule_heartbeat(session_id, args["interval_seconds"], args["message"])
    end
  end

  def call("cancel_heartbeat", _args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      session_id ->
        case HubRPC.get_heartbeat(session_id) do
          nil ->
            text("No active heartbeat to cancel.")

          _info ->
            HubRPC.cancel_heartbeat(session_id)

            text(
              "Heartbeat cancelled. Your session will no longer receive periodic wake-up messages."
            )
        end
    end
  end

  # ── schedule_heartbeat helpers ────────────────────────────────────────

  defp do_schedule_heartbeat(_session_id, interval, _message) when not is_integer(interval) do
    error("interval_seconds is required and must be an integer.")
  end

  defp do_schedule_heartbeat(_session_id, _interval, message)
       when is_nil(message) or message == "" do
    error("message is required and cannot be empty.")
  end

  defp do_schedule_heartbeat(session_id, interval, message) do
    # Prefix the message to make it clear it's a heartbeat
    prefixed_message = "[Heartbeat]\n\n#{message}"

    case HubRPC.schedule_heartbeat(session_id, interval, prefixed_message) do
      :ok ->
        text(
          "Heartbeat scheduled: your session will receive a wake-up message every #{interval} seconds. " <>
            "Remember to call cancel_heartbeat when you're done with your task."
        )

      {:error, reason} ->
        error("Failed to schedule heartbeat: #{reason}")
    end
  end
end
