defmodule OrcaHub.MCP.Tools.Issues do
  @moduledoc """
  MCP tools for reading and updating issue metadata.
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.HubRPC

  def list do
    [
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
              "description" =>
                "Text to append to the approaches log. Describe what you tried and whether it worked."
            },
            "notes" => %{
              "type" => "string",
              "description" =>
                "Text to append to the notes. Use for theories, observations, or context for future sessions."
            },
            "status" => %{
              "type" => "string",
              "enum" => ["open", "in_progress", "closed"],
              "description" => "Update the issue status"
            }
          },
          "required" => ["issue_id"]
        }
      }
    ]
  end

  def call("get_issue", args, _state) do
    issue_id = args["issue_id"]

    issue = HubRPC.get_issue!(issue_id)

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
      error("Issue #{args["issue_id"]} not found")
  end

  def call("update_issue", args, _state) do
    issue_id = args["issue_id"]

    issue = HubRPC.get_issue!(issue_id)

    attrs =
      %{}
      |> maybe_append_field(issue, :approaches_tried, args["approaches_tried"])
      |> maybe_append_field(issue, :notes, args["notes"])
      |> maybe_put_field(:status, args["status"])

    case HubRPC.update_issue(issue, attrs) do
      {:ok, _issue} ->
        text("Issue #{issue_id} updated successfully.")

      {:error, changeset} ->
        error("Failed to update issue: #{inspect(changeset.errors)}")
    end
  rescue
    Ecto.NoResultsError ->
      error("Issue #{args["issue_id"]} not found")
  end
end
