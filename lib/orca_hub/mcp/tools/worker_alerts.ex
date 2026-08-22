defmodule OrcaHub.MCP.Tools.WorkerAlerts do
  @moduledoc """
  MCP tools for configuring condition-based worker alerts (ORCAHUB3-44
  Phase 2) — an orchestrator's standing, unattended-monitoring config,
  evaluated every ~120s by `OrcaHub.ChurnSampler`/`AlertEvaluator` against
  the orchestrator's watched sessions. Shape deliberately mirrors
  `schedule_heartbeat`/`cancel_heartbeat` (one config per orchestrator,
  update-in-place) but is DB-persisted (`OrcaHub.AlertSubscriptions`)
  rather than in-memory, since the whole point is surviving a deploy.
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.HubRPC

  @default_conditions %{"churn" => true, "stall" => true}
  @default_cooldown_seconds 900

  def list do
    [
      %{
        "name" => "set_worker_alerts",
        "description" =>
          "Configure (or update in place) condition-based alerts for workers you're watching. " <>
            "Unlike a heartbeat's periodic wake-up, this only messages you when something specific " <>
            "goes wrong: server-side evaluation runs every ~2 minutes and messages you (via the " <>
            "same queued delivery send_message_to_session uses) on a false->true transition of any " <>
            "enabled condition, then again only after cooldown_seconds if it's still true. Alerts " <>
            "are advisory only — you peek and judge, nothing here auto-intervenes. Only one " <>
            "config is active per orchestrator session; calling this again replaces it entirely " <>
            "(defaults: watch_children=true, conditions={\"churn\":true,\"stall\":true}, " <>
            "cooldown_seconds=900). Call cancel_worker_alerts when you no longer need monitoring.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "watch_children" => %{
              "type" => "boolean",
              "description" =>
                "If true (default), watch ALL of your non-archived child sessions (spawned via " <>
                  "start_session with you as parent). Resolved fresh on every evaluation, so " <>
                  "children spawned after this call are picked up automatically. Combine with " <>
                  "session_ids to also watch non-child sessions."
            },
            "session_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Optional additional session ids to watch beyond your children."
            },
            "conditions" => %{
              "type" => "object",
              "description" =>
                "Which conditions to alert on. Boolean keys \"churn\" and \"stall\" opt in/out; " <>
                  "integer-minutes keys \"progress_stale\" and \"no_commit_for\" are opt-in (only " <>
                  "evaluated when present). \"churn\" = the server-side rumination heuristic " <>
                  "(high tool-call rate + high repetition + no fresh commit/progress). \"stall\" = " <>
                  "status running with zero messages AND zero tool calls in the last 15 minutes " <>
                  "(a hung turn — lifecycle notifications can't catch this since they only fire on " <>
                  "idle/error). \"progress_stale\": N = report_progress hasn't updated in N minutes " <>
                  "(only once the session has reported progress at least once). \"no_commit_for\": " <>
                  "N = running, still calling tools, but no commit in N minutes. Default when " <>
                  "omitted: {\"churn\": true, \"stall\": true}.",
              "properties" => %{
                "churn" => %{"type" => "boolean"},
                "stall" => %{"type" => "boolean"},
                "progress_stale" => %{"type" => "integer"},
                "no_commit_for" => %{"type" => "integer"}
              }
            },
            "cooldown_seconds" => %{
              "type" => "integer",
              "description" =>
                "Minimum seconds between repeat alerts for the same (session, condition) while " <>
                  "it stays true. Default: 900 (15 minutes)."
            },
            "enabled" => %{
              "type" => "boolean",
              "description" =>
                "Set to false to pause evaluation without losing your configuration (e.g. instead " <>
                  "of cancel_worker_alerts when you plan to resume soon). Default: true."
            }
          },
          "required" => []
        }
      },
      %{
        "name" => "cancel_worker_alerts",
        "description" =>
          "Remove your worker-alert subscription entirely. Call this when you no longer need " <>
            "unattended monitoring of your workers.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }
      },
      %{
        "name" => "get_worker_alerts",
        "description" => "Show your current worker-alert configuration, if any.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }
      }
    ]
  end

  def call("set_worker_alerts", args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      session_id ->
        attrs = %{
          watch_children: resolve_bool(args["watch_children"], true),
          session_ids: normalize_ids(args["session_ids"]),
          conditions: normalize_conditions(args["conditions"]),
          cooldown_seconds: resolve_cooldown(args["cooldown_seconds"]),
          enabled: resolve_bool(args["enabled"], true)
        }

        case HubRPC.upsert_alert_subscription(session_id, attrs) do
          {:ok, subscription} ->
            text(
              "Worker alerts configured: watch_children=#{subscription.watch_children}, " <>
                "session_ids=#{inspect(subscription.session_ids)}, " <>
                "conditions=#{Jason.encode!(subscription.conditions)}, " <>
                "cooldown_seconds=#{subscription.cooldown_seconds}, " <>
                "enabled=#{subscription.enabled}. Call cancel_worker_alerts when you're done."
            )

          {:error, changeset} ->
            error("Failed to configure worker alerts: #{inspect(changeset.errors)}")
        end
    end
  end

  def call("cancel_worker_alerts", _args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      session_id ->
        case HubRPC.get_alert_subscription(session_id) do
          nil ->
            text("No active worker-alert subscription to cancel.")

          _subscription ->
            HubRPC.cancel_alert_subscription(session_id)
            text("Worker alerts cancelled. No more condition-based alert messages will be sent.")
        end
    end
  end

  def call("get_worker_alerts", _args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      session_id ->
        case HubRPC.get_alert_subscription(session_id) do
          nil ->
            text("No worker-alert subscription configured for your session.")

          subscription ->
            text(
              Jason.encode!(%{
                watch_children: subscription.watch_children,
                session_ids: subscription.session_ids,
                conditions: subscription.conditions,
                cooldown_seconds: subscription.cooldown_seconds,
                enabled: subscription.enabled
              })
            )
        end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────

  defp resolve_bool(v, _default) when is_boolean(v), do: v
  defp resolve_bool(_v, default), do: default

  defp resolve_cooldown(v) when is_integer(v) and v >= 0, do: v
  defp resolve_cooldown(_v), do: @default_cooldown_seconds

  defp normalize_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp normalize_ids(_), do: []

  defp normalize_conditions(conditions) when is_map(conditions) do
    conditions
    |> Enum.reduce(%{}, fn
      {"churn", v}, acc when is_boolean(v) -> Map.put(acc, "churn", v)
      {"stall", v}, acc when is_boolean(v) -> Map.put(acc, "stall", v)
      {"progress_stale", v}, acc when is_integer(v) -> Map.put(acc, "progress_stale", v)
      {"no_commit_for", v}, acc when is_integer(v) -> Map.put(acc, "no_commit_for", v)
      _kv, acc -> acc
    end)
    |> case do
      empty when map_size(empty) == 0 -> @default_conditions
      normalized -> normalized
    end
  end

  defp normalize_conditions(_), do: @default_conditions
end
