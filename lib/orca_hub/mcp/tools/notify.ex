defmodule OrcaHub.MCP.Tools.Notify do
  @moduledoc """
  MCP tool for pushing a Gotify notification to the human user (Zach).

  Delivery is routed through the hub via `OrcaHub.HubRPC.send_notification/1`
  (backed by `OrcaHub.Notify`) so only the hub node needs Gotify creds —
  unlike `OrcaHub.MCP.Tools.Databases`/`PhxAgents`, which call their external
  API directly from the session's own runner node.
  """
  import OrcaHub.MCP.Tools.Result

  def list do
    [
      %{
        "name" => "send_notification",
        "description" =>
          "Push a notification to the human user (Zach) via Gotify. Use this for things " <>
            "like \"a long task finished,\" \"I need your input or a decision,\" or an " <>
            "important alert that needs prompt human attention — NOT for routine chatter " <>
            "or progress updates (use report_progress for those). Delivery is routed " <>
            "through the hub, so this works from any node.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "message" => %{
              "type" => "string",
              "description" => "The notification body. Required."
            },
            "title" => %{
              "type" => "string",
              "description" => "Notification title. Defaults to \"OrcaHub\"."
            },
            "priority" => %{
              "type" => "integer",
              "description" =>
                "Gotify priority, 0-10. Higher is more urgent/attention-grabbing. Defaults to 5."
            },
            "click_url" => %{
              "type" => "string",
              "description" => "Optional URL to open when the notification is tapped/clicked."
            },
            "markdown" => %{
              "type" => "boolean",
              "description" => "If true, render the message body as markdown. Defaults to false."
            }
          },
          "required" => ["message"]
        }
      }
    ]
  end

  def call("send_notification", args, _state) do
    with {:ok, message} <- validate_message(args["message"]) do
      payload = %{
        "message" => message,
        "title" => args["title"],
        "priority" => args["priority"],
        "click_url" => args["click_url"],
        "markdown" => args["markdown"]
      }

      deliver(payload)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp validate_message(message) when is_binary(message) do
    if String.trim(message) == "" do
      {:error, "message is required and cannot be empty."}
    else
      {:ok, message}
    end
  end

  defp validate_message(_message),
    do: {:error, "message is required and must be a string."}

  defp deliver(payload) do
    case OrcaHub.HubRPC.send_notification(payload) do
      {:ok, msg} -> text(msg)
      {:error, reason} -> error(reason)
    end
  rescue
    e -> error("Failed to route notification through the hub: #{Exception.message(e)}")
  catch
    :exit, reason ->
      error("Failed to route notification through the hub: #{inspect(reason)}")
  end
end
