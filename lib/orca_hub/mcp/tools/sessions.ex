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
          "Send a message to another active Claude Code session. The message will interrupt the target session and deliver your message. Your session ID will be included automatically so the recipient knows who sent it. Use this to coordinate with sibling sessions working in the same directory — check the .agents/ directory to discover active sessions and their IDs. If the target session is archived, it will be automatically unarchived.",
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
          "Create a new agent session (Claude by default; optionally codex or pi) in the same project and directory as the calling session, and send it a starting prompt. Use this to delegate subtasks to a parallel session.",
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
            },
            "backend" => %{
              "type" => "string",
              "description" =>
                "Optional agent-CLI backend for the new session: \"claude\" (default), \"codex\", or \"pi\". Availability depends on which CLIs are installed on the target node — an unavailable backend is rejected with the list of backends actually installed there. Omit to use the default (\"claude\")."
            },
            "model" => %{
              "type" => "string",
              "description" =>
                "Optional backend-specific model id, passed through as free text (no enum) — e.g. a Claude alias like \"opus\", a Codex model id like \"gpt-5-codex\", or a pi provider/model string like \"fireworks/accounts/fireworks/models/glm-5\". Omit to use the backend's default model."
            }
          },
          "required" => ["prompt"]
        }
      },
      %{
        "name" => "archive_session",
        "description" =>
          "Archive a session. Orchestrators should call this after a child session has finished its task to keep the queue and UI clean. Archived sessions are automatically unarchived when you send them a message via `send_message_to_session`, so it's safe to archive a session and resume the conversation later.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "session_id" => %{
              "type" => "string",
              "description" => "The OrcaHub session ID of the session to archive"
            }
          },
          "required" => ["session_id"]
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
            message =
              Cluster.node_unavailable_message(reason) ||
                "Failed to send message to session #{target_id}: #{inspect(reason)}"

            error(message)
        end

      nil ->
        error("Session #{target_id} not found on any node.")
    end
  end

  def call("archive_session", args, _state) do
    target_id = args["session_id"]

    case Cluster.find_session(target_id) do
      {node, session} ->
        case Cluster.archive_session(node, session) do
          {:ok, _} ->
            text(
              "Session #{target_id} archived. Send it a message to resume — it will be automatically unarchived."
            )

          {:error, changeset} ->
            error("Failed to archive session #{target_id}: #{inspect(changeset.errors)}")
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

        case validate_backend(args["backend"], runner_node) do
          {:error, message} ->
            error(message)

          {:ok, backend} ->
            session_attrs =
              %{
                directory: directory,
                project_id: project_id,
                runner_node: Atom.to_string(runner_node)
              }
              |> maybe_put_field(:title, args["title"])
              |> maybe_put_field(:backend, backend)
              |> maybe_put_field(:model, blank_to_nil(args["model"]))
              |> maybe_link_parent(caller, caller_session_id)

            case HubRPC.create_session(session_attrs) do
              {:ok, session} ->
                case Cluster.start_session(runner_node, session.id, session) do
                  {:ok, _} ->
                    Cluster.send_message(runner_node, session.id, args["prompt"])
                    text("Session #{session.id} started in #{directory}")

                  {:error, reason} ->
                    message =
                      Cluster.node_unavailable_message(reason) ||
                        "Session #{session.id} created but failed to start: #{inspect(reason)}"

                    error(message)
                end

              {:error, changeset} ->
                error("Failed to create session: #{inspect(changeset.errors)}")
            end
        end
    end
  end

  # No `backend` arg (nil, or blank) → leave it unset so the schema default
  # ("claude") applies, same as before this parameter existed.
  defp validate_backend(nil, _runner_node), do: {:ok, nil}
  defp validate_backend("", _runner_node), do: {:ok, nil}

  defp validate_backend(backend, runner_node) when is_binary(backend) do
    available = OrcaHub.Backend.available_on(runner_node)

    if Enum.any?(available, fn {value, _label} -> value == backend end) do
      {:ok, backend}
    else
      installed = available |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")

      {:error,
       "Unknown or unavailable backend #{inspect(backend)}. Backends installed on this node: #{installed}."}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  # A non-nil parent_session_id always means "spawned by an orchestrator", so only
  # set it when the caller is itself an orchestrator.
  defp maybe_link_parent(attrs, %{orchestrator: true}, caller_session_id) do
    Map.put(attrs, :parent_session_id, caller_session_id)
  end

  defp maybe_link_parent(attrs, _caller, _caller_session_id), do: attrs

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
