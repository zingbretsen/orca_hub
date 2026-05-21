defmodule OrcaHub.MCP.Tools.Sessions do
  @moduledoc """
  MCP tools for creating, searching, and messaging Claude Code sessions.
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC}

  def list do
    [
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
        "name" => "search_sessions",
        "description" =>
          "Search for other OrcaHub sessions. By default, searches for sessions in the same project directory as the calling session. You can optionally provide a different directory to search in, search across all projects, or filter by title. Use this to discover other sessions you may want to coordinate with or learn from.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "directory" => %{
              "type" => "string",
              "description" =>
                "Directory to search for sessions in. Defaults to the current session's project directory. Provide an absolute path to search in a different project. Ignored if all_projects is true."
            },
            "all_projects" => %{
              "type" => "boolean",
              "description" =>
                "If true, search across ALL projects instead of just the current directory. Useful for cross-project coordination. Default: false"
            },
            "query" => %{
              "type" => "string",
              "description" =>
                "Optional text to filter sessions by title. Case-insensitive partial match."
            },
            "status" => %{
              "type" => "string",
              "enum" => ["running", "idle", "waiting", "error", "ready"],
              "description" => "Optional filter by session status"
            },
            "include_archived" => %{
              "type" => "boolean",
              "description" =>
                "Whether to include archived sessions in results. Default: false. When true, returns both active and archived sessions."
            },
            "archived_only" => %{
              "type" => "boolean",
              "description" =>
                "If true, return ONLY archived sessions. Useful for browsing past session history. Default: false"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Maximum number of sessions to return. Default: 20"
            }
          }
        }
      },
      %{
        "name" => "start_session",
        "description" =>
          "Create a new Claude Code session in the same project and directory as the calling session, and send it a starting prompt. Use this to delegate subtasks to a parallel session.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "prompt" => %{
              "type" => "string",
              "description" => "The starting prompt to send to the new session"
            },
            "directory" => %{
              "type" => "string",
              "description" =>
                "Override the working directory for the new session. Defaults to the calling session's directory."
            },
            "title" => %{
              "type" => "string",
              "description" =>
                "Optional title for the new session. Auto-generated if not provided."
            }
          },
          "required" => ["prompt"]
        }
      }
    ]
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

    case Cluster.find_session(target_id) do
      {node, session} ->
        unless Cluster.session_alive?(node, target_id) do
          Cluster.start_session(node, target_id, session)
        end

        case Cluster.send_message(node, target_id, signed_message) do
          :ok ->
            text("Message delivered to session #{target_id}")

          {:error, reason} ->
            error("Failed to send message to session #{target_id}: #{inspect(reason)}")
        end

      nil ->
        error("Session #{target_id} not found on any node.")
    end
  end

  def call("search_sessions", args, state) do
    limit = args["limit"] || 20

    search_opts = %{
      query: args["query"],
      status: args["status"],
      include_archived: args["include_archived"] || false,
      archived_only: args["archived_only"] || false,
      limit: limit
    }

    case search_sessions_for(args, state, search_opts) do
      {:error, msg} ->
        error(msg)

      sessions when is_list(sessions) ->
        text(Jason.encode!(format_session_results(sessions, limit)))
    end
  end

  def call("start_session", args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection. Cannot determine project.")

      caller_session_id ->
        caller = HubRPC.get_session!(caller_session_id)
        directory = args["directory"] || caller.directory
        project_id = caller.project_id

        runner_node =
          if caller.project, do: Cluster.project_node_for(caller.project), else: node()

        session_attrs =
          %{
            directory: directory,
            project_id: project_id,
            runner_node: Atom.to_string(runner_node)
          }
          |> maybe_put_field(:title, args["title"])

        case HubRPC.create_session(session_attrs) do
          {:ok, session} ->
            {:ok, _} = Cluster.start_session(runner_node, session.id, session)
            Cluster.send_message(runner_node, session.id, args["prompt"])
            text("Session #{session.id} started in #{directory}")

          {:error, changeset} ->
            error("Failed to create session: #{inspect(changeset.errors)}")
        end
    end
  end

  # ── search_sessions helpers ───────────────────────────────────────────

  defp search_sessions_for(%{"all_projects" => true}, _state, search_opts) do
    HubRPC.search_all_sessions(search_opts)
  end

  defp search_sessions_for(args, state, search_opts) do
    case resolve_search_directory(args, state) do
      nil ->
        {:error,
         "Could not determine project directory. Provide a 'directory' parameter, " <>
           "use 'all_projects: true' to search across all projects, " <>
           "or ensure this MCP connection is linked to an OrcaHub session."}

      directory ->
        HubRPC.search_sessions_by_directory(directory, search_opts)
    end
  end

  defp resolve_search_directory(%{"directory" => dir}, _state) when not is_nil(dir), do: dir
  defp resolve_search_directory(_args, %{orca_session_id: nil}), do: nil

  defp resolve_search_directory(_args, %{orca_session_id: session_id}) do
    case Cluster.find_session(session_id) do
      {_node, session} -> session.directory
      nil -> nil
    end
  end

  defp format_session_results(sessions, limit) do
    clustered = Node.list() != []

    sessions
    |> Enum.sort_by(fn s -> s.updated_at end, {:desc, NaiveDateTime})
    |> Enum.take(limit)
    |> Enum.map(&format_session_result(&1, clustered))
  end

  defp format_session_result(session, clustered) do
    result = %{
      id: session.id,
      title: session.title,
      status: session.status,
      archived: not is_nil(session.archived_at),
      directory: session.directory,
      project: if(session.project, do: session.project.name),
      updated_at: session.updated_at,
      inserted_at: session.inserted_at
    }

    if clustered do
      Map.put(result, :node, Cluster.node_name(session.runner_node || node()))
    else
      result
    end
  end
end
