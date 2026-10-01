defmodule OrcaHub.MCP.Tools.Triggers do
  @moduledoc """
  MCP tools for creating scheduled (cron), one-off, and webhook triggers.
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC, NodePolicy}
  alias OrcaHub.Triggers.OneOff

  def list do
    [
      %{
        "name" => "create_scheduled_trigger",
        "description" =>
          "Create a scheduled trigger that automatically runs a prompt on a cron schedule. The trigger will create (or reuse) a Claude Code session in the specified project's directory and send the prompt each time the cron schedule fires. Like a calendar event, it can end: after N runs (max_runs) and/or on a date (ends_at) — it then disables itself. For a single run at a specific time, use create_one_off_trigger instead.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" =>
                "A short descriptive name for the trigger (e.g. \"Daily test run\")"
            },
            "prompt" => %{
              "type" => "string",
              "description" =>
                "The prompt to send to the Claude Code session each time the trigger fires"
            },
            "schedule" => %{
              "type" => "string",
              "enum" => ["hourly", "daily", "weekly"],
              "description" =>
                "Simple schedule preset. Use this OR cron_expression, not both. Defaults: hourly = minute 0, daily = 9:00 AM, weekly = Monday 9:00 AM. Use hour/minute/day_of_week to customize."
            },
            "hour" => %{
              "type" => "integer",
              "description" => "Hour of day (0-23) for daily/weekly schedules. Default: 9"
            },
            "minute" => %{
              "type" => "integer",
              "description" => "Minute of hour (0-59). Default: 0"
            },
            "day_of_week" => %{
              "type" => "integer",
              "description" =>
                "Day of week for weekly schedule (0=Sunday, 1=Monday, ..., 6=Saturday). Default: 1 (Monday)"
            },
            "cron_expression" => %{
              "type" => "string",
              "description" =>
                "Advanced: a raw cron expression (5-7 parts). Use this for schedules that don't fit the simple presets. Overrides the schedule parameter."
            },
            "max_runs" => %{
              "type" => "integer",
              "description" =>
                "Ends after N runs: the trigger disables itself after its Nth successful " <>
                  "fire. Omit for no limit. Skipped fires (node offline) don't count."
            },
            "ends_at" => %{
              "type" => "string",
              "description" =>
                "Ends on a date: no fire happens after this time, and the trigger disables " <>
                  "itself once its next fire would land after it. ISO8601; without an offset " <>
                  "it is America/New_York local time, and a bare date (\"2026-12-31\") means " <>
                  "the END of that day. Must be in the future. Omit for no end date."
            },
            "project_id" => %{
              "type" => "string",
              "description" =>
                "The UUID of the project to run the trigger in. Either this or `directory` " <>
                  "is required; project_id wins if both are given. Use the list_projects " <>
                  "tool to look up a project's UUID."
            },
            "directory" => %{
              "type" => "string",
              "description" =>
                "Alternative to project_id: the absolute directory of a registered project. " <>
                  "Resolved to that project's id the same way start_session resolves a " <>
                  "directory. Ignored if project_id is also given."
            },
            "reuse_session" => %{
              "type" => "boolean",
              "description" =>
                "If true, reuse the last session instead of creating a new one each time. Default: false"
            },
            "archive_on_complete" => %{
              "type" => "boolean",
              "description" => "If true, archive the session once it completes. Default: false"
            },
            "memory_extract" => %{
              "type" => "boolean",
              "description" =>
                "Override automatic memory extraction for every session this trigger " <>
                  "spawns: true forces it on, false forces it off. Omit to apply the " <>
                  "normal default rule (orchestrator or root sessions only)."
            }
          },
          "required" => ["name", "prompt"]
        }
      },
      %{
        "name" => "create_one_off_trigger",
        "description" =>
          "Schedule a prompt to run ONCE at a future time — e.g. a reminder (\"in 2.5 " <>
            "months, remind me to cancel X if I'm not using it\") or a deferred check. " <>
            "Pass exactly one of `run_at` or `delay`. When it fires, a Claude Code session " <>
            "is created in the project's directory and sent the prompt; the trigger is then " <>
            "disabled so it never fires again. Durable across restarts and deploys: a " <>
            "trigger that comes due while the hub is down fires late, right after it comes " <>
            "back. The spawned session talks to no one by default, so for a REMINDER, write " <>
            "the prompt to tell the session to notify the user — e.g. \"Use send_notification " <>
            "to remind Zach to ...\" (send_discord_message also works). Returns the " <>
            "resolved run_at.",
        "inputSchema" => %{
          "type" => "object",
          "properties" =>
            Map.merge(common_properties(), %{
              "name" => %{
                "type" => "string",
                "description" =>
                  "A short descriptive name (e.g. \"Cancel Google coach subscription\")"
              },
              "prompt" => %{
                "type" => "string",
                "description" =>
                  "The prompt sent to the session when the trigger fires. For a reminder, " <>
                    "include an instruction to notify the user via send_notification."
              },
              "run_at" => %{
                "type" => "string",
                "description" =>
                  "Absolute fire time, ISO8601. With an offset (\"2026-12-15T09:00:00-05:00\", " <>
                    "\"...Z\") it is used as-is; without one (\"2026-12-15T09:00\") it is " <>
                    "local time in America/New_York; a bare date (\"2026-12-15\") means 09:00 " <>
                    "local. Must be in the future. Use this OR delay."
              },
              "delay" => %{
                "type" => "string",
                "description" =>
                  "Relative fire time from now: one or more <number><unit> parts, summed, " <>
                    "fractions allowed — \"2.5 months\", \"3 days\", \"4h\", \"1 day 6 hours\", " <>
                    "\"90m\". Units: s, m/min (minutes), h, d, w, mo/month (a fixed 30 days), " <>
                    "y (365 days). Use this OR run_at."
              }
            }),
          "required" => ["name", "prompt"]
        }
      },
      %{
        "name" => "create_webhook_trigger",
        "description" =>
          "Create a webhook trigger with a unique URL endpoint. When the URL receives a POST request, it sends the configured prompt along with the request payload to a Claude Code session.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "A short descriptive name for the trigger"
            },
            "prompt" => %{
              "type" => "string",
              "description" =>
                "The prompt to send to the Claude Code session. The webhook payload will be appended as context."
            },
            "project_id" => %{
              "type" => "string",
              "description" =>
                "The UUID of the project to run the trigger in. Either this or `directory` " <>
                  "is required; project_id wins if both are given. Use the list_projects " <>
                  "tool to look up a project's UUID."
            },
            "directory" => %{
              "type" => "string",
              "description" =>
                "Alternative to project_id: the absolute directory of a registered project. " <>
                  "Resolved to that project's id the same way start_session resolves a " <>
                  "directory. Ignored if project_id is also given."
            },
            "reuse_session" => %{
              "type" => "boolean",
              "description" =>
                "If true, reuse the last session instead of creating a new one each time. Default: false"
            },
            "archive_on_complete" => %{
              "type" => "boolean",
              "description" => "If true, archive the session once it completes. Default: false"
            },
            "memory_extract" => %{
              "type" => "boolean",
              "description" =>
                "Override automatic memory extraction for every session this trigger " <>
                  "spawns: true forces it on, false forces it off. Omit to apply the " <>
                  "normal default rule (orchestrator or root sessions only)."
            }
          },
          "required" => ["name", "prompt"]
        }
      }
    ]
  end

  def call("create_scheduled_trigger", args, _state) do
    with {:ok, ends_at} <- resolve_ends_at(args),
         {:ok, project_id} <- resolve_project_id(args),
         :ok <- check_project_node_allowed(project_id) do
      attrs =
        %{
          name: args["name"],
          prompt: args["prompt"],
          cron_expression: build_cron(args),
          project_id: project_id,
          reuse_session: args["reuse_session"] || false,
          archive_on_complete: args["archive_on_complete"] || false,
          max_runs: args["max_runs"],
          ends_at: ends_at
        }
        |> maybe_put_memory_extract(args)

      case HubRPC.create_trigger(attrs) do
        {:ok, trigger} ->
          text(
            "Trigger \"#{trigger.name}\" created (id: #{trigger.id}). " <>
              "Schedule: #{trigger.cron_expression} (UTC)" <> ends_text(trigger)
          )

        {:error, changeset} ->
          error("Failed to create trigger: #{inspect(changeset.errors)}")
      end
    else
      {:error, message} -> error(message)
      other -> other
    end
  end

  def call("create_one_off_trigger", args, _state) do
    with {:ok, run_at} <- OneOff.resolve(args),
         {:ok, project_id} <- resolve_project_id(args),
         :ok <- check_project_node_allowed(project_id) do
      attrs =
        %{
          name: args["name"],
          prompt: args["prompt"],
          type: "once",
          run_at: run_at,
          project_id: project_id,
          reuse_session: args["reuse_session"] || false,
          archive_on_complete: args["archive_on_complete"] || false
        }
        |> maybe_put_memory_extract(args)

      case HubRPC.create_trigger(attrs) do
        {:ok, trigger} ->
          local = OneOff.to_local(trigger.run_at)

          text(
            "One-off trigger \"#{trigger.name}\" created (id: #{trigger.id}). " <>
              "Fires once at #{DateTime.to_iso8601(trigger.run_at)} " <>
              "(#{Calendar.strftime(local, "%Y-%m-%d %H:%M %Z")})."
          )

        {:error, changeset} ->
          error("Failed to create trigger: #{inspect(changeset.errors)}")
      end
    else
      {:error, message} -> error(message)
      other -> other
    end
  end

  def call("create_webhook_trigger", args, _state) do
    with {:ok, project_id} <- resolve_project_id(args),
         :ok <- check_project_node_allowed(project_id) do
      attrs =
        %{
          name: args["name"],
          prompt: args["prompt"],
          type: "webhook",
          project_id: project_id,
          reuse_session: args["reuse_session"] || false,
          archive_on_complete: args["archive_on_complete"] || false
        }
        |> maybe_put_memory_extract(args)

      case HubRPC.create_trigger(attrs) do
        {:ok, trigger} ->
          url = OrcaHubWeb.Endpoint.url() <> "/api/webhooks/#{trigger.webhook_secret}"

          text(
            "Webhook trigger \"#{trigger.name}\" created (id: #{trigger.id}). " <>
              "Webhook URL: #{url}"
          )

        {:error, changeset} ->
          error("Failed to create trigger: #{inspect(changeset.errors)}")
      end
    else
      {:error, message} -> error(message)
      other -> other
    end
  end

  defp resolve_ends_at(%{"ends_at" => ends_at}) when is_binary(ends_at) and ends_at != "",
    do: OneOff.parse_end_date(ends_at)

  defp resolve_ends_at(_args), do: {:ok, nil}

  defp ends_text(%{max_runs: nil, ends_at: nil}), do: ". Never ends."

  defp ends_text(trigger) do
    parts =
      [
        trigger.max_runs && "after #{trigger.max_runs} run(s)",
        trigger.ends_at &&
          "on #{DateTime.to_iso8601(trigger.ends_at)} " <>
            "(#{Calendar.strftime(OneOff.to_local(trigger.ends_at), "%Y-%m-%d %H:%M %Z")})"
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    case parts do
      [one] -> ". Ends #{one}."
      _ -> ". Ends " <> Enum.join(parts, " or ") <> ", whichever comes first."
    end
  end

  # The optional args every create_*_trigger tool shares.
  defp common_properties do
    %{
      "project_id" => %{
        "type" => "string",
        "description" =>
          "The UUID of the project to run the trigger in. Either this or `directory` " <>
            "is required; project_id wins if both are given. Use the list_projects " <>
            "tool to look up a project's UUID."
      },
      "directory" => %{
        "type" => "string",
        "description" =>
          "Alternative to project_id: the absolute directory of a registered project. " <>
            "Resolved to that project's id the same way start_session resolves a " <>
            "directory. Ignored if project_id is also given."
      },
      "reuse_session" => %{
        "type" => "boolean",
        "description" =>
          "If true, reuse the last session instead of creating a new one each time. Default: false"
      },
      "archive_on_complete" => %{
        "type" => "boolean",
        "description" => "If true, archive the session once it completes. Default: false"
      },
      "memory_extract" => %{
        "type" => "boolean",
        "description" =>
          "Override automatic memory extraction for every session this trigger " <>
            "spawns: true forces it on, false forces it off. Omit to apply the " <>
            "normal default rule (orchestrator or root sessions only)."
      }
    }
  end

  # project_id wins when both are given; a directory resolves the same way
  # start_session resolves one (OrcaHub.MCP.Tools.Sessions.resolve_routing) —
  # via HubRPC.get_project_by_directory/1. Neither present, or a directory
  # matching no registered project, is a clear user error rather than a
  # changeset FK failure.
  defp resolve_project_id(%{"project_id" => project_id})
       when is_binary(project_id) and project_id != "" do
    {:ok, project_id}
  end

  defp resolve_project_id(%{"directory" => directory})
       when is_binary(directory) and directory != "" do
    case HubRPC.get_project_by_directory(directory) do
      %{} = project ->
        {:ok, project.id}

      nil ->
        {:error,
         "No registered project found for directory #{inspect(directory)}. Use the " <>
           "list_projects tool to see registered projects (id, name, directory, node), " <>
           "or pass project_id directly."}
    end
  end

  defp resolve_project_id(_args) do
    {:error, "Either project_id or directory is required."}
  end

  # A trigger fires on ITS project's node (see TriggerExecutor), not
  # necessarily the caller's — so pointing a trigger at a project on
  # another node is itself a cross-node action an isolated node must not
  # be able to initiate, same as start_session's directory-based routing.
  # An unknown project_id is left to the existing FK/changeset error path
  # below rather than duplicated here.
  defp check_project_node_allowed(project_id) when is_binary(project_id) do
    case HubRPC.get_project(project_id) do
      %{} = project ->
        target_node = Cluster.project_node_for(project)

        if NodePolicy.cross_node_allowed?(target_node) do
          :ok
        else
          error(NodePolicy.denial_message(target_node))
        end

      nil ->
        :ok
    end
  end

  defp check_project_node_allowed(_project_id), do: :ok

  # `nil`/absent is left out entirely so the trigger's own default (inherit
  # the normal session scope rule) applies — see Trigger.memory_extract.
  defp maybe_put_memory_extract(attrs, %{"memory_extract" => override})
       when is_boolean(override) do
    Map.put(attrs, :memory_extract, override)
  end

  defp maybe_put_memory_extract(attrs, _args), do: attrs

  # ── create_scheduled_trigger helpers ──────────────────────────────────

  defp build_cron(%{"cron_expression" => cron}) when not is_nil(cron), do: cron

  defp build_cron(%{"schedule" => "hourly"} = args), do: "#{args["minute"] || 0} * * * *"

  defp build_cron(%{"schedule" => "weekly"} = args) do
    "#{args["minute"] || 0} #{args["hour"] || 9} * * #{args["day_of_week"] || 1}"
  end

  defp build_cron(args), do: "#{args["minute"] || 0} #{args["hour"] || 9} * * *"
end
