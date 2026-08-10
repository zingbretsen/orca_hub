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
          "Schedule periodic heartbeat messages to your session. Unlike the Claude-CLI-native ScheduleWakeup tool (delaySeconds/prompt), this tool takes interval_seconds (integer seconds) and message. Use this when you're orchestrating other sessions or waiting for external events and need to periodically wake up to check status. The heartbeat will send the specified message to your session at the given interval, with an auto-digest of any watched sessions appended, plus watch_job_ids (see below) for waking early on a start_job job finishing. Only one heartbeat can be active per session - calling this again updates the existing heartbeat. Call cancel_heartbeat when you're done with your task. A heartbeat does not prevent teardown - it only wakes you afterwards. It is the polling mechanism, not the durability mechanism; start_job is what makes the underlying work survive.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "interval_seconds" => %{
              "type" => "integer",
              "description" =>
                "Interval between heartbeats in seconds. Minimum 30 seconds, no maximum."
            },
            "interval_minutes" => %{
              "type" => "integer",
              "description" =>
                "Convenience alias for interval_seconds, in whole positive minutes. Used only when interval_seconds is absent."
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
            },
            "watch_job_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Optional start_job job ids to wake EARLY for, on top of the normal timer (which " <>
                  "keeps firing as the backstop even if a watched job never finishes). Only a " <>
                  "job reaching a TERMINAL status wakes you - one still in verifying (its " <>
                  "verify_command hasn't finished) does not; see start_job. This is a one-shot " <>
                  "early wake: once it fires, watch_job_ids is cleared and the timer resets to a " <>
                  "fresh full interval. A heartbeat does not prevent teardown, it only wakes you " <>
                  "afterwards - the job itself survives on its own via start_job, not because " <>
                  "anything is watching it."
            },
            "wake_on" => %{
              "type" => "string",
              "description" =>
                "\"any\" (default) fires as soon as ONE watch_job_ids job reaches a terminal " <>
                  "status; \"all\" waits for every one of them. No effect without watch_job_ids."
            }
          },
          "required" => ["message"]
        }
      },
      %{
        "name" => "cancel_heartbeat",
        "description" =>
          "Cancel the active heartbeat for your session, or (optionally) for a direct child session of yours. Call this when you no longer need periodic wake-ups, such as when the orchestration task has completed or the event you were waiting for has occurred. Also useful when archiving/tearing down a child you spawned: pass its session_id so you don't have to ask it to cancel its own heartbeat first.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "session_id" => %{
              "type" => "string",
              "description" =>
                "Optional. Defaults to your own session. If set to a DIFFERENT session id, that session must be your direct child (its parent_session_id must be you) - cancelling an unrelated session's heartbeat is rejected."
            }
          }
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
          only_if_changed: args["only_if_changed"] == true,
          watch_job_ids: normalize_watch_ids(args["watch_job_ids"]),
          wake_on: if(args["wake_on"] == "all", do: "all", else: "any")
        }

        interval = resolve_interval(args["interval_seconds"], args["interval_minutes"])
        do_schedule_heartbeat(session_id, interval, args["message"], opts)
    end
  end

  def call("cancel_heartbeat", args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      caller_id ->
        do_cancel_heartbeat(args["session_id"] || caller_id, caller_id)
    end
  end

  # ── schedule_heartbeat helpers ────────────────────────────────────────

  defp resolve_interval(interval_seconds, _interval_minutes) when not is_nil(interval_seconds),
    do: interval_seconds

  defp resolve_interval(nil, interval_minutes)
       when is_integer(interval_minutes) and interval_minutes > 0,
       do: interval_minutes * 60

  defp resolve_interval(_interval_seconds, _interval_minutes), do: nil

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

  # ── cancel_heartbeat helpers ─────────────────────────────────────────

  defp do_cancel_heartbeat(target_id, caller_id) when target_id == caller_id do
    cancel_and_report(target_id, "your session")
  end

  defp do_cancel_heartbeat(target_id, caller_id) do
    case HubRPC.get_session(target_id) do
      nil ->
        error("Session #{target_id} not found.")

      %{parent_session_id: ^caller_id} ->
        cancel_and_report(target_id, "child session #{target_id}")

      _ ->
        error(
          "Permission denied: you can only cancel your own heartbeat or a direct child's " <>
            "(session #{target_id} is not your child)."
        )
    end
  end

  defp cancel_and_report(session_id, label) do
    case HubRPC.get_heartbeat(session_id) do
      nil ->
        text("No active heartbeat to cancel for #{label}.")

      _info ->
        HubRPC.cancel_heartbeat(session_id)
        text("Heartbeat cancelled for #{label}. No more periodic wake-up messages will be sent.")
    end
  end
end
