defmodule OrcaHub.MCP.Tools.Triggers do
  @moduledoc """
  MCP tools for creating scheduled and webhook triggers.
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC, NodePolicy}

  def list do
    [
      %{
        "name" => "create_scheduled_trigger",
        "description" =>
          "Create a scheduled trigger that automatically runs a prompt on a cron schedule. The trigger will create (or reuse) a Claude Code session in the specified project's directory and send the prompt each time the cron schedule fires.",
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
            "project_id" => %{
              "type" => "string",
              "description" => "The UUID of the project to run the trigger in"
            },
            "reuse_session" => %{
              "type" => "boolean",
              "description" =>
                "If true, reuse the last session instead of creating a new one each time. Default: false"
            },
            "archive_on_complete" => %{
              "type" => "boolean",
              "description" => "If true, archive the session once it completes. Default: false"
            }
          },
          "required" => ["name", "prompt", "project_id"]
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
              "description" => "The UUID of the project to run the trigger in"
            },
            "reuse_session" => %{
              "type" => "boolean",
              "description" =>
                "If true, reuse the last session instead of creating a new one each time. Default: false"
            },
            "archive_on_complete" => %{
              "type" => "boolean",
              "description" => "If true, archive the session once it completes. Default: false"
            }
          },
          "required" => ["name", "prompt", "project_id"]
        }
      }
    ]
  end

  def call("create_scheduled_trigger", args, _state) do
    with :ok <- check_project_node_allowed(args["project_id"]) do
      attrs = %{
        name: args["name"],
        prompt: args["prompt"],
        cron_expression: build_cron(args),
        project_id: args["project_id"],
        reuse_session: args["reuse_session"] || false,
        archive_on_complete: args["archive_on_complete"] || false
      }

      case HubRPC.create_trigger(attrs) do
        {:ok, trigger} ->
          text(
            "Trigger \"#{trigger.name}\" created (id: #{trigger.id}). " <>
              "Schedule: #{trigger.cron_expression}"
          )

        {:error, changeset} ->
          error("Failed to create trigger: #{inspect(changeset.errors)}")
      end
    end
  end

  def call("create_webhook_trigger", args, _state) do
    with :ok <- check_project_node_allowed(args["project_id"]) do
      attrs = %{
        name: args["name"],
        prompt: args["prompt"],
        type: "webhook",
        project_id: args["project_id"],
        reuse_session: args["reuse_session"] || false,
        archive_on_complete: args["archive_on_complete"] || false
      }

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
    end
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

  # ── create_scheduled_trigger helpers ──────────────────────────────────

  defp build_cron(%{"cron_expression" => cron}) when not is_nil(cron), do: cron

  defp build_cron(%{"schedule" => "hourly"} = args), do: "#{args["minute"] || 0} * * * *"

  defp build_cron(%{"schedule" => "weekly"} = args) do
    "#{args["minute"] || 0} #{args["hour"] || 9} * * #{args["day_of_week"] || 1}"
  end

  defp build_cron(args), do: "#{args["minute"] || 0} #{args["hour"] || 9} * * *"
end
