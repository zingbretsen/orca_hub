defmodule OrcaHub.MCP.Tools do
  @moduledoc """
  MCP tool definitions and dispatch.
  """
  require Logger

  alias OrcaHub.{Issues, Sessions, SessionSupervisor, SessionRunner, Feedback, Triggers, Projects}

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
      },
      %{
        "name" => "get_issue",
        "description" =>
          "Get the current state of an issue, including its description, approaches tried by previous sessions, and notes. Use this at the start of a session to understand what has already been attempted before starting work.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "issue_id" => %{
              "type" => "string",
              "description" => "The ID of the issue to retrieve"
            }
          },
          "required" => ["issue_id"]
        }
      },
      %{
        "name" => "update_issue",
        "description" =>
          "Append information to an issue's metadata. Use this to record your approaches, theories, and findings so future sessions can build on your work. Values for approaches_tried and notes are APPENDED to the existing content (not replaced). Use approaches_tried to log what you attempted and the outcome. Use notes for general observations, theories, or context that might help future sessions.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "issue_id" => %{
              "type" => "string",
              "description" => "The ID of the issue to update"
            },
            "approaches_tried" => %{
              "type" => "string",
              "description" => "Text to append to the approaches log. Describe what you tried and whether it worked."
            },
            "notes" => %{
              "type" => "string",
              "description" => "Text to append to the notes. Use for theories, observations, or context for future sessions."
            },
            "status" => %{
              "type" => "string",
              "enum" => ["open", "in_progress", "closed"],
              "description" => "Update the issue status"
            }
          },
          "required" => ["issue_id"]
        }
      },
      %{
        "name" => "create_scheduled_trigger",
        "description" =>
          "Create a scheduled trigger that automatically runs a prompt on a cron schedule. The trigger will create (or reuse) a Claude Code session in the specified project's directory and send the prompt each time the cron schedule fires.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "A short descriptive name for the trigger (e.g. \"Daily test run\")"
            },
            "prompt" => %{
              "type" => "string",
              "description" => "The prompt to send to the Claude Code session each time the trigger fires"
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
              "description" =>
                "If true, archive the session once it completes. Default: false"
            }
          },
          "required" => ["name", "prompt", "project_id"]
        }
      },
      %{
        "name" => "send_message_to_session",
        "description" =>
          "Send a message to another active Claude Code session. The message will interrupt the target session and deliver your message. Your session ID will be included automatically so the recipient knows who sent it. Use this to coordinate with sibling sessions working in the same directory — check the .agents/ directory to discover active sessions and their IDs.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "session_id" => %{
              "type" => "string",
              "description" => "The OrcaHub session ID of the target session"
            },
            "message" => %{
              "type" => "string",
              "description" => "The message to send to the target session"
            },
            "sender_session_id" => %{
              "type" => "string",
              "description" =>
                "Your own OrcaHub session ID, so the recipient knows who sent the message. Find this in your .agents/ presence file."
            }
          },
          "required" => ["session_id", "message"]
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
              "description" =>
                "If true, archive the session once it completes. Default: false"
            }
          },
          "required" => ["name", "prompt", "project_id"]
        }
      },
      %{
        "name" => "open_file",
        "description" =>
          "Open a file in the user's session file viewer. The file will appear in a side panel next to the chat. Use this to show the user a file you've written or modified, or to pull up a reference file for discussion. Supports relative paths (within the project) and absolute paths (opened read-only if outside the project directory).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "file_path" => %{
              "type" => "string",
              "description" =>
                "The file path, either relative to the project directory (e.g. \"lib/my_app/module.ex\") or an absolute path (e.g. \"/home/user/other_project/file.ex\", opened read-only if outside project)"
            },
            "line" => %{
              "type" => "integer",
              "description" =>
                "Optional line number to scroll to when opening the file. The file viewer will highlight and scroll to this line."
            }
          },
          "required" => ["file_path"]
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

    # Notify SessionRunner to transition to :waiting
    if session_id do
      OrcaHub.SessionRunner.notify_feedback_requested(session_id)
    end

    # Subscribe and wait for the response
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "feedback:#{request.id}")

    result =
      receive do
        {:feedback_response, responded_request} ->
          {:ok, responded_request.response}

        {:feedback_cancelled, _request} ->
          :cancelled
      end

    Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, "feedback:#{request.id}")

    case result do
      {:ok, response} -> text(response)
      :cancelled -> error("The user cancelled this feedback request.")
    end
  end

  def call("get_issue", args, _state) do
    issue_id = args["issue_id"]

    try do
      issue = Issues.get_issue!(issue_id)

      response =
        Jason.encode!(%{
          id: issue.id,
          title: issue.title,
          description: issue.description,
          status: issue.status,
          approaches_tried: issue.approaches_tried,
          notes: issue.notes,
          project: if(issue.project, do: issue.project.name),
          session_count: length(issue.sessions),
          created_at: issue.inserted_at,
          updated_at: issue.updated_at
        })

      text(response)
    rescue
      Ecto.NoResultsError ->
        error("Issue #{issue_id} not found")
    end
  end

  def call("update_issue", args, _state) do
    issue_id = args["issue_id"]

    try do
      issue = Issues.get_issue!(issue_id)

      attrs =
        %{}
        |> maybe_append_field(issue, :approaches_tried, args["approaches_tried"])
        |> maybe_append_field(issue, :notes, args["notes"])
        |> maybe_put_field(:status, args["status"])

      case Issues.update_issue(issue, attrs) do
        {:ok, _issue} ->
          text("Issue #{issue_id} updated successfully.")

        {:error, changeset} ->
          error("Failed to update issue: #{inspect(changeset.errors)}")
      end
    rescue
      Ecto.NoResultsError ->
        error("Issue #{issue_id} not found")
    end
  end

  def call("create_scheduled_trigger", args, _state) do
    cron =
      cond do
        args["cron_expression"] ->
          args["cron_expression"]

        args["schedule"] == "hourly" ->
          "#{args["minute"] || 0} * * * *"

        args["schedule"] == "weekly" ->
          "#{args["minute"] || 0} #{args["hour"] || 9} * * #{args["day_of_week"] || 1}"

        true ->
          # Default to daily
          "#{args["minute"] || 0} #{args["hour"] || 9} * * *"
      end

    attrs = %{
      name: args["name"],
      prompt: args["prompt"],
      cron_expression: cron,
      project_id: args["project_id"],
      reuse_session: args["reuse_session"] || false,
      archive_on_complete: args["archive_on_complete"] || false
    }

    # Verify the project exists
    try do
      _project = Projects.get_project!(attrs.project_id)

      case Triggers.create_trigger(attrs) do
        {:ok, trigger} ->
          text(
            "Trigger \"#{trigger.name}\" created (id: #{trigger.id}). " <>
              "Schedule: #{trigger.cron_expression}"
          )

        {:error, changeset} ->
          error("Failed to create trigger: #{inspect(changeset.errors)}")
      end
    rescue
      Ecto.NoResultsError ->
        error("Project #{attrs.project_id} not found")
    end
  end

  def call("send_message_to_session", args, _state) do
    target_id = args["session_id"]
    message = args["message"]
    sender_id = args["sender_session_id"]

    signed_message =
      if sender_id do
        "[Message from session #{sender_id}]\n\n#{message}"
      else
        "[Message from another session]\n\n#{message}"
      end

    if SessionSupervisor.session_alive?(target_id) do
      case SessionRunner.send_message(target_id, signed_message) do
        :ok ->
          text("Message delivered to session #{target_id}")

        {:error, reason} ->
          error("Failed to send message to session #{target_id}: #{inspect(reason)}")
      end
    else
      error("Session #{target_id} is not running. Check .agents/ for active sessions.")
    end
  end

  def call("create_webhook_trigger", args, _state) do
    attrs = %{
      name: args["name"],
      prompt: args["prompt"],
      type: "webhook",
      project_id: args["project_id"],
      reuse_session: args["reuse_session"] || false,
      archive_on_complete: args["archive_on_complete"] || false
    }

    try do
      _project = Projects.get_project!(attrs.project_id)

      case Triggers.create_trigger(attrs) do
        {:ok, trigger} ->
          url = OrcaHubWeb.Endpoint.url() <> "/api/webhooks/#{trigger.webhook_secret}"

          text(
            "Webhook trigger \"#{trigger.name}\" created (id: #{trigger.id}). " <>
              "Webhook URL: #{url}"
          )

        {:error, changeset} ->
          error("Failed to create trigger: #{inspect(changeset.errors)}")
      end
    rescue
      Ecto.NoResultsError ->
        error("Project #{attrs.project_id} not found")
    end
  end

  def call("open_file", args, state) do
    file_path = args["file_path"]
    line = args["line"]

    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection. Cannot open file in viewer.")

      session_id ->
        Phoenix.PubSub.broadcast(
          OrcaHub.PubSub,
          "session:#{session_id}",
          {:open_file, file_path, line}
        )

        line_msg = if line, do: " at line #{line}", else: ""
        text("Opened #{file_path}#{line_msg} in the session file viewer.")
    end
  end

  def call(name, _args, _state) do
    error("Unknown tool: #{name}")
  end

  defp maybe_append_field(attrs, _issue, _field, nil), do: attrs

  defp maybe_append_field(attrs, issue, field, new_value) do
    existing = Map.get(issue, field) || ""

    appended =
      if existing == "" do
        new_value
      else
        existing <> "\n\n" <> new_value
      end

    Map.put(attrs, field, appended)
  end

  defp maybe_put_field(attrs, _key, nil), do: attrs
  defp maybe_put_field(attrs, key, val), do: Map.put(attrs, key, val)

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
