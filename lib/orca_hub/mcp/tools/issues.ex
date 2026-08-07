defmodule OrcaHub.MCP.Tools.Issues do
  @moduledoc """
  MCP tools for durable, agent-usable work items (issues_spec.md) — the
  full Phase 2a tool surface: `create_issue`, `list_issues`, `get_issue`,
  `update_issue`, `append_issue_note`, `close_issue`. Backed by
  `OrcaHub.Issues` (schema/context landed in Phase 1).

  An issue is a NARRATIVE (what happened and why), not standing guidance —
  see issues_spec.md §1. `kind: "feature_request"` replaces the old
  `[agent-fr] `-title-prefix hack entirely: it's the same table, filtered.

  `close_issue` implements the two-mode read-back flow (§6.6): a bare `id`
  harvests and returns the live attempt evidence WITHOUT closing, so the
  closing agent synthesizes `resolution` from that record instead of from
  its own (possibly-compacted) memory of the work; `id` + `outcome` +
  `resolution` actually closes.

  ## FR-board compat shim (temporary — see issues_spec.md §8)

  `file_feature_request`, `list_feature_requests`, `get_feature_request`,
  `append_feature_request_note`, and `close_feature_request` stay
  registered below as thin, deprecated wrappers over the six tools above
  (`kind` forced to `"feature_request"`, `directory` forced to
  `@orca_hub_directory`) rather than being removed outright — a warm
  session mid-flight when this shipped shouldn't suddenly lose a tool it
  can already see (a warm port's tool list doesn't refresh until its next
  cold spawn — the same caveat issues_spec.md §10.2 notes for the resume
  hook applies here too). This module replaces
  `OrcaHub.MCP.Tools.FeatureRequests` outright (removed from the tool
  registry, see `OrcaHub.MCP.Tools`).

  **Removal condition** (§8 point 3), recorded here so a future maintainer
  doesn't have to re-derive it: delete the five deprecated `list/0` entries
  and `call/3` clauses below the `── FR-board compat shim ──` marker once
  EITHER holds — a grep of prod session logs shows zero calls to any of
  the five old names over a full deploy cycle, OR a fixed two-week window
  has passed with no further deploys pinning an older prompt (this shim
  shipped 2026-08-06, so 2026-08-20 satisfies the fixed-window form on its
  own — this is a fully internal tool surface with no external,
  version-pinned consumers).
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC}
  alias OrcaHub.Issues.Issue

  @orca_hub_directory "/home/zach/orca_hub"
  @kinds ~w(task feature_request)

  @id_description "The issue's id — its short key (e.g. `ORCA-142`, shown in `/issues` URLs " <>
                    "and session messages), a full UUID, or an unambiguous UUID hex prefix " <>
                    "(>= 8 hex chars, dashes optional)."

  @deprecated_prefix "[deprecated — use create_issue/list_issues/get_issue/" <>
                       "append_issue_note/close_issue instead] "

  @fr_default_resolution "Closed via deprecated close_feature_request with no resolution " <>
                           "note provided."

  @update_field_keys ~w(title description kind status plan premise resolution superseded_by)

  # ── tool definitions ────────────────────────────────────────────────

  def list do
    [
      %{
        "name" => "create_issue",
        "description" =>
          "File a durable work item — a task against your own project, or (kind: " <>
            "\"feature_request\") a platform-friction report against OrcaHub itself. " <>
            "Unlike a memory rule, an issue is a NARRATIVE, not standing guidance — record " <>
            "what's broken/being asked and why it matters, not a rule to follow going " <>
            "forward. Light dedup: if an open issue with a similar title already exists in " <>
            "the same project+kind, no new issue is created — the existing one is returned " <>
            "instead; use append_issue_note on it.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{
              "type" => "string",
              "description" =>
                "Short summary, written like a commit subject line — specific enough that " <>
                  "the dedup check won't confuse it with something else."
            },
            "description" => %{
              "type" => "string",
              "description" =>
                "What's broken, what's being asked, or what you're proposing — and why it " <>
                  "matters right now. Written so someone can understand what prompted this " <>
                  "without you in the room."
            },
            "kind" => %{
              "type" => "string",
              "enum" => @kinds,
              "description" =>
                "\"task\" (default) for work against your own project. \"feature_request\" " <>
                  "for platform friction filed against OrcaHub itself — a missing tool, an " <>
                  "awkward workflow, a confusing error."
            },
            "premise" => %{
              "type" => "string",
              "description" =>
                "The assumption you're operating under that makes this worth doing — what " <>
                  "do you believe is true right now that, if it stopped being true, would " <>
                  "make this moot? This gets checked later, so write it for someone " <>
                  "auditing a rule that might one day cite this issue."
            },
            "plan" => %{
              "type" => "string",
              "description" =>
                "Your current intended approach, in your own words. Optional at file time " <>
                  "— set or update it later with update_issue as your understanding develops."
            },
            "directory" => %{
              "type" => "string",
              "description" =>
                "Which project to file this against. Defaults to your own project. Pass an " <>
                  "absolute path belonging to a DIFFERENT registered project to file " <>
                  "against that project instead (this is how feature_request issues target " <>
                  "the OrcaHub codebase from any calling session)."
            }
          },
          "required" => ["title", "description"]
        }
      },
      %{
        "name" => "list_issues",
        "description" =>
          "List issues. Defaults to open issues in your own project, across both kinds, " <>
            "newest first. Check this (or the dedup check inside create_issue) before " <>
            "filing — if something similar is already tracked, append_issue_note on it " <>
            "instead of creating a duplicate.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "status" => %{
              "type" => "string",
              "description" =>
                "\"open\" (default), \"in_progress\", \"closed\", \"abandoned\", or \"all\"."
            },
            "kind" => %{
              "type" => "string",
              "description" => "\"task\", \"feature_request\", or \"all\" (default)."
            },
            "directory" => %{
              "type" => "string",
              "description" => "Project to list issues for. Defaults to your own project."
            },
            "all_projects" => %{
              "type" => "boolean",
              "description" => "List across every project instead of one. Default: false."
            },
            "mine" => %{
              "type" => "boolean",
              "description" =>
                "Only issues YOU (this session) created. Useful after a compaction or a " <>
                  "long idle gap to re-orient without waiting on the automatic reminder. " <>
                  "Default: false."
            },
            "query" => %{
              "type" => "string",
              "description" => "Optional case-insensitive title substring filter."
            },
            "limit" => %{"type" => "integer", "description" => "Default 50."}
          }
        }
      },
      %{
        "name" => "get_issue",
        "description" =>
          "Fetch an issue's full record. While open/in_progress, also returns \"attempts\" " <>
            "— a live summary of every session linked to this issue (via start_session's " <>
            "issue_id) showing what each one did: final status, last message, self-reported " <>
            "progress, and commits. This is the raw material to read BEFORE closing an " <>
            "issue — see close_issue. If this issue has been superseded, the response " <>
            "points straight at what replaced it.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string", "description" => @id_description}},
          "required" => ["id"]
        }
      },
      %{
        "name" => "update_issue",
        "description" =>
          "Update an issue's fields. On an open/in_progress issue: edit " <>
            "title/description/kind/plan/premise, or move it to \"in_progress\". Setting " <>
            "status to \"open\" on a closed/abandoned issue REOPENS it — the frozen " <>
            "commits/attempts/resolution are archived into notes first, then cleared, " <>
            "since real work resuming means they're about to go stale. Cannot set status " <>
            "to closed/abandoned here; use close_issue for that. On an already-closed/" <>
            "abandoned issue, resolution/premise can still be AMENDED (the prior value is " <>
            "preserved in notes first, never silently overwritten) — this is how " <>
            "retroactive corrections like \"this turned out to be wrong\" get recorded " <>
            "without destroying what was known at the time it closed.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => @id_description},
            "title" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "kind" => %{"type" => "string", "enum" => @kinds},
            "status" => %{
              "type" => "string",
              "enum" => ["open", "in_progress"],
              "description" =>
                "Cannot be used to close or abandon an issue — see close_issue. Setting " <>
                  "\"open\" from a currently closed/abandoned status is how you reopen one."
            },
            "plan" => %{
              "type" => "string",
              "description" =>
                "Your current intended approach. This OVERWRITES the existing plan, it " <>
                  "doesn't append — write the whole current plan, not a diff."
            },
            "premise" => %{
              "type" => "string",
              "description" =>
                "The assumption behind this issue. On an open issue this just updates it. " <>
                  "On a closed/abandoned issue, the PRIOR premise is preserved in notes " <>
                  "before the new one is applied — you're amending the record, not " <>
                  "rewriting history."
            },
            "resolution" => %{
              "type" => "string",
              "description" =>
                "Only settable on an already-closed/abandoned issue (close_issue sets it " <>
                  "the first time) — use this to amend the resolution once new information " <>
                  "surfaces, e.g. \"this turned out to be wrong\" or \"superseded by " <>
                  "ORCA-201.\" The prior resolution is preserved in notes before the new " <>
                  "one is applied."
            },
            "superseded_by" => %{
              "type" => "string",
              "description" =>
                "Mark this issue as replaced by another one — pass the superseding issue's " <>
                  "id/key. Use this when you discover a newer issue already covers what " <>
                  "this one was about; it's often the single highest-value thing you can " <>
                  "add to a closed issue, since it tells a future reader exactly where the " <>
                  "current thinking moved to. Works regardless of this issue's own status. " <>
                  "Does not itself change status."
            }
          },
          "required" => ["id"]
        }
      },
      %{
        "name" => "append_issue_note",
        "description" =>
          "Append a note to an existing issue — use this to record new evidence on an " <>
            "issue create_issue already deduped against instead of filing a duplicate, or " <>
            "to add any other context. Always works regardless of status.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => @id_description},
            "note" => %{"type" => "string", "description" => "The note text to append."}
          },
          "required" => ["id", "note"]
        }
      },
      %{
        "name" => "close_issue",
        "description" =>
          "Close an issue with outcome \"resolved\" (the work landed) or \"abandoned\" " <>
            "(stopping without finishing — still requires a resolution explaining why; an " <>
            "abandoned issue with a real narrative is more valuable than a resolved one " <>
            "with none). Commits and a compact attempt summary are derived and frozen " <>
            "automatically from linked attempts and the OrcaHub-Issue commit trailer — you " <>
            "cannot pass them by hand. Call this with ONLY id first: it returns the " <>
            "harvested attempt evidence (same shape as get_issue's \"attempts\") WITHOUT " <>
            "closing anything. Synthesize resolution from THAT evidence, not from your own " <>
            "memory of the work (your context may have been compacted since you started) " <>
            "— then call close_issue again with outcome and resolution to actually close " <>
            "it. To close as abandoned because a newer issue already covers this, pass " <>
            "superseded_by in the same call.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => @id_description},
            "outcome" => %{
              "type" => "string",
              "enum" => ["resolved", "abandoned"],
              "description" =>
                "Omit on the first call to get the harvested evidence without closing."
            },
            "resolution" => %{
              "type" => "string",
              "description" =>
                "What actually happened — not what you planned to happen. If outcome is " <>
                  "\"abandoned\", explain what made this not worth finishing and what that " <>
                  "implies for anyone who reopens it later. Required together with outcome " <>
                  "to actually close."
            },
            "superseded_by" => %{
              "type" => "string",
              "description" =>
                "Optional: the id/key of the issue that replaces this one. Common when " <>
                  "closing as \"abandoned\" because you found this is already covered " <>
                  "elsewhere — sets the same structured link update_issue's superseded_by does."
            }
          },
          "required" => ["id"]
        }
      }
      | deprecated_fr_tool_definitions()
    ]
  end

  defp deprecated_fr_tool_definitions do
    [
      %{
        "name" => "file_feature_request",
        "description" =>
          @deprecated_prefix <>
            "File a feature request or platform-friction report against the OrcaHub " <>
            "codebase itself — NOT the calling session's own project. Equivalent to " <>
            "create_issue(kind: \"feature_request\", directory: \"#{@orca_hub_directory}\", ...).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{
              "type" => "string",
              "description" => "Short title for the feature request."
            },
            "description" => %{
              "type" => "string",
              "description" =>
                "The pain point, the proposed change, and any evidence from this session."
            },
            "category" => %{
              "type" => "string",
              "description" => "Optional free-text category — folded into the description."
            }
          },
          "required" => ["title", "description"]
        }
      },
      %{
        "name" => "list_feature_requests",
        "description" =>
          @deprecated_prefix <>
            "List agent-filed feature requests. Equivalent to list_issues(kind: " <>
            "\"feature_request\", directory: \"#{@orca_hub_directory}\", ...).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "status" => %{
              "type" => "string",
              "description" => "\"open\" (default), \"in_progress\", \"closed\", or \"all\"."
            }
          }
        }
      },
      %{
        "name" => "get_feature_request",
        "description" =>
          @deprecated_prefix <> "Fetch a feature request by id. Equivalent to get_issue(id).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string", "description" => @id_description}},
          "required" => ["id"]
        }
      },
      %{
        "name" => "append_feature_request_note",
        "description" =>
          @deprecated_prefix <>
            "Append a note to a feature request. Equivalent to append_issue_note(id, note).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => @id_description},
            "note" => %{"type" => "string", "description" => "The note text to append."}
          },
          "required" => ["id", "note"]
        }
      },
      %{
        "name" => "close_feature_request",
        "description" =>
          @deprecated_prefix <>
            "Close a feature request once its fix has shipped and been verified. " <>
            "Equivalent to close_issue(id, outcome: \"resolved\", resolution: resolution_note).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => @id_description},
            "resolution_note" => %{
              "type" => "string",
              "description" =>
                "Optional note recording how/where this was resolved, e.g. a commit SHA."
            }
          },
          "required" => ["id"]
        }
      }
    ]
  end

  # ── call/3 ───────────────────────────────────────────────────────────

  def call("create_issue", args, state) do
    title = args["title"]
    description = args["description"]
    kind = normalize_kind(args["kind"])

    cond do
      not is_binary_non_empty(title) ->
        error("create_issue requires a non-empty `title` string argument.")

      not is_binary_non_empty(description) ->
        error("create_issue requires a non-empty `description` string argument.")

      kind not in @kinds ->
        error(
          "create_issue's `kind` must be \"task\" or \"feature_request\" (got #{inspect(kind)})."
        )

      true ->
        case resolve_target_project(args, state) do
          {:ok, project} ->
            do_create_issue(
              project,
              title,
              description,
              kind,
              %{premise: args["premise"], plan: args["plan"]},
              state
            )

          {:error, message} ->
            error(message)
        end
    end
  end

  def call("list_issues", args, state) do
    case resolve_list_scope(args, state) do
      {:ok, project_id} ->
        opts =
          %{
            status: args["status"] || "open",
            kind: args["kind"] || "all",
            limit: args["limit"] || 50
          }
          |> maybe_put_field(:project_id, project_id)
          |> maybe_put_field(:query, blank_to_nil(args["query"]))
          |> maybe_put_mine(args, state)

        results = opts |> HubRPC.list_issues() |> Enum.map(&issue_summary_result/1)
        text(Jason.encode!(%{"count" => length(results), "issues" => results}))

      {:error, message} ->
        error(message)
    end
  end

  def call("get_issue", args, _state) do
    case resolve(args["id"], "get_issue") do
      {:ok, issue} -> text(Jason.encode!(issue_full_result(issue)))
      {:error, message} -> error(message)
    end
  end

  def call("update_issue", args, state) do
    id = args["id"]

    cond do
      not is_binary_non_empty(id) ->
        error("update_issue requires a non-empty `id` string argument.")

      not has_update_field?(args) ->
        error("update_issue requires at least one field besides `id`.")

      true ->
        case resolve(id, "update_issue") do
          {:ok, issue} -> do_update_issue(issue, args, state)
          {:error, message} -> error(message)
        end
    end
  end

  def call("append_issue_note", args, state) do
    id = args["id"]
    note = args["note"]

    cond do
      not is_binary_non_empty(id) ->
        error("append_issue_note requires a non-empty `id` string argument.")

      not is_binary_non_empty(note) ->
        error("append_issue_note requires a non-empty `note` string argument.")

      true ->
        case resolve(id, "append_issue_note") do
          {:ok, issue} -> do_append_note(issue, note, state)
          {:error, message} -> error(message)
        end
    end
  end

  def call("close_issue", args, state) do
    id = args["id"]

    if is_binary_non_empty(id) do
      case resolve(id, "close_issue") do
        {:ok, issue} -> do_close_issue(issue, args, state)
        {:error, message} -> error(message)
      end
    else
      error("close_issue requires a non-empty `id` string argument.")
    end
  end

  # ── FR-board compat shim (temporary — see moduledoc) ────────────────

  def call("file_feature_request", args, state) do
    title = args["title"]
    description = args["description"]

    cond do
      not is_binary_non_empty(title) ->
        error("file_feature_request requires a non-empty `title` string argument.")

      not is_binary_non_empty(description) ->
        error("file_feature_request requires a non-empty `description` string argument.")

      true ->
        case HubRPC.get_project_by_directory(@orca_hub_directory) do
          nil ->
            error(
              "No OrcaHub project is registered for #{@orca_hub_directory} — cannot file a " <>
                "feature request. Register that project first."
            )

          project ->
            full_description =
              description <> "\n\n" <> fr_provenance_block(args["category"], state)

            do_create_issue(project, title, full_description, "feature_request", %{}, state)
        end
    end
  end

  def call("list_feature_requests", args, _state) do
    case HubRPC.get_project_by_directory(@orca_hub_directory) do
      nil ->
        error(
          "No OrcaHub project is registered for #{@orca_hub_directory} — cannot list feature requests."
        )

      project ->
        opts = %{
          status: args["status"] || "open",
          kind: "feature_request",
          project_id: project.id,
          limit: 50
        }

        results = opts |> HubRPC.list_issues() |> Enum.map(&issue_summary_result/1)
        text(Jason.encode!(%{"count" => length(results), "feature_requests" => results}))
    end
  end

  def call("get_feature_request", args, state), do: call("get_issue", args, state)

  def call("append_feature_request_note", args, state), do: call("append_issue_note", args, state)

  def call("close_feature_request", args, state) do
    id = args["id"]

    if is_binary_non_empty(id) do
      resolution = blank_to_nil(args["resolution_note"]) || @fr_default_resolution

      call(
        "close_issue",
        %{"id" => id, "outcome" => "resolved", "resolution" => resolution},
        state
      )
    else
      error("close_feature_request requires a non-empty `id` string argument.")
    end
  end

  # ── create_issue helpers ─────────────────────────────────────────────

  defp normalize_kind(nil), do: "task"
  defp normalize_kind(""), do: "task"
  defp normalize_kind(kind), do: kind

  defp do_create_issue(project, title, description, kind, opts, state) do
    case HubRPC.find_similar_open_issue(project.id, kind, title) do
      %Issue{} = existing ->
        text(Jason.encode!(dedup_issue_result(existing)))

      nil ->
        attrs =
          %{title: title, description: description, kind: kind, project_id: project.id}
          |> maybe_put_field(:premise, blank_to_nil(opts[:premise]))
          |> maybe_put_field(:plan, blank_to_nil(opts[:plan]))
          |> maybe_put_field(:created_by_session_id, state[:orca_session_id])

        case HubRPC.create_issue(attrs) do
          {:ok, issue} ->
            text(Jason.encode!(created_issue_result(issue)))

          {:error, changeset} ->
            error("Failed to create issue: #{format_changeset_errors(changeset)}")
        end
    end
  end

  defp created_issue_result(issue) do
    %{
      id: issue.id,
      key: HubRPC.render_issue_key(issue),
      title: issue.title,
      kind: issue.kind,
      status: issue.status,
      url: issue_url(issue.id),
      created: true,
      deduped: false
    }
  end

  defp dedup_issue_result(issue) do
    %{
      id: issue.id,
      key: HubRPC.render_issue_key(issue),
      title: issue.title,
      kind: issue.kind,
      status: issue.status,
      url: issue_url(issue.id),
      created: false,
      deduped: true,
      message:
        "A similar open issue already exists — not creating a duplicate. Call " <>
          "append_issue_note(id: \"#{issue.id}\", note: ...) to record new evidence on the " <>
          "existing issue instead."
    }
  end

  defp issue_url(id), do: "/issues/#{id}"

  defp fr_provenance_block(category, state) do
    """
    ---
    Filed automatically via file_feature_request.
    Session: #{state[:orca_session_id] || "unknown"}
    Node: #{Cluster.node_name(node())}
    Date: #{Date.utc_today()}
    Category: #{category || "uncategorized"}
    """
    |> String.trim()
  end

  # ── list_issues helpers ──────────────────────────────────────────────

  defp resolve_list_scope(%{"all_projects" => true}, _state), do: {:ok, nil}

  defp resolve_list_scope(args, state) do
    case resolve_target_project(args, state) do
      {:ok, project} -> {:ok, project.id}
      {:error, message} -> {:error, message}
    end
  end

  defp maybe_put_mine(opts, %{"mine" => true}, state) do
    maybe_put_field(opts, :created_by_session_id, state[:orca_session_id])
  end

  defp maybe_put_mine(opts, _args, _state), do: opts

  defp issue_summary_result(issue) do
    %{
      id: issue.id,
      key: HubRPC.render_issue_key(issue),
      title: issue.title,
      kind: issue.kind,
      status: issue.status,
      project: project_display_name(issue),
      inserted_at: issue.inserted_at
    }
  end

  defp project_display_name(%{project: %OrcaHub.Projects.Project{name: name}}), do: name
  defp project_display_name(issue), do: project_name(issue)

  defp project_name(issue) do
    case issue.project_id && HubRPC.get_project(issue.project_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  # ── get_issue helpers ────────────────────────────────────────────────

  defp issue_full_result(issue) do
    %{
      id: issue.id,
      key: HubRPC.render_issue_key(issue),
      title: issue.title,
      kind: issue.kind,
      status: issue.status,
      description: issue.description,
      premise: issue.premise,
      plan: issue.plan,
      approaches_tried: issue.approaches_tried,
      notes: issue.notes,
      project: project_name(issue),
      created_by_session_id: issue.created_by_session_id,
      resolution: issue.resolution,
      closed_at: issue.closed_at,
      closed_by_session_id: issue.closed_by_session_id,
      superseded_by: superseded_by_summary(issue.superseded_by_issue_id),
      commits: issue.commits,
      attempts: issue_attempts(issue)
    }
  end

  # Rich + live while open/in_progress (§3.5); compact + frozen once closed
  # (§4.3) — same key ("attempts") in both states, different source/richness.
  defp issue_attempts(%{status: status} = issue) when status in ["open", "in_progress"] do
    HubRPC.live_issue_attempts(issue)
  end

  defp issue_attempts(issue), do: issue.attempts

  defp superseded_by_summary(nil), do: nil

  defp superseded_by_summary(issue_id) do
    case HubRPC.get_issue(issue_id) do
      nil ->
        nil

      issue ->
        %{
          id: issue.id,
          key: HubRPC.render_issue_key(issue),
          title: issue.title,
          status: issue.status
        }
    end
  end

  # ── update_issue helpers ─────────────────────────────────────────────

  defp has_update_field?(args), do: Enum.any?(@update_field_keys, &Map.has_key?(args, &1))

  defp do_update_issue(issue, args, state) do
    with :ok <- validate_status_arg(args["status"]),
         {:ok, superseded_by_id} <- resolve_superseded_by(args["superseded_by"], issue) do
      attrs =
        %{}
        |> maybe_put_field(:title, blank_to_nil(args["title"]))
        |> maybe_put_field(:description, blank_to_nil(args["description"]))
        |> maybe_put_field(:kind, blank_to_nil(args["kind"]))
        |> maybe_put_field(:status, blank_to_nil(args["status"]))
        |> maybe_put_field(:plan, blank_to_nil(args["plan"]))
        |> maybe_put_field(:premise, blank_to_nil(args["premise"]))
        |> maybe_put_field(:resolution, blank_to_nil(args["resolution"]))
        |> maybe_put_field(:superseded_by_issue_id, superseded_by_id)

      case HubRPC.update_issue(issue, attrs, state[:orca_session_id]) do
        {:ok, updated} ->
          text(Jason.encode!(update_issue_result(updated)))

        {:error, :resolution_requires_close} ->
          error(
            "`resolution` can only be set via close_issue on an open/in_progress issue — " <>
              "update_issue only amends an already-closed/abandoned issue's resolution."
          )

        {:error, changeset} ->
          error("Failed to update issue: #{format_changeset_errors(changeset)}")
      end
    else
      {:error, message} -> error(message)
    end
  end

  defp validate_status_arg(nil), do: :ok
  defp validate_status_arg(status) when status in ["open", "in_progress"], do: :ok

  defp validate_status_arg(status) do
    {:error,
     "update_issue's `status` can only be \"open\" or \"in_progress\" (got #{inspect(status)}) " <>
       "— use close_issue to close/abandon an issue."}
  end

  defp resolve_superseded_by(nil, _issue), do: {:ok, nil}
  defp resolve_superseded_by("", _issue), do: {:ok, nil}

  defp resolve_superseded_by(id, issue) do
    case HubRPC.resolve_issue_id(id) do
      {:ok, %{id: superseding_id}} when superseding_id == issue.id ->
        {:error, "An issue cannot supersede itself."}

      {:ok, superseding} ->
        {:ok, superseding.id}

      {:error, message} ->
        {:error, message}
    end
  end

  defp update_issue_result(issue) do
    %{
      id: issue.id,
      key: HubRPC.render_issue_key(issue),
      title: issue.title,
      kind: issue.kind,
      status: issue.status,
      plan: issue.plan,
      premise: issue.premise,
      resolution: issue.resolution,
      superseded_by: superseded_by_summary(issue.superseded_by_issue_id)
    }
  end

  # ── append_issue_note helpers ────────────────────────────────────────

  defp do_append_note(issue, note, state) do
    case HubRPC.append_issue_note(
           issue,
           note <> "\n\n" <> note_provenance(state, "append_issue_note")
         ) do
      {:ok, updated} ->
        text(
          Jason.encode!(%{
            id: updated.id,
            key: HubRPC.render_issue_key(updated),
            title: updated.title,
            notes: updated.notes
          })
        )

      {:error, changeset} ->
        error("Failed to append note: #{format_changeset_errors(changeset)}")
    end
  end

  # ── close_issue helpers ──────────────────────────────────────────────

  defp do_close_issue(%{status: status} = issue, _args, _state)
       when status in ["closed", "abandoned"] do
    error(
      "#{issue_ref(issue)} is already #{status} (resolution: #{issue.resolution || "(none)"}). " <>
        "Use update_issue to amend resolution/premise, or update_issue(id: \"#{issue.id}\", " <>
        "status: \"open\") to reopen it first."
    )
  end

  defp do_close_issue(issue, args, state) do
    outcome = blank_to_nil(args["outcome"])
    resolution = blank_to_nil(args["resolution"])

    if is_nil(outcome) and is_nil(resolution) do
      preview_close_issue(issue)
    else
      finalize_close_issue(issue, outcome, resolution, args, state)
    end
  end

  defp preview_close_issue(issue) do
    text(
      Jason.encode!(%{
        id: issue.id,
        key: HubRPC.render_issue_key(issue),
        title: issue.title,
        attempts: HubRPC.live_issue_attempts(issue),
        instruction:
          "This is the harvested attempt evidence — synthesize `resolution` from THIS, not " <>
            "from your own memory of the work (it may have been compacted since you " <>
            "started). Call close_issue again with `outcome` (\"resolved\" or \"abandoned\") " <>
            "and `resolution` to actually close #{issue_ref(issue)}."
      })
    )
  end

  defp finalize_close_issue(issue, outcome, resolution, args, state) do
    case resolve_superseded_by(args["superseded_by"], issue) do
      {:ok, superseded_by_id} ->
        close_attrs =
          %{outcome: outcome, resolution: resolution, session_id: state[:orca_session_id]}
          |> maybe_put_field(:superseded_by_issue_id, superseded_by_id)

        case HubRPC.close_issue(issue, close_attrs) do
          {:ok, closed} ->
            text(Jason.encode!(close_issue_result(closed)))

          {:error, :invalid_outcome} ->
            error(
              "close_issue requires `outcome` (\"resolved\" or \"abandoned\") together with " <>
                "`resolution` to close — call close_issue with only `id` first to see the " <>
                "harvested evidence."
            )

          {:error, :resolution_required} ->
            error(
              "close_issue requires a non-empty `resolution` explaining what actually " <>
                "happened, alongside `outcome`."
            )

          {:error, changeset} ->
            error("Failed to close issue: #{format_changeset_errors(changeset)}")
        end

      {:error, message} ->
        error(message)
    end
  end

  defp close_issue_result(issue) do
    %{
      id: issue.id,
      key: HubRPC.render_issue_key(issue),
      title: issue.title,
      status: issue.status,
      resolution: issue.resolution,
      commits: issue.commits,
      attempts: issue.attempts,
      superseded_by: superseded_by_summary(issue.superseded_by_issue_id)
    }
  end

  defp issue_ref(issue), do: HubRPC.render_issue_key(issue) || issue.id

  # ── shared helpers ───────────────────────────────────────────────────

  defp resolve(id, _tool_name) when is_binary(id) and id != "", do: HubRPC.resolve_issue_id(id)

  defp resolve(_id, tool_name),
    do: {:error, "#{tool_name} requires a non-empty `id` string argument."}

  defp resolve_target_project(args, state) do
    case blank_to_nil(args["directory"]) do
      nil ->
        resolve_caller_project(state)

      directory ->
        case HubRPC.get_project_by_directory(directory) do
          %{} = project -> {:ok, project}
          nil -> {:error, "No project is registered for directory #{directory}."}
        end
    end
  end

  defp resolve_caller_project(%{orca_session_id: session_id}) when is_binary(session_id) do
    session = HubRPC.get_session!(session_id)

    case session.project_id && HubRPC.get_project(session.project_id) do
      %{} = project -> {:ok, project}
      _ -> {:error, "Could not determine your project — pass `directory` explicitly."}
    end
  end

  defp resolve_caller_project(_state) do
    {:error,
     "Could not determine which project to use — pass `directory` explicitly (no OrcaHub " <>
       "session is linked to this connection)."}
  end

  defp note_provenance(state, tool_name) do
    "— via #{tool_name}. Session: #{state[:orca_session_id] || "unknown"}, " <>
      "Node: #{Cluster.node_name(node())}, Date: #{Date.utc_today()}"
  end

  defp format_changeset_errors(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
  end

  defp is_binary_non_empty(v), do: is_binary(v) and v != ""

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val
end
