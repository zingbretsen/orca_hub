defmodule OrcaHub.MCP.Tools do
  @moduledoc """
  MCP tool definitions and dispatch.
  """
  require Logger

  alias OrcaHub.{Issues, Sessions, SessionSupervisor, SessionRunner, Feedback}

  def list do
    [
      %{
        "name" => "start_session_from_issue",
        "description" =>
          "Start a new Claude Code session for a given issue. Creates a session in the issue's project directory, starts the Claude CLI, and sends the issue description as the initial prompt.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "issue_id" => %{
              "type" => "integer",
              "description" => "The ID of the issue to start a session for"
            },
            "prompt" => %{
              "type" => "string",
              "description" => "Optional additional instructions to append to the issue description"
            }
          },
          "required" => ["issue_id"]
        }
      },
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
              "description" => "Notification priority (0-10). Default is 5. Higher values are more urgent."
            }
          },
          "required" => ["title", "message"]
        }
      },
      %{
        "name" => "get_human_feedback",
        "description" =>
          "Ask a human operator a question and wait for their response. The question appears in the OrcaHub queue for a human to answer. This call blocks until the human responds.\n\nUse this tool when you need specific feedback or a decision from the user about your implementation — for example, choosing between approaches, clarifying requirements, or confirming a design choice. The human will only see the question you send, with no other context, so make your question self-contained and include any relevant details they'd need to answer. Do NOT use this tool for general status updates or thinking out loud — those can be regular assistant messages.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "question" => %{
              "type" => "string",
              "description" => "The question to ask the human operator"
            },
            "session_id" => %{
              "type" => "integer",
              "description" => "Optional OrcaHub session ID to associate the feedback request with"
            }
          },
          "required" => ["question"]
        }
      }
    ]
  end

  def call("start_session_from_issue", args, _state) do
    issue_id = args["issue_id"]

    try do
      issue = Issues.get_issue!(issue_id)
      directory = if issue.project, do: issue.project.directory, else: File.cwd!()

      project_id = if issue.project, do: issue.project.id, else: nil

      case Sessions.create_session(%{directory: directory, issue_id: issue.id, project_id: project_id}) do
        {:ok, session} ->
          {:ok, _} = SessionSupervisor.start_session(session.id)

          if issue.status == "open" do
            Issues.update_issue(issue, %{status: "in_progress"})
          end

          prompt =
            "Issue: #{issue.title}\n\n#{issue.description || ""}" <>
              if(args["prompt"], do: "\n\n#{args["prompt"]}", else: "")

          SessionRunner.send_message(session.id, prompt)

          text("Session #{session.id} started for issue ##{issue.id}: #{issue.title}")

        {:error, changeset} ->
          error("Failed to create session: #{inspect(changeset.errors)}")
      end
    rescue
      Ecto.NoResultsError ->
        error("Issue #{issue_id} not found")
    end
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

  def call("get_human_feedback", args, state) do
    question = args["question"]
    session_id = args["session_id"]

    {:ok, request} =
      Feedback.create_request(%{
        question: question,
        session_id: session_id,
        mcp_session_id: state.session_id
      })

    # Broadcast so the Queue UI picks it up
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "feedback_requests", {:new_feedback_request, request})

    # Subscribe and wait for the response
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "feedback:#{request.id}")

    response =
      receive do
        {:feedback_response, responded_request} ->
          responded_request.response
      end

    Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, "feedback:#{request.id}")

    text(response)
  end

  def call(name, _args, _state) do
    error("Unknown tool: #{name}")
  end

  defp text(content) do
    %{
      "content" => [%{"type" => "text", "text" => content}],
      "isError" => false
    }
  end

  defp error(message) do
    %{
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => true
    }
  end
end
