defmodule OrcaHub.MCP.Tools.Notifications do
  @moduledoc """
  MCP tool for sending push notifications via Gotify.
  """
  import OrcaHub.MCP.Tools.Result

  def list do
    [
      %{
        "name" => "send_gotify_notification",
        "description" =>
          "Send a push notification via Gotify. Use this to alert the user about important events, such as task completion, errors requiring attention, or status updates.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{
              "type" => "string",
              "description" => "The notification title"
            },
            "message" => %{
              "type" => "string",
              "description" => "The notification body text"
            },
            "priority" => %{
              "type" => "integer",
              "description" =>
                "Notification priority (0-10). Default is 5. Higher values are more urgent."
            }
          },
          "required" => ["title", "message"]
        }
      }
    ]
  end

  def call("send_gotify_notification", args, _state) do
    title = args["title"]
    message = args["message"]
    priority = args["priority"] || 5

    url = Application.get_env(:orca_hub, :gotify_url)
    token = Application.get_env(:orca_hub, :gotify_token)

    if is_nil(url) or is_nil(token) do
      error("Gotify is not configured. Set GOTIFY_URL and GOTIFY_TOKEN environment variables.")
    else
      case Req.post("#{url}/message",
             json: %{title: title, message: message, priority: priority},
             headers: [{"x-gotify-key", token}]
           ) do
        {:ok, %{status: 200}} ->
          text("Notification sent: #{title}")

        {:ok, resp} ->
          error("Gotify returned status #{resp.status}: #{inspect(resp.body)}")

        {:error, reason} ->
          error("Failed to send Gotify notification: #{inspect(reason)}")
      end
    end
  end
end
