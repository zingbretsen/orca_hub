defmodule OrcaHub.MCP.Tools.Sessions do
  @moduledoc """
  MCP tools for creating, searching, and messaging Claude Code sessions.
  """
  import OrcaHub.MCP.Tools.Result

  require Logger

  alias OrcaHub.MCP.CodeExec.Analyzer
  alias OrcaHub.MCP.Tools.NodeArg
  alias OrcaHub.ForkGate
  alias OrcaHub.ForkGate.ServingProfile
  alias OrcaHub.{Cluster, HubRPC, NodePolicy, Probes}

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
          "Send a message to another active Claude Code session. By default (delivery: \"queue\") the message waits until the target's current turn ends, then delivers — this never cancels anything in-progress. Pass delivery: \"interrupt\" for a genuine urgent correction: it delivers immediately, cancelling the target's in-progress tool call if it's mid-turn (the target is told why). Your session ID will be included automatically so the recipient knows who sent it. Use this to coordinate with sibling sessions working in the same directory — check the .agents/ directory to discover active sessions and their IDs. If the target session is archived, it will be automatically unarchived.",
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
            "delivery" => %{
              "type" => "string",
              "enum" => ["queue", "interrupt"],
              "description" =>
                "How to deliver this if the target is currently running a turn. \"queue\" " <>
                  "(default): wait until the target's current turn ends, then deliver — " <>
                  "safe, never cancels anything in-progress; costs at most one turn's " <>
                  "delay (and if that turn hangs, delivery auto-escalates to interrupt " <>
                  "rather than waiting forever). Use this unless your message is a genuine " <>
                  "urgent correction. \"interrupt\": deliver immediately, cancelling the " <>
                  "target's in-progress tool call if it's mid-turn — the target is told " <>
                  "why its tool call was interrupted, but still loses whatever that tool " <>
                  "call was doing. If the target backend supports non-destructive mid-turn " <>
                  "steering, both modes may deliver immediately without cancelling " <>
                  "anything, since steering has no destructive cost. Ignored (delivers " <>
                  "immediately) if the target isn't currently running a turn."
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
          "Create a new agent session (Claude by default; optionally codex or pi) in the same project and directory as the calling session, and send it a starting prompt. Use this to delegate subtasks to a parallel session. The new session is automatically linked as your child: when it finishes its turn (goes idle) or errors, you automatically receive a \"[Session lifecycle]\" message — no need to instruct the worker to message you back, and no need to poll with search_sessions/heartbeats just to detect completion. Set notify_on_completion to false to opt out for a true fire-and-forget spawn. Exception: orchestrator: true is a HANDOFF to a sibling session, not a child spawn — see the orchestrator param. Returns structured JSON: session_id, node, model, backend, directory, already_exists, orchestrator.",
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
                "Override the working directory for the new session. Defaults to the calling session's directory (or, if project_id is given, that project's own directory). If this directory belongs to a DIFFERENT registered project than the caller's, the new session is routed to THAT project's node and project_id instead of the caller's — use this to delegate work to another node. An unregistered directory (no matching project) falls back to the caller's own node/project, with only the working directory changed. If project_id is ALSO given, directory instead sets the new session's working directory under that project — it must equal the project's own directory or a sub-path of it (e.g. a worktree); a directory outside the project is rejected. If node is ALSO given (without project_id), directory + node together explicitly target an unregistered directory on that node — see node."
            },
            "project_id" => %{
              "type" => "string",
              "description" =>
                "The UUID of the project to route the new session to — takes precedence over directory for project/node routing (directory can still be given alongside this to set the working directory; see directory). Accepts a full UUID or an unambiguous hex prefix (>= 8 chars, as copy-pasted from list_projects output). node is not needed here — this project's own node is used; if node is also given, it must match."
            },
            "node" => %{
              "type" => "string",
              "description" =>
                "Explicit target node, used together with directory to spawn a session in a directory OrcaHub has no project row for yet — the two together are an explicit, caller-vouched-for override of the normal directory-based routing (a node is never inferred on its own). Must be the RAW Erlang node name (e.g. \"orca@dell\"), NOT the display name shown by list_projects/the UI (e.g. \"debian\" or \"orca-agent-dell.lab\") — that display form does not round-trip back into this argument. The directory is verified to exist on the target node before the session is created; a missing directory is rejected rather than silently spawning a broken session. Passing node without directory (and without project_id) is rejected — \"my own directory, but on some other node\" isn't a coherent target."
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
                "Whether the new session should automatically message you (the caller) when it goes idle or errors. Applies whenever this call is made from within another OrcaHub session — a parent link is always created in that case. Default: true. Set false for a fire-and-forget spawn you don't want a callback from. No effect on a direct HTTP/API-triggered start_session call with no calling session, since no parent link is created there. Exception: for an orchestrator: true spawn (a handoff, see the orchestrator param), the default flips to no parent link/no callback — pass notify_on_completion: true explicitly if you want this orchestrator spawn linked and reported back as a child instead."
            },
            "idempotency_key" => %{
              "type" => "string",
              "description" =>
                "Optional dedup key. If a non-archived session was already started with this same key, that session is returned (with \"already_exists\": true) instead of spawning a duplicate — no prompt is sent. Use this when retrying a start_session call you're not sure succeeded."
            },
            "orchestrator" => %{
              "type" => "boolean",
              "description" =>
                "If true, the new session is created as an orchestrator session — it gets the orchestrator system prompt and coordination tool surface, and is expected to delegate work to its own child sessions rather than implement directly. Default: false (a normal worker session). Use for a coordinator managing a large multi-part effort as a sub-tree. IMPORTANT: spawning another orchestrator is a HANDOFF to a sibling session by default, not a child spawn — the new orchestrator gets the caller's own parent (often none, making it a root session), notify_on_completion defaults to false, and you will NOT get a \"[Session lifecycle]\" callback or see it in watch_children. Pass notify_on_completion: true explicitly if you actually want this orchestrator spawn treated as a reporting child (the old behavior)."
            },
            "issue_id" => %{
              "type" => "string",
              "description" =>
                "Link the new session to an issue as an attempt at it (session.issue_id) — the primary way issues get worked. Same id format as get_issue (key, UUID, or UUID prefix). If the issue is currently \"open\", it's automatically moved to \"in_progress\" (best-effort, non-blocking)."
            },
            "fork_from_parent" => %{
              "type" => "boolean",
              "description" =>
                "pi-backend only. Fork the CALLER's session: the new child starts with a " <>
                  "byte-identical copy of your full conversation context (cheap on a " <>
                  "prompt-cached provider) instead of a blank context. The child is a " <>
                  "normal child session in every other respect. Default: false."
            }
          },
          "required" => ["prompt"]
        }
      },
      %{
        "name" => "report_progress",
        "description" =>
          "Self-report your current phase and/or update your session title, as a " <>
            "non-interrupting signal — an orchestrator (or a human) can see this via " <>
            "search_sessions/get_session_tail and the session UI without messaging you. " <>
            "Suggested phases: planning, implementing, validating, fixing-tests, done — but " <>
            "phase is free text, use whatever's clearest for the task. phase/note are " <>
            "cleared automatically at the start of your next turn, so call it again after " <>
            "each phase boundary rather than once at the start. `title`, unlike phase/note, " <>
            "PERSISTS across turns and updates the session title shown in the hub UI — set " <>
            "it when your work has meaningfully shifted from what the current title says " <>
            "(the tool result always echoes the session's current title, so you can check " <>
            "it without another call).",
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
            },
            "title" => %{
              "type" => "string",
              "description" =>
                "Optional new session title. Unlike phase/note, this persists across turns " <>
                  "rather than clearing at the start of the next one. Set it when what " <>
                  "you're doing has meaningfully changed from the current title."
            }
          },
          "required" => []
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
                  "truncating it to ~800 bytes. Use when you need the worker's full report " <>
                  "verbatim. Default: false"
            },
            "include_last_message" => %{
              "type" => "boolean",
              "description" =>
                "If false, omit the last assistant text entirely from the result. Use for " <>
                  "repeated/polling peeks where only liveness/status matters, not the " <>
                  "worker's prose. When true (default), the text is included and truncated " <>
                  "to ~800 bytes unless full_last_message is also true. Default: true"
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
    delivery = parse_delivery(args["delivery"])

    signed_message =
      if sender_id do
        "[Message from session #{sender_id}]\n\n#{message}"
      else
        "[Message from another session]\n\n#{message}"
      end

    case Cluster.find_session(target_id) do
      {node, session} ->
        if NodePolicy.cross_node_allowed?(node) do
          # No manual session_alive?/start_session pre-check needed here —
          # Cluster.send_message/4 handles that internally for BOTH delivery
          # modes (directly for :interrupt; via SessionHeartbeat.deliver_or_queue/2's
          # own immediate-delivery branch for :queue).
          case Cluster.send_message(node, target_id, signed_message, delivery) do
            :ok ->
              maybe_record_interaction(sender_id, session.id, "message")
              text("Message delivered to session #{target_id}")

            {:queued, queued_status} ->
              maybe_record_interaction(sender_id, session.id, "message")

              text(
                "Message queued for session #{target_id} (currently \"#{queued_status}\") — " <>
                  "it will be delivered once the session's current turn ends, or " <>
                  "automatically escalated to an interrupt if that takes too long."
              )

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
        do_report_progress(session_id, args["phase"], args["note"], args["title"])
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
    include_last_message = args["include_last_message"] != false

    case Cluster.find_session(target_id) do
      {node, session} ->
        if NodePolicy.cross_node_allowed?(node) do
          tail = HubRPC.session_tail(target_id, tool_call_limit: limit)

          activity =
            Map.get(HubRPC.activity_metadata([session.id]), session.id, empty_activity())

          last_assistant_text =
            if include_last_message do
              if full_last_message do
                tail.last_assistant_text
              else
                cap_tail_text(tail.last_assistant_text)
              end
            else
              nil
            end

          result =
            %{
              id: session.id,
              title: session.title,
              status: session.status,
              updated_at: session.updated_at,
              progress_phase: session.progress_phase,
              progress_note: session.progress_note,
              progress_updated_at: session.progress_updated_at,
              recent_tool_calls: Enum.map(tail.recent_tool_calls, &format_tool_call/1),
              activity: activity,
              last_commit: fetch_last_commit(node, session.directory)
            }
            |> maybe_put_last_assistant_text(last_assistant_text)

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
  # message delivery / session creation already succeeded by the time this
  # runs, so a failure here (bad sender id, transient DB/erpc error) must
  # never surface as a tool error — just log and move on. `kind` is
  # "message" for a send_message_to_session delivery or "handoff" for an
  # orchestrator-spawns-orchestrator sibling link (see maybe_link_parent/4)
  # — the latter is how that spawn's lineage survives not being captured by
  # parent_session_id anymore.
  # ORCAHUB3-29: anything other than the literal "interrupt" — including a
  # typo, an unrecognized value, or an omitted arg — falls to the SAFE
  # default (never-interrupt "queue"), not the destructive one. The cost
  # asymmetry that makes "queue" the default in the first place (a bad
  # queue guess costs one turn; a bad interrupt guess costs real work) means
  # invalid input should fail toward the cheap mistake.
  defp parse_delivery("interrupt"), do: :interrupt
  defp parse_delivery(_), do: :queue

  defp maybe_record_interaction(nil, _recipient_id, _kind), do: :ok

  defp maybe_record_interaction(sender_id, recipient_id, kind) do
    case HubRPC.create_session_interaction(%{
           sender_session_id: sender_id,
           recipient_session_id: recipient_id,
           kind: kind
         }) do
      {:ok, _interaction} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[MCP] failed to record session_interactions #{kind} edge " <>
            "(#{sender_id} -> #{recipient_id}): #{inspect(changeset.errors)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[MCP] failed to record session_interactions #{kind} edge " <>
          "(#{sender_id} -> #{recipient_id}): #{Exception.format(:error, error)}"
      )

      :ok
  end

  @max_title_length 80
  @max_note_length 250
  @max_phase_length 250

  defp do_report_progress(session_id, phase, note, title) do
    if is_binary_non_empty(phase) or is_binary_non_empty(title) do
      do_report_progress!(session_id, phase, note, title)
    else
      error(
        "report_progress requires at least one of `phase` or `title` to be a non-empty string."
      )
    end
  end

  defp do_report_progress!(session_id, phase, note, title) do
    session = HubRPC.get_session!(session_id)
    new_title = if is_binary_non_empty(title), do: normalize_title(title)
    phase = normalize_phase(phase)
    note = normalize_note(note)

    attrs =
      %{}
      |> maybe_put_progress_attrs(phase, note)
      |> maybe_put_field(:title, new_title)

    case HubRPC.update_session(session, attrs) do
      {:ok, updated} ->
        if is_binary_non_empty(phase), do: broadcast_progress(session_id, phase, note)
        if new_title, do: broadcast_title(session_id, new_title)

        text(report_progress_result_text(phase, note, new_title, updated.title))

      {:error, changeset} ->
        error("Failed to record progress: #{inspect(changeset.errors)}")
    end
  end

  defp is_binary_non_empty(v), do: is_binary(v) and v != ""

  defp maybe_put_progress_attrs(attrs, phase, note) do
    if is_binary_non_empty(phase) do
      attrs
      |> Map.put(:progress_phase, phase)
      |> Map.put(:progress_note, note)
      |> Map.put(:progress_updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      attrs
    end
  end

  # Collapses to a single line and caps length — this is a UI label (session
  # list, tab title), not free-form text.
  defp normalize_title(title) do
    title
    |> String.trim()
    |> String.replace(~r/\s*\n+\s*/, " ")
    |> safe_truncate(@max_title_length)
  end

  # Trims whitespace and truncates to byte budget, keeping complete UTF-8
  # characters. Used for progress_note, which is free-form text — no newline
  # collapsing.
  defp normalize_note(nil), do: ""

  defp normalize_note(note) do
    note
    |> String.trim()
    |> safe_truncate(@max_note_length)
  end

  # Trims whitespace and truncates to byte budget. Used for progress_phase,
  # which should be a short label but may contain multibyte characters.
  defp normalize_phase(nil), do: ""

  defp normalize_phase(phase) do
    phase
    |> String.trim()
    |> safe_truncate(@max_phase_length)
  end

  defp report_progress_result_text(phase, note, new_title, current_title) do
    progress_part =
      if is_binary_non_empty(phase) do
        suffix = if note, do: " — #{note}", else: ""
        "Progress recorded: #{phase}#{suffix}."
      end

    title_part =
      cond do
        new_title -> "Title updated to #{title_display(current_title)}."
        progress_part -> "Session title: #{title_display(current_title)}"
        true -> nil
      end

    [progress_part, title_part] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp title_display(nil), do: "(untitled)"
  defp title_display(""), do: "(untitled)"
  defp title_display(title), do: inspect(title)

  # Live-updates the session UI's progress badge (SessionLive.Show subscribes
  # to "session:<id>" — same topic SessionRunner's own broadcast/2 uses).
  defp broadcast_progress(session_id, phase, note) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", {:progress, phase, note})
  end

  # Same topic/shape SessionRunner's own title-generation broadcast used —
  # SessionLive.Show already handles {:title_updated, title}.
  defp broadcast_title(session_id, title) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "session:#{session_id}",
      {:title_updated, title}
    )
  end

  defp do_start_session(args, caller_session_id, idempotency_key) do
    caller = HubRPC.get_session!(caller_session_id)

    case prepare_fork_args(args, caller) do
      {:error, message} ->
        error(message)

      {:ok, args} ->
        case resolve_routing(args, caller) do
          {:ok, {project_id, runner_node, directory}} ->
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

          {:error, message} ->
            error(message)
        end
    end
  end

  # ── pi session forking (pi_fork_spec.md §3) ───────────────────────────
  # Validation + inheritance-forcing lives entirely in this block so it
  # stays a single, easily-lifted unit: everything downstream of
  # prepare_fork_args/2 (routing, backend/model validation, attrs building,
  # row creation, delivery) is UNCHANGED for a fork spawn — it just
  # receives caller-matching args instead of whatever the tool call itself
  # passed.

  defp fork?(args), do: args["fork_from_parent"] == true

  # Not forking: args pass through untouched. Forking: validate the caller
  # is pi-backed and that no arg explicitly conflicts with what it must
  # inherit, then FORCE backend/model/orchestrator onto the caller's own
  # values (directory/project_id/node inheritance already falls out of
  # resolve_routing/2's existing "no override args → caller's own routing"
  # default, once conflicts are ruled out below; code_exec has no `args`
  # slot at all and is copied directly onto the child row in
  # create_and_start_session/7 instead).
  defp prepare_fork_args(args, caller) do
    if fork?(args) do
      with :ok <- validate_fork_backend(caller),
           :ok <- validate_fork_no_override(args, caller) do
        {:ok,
         args
         |> Map.put("backend", caller.backend)
         |> Map.put("model", caller.model)
         |> Map.put("orchestrator", caller.orchestrator)}
      end
    else
      {:ok, args}
    end
  end

  defp validate_fork_backend(%{backend: "pi"}), do: :ok

  defp validate_fork_backend(%{backend: backend}) do
    {:error,
     "fork_from_parent requires the calling session's own backend to be \"pi\" (this " <>
       "session's backend is #{inspect(backend)}). Forking is a pi-native primitive " <>
       "with no equivalent for other backends."}
  end

  defp validate_fork_no_override(args, caller) do
    with :ok <- reject_fork_override(args["backend"], caller.backend, "backend"),
         :ok <- reject_fork_override(args["model"], caller.model, "model"),
         :ok <- reject_fork_override(args["directory"], caller.directory, "directory"),
         :ok <- reject_fork_override(args["orchestrator"], caller.orchestrator, "orchestrator"),
         :ok <- reject_fork_project_id_override(args["project_id"], caller),
         :ok <- reject_fork_node_override(args["node"], caller) do
      :ok
    end
  end

  defp reject_fork_override(nil, _caller_value, _label), do: :ok
  defp reject_fork_override("", _caller_value, _label), do: :ok
  defp reject_fork_override(value, value, _label), do: :ok

  defp reject_fork_override(value, caller_value, label) do
    {:error,
     "fork_from_parent: #{label} #{inspect(value)} conflicts with the caller's own " <>
       "#{label} (#{inspect(caller_value)}) — a fork child inherits #{label} from its " <>
       "parent and cannot override it. Omit #{label} to inherit it."}
  end

  defp reject_fork_project_id_override(nil, _caller), do: :ok
  defp reject_fork_project_id_override("", _caller), do: :ok

  defp reject_fork_project_id_override(project_id_arg, caller) do
    case HubRPC.resolve_project_id(project_id_arg) do
      {:ok, %{id: id}} when id == caller.project_id ->
        :ok

      {:ok, project} ->
        {:error,
         "fork_from_parent: project_id #{inspect(project_id_arg)} resolves to " <>
           "#{inspect(project.id)}, which conflicts with the caller's own project_id " <>
           "#{inspect(caller.project_id)} — a fork child inherits project_id and cannot " <>
           "override it. Omit project_id to inherit it."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp reject_fork_node_override(nil, _caller), do: :ok
  defp reject_fork_node_override("", _caller), do: :ok

  defp reject_fork_node_override(node_arg, caller) do
    case NodeArg.resolve(node_arg) do
      {:ok, node} ->
        if Atom.to_string(node) == caller.runner_node do
          :ok
        else
          {:error,
           "fork_from_parent: node #{inspect(node_arg)} conflicts with the caller's own " <>
             "runner node #{inspect(caller.runner_node)} — a fork child must run on the " <>
             "same node as its parent (its session file must be readable at spawn time). " <>
             "Omit node to inherit it."}
        end

      {:error, message} ->
        {:error, message}
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
            case resolve_issue_id_arg(args["issue_id"]) do
              {:error, message} ->
                error(message)

              {:ok, issue_id} ->
                # `code_exec` has no `args` slot (inventory #1) — inherit
                # it directly rather than via the schema default, which
                # would silently break forking from a `code_exec: false`
                # parent (pi_fork_spec.md §3 ⚠).
                forked_from = if fork?(args), do: caller.id

                session_attrs =
                  %{
                    directory: directory,
                    project_id: project_id,
                    runner_node: Atom.to_string(runner_node)
                  }
                  |> maybe_put_field(:title, args["title"])
                  |> maybe_put_field(:backend, backend)
                  |> maybe_put_field(:model, model)
                  |> maybe_put_field(:orchestrator, args["orchestrator"])
                  |> maybe_put_field(:idempotency_key, idempotency_key)
                  |> maybe_put_field(:issue_id, issue_id)
                  |> maybe_put_field(:code_exec, forked_from && caller.code_exec)
                  |> maybe_put_field(:forked_from_session_id, forked_from)
                  |> maybe_link_parent(caller, caller_session_id, args["notify_on_completion"])

                case HubRPC.create_session(session_attrs) do
                  {:ok, session} ->
                    if orchestrator_handoff?(session_attrs, args["notify_on_completion"]) do
                      maybe_record_interaction(caller_session_id, session.id, "handoff")
                    end

                    if forked_from do
                      create_fork_marker_message(session.id, forked_from)
                      maybe_record_interaction(caller_session_id, session.id, "fork")
                    end

                    maybe_auto_progress_issue(issue_id, session.id)

                    case Cluster.start_session(runner_node, session.id, session) do
                      {:ok, _} ->
                        deliver_initial_prompt(
                          forked_from,
                          runner_node,
                          session,
                          args["prompt"]
                        )

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
  end

  # ── Initial-prompt delivery ──────────────────────────────────────────
  # Non-fork spawn (`forked_from == nil`) — EVERY claude/codex/non-fork pi
  # spawn — takes exactly the path it always has: one Cluster.send_message
  # with :queue, nothing else in the way. That guardrail is why this is a
  # two-clause split on the fork discriminant rather than a branch inside a
  # shared delivery function.
  #
  # :queue: brand-new session (status "ready"), so this always delivers
  # immediately either way — :queue for consistency.
  defp deliver_initial_prompt(nil, runner_node, session, prompt) do
    Cluster.send_message(runner_node, session.id, prompt, :queue)
  end

  # Fork spawn (pi_fork_spec.md §6): the child is CREATED here (ids, links,
  # marker, UI all exist already) but its first prompt is NOT sent — it is
  # handed to the per-node ForkGate, which releases it only once the
  # previous forked sibling's first turn has completed. Concurrent
  # same-prefix first turns get 1 warm hit + N−1 full cold prefills (§1), so
  # this serialization is the ship gate (§1.1), not a nicety.
  #
  # The gate lives on the node that owns the queue, which is this node: a
  # fork child is same-node with its parent (§3), and this MCP connection is
  # served by the parent's own node.
  defp deliver_initial_prompt(parent_id, runner_node, session, prompt) do
    case ForkGate.enqueue_first_turn(parent_id, session.id, prompt,
           runner_node: runner_node,
           parent_context_tokens: HubRPC.last_context_tokens(parent_id)
         ) do
      :ok ->
        :ok

      other ->
        fork_gate_bypass(parent_id, runner_node, session, prompt, other)
    end
  rescue
    error -> fork_gate_bypass(parent_id, runner_node, session, prompt, error)
  catch
    :exit, reason -> fork_gate_bypass(parent_id, runner_node, session, prompt, reason)
  end

  # The gate being unreachable must not strand a child that was already
  # created — but silently unserializing is exactly the regression §1.1 is
  # about, so the fallback is LOUD: deliver, and warn on the child's and the
  # parent's session topics the same way ForkGate's own failure paths do.
  # A cold prefill here shows up in the child's own first `result`, which
  # nothing is left watching, so this warning is the only signal.
  defp fork_gate_bypass(parent_id, runner_node, session, prompt, reason) do
    Logger.warning(
      "[MCP] start_session: ForkGate unavailable for fork child #{session.id} " <>
        "(parent #{parent_id}): #{inspect(reason)} — delivering the first prompt " <>
        "UNSERIALIZED"
    )

    event = %{
      "type" => "system",
      "subtype" => "fork_gate_bypass",
      "child_session_id" => session.id,
      "parent_session_id" => parent_id,
      "message" =>
        "Fork gate unavailable — this fork's first prompt was sent WITHOUT first-turn " <>
          "serialization, so its inherited context may have been cold-prefilled " <>
          "(pi_fork_spec.md §6)."
    }

    for topic_session_id <- [session.id, parent_id] do
      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{topic_session_id}",
        {:event, event}
      )
    end

    Cluster.send_message(runner_node, session.id, prompt, :queue)
  end

  # Same id-resolution as get_issue (key, UUID, or UUID prefix — see
  # OrcaHub.Issues.resolve_id/1) — issues_spec.md §9's start_session link.
  defp resolve_issue_id_arg(nil), do: {:ok, nil}
  defp resolve_issue_id_arg(""), do: {:ok, nil}

  defp resolve_issue_id_arg(id) do
    case HubRPC.resolve_issue_id(id) do
      {:ok, issue} -> {:ok, issue.id}
      {:error, message} -> {:error, message}
    end
  end

  # Best-effort open -> in_progress transition when a session is linked to
  # an issue at spawn time (issues_spec.md §9) — never allowed to block or
  # fail the actual session spawn, same defensive pattern
  # maybe_record_interaction/3 already uses.
  defp maybe_auto_progress_issue(nil, _session_id), do: :ok

  defp maybe_auto_progress_issue(issue_id, session_id) do
    case HubRPC.get_issue(issue_id) do
      %{status: "open"} = issue ->
        case HubRPC.update_issue(issue, %{status: "in_progress"}) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "[MCP] start_session: failed to auto-transition issue #{issue_id} to " <>
                "in_progress for session #{session_id}: #{inspect(changeset.errors)}"
            )

            :ok
        end

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[MCP] start_session: failed to auto-transition issue #{issue_id} to in_progress " <>
          "for session #{session_id}: #{Exception.format(:error, error)}"
      )

      :ok
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
  # (identical id AND identical prompt/title/directory/model/backend/orchestrator)
  # matches, while a later legitimate call reusing the id almost certainly
  # differs in at least one of those fields and so gets its own key. Pure
  # function of its inputs only — no node()/timestamp — so it's identical
  # across nodes and releases, which matters since a replay pair can land on
  # different nodes during a rollout.
  defp auto_idempotency_key(caller_session_id, state, args) do
    material =
      [
        caller_session_id,
        Map.get(state, :mcp_request_id),
        args["prompt"],
        args["title"],
        args["directory"],
        args["model"],
        args["backend"],
        args["orchestrator"]
      ]
      |> Enum.map_join(<<0x1F>>, &to_string(&1 || ""))

    "auto:" <> (:crypto.hash(:sha256, material) |> Base.encode16(case: :lower))
  end

  # Routing precedence for start_session, extending the directory-only
  # design from issue 6c304aec (see the directory-only clauses below):
  #
  #   1. `project_id` given -> that project's routing wins outright. An
  #      explicit `directory` alongside it is NOT an alternate way to name
  #      the project (unlike triggers.ex's directory param) — it instead
  #      sets the session's cwd, validated to be at/under the project's own
  #      directory (worktree/subdir support).
  #   2. `directory` + `node` (no project_id) -> explicit, caller-vouched
  #      unregistered-spawn targeting. A node the CALLER passes here is not
  #      "invented" — 6c304aec only ever ruled out OrcaHub GUESSING one.
  #   3. `directory` alone (no project_id, no node) -> unchanged: matches
  #      an existing project by directory, or falls back to the caller's
  #      own routing.
  #   4. `node` alone (no directory, no project_id) -> rejected outright;
  #      "the caller's own directory, but on some other node" is not a
  #      real use case.
  #   5. none of the three -> unchanged: caller's own directory + routing.
  #
  # Returns {:ok, {project_id, runner_node, directory}} | {:error, message}.
  defp resolve_routing(args, caller) do
    project_id = blank_to_nil(args["project_id"])
    directory_arg = blank_to_nil(args["directory"])
    node_arg = blank_to_nil(args["node"])

    cond do
      project_id ->
        resolve_routing_by_project_id(project_id, directory_arg, node_arg)

      directory_arg && node_arg ->
        resolve_routing_by_directory_and_node(directory_arg, node_arg)

      node_arg ->
        {:error,
         "node was given without project_id or directory — \"the caller's own directory, " <>
           "but on some other node\" isn't a coherent target. Pass project_id, or pass " <>
           "directory together with node."}

      true ->
        directory = directory_arg || caller.directory
        {:ok, resolve_directory_only_routing(directory, caller)}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  # project_id given: that project's own routing wins outright. An
  # explicit node must agree with it (never silently overridden); an
  # explicit directory must be at/under the project's own directory.
  defp resolve_routing_by_project_id(project_id, directory_arg, node_arg) do
    case HubRPC.resolve_project_id(project_id) do
      {:error, message} ->
        {:error, message}

      {:ok, project} ->
        runner_node = Cluster.project_node_for(project)

        with :ok <- check_node_matches_project(node_arg, runner_node),
             {:ok, directory} <- resolve_directory_under_project(directory_arg, project) do
          {:ok, {project.id, runner_node, directory}}
        end
    end
  end

  defp check_node_matches_project(nil, _runner_node), do: :ok

  defp check_node_matches_project(node_arg, runner_node) do
    case NodeArg.resolve(node_arg) do
      {:ok, ^runner_node} ->
        :ok

      {:ok, other_node} ->
        {:error,
         "node #{inspect(Atom.to_string(other_node))} contradicts project_id's own node " <>
           "#{inspect(Atom.to_string(runner_node))}. Omit node when passing project_id — " <>
           "its routing already determines the node."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp resolve_directory_under_project(nil, project), do: {:ok, project.directory}

  defp resolve_directory_under_project(directory, project) do
    if directory == project.directory or
         String.starts_with?(directory, project.directory <> "/") do
      {:ok, directory}
    else
      {:error,
       "directory #{inspect(directory)} is not project_id's own directory " <>
         "(#{inspect(project.directory)}) or a sub-path of it (e.g. a worktree). Omit " <>
         "directory to use the project's own directory, or pass a path under it."}
    end
  end

  # directory + node (no project_id): explicit unregistered-spawn
  # targeting. A registered project for this exact directory, if any,
  # still wins (and must agree with the given node — a contradiction
  # between the caller's model and the DB is exactly how issue 6c304aec
  # happened, so it's rejected rather than guessed at). With no project
  # row nothing vouches for the directory, so it's pre-flight verified to
  # actually exist on the target node before a session is created against
  # it — a cross-node call, so isolation is checked first.
  defp resolve_routing_by_directory_and_node(directory, node_arg) do
    with {:ok, runner_node} <- NodeArg.resolve(node_arg) do
      case HubRPC.get_project_by_directory(directory) do
        %{} = project ->
          if Cluster.project_node_for(project) == runner_node do
            {:ok, {project.id, runner_node, directory}}
          else
            {:error,
             "directory #{inspect(directory)} is already registered to project " <>
               "#{inspect(project.name)} on node #{inspect(project.node)}, which differs " <>
               "from the given node #{inspect(node_arg)}. Pass the project's own node, " <>
               "omit node and let the registered project's routing win, or pass " <>
               "project_id directly."}
          end

        nil ->
          with :ok <- check_cross_node_allowed(runner_node),
               :ok <- preflight_directory_exists(directory, runner_node) do
            {:ok, {nil, runner_node, directory}}
          end
      end
    end
  end

  defp check_cross_node_allowed(runner_node) do
    if NodePolicy.cross_node_allowed?(runner_node) do
      :ok
    else
      {:error, NodePolicy.denial_message(runner_node)}
    end
  end

  # A single-path, shallow (max_entries: 1) OrcaHub.Probes.stat_paths/2
  # RPC — cheap existence/type check, not a real listing. Mirrors
  # OrcaHub.MCP.Tools.Probes' own stat_paths dispatch (same primitive,
  # same {:error, reason} shape from Cluster.rpc/5 for an unreachable
  # node).
  defp preflight_directory_exists(directory, runner_node) do
    case Cluster.rpc(runner_node, Probes, :stat_paths, [[directory], 1]) do
      [%{exists: true, type: "directory"}] ->
        :ok

      [%{exists: true}] ->
        {:error,
         "#{inspect(directory)} exists on node #{inspect(Atom.to_string(runner_node))} but " <>
           "is not a directory."}

      [%{exists: false}] ->
        {:error,
         "directory #{inspect(directory)} does not exist on node " <>
           "#{inspect(Atom.to_string(runner_node))}."}

      {:error, reason} ->
        {:error,
         "Could not verify directory #{inspect(directory)} on node " <>
           "#{inspect(Atom.to_string(runner_node))}: " <>
           "#{Cluster.node_unavailable_message(reason) || inspect(reason)}"}
    end
  end

  # directory alone (no project_id, no node) — UNCHANGED back-compat
  # behavior from issue 6c304aec: an explicit `directory` that differs
  # from the caller's own directory may belong to a DIFFERENT project
  # (registered on a different node) — route the child there instead of
  # blindly inheriting the caller's project_id and node, which used to
  # silently spawn cross-node delegation attempts on the WRONG node
  # against the WRONG project_id. An unregistered directory (no project
  # row for it) falls back to the caller's own routing unchanged — never
  # invent or reassign a node for a directory OrcaHub doesn't have on
  # file.
  defp resolve_directory_only_routing(directory, %{directory: directory} = caller),
    do: {caller.project_id, caller_runner_node(caller), directory}

  defp resolve_directory_only_routing(directory, caller) do
    case HubRPC.get_project_by_directory(directory) do
      %{} = project -> {project.id, Cluster.project_node_for(project), directory}
      nil -> {caller.project_id, caller_runner_node(caller), directory}
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
      already_exists: already_exists,
      orchestrator: session.orchestrator,
      issue_id: session.issue_id
    }
    |> maybe_put_fork_fields(session.forked_from_session_id)
  end

  # pi_fork_spec.md §3/§7: a fork spawn's result additionally carries the
  # parent id, the parent's last known context size, and — above the KV
  # budget threshold — a soft warning. Threaded through start_session_result/2
  # (rather than a separate value at the call site) so a fresh fork spawn
  # AND an idempotency-key replay of one get the same fields, computed
  # fresh each time.
  defp maybe_put_fork_fields(result, nil), do: result

  defp maybe_put_fork_fields(result, parent_id) do
    parent_tokens = HubRPC.last_context_tokens(parent_id)
    # Counted AFTER this child's row exists (or already existed, on a
    # replay), so this total already includes the spec's "+1".
    concurrent_total = HubRPC.count_active_fork_children(parent_id)

    result
    |> Map.put(:forked_from, parent_id)
    |> Map.put(:parent_context_tokens, parent_tokens)
    |> maybe_put_field(
      :fork_budget_warning,
      fork_budget_warning(parent_tokens, concurrent_total)
    )
  end

  # Unified-KV budget (pi_fork_spec.md §7) — total slot-resident cells on
  # the gb10 llama-server serving profile. A property of the serving box,
  # not of OrcaHub, so it lives with the rest of the llama.cpp-specific
  # knobs in the §9 serving profile (still `ORCA_FORK_KV_BUDGET`, still
  # 262_144 by default) rather than being parsed a second time here.
  defp fork_kv_budget, do: ServingProfile.kv_budget()

  # v1 is a SOFT guard only (§7) — this never refuses a spawn, it only
  # appends a warning string to the tool result.
  defp fork_budget_warning(nil, _concurrent_total), do: nil

  defp fork_budget_warning(parent_tokens, concurrent_total) do
    projected = concurrent_total * parent_tokens
    budget = fork_kv_budget()

    if projected > budget do
      "KV budget pressure: #{concurrent_total} concurrently-resident fork context(s) x " <>
        "~#{parent_tokens} parent tokens ~= #{projected}, above the #{budget}-cell budget " <>
        "for this serving profile (pi_fork_spec.md §7). Soft guard only — this does not " <>
        "block spawning, but slot thrash may slow turns; consider spacing out concurrent " <>
        "forks."
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

  @max_tool_arg_bytes 200

  @max_tail_text_bytes 800

  defp cap_tail_text(nil), do: nil

  defp cap_tail_text(text) when byte_size(text) > @max_tail_text_bytes do
    safe_truncate(text, @max_tail_text_bytes) <>
      "…[truncated — pass full_last_message: true for the complete message, or " <>
      "include_last_message: false to omit it entirely when polling]"
  end

  defp cap_tail_text(text), do: text

  defp maybe_put_last_assistant_text(map, nil), do: map
  defp maybe_put_last_assistant_text(map, text), do: Map.put(map, :last_assistant_text, text)

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
    do: safe_truncate(str, @max_tool_arg_bytes) <> "…"

  defp cap_tail_arg(str), do: str

  # binary_part alone can split a multibyte UTF-8 character mid-sequence,
  # producing an invalid binary that later blows up (e.g. Jason.encode!) —
  # prod crash: "invalid byte 0xE2 in <<35, 35, 32, 82, ...>>". Trim back to
  # the last complete character after the byte-budget cut.
  defp safe_truncate(bin, max_bytes) do
    if byte_size(bin) <= max_bytes do
      bin
    else
      bin
      |> binary_part(0, max_bytes)
      |> trim_incomplete_utf8()
    end
  end

  defp trim_incomplete_utf8(<<>>), do: <<>>

  defp trim_incomplete_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_incomplete_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  # Child spawning is first-class for ANY caller session now, not just
  # orchestrators: whenever this start_session call happened from within a
  # running OrcaHub session (caller_session_id present), the new session is
  # linked as that caller's child. `notify_on_completion` (default true)
  # becomes `notify_parent` — the "[Session lifecycle]" running->idle/error
  # callback to the parent. There's still nothing to link when start_session
  # is invoked with no calling session at all (e.g. an HTTP/API-triggered
  # spawn) — `caller_session_id` is nil in that case and no parent/notify
  # fields are set.
  #
  # Exception: spawning another ORCHESTRATOR (`attrs[:orchestrator] == true`,
  # already stamped in by the time this runs) defaults to a HANDOFF to a
  # sibling rather than a supervised child — otherwise a chain of
  # orchestrator-spawns-orchestrator produces a wake-up cascade every time an
  # inner one finishes. The new orchestrator inherits the CALLER's own
  # parent (often nil, making it a root session — intended) and gets no
  # notify-back. `notify_on_completion: true` is the explicit escape hatch
  # back to the old child-link behavior, for a deliberate reporting
  # sub-orchestrator.
  # pi_fork_spec.md §8: bridges the gap between an empty OrcaHub `messages`
  # feed and a full LLM context the fork actually inherited. Best-effort —
  # same posture as maybe_record_interaction/3, since the session itself
  # was already successfully created by the time this runs.
  defp create_fork_marker_message(child_session_id, parent_session_id) do
    inherited_tokens = HubRPC.last_context_tokens(parent_session_id)

    case HubRPC.create_message(%{
           session_id: child_session_id,
           data: %{
             "type" => "system",
             "subtype" => "forked_from",
             "parent_session_id" => parent_session_id,
             "inherited_tokens" => inherited_tokens
           }
         }) do
      {:ok, _message} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[MCP] start_session: failed to create fork marker message for child " <>
            "#{child_session_id} (parent #{parent_session_id}): #{inspect(changeset.errors)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[MCP] start_session: failed to create fork marker message for child " <>
          "#{child_session_id} (parent #{parent_session_id}): #{Exception.format(:error, error)}"
      )

      :ok
  end

  defp maybe_link_parent(attrs, caller, caller_session_id, notify_on_completion)
       when is_binary(caller_session_id) do
    if orchestrator_handoff?(attrs, notify_on_completion) do
      attrs
      |> Map.put(:parent_session_id, caller.parent_session_id)
      |> Map.put(:notify_parent, false)
    else
      attrs
      |> Map.put(:parent_session_id, caller_session_id)
      |> Map.put(:notify_parent, notify_on_completion != false)
    end
  end

  defp maybe_link_parent(attrs, _caller, _caller_session_id, _notify_on_completion), do: attrs

  defp orchestrator_handoff?(attrs, notify_on_completion) do
    attrs[:orchestrator] == true and notify_on_completion != true
  end

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
