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
          "Schedule periodic heartbeat messages to your session. Use this when you're orchestrating other sessions or waiting for external events and need to periodically wake up to check status. The heartbeat will send the specified message to your session at the given interval, with an auto-digest of any watched sessions appended. Only one heartbeat can be active per session - calling this again updates the existing heartbeat. Call cancel_heartbeat when you're done with your task.",
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
            },
            "watch_session_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Optional session ids to auto-digest into each heartbeat message: status, progress phase/note, recent activity counts, last git commit, and error detail if errored. Archived/deleted watched sessions drop out silently."
            },
            "watch_children" => %{
              "type" => "boolean",
              "description" =>
                "If true, also auto-digest ALL of your non-archived child sessions (spawned via start_session with you as parent). Resolved fresh at each fire, so children spawned after scheduling are picked up automatically. Combine with watch_session_ids to also watch non-child sessions. Default: false."
            },
            "only_if_changed" => %{
              "type" => "boolean",
              "description" =>
                "If true, skip delivering a fire entirely when no watched session's status/phase/activity changed since the previous fire. No effect if there's no watch list. Default: false."
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
        opts = %{
          watch_session_ids: normalize_watch_ids(args["watch_session_ids"]),
          watch_children: args["watch_children"] == true,
          only_if_changed: args["only_if_changed"] == true
        }

        do_schedule_heartbeat(session_id, args["interval_seconds"], args["message"], opts)
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

  defp do_schedule_heartbeat(_session_id, interval, _message, _opts)
       when not is_integer(interval) do
    error("interval_seconds is required and must be an integer.")
  end

  defp do_schedule_heartbeat(_session_id, _interval, message, _opts)
       when is_nil(message) or message == "" do
    error("message is required and cannot be empty.")
  end

  defp do_schedule_heartbeat(session_id, interval, message, opts) do
    # Prefix the message to make it clear it's a heartbeat
    prefixed_message = "[Heartbeat]\n\n#{message}"

    case HubRPC.schedule_heartbeat(session_id, interval, prefixed_message, opts) do
      :ok ->
        text(
          "Heartbeat scheduled: your session will receive a wake-up message every #{interval} seconds. " <>
            "Remember to call cancel_heartbeat when you're done with your task."
        )

      {:error, reason} ->
        error("Failed to schedule heartbeat: #{reason}")
    end
  end

  defp normalize_watch_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp normalize_watch_ids(_), do: []
end
