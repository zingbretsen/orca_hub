defmodule OrcaHub.MCP.Tools.Sessions do
  @moduledoc """
  MCP tools for creating, searching, and messaging Claude Code sessions.
  """
  import OrcaHub.MCP.Tools.Result

  require Logger

  alias OrcaHub.MCP.CodeExec.Analyzer
  alias OrcaHub.{Cluster, HubRPC, NodePolicy}

  # Time bound for AUTO-derived idempotency keys only (see
  # auto_idempotency_key/3) — belt-and-braces against a pathological hash
  # collision on a recycled MCP request id: even if the same auto-key were
  # (virtually impossibly) computed twice for genuinely different spawns
  # more than this far apart, the second one is no longer deduped. Explicit
  # caller-supplied idempotency_key stays unbounded.
  @auto_idempotency_window_seconds 15 * 60

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
                "Optional override for your own OrcaHub session ID. Normally inferred automatically from this MCP connection — only pass this if you're relaying on behalf of a different session."
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
            "session_id" => %{
              "type" => "string",
              "description" =>
                "Optional exact-match filter: only return the session with this id."
            },
            "parent_session_id" => %{
              "type" => "string",
              "description" =>
                "Optional exact-match filter: only return sessions spawned with this session id as their parent (see start_session's automatic child-linking)."
            },
            "include_activity" => %{
              "type" => "boolean",
              "description" =>
                "If true, include per-session activity metadata (message/tool-call counts " <>
                  "bucketed over the last 5/15/30 minutes, last_activity_at, and last_commit) " <>
                  "in each result — computed in one grouped query for the whole result set, " <>
                  "not per session. Default: false."
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
          "Create a new agent session (Claude by default; optionally codex or pi) in the same project and directory as the calling session, and send it a starting prompt. Use this to delegate subtasks to a parallel session. The new session is automatically linked as your child: when it finishes its turn (goes idle) or errors, you automatically receive a \"[Session lifecycle]\" message — no need to instruct the worker to message you back, and no need to poll with search_sessions/heartbeats just to detect completion. Set notify_on_completion to false to opt out for a true fire-and-forget spawn. Returns structured JSON: session_id, node, model, backend, directory, already_exists.",
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
                "Override the working directory for the new session. Defaults to the calling session's directory. If this directory belongs to a DIFFERENT registered project than the caller's, the new session is routed to THAT project's node and project_id instead of the caller's — use this to delegate work to another node. An unregistered directory (no matching project) falls back to the caller's own node/project, with only the working directory changed."
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
                "Optional backend-specific model id, passed through as free text (no enum) — e.g. a Claude alias like \"opus\", a Codex model id like \"gpt-5.5\", or a pi provider/model string like \"fireworks/accounts/fireworks/models/glm-5\". Omit to use the backend's default model."
            },
            "notify_on_completion" => %{
              "type" => "boolean",
              "description" =>
                "Whether the new session should automatically message you (the caller) when it goes idle or errors. Applies whenever this call is made from within another OrcaHub session — a parent link is always created in that case. Default: true. Set false for a fire-and-forget spawn you don't want a callback from. No effect on a direct HTTP/API-triggered start_session call with no calling session, since no parent link is created there."
            },
            "idempotency_key" => %{
              "type" => "string",
              "description" =>
                "Optional dedup key. If a non-archived session was already started with this same key, that session is returned (with \"already_exists\": true) instead of spawning a duplicate — no prompt is sent. Use this when retrying a start_session call you're not sure succeeded."
            }
          },
          "required" => ["prompt"]
        }
      },
      %{
        "name" => "report_progress",
        "description" =>
          "Self-report your current phase, as a non-interrupting progress signal — an " <>
            "orchestrator (or a human) can see this via search_sessions/get_session_tail " <>
            "and the session UI without messaging you. Suggested phases: planning, " <>
            "implementing, validating, fixing-tests, done — but phase is free text, use " <>
            "whatever's clearest for the task. Cleared automatically at the start of your " <>
            "next turn, so call it again after each phase boundary rather than once at the " <>
            "start.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "phase" => %{
              "type" => "string",
              "description" =>
                "Short phase label, e.g. \"planning\", \"implementing\", \"validating\", \"fixing-tests\"."
            },
            "note" => %{
              "type" => "string",
              "description" => "Optional one-line detail about the phase."
            }
          },
          "required" => ["phase"]
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
      },
      %{
        "name" => "get_session_tail",
        "description" =>
          "Peek at another session's recent activity WITHOUT interrupting it — unlike " <>
            "send_message_to_session, this does not send a message or touch the live agent " <>
            "process. Returns the session's current status plus its last assistant text " <>
            "message (truncated to ~2KB by default; pass full_last_message to get it in " <>
            "full), a compact list of its most recent tool calls (name + truncated " <>
            "input), self-reported progress (phase/note from report_progress, if any), " <>
            "activity metadata (message/tool-call counts over the last 5/15/30 minutes, " <>
            "last_activity_at), and last_commit (git HEAD of its directory, if it's a repo). " <>
            "Use this to tell \"making progress\" from \"stuck\" before deciding whether to " <>
            "interrupt a worker.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "session_id" => %{
              "type" => "string",
              "description" => "The OrcaHub session ID to peek at"
            },
            "tool_call_limit" => %{
              "type" => "integer",
              "description" => "Maximum number of recent tool calls to include. Default: 10"
            },
            "full_last_message" => %{
              "type" => "boolean",
              "description" =>
                "If true, return the complete last assistant text message instead of " <>
                  "truncating it to ~2KB. Use when you need the worker's full report " <>
                  "verbatim. Default: false"
            }
          },
          "required" => ["session_id"]
        }
      }
    ]
  end

  def call("send_message_to_session", args, state) do
    target_id = args["session_id"]
    message = args["message"]
    # The explicit arg is an override; normally the sender is whichever
    # OrcaHub session this MCP connection is linked to (state.orca_session_id),
    # set once at connection time — see MCP.Server/MCP.Tools dispatch.
    sender_id = args["sender_session_id"] || state.orca_session_id

    signed_message =
      if sender_id do
        "[Message from session #{sender_id}]\n\n#{message}"
      else
        "[Message from another session]\n\n#{message}"
      end

    case Cluster.find_session(target_id) do
      {node, session} ->
        if NodePolicy.cross_node_allowed?(node) do
          unless Cluster.session_alive?(node, target_id) do
            Cluster.start_session(node, target_id, session)
          end

          case Cluster.send_message(node, target_id, signed_message) do
            :ok ->
              maybe_record_interaction(sender_id, session.id)
              text("Message delivered to session #{target_id}")

            {:error, reason} ->
              message =
                Cluster.node_unavailable_message(reason) ||
                  "Failed to send message to session #{target_id}: #{inspect(reason)}"

              error(message)
          end
        else
          error(NodePolicy.denial_message(node))
        end

      nil ->
        error("Session #{target_id} not found on any node.")
    end
  end

  def call("report_progress", args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      session_id ->
        do_report_progress(session_id, args["phase"], args["note"])
    end
  end

  def call("archive_session", args, _state) do
    target_id = args["session_id"]

    case Cluster.find_session(target_id) do
      {node, session} ->
        if NodePolicy.cross_node_allowed?(node) do
          case Cluster.archive_session(node, session) do
            {:ok, _} ->
              text(
                "Session #{target_id} archived. Send it a message to resume — it will be automatically unarchived."
              )

            {:error, changeset} ->
              error("Failed to archive session #{target_id}: #{inspect(changeset.errors)}")
          end
        else
          error(NodePolicy.denial_message(node))
        end

      nil ->
        error("Session #{target_id} not found on any node.")
    end
  end

  def call("get_session_tail", args, _state) do
    target_id = args["session_id"]
    limit = args["tool_call_limit"] || 10
    full_last_message = args["full_last_message"] == true

    case Cluster.find_session(target_id) do
      {node, session} ->
        if NodePolicy.cross_node_allowed?(node) do
          tail = HubRPC.session_tail(target_id, tool_call_limit: limit)

          activity =
            Map.get(HubRPC.activity_metadata([session.id]), session.id, empty_activity())

          last_assistant_text =
            if full_last_message do
              tail.last_assistant_text
            else
              cap_tail_text(tail.last_assistant_text)
            end

          result = %{
            id: session.id,
            title: session.title,
            status: session.status,
            updated_at: session.updated_at,
            progress_phase: session.progress_phase,
            progress_note: session.progress_note,
            progress_updated_at: session.progress_updated_at,
            last_assistant_text: last_assistant_text,
            recent_tool_calls: Enum.map(tail.recent_tool_calls, &format_tool_call/1),
            activity: activity,
            last_commit: fetch_last_commit(node, session.directory)
          }

          text(Jason.encode!(result))
        else
          error(NodePolicy.denial_message(node))
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
      session_id: args["session_id"],
      parent_session_id: args["parent_session_id"],
      include_archived: args["include_archived"] || false,
      archived_only: args["archived_only"] || false,
      limit: limit
    }

    case search_sessions_for(args, state, search_opts) do
      {:error, msg} ->
        error(msg)

      sessions when is_list(sessions) ->
        include_activity = args["include_activity"] == true

        text(
          Jason.encode!(
            sessions
            |> scope_to_local_node_if_isolated()
            |> format_session_results(limit, include_activity)
          )
        )
    end
  end

  def call("start_session", args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection. Cannot determine project.")

      caller_session_id ->
        explicit_key = args["idempotency_key"]

        if explicit_key in [nil, ""] do
          auto_key = auto_idempotency_key(caller_session_id, state, args)

          case HubRPC.get_recent_session_by_idempotency_key(
                 auto_key,
                 @auto_idempotency_window_seconds
               ) do
            %{} = existing ->
              Logger.warning(
                "[MCP] start_session: auto idempotency key absorbed a replay — " <>
                  "returning existing session #{existing.id} instead of spawning a " <>
                  "duplicate (caller_session_id=#{caller_session_id})"
              )

              text(Jason.encode!(start_session_result(existing, true)))

            nil ->
              do_start_session(args, caller_session_id, auto_key)
          end
        else
          case HubRPC.get_session_by_idempotency_key(explicit_key) do
            %{} = existing ->
              text(Jason.encode!(start_session_result(existing, true)))

            nil ->
              do_start_session(args, caller_session_id, explicit_key)
          end
        end
    end
  end

  # Structural edge for the session graph feature. Best-effort: the actual
  # message delivery already succeeded by the time this runs, so a failure
  # here (bad sender id, transient DB/erpc error) must never surface as a
  # tool error — just log and move on.
  defp maybe_record_interaction(nil, _recipient_id), do: :ok

  defp maybe_record_interaction(sender_id, recipient_id) do
    case HubRPC.create_session_interaction(%{
           sender_session_id: sender_id,
           recipient_session_id: recipient_id,
           kind: "message"
         }) do
      {:ok, _interaction} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[MCP] send_message_to_session: failed to record session_interactions edge " <>
            "(#{sender_id} -> #{recipient_id}): #{inspect(changeset.errors)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[MCP] send_message_to_session: failed to record session_interactions edge " <>
          "(#{sender_id} -> #{recipient_id}): #{Exception.format(:error, error)}"
      )

      :ok
  end

  defp do_report_progress(_session_id, phase, _note) when not is_binary(phase) or phase == "" do
    error("report_progress requires a non-empty `phase` string argument.")
  end

  defp do_report_progress(session_id, phase, note) do
    session = HubRPC.get_session!(session_id)

    attrs = %{
      progress_phase: phase,
      progress_note: note,
      progress_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case HubRPC.update_session(session, attrs) do
      {:ok, _session} ->
        broadcast_progress(session_id, phase, note)
        suffix = if note, do: " — #{note}", else: ""
        text("Progress recorded: #{phase}#{suffix}")

      {:error, changeset} ->
        error("Failed to record progress: #{inspect(changeset.errors)}")
    end
  end

  # Live-updates the session UI's progress badge (SessionLive.Show subscribes
  # to "session:<id>" — same topic SessionRunner's own broadcast/2 uses).
  defp broadcast_progress(session_id, phase, note) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", {:progress, phase, note})
  end

  defp do_start_session(args, caller_session_id, idempotency_key) do
    caller = HubRPC.get_session!(caller_session_id)
    directory = args["directory"] || caller.directory
    {project_id, runner_node} = resolve_routing(directory, caller)

    if NodePolicy.cross_node_allowed?(runner_node) do
      create_and_start_session(
        args,
        directory,
        project_id,
        runner_node,
        caller,
        caller_session_id,
        idempotency_key
      )
    else
      error(NodePolicy.denial_message(runner_node))
    end
  end

  defp create_and_start_session(
         args,
         directory,
         project_id,
         runner_node,
         caller,
         caller_session_id,
         idempotency_key
       ) do
    case validate_backend(args["backend"], runner_node) do
      {:error, message} ->
        error(message)

      {:ok, backend} ->
        case validate_model(args["model"], backend, runner_node) do
          {:error, message} ->
            error(message)

          {:ok, model} ->
            session_attrs =
              %{
                directory: directory,
                project_id: project_id,
                runner_node: Atom.to_string(runner_node)
              }
              |> maybe_put_field(:title, args["title"])
              |> maybe_put_field(:backend, backend)
              |> maybe_put_field(:model, model)
              |> maybe_put_field(:idempotency_key, idempotency_key)
              |> maybe_link_parent(caller, caller_session_id, args["notify_on_completion"])

            case HubRPC.create_session(session_attrs) do
              {:ok, session} ->
                case Cluster.start_session(runner_node, session.id, session) do
                  {:ok, _} ->
                    Cluster.send_message(runner_node, session.id, args["prompt"])
                    text(Jason.encode!(start_session_result(session, false)))

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

  # Automatic idempotency key (issue c7eeef06) — derived when the caller
  # didn't supply one, so a transport-level replay of the SAME logical
  # tools/call (e.g. an infra-level retry during a rolling deploy) still gets
  # deduped even though the model never retried and passed no explicit key.
  #
  # The MCP JSON-RPC request id alone can't be the key: it's connection/turn
  # scoped and resets across CLI re-handshakes, so a later, genuinely
  # different start_session call can legitimately recycle the same id. Hashing
  # it together with every session-shaping argument means a true replay
  # (identical id AND identical prompt/title/directory/model/backend) matches,
  # while a later legitimate call reusing the id almost certainly differs in
  # at least one of those fields and so gets its own key. Pure function of its
  # inputs only — no node()/timestamp — so it's identical across nodes and
  # releases, which matters since a replay pair can land on different nodes
  # during a rollout.
  defp auto_idempotency_key(caller_session_id, state, args) do
    material =
      [
        caller_session_id,
        Map.get(state, :mcp_request_id),
        args["prompt"],
        args["title"],
        args["directory"],
        args["model"],
        args["backend"]
      ]
      |> Enum.map_join(<<0x1F>>, &to_string(&1 || ""))

    "auto:" <> (:crypto.hash(:sha256, material) |> Base.encode16(case: :lower))
  end

  # An explicit `directory` that differs from the caller's own directory may
  # belong to a DIFFERENT project (registered on a different node) — route
  # the child there instead of blindly inheriting the caller's project_id
  # and node, which used to silently spawn cross-node delegation attempts on
  # the WRONG node against the WRONG project_id (issue 6c304aec). An
  # unregistered directory (no project row for it) falls back to the
  # caller's own routing unchanged — never invent or reassign a node for a
  # directory OrcaHub doesn't have on file.
  defp resolve_routing(directory, %{directory: directory} = caller),
    do: {caller.project_id, caller_runner_node(caller)}

  defp resolve_routing(directory, caller) do
    case HubRPC.get_project_by_directory(directory) do
      %{} = project -> {project.id, Cluster.project_node_for(project)}
      nil -> {caller.project_id, caller_runner_node(caller)}
    end
  end

  defp caller_runner_node(caller) do
    if caller.project, do: Cluster.project_node_for(caller.project), else: node()
  end

  defp start_session_result(session, already_exists) do
    %{
      session_id: session.id,
      node: Cluster.node_name(session.runner_node || node()),
      model: session.model,
      backend: session.backend,
      directory: session.directory,
      already_exists: already_exists
    }
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

  # The model arg is free text (backend-specific — a Codex model id or a pi
  # provider/model string can't be enumerated here), so this ONLY guards the
  # claude backend, and only against its OWN known model list — never a
  # hardcoded enum, and never applied to other backends (Codex/pi model ids
  # legitimately range far beyond any static picker list). Catches exactly
  # the incident this exists for: an alias like "sonnet-5" that matches
  # neither a full model id (e.g. "claude-sonnet-5") nor a bare tier alias
  # (e.g. "sonnet") — start_session used to accept it and the CLI died ~2s
  # later with only "status: error" to go on.
  defp validate_model(model, _backend, _runner_node) when model in [nil, ""], do: {:ok, nil}

  defp validate_model(model, backend, runner_node) when backend in [nil, "claude"] do
    case OrcaHub.Backend.models_for("claude", runner_node) do
      # Empty means "couldn't determine the list right now" (unreachable
      # node) — don't block on it.
      [] ->
        {:ok, model}

      known ->
        ids = Enum.map(known, &elem(&1, 0))
        aliases = claude_model_aliases(ids)

        if model in ids or model in aliases do
          {:ok, model}
        else
          {:error,
           "Unknown claude model #{inspect(model)}. Known model ids/aliases: " <>
             "#{Enum.join(ids ++ aliases, ", ")}."}
        end
    end
  end

  defp validate_model(model, _backend, _runner_node), do: {:ok, model}

  # Bare tier aliases the Claude CLI also accepts (e.g. "opus" for the latest
  # Opus snapshot), derived from the full ids rather than hardcoded — strips
  # the "claude-" prefix and any trailing version/date suffix.
  defp claude_model_aliases(full_ids) do
    full_ids
    |> Enum.map(&(&1 |> String.replace_prefix("claude-", "") |> String.replace(~r/-\d.*$/, "")))
    |> Enum.uniq()
  end

  # ── get_session_tail helpers ──────────────────────────────────────────
  # Keep the payload slim — this is a cheap progress peek, not a transcript.

  @max_tail_text_bytes 2000
  @max_tool_arg_bytes 200

  defp cap_tail_text(nil), do: nil

  defp cap_tail_text(text) when byte_size(text) > @max_tail_text_bytes do
    binary_part(text, 0, @max_tail_text_bytes) <> "…[truncated]"
  end

  defp cap_tail_text(text), do: text

  @run_elixir_tool_names ~w(run_elixir mcp__orca__run_elixir)
  @max_tail_extracted_tools 10

  defp format_tool_call(%{name: name, input: input}) do
    %{name: name, args: cap_tail_arg(inspect(input, pretty: false, limit: 20))}
    |> maybe_put_extracted_tools(name, input)
  end

  # Static peek at which `Tools.*` a run_elixir snippet references — cheap
  # legibility for an orchestrator skimming get_session_tail, not a runtime
  # trace (see `OrcaHub.MCP.CodeExec.Analyzer`). Omitted entirely for
  # non-run_elixir calls and when nothing was extracted (plain-stdlib
  # snippets are common).
  defp maybe_put_extracted_tools(call, name, %{"code" => code})
       when name in @run_elixir_tool_names do
    case Analyzer.tool_calls(code) do
      [] -> call
      tools -> Map.put(call, :tools, Enum.take(tools, @max_tail_extracted_tools))
    end
  end

  defp maybe_put_extracted_tools(call, _name, _input), do: call

  defp cap_tail_arg(str) when byte_size(str) > @max_tool_arg_bytes,
    do: binary_part(str, 0, @max_tool_arg_bytes) <> "…"

  defp cap_tail_arg(str), do: str

  # Child spawning is first-class for ANY caller session now, not just
  # orchestrators: whenever this start_session call happened from within a
  # running OrcaHub session (caller_session_id present), the new session is
  # linked as that caller's child. `notify_on_completion` (default true)
  # becomes `notify_parent` — the "[Session lifecycle]" running->idle/error
  # callback to the parent. There's still nothing to link when start_session
  # is invoked with no calling session at all (e.g. an HTTP/API-triggered
  # spawn) — `caller_session_id` is nil in that case and no parent/notify
  # fields are set.
  defp maybe_link_parent(attrs, _caller, caller_session_id, notify_on_completion)
       when is_binary(caller_session_id) do
    attrs
    |> Map.put(:parent_session_id, caller_session_id)
    |> Map.put(:notify_parent, notify_on_completion != false)
  end

  defp maybe_link_parent(attrs, _caller, _caller_session_id, _notify_on_completion), do: attrs

  # ── search_sessions helpers ───────────────────────────────────────────

  # Isolation is scoped silently here (rather than erroring) so an isolated
  # node's search_sessions still "works" — it just can't discover sessions
  # elsewhere. Checked once per call (not cached across calls/process —
  # NodePolicy always re-checks the current `nodes` row) since a single
  # search can return many sessions to filter.
  defp scope_to_local_node_if_isolated(sessions) do
    if NodePolicy.local_node_isolated?() do
      Enum.filter(sessions, fn s -> Cluster.runner_node_for(s) == node() end)
    else
      sessions
    end
  end

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

  defp format_session_results(sessions, limit, include_activity) do
    clustered = Node.list() != []

    page =
      sessions
      |> Enum.sort_by(fn s -> s.updated_at end, {:desc, NaiveDateTime})
      |> Enum.take(limit)

    {activity_by_id, last_commit_by_id} =
      if include_activity do
        {HubRPC.activity_metadata(Enum.map(page, & &1.id)), fetch_last_commits(page)}
      else
        {%{}, %{}}
      end

    Enum.map(
      page,
      &format_session_result(&1, clustered, activity_by_id, last_commit_by_id, include_activity)
    )
  end

  defp format_session_result(
         session,
         clustered,
         activity_by_id,
         last_commit_by_id,
         include_activity
       ) do
    result = %{
      id: session.id,
      title: session.title,
      status: session.status,
      archived: not is_nil(session.archived_at),
      directory: session.directory,
      project: if(session.project, do: session.project.name),
      backend: session.backend,
      model: session.model,
      parent_session_id: session.parent_session_id,
      progress_phase: session.progress_phase,
      progress_note: session.progress_note,
      updated_at: session.updated_at,
      inserted_at: session.inserted_at
    }

    result =
      if session.status == "error" and session.error_detail do
        Map.put(result, :error_detail, session.error_detail)
      else
        result
      end

    result =
      if clustered do
        Map.put(result, :node, Cluster.node_name(session.runner_node || node()))
      else
        result
      end

    if include_activity do
      result
      |> Map.put(:activity, Map.get(activity_by_id, session.id, empty_activity()))
      |> Map.put(:last_commit, Map.get(last_commit_by_id, session.id))
    else
      result
    end
  end

  # ── activity metadata / last_commit helpers ──────────────────────────
  # Shared by get_session_tail (always on, single session) and search_sessions
  # (opt-in via include_activity, whole result page at once).

  defp empty_activity do
    %{
      messages_5m: 0,
      messages_15m: 0,
      messages_30m: 0,
      tool_calls_5m: 0,
      tool_calls_15m: 0,
      tool_calls_30m: 0,
      last_activity_at: nil
    }
  end

  # Dedupes by {node, directory} so sessions sharing a working directory (the
  # common case) only trigger one `git log` per directory, not one per session.
  defp fetch_last_commits(sessions) do
    tagged =
      Enum.map(sessions, fn s -> {s.id, Cluster.runner_node_for(s) || node(), s.directory} end)

    commit_by_pair =
      tagged
      |> Enum.map(fn {_id, node, dir} -> {node, dir} end)
      |> Enum.uniq()
      |> Map.new(fn {node, dir} -> {{node, dir}, fetch_last_commit(node, dir)} end)

    Map.new(tagged, fn {id, node, dir} -> {id, commit_by_pair[{node, dir}]} end)
  end

  defp fetch_last_commit(node, directory) do
    case Cluster.rpc(node, OrcaHub.Sessions, :git_head_info, [directory]) do
      %{} = info -> info
      _ -> nil
    end
  end
end
