defmodule OrcaHub.MCP.Tools.Memory do
  @moduledoc """
  MCP tools for the external agent-memory service (`OrcaHub.MemoryClient`),
  visible to every session — regular and orchestrator alike. Every call
  routes through the hub (`MemoryClient` -> `HubRPC` -> the memory-service
  HTTP API), so this works identically from any node.

  `remember`/`recall` are the everyday pair: `remember` for a durable fact,
  preference, procedure, or decision worth reusing across FUTURE sessions
  (never task progress — that's `report_progress`/issue notes); `recall`
  before starting unfamiliar work, to check whether a relevant memory
  already exists. `update_memory`/`retire_memory`/`verify_memory`/
  `merge_memories`/`list_memories` round out maintenance: correcting,
  soft-deleting, re-confirming, deduping, and browsing.

  Every write scopes the memory to `app: "orcahub"` and this session's
  project (`id`/`name`/`slug`, `slug` derived from the project's directory)
  plus `session_id`/`backend`/`node`/`created_by: "agent"` — the caller
  never supplies these.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{HubRPC, MemoryClient}

  @kinds ~w(fact preference procedure episode decision reference profile)
  @visibilities ~w(project global shared)

  def list do
    [
      %{
        "name" => "remember",
        "description" =>
          "Save a durable memory — a fact, preference, procedure, or decision worth " <>
            "reusing across FUTURE sessions (e.g. \"the deploy script lives at X\", \"the " <>
            "user prefers Y\", \"we chose Z because W\"). Do NOT use this for task " <>
            "progress, TODOs, or anything ephemeral to the current turn — use " <>
            "report_progress or issue notes for that instead. The response includes " <>
            "`near_duplicates`: if one of those is really the same fact, call " <>
            "update_memory on it instead of creating a duplicate.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "text" => %{
              "type" => "string",
              "description" => "The memory itself. Atomic — one fact per memory, 1-4 sentences."
            },
            "kind" => %{
              "type" => "string",
              "enum" => @kinds,
              "description" => "What kind of memory this is."
            },
            "hook" => %{
              "type" => "string",
              "description" =>
                "Optional one-line summary (<= 120 chars). Defaults to text's first sentence."
            },
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "importance" => %{
              "type" => "integer",
              "description" => "1-5, default 3."
            },
            "pinned" => %{
              "type" => "boolean",
              "description" =>
                "If true, this memory is always injected at session start (default false)."
            },
            "visibility" => %{
              "type" => "string",
              "enum" => @visibilities,
              "description" =>
                "\"project\" (default, recallable only in this project), \"global\" " <>
                  "(any project of this app), or \"shared\" (any app)."
            },
            "source" => %{
              "type" => "object",
              "description" => "Optional provenance: commits, issue_key, paths, url."
            },
            "valid_until" => %{
              "type" => "string",
              "description" => "Optional ISO8601 expiry."
            }
          },
          "required" => ["text", "kind"]
        }
      },
      %{
        "name" => "recall",
        "description" =>
          "Search saved memories. Use this BEFORE starting unfamiliar work — a subsystem " <>
            "you haven't touched, or a decision that might already have a documented " <>
            "precedent. Searches this project's memories plus global/shared ones by " <>
            "default.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "What to search for."},
            "kinds" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => @kinds},
              "description" => "Optionally narrow to these kinds."
            },
            "include_other_projects" => %{
              "type" => "boolean",
              "description" =>
                "Also search other projects' project-scoped memories (default false)."
            },
            "limit" => %{"type" => "integer", "description" => "Default 10."}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "update_memory",
        "description" =>
          "Update fields on an existing memory — e.g. after re-confirming it, or " <>
            "refining its text/tags/importance. Only pass the fields you want changed.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "The memory's id."},
            "text" => %{"type" => "string"},
            "hook" => %{"type" => "string"},
            "kind" => %{"type" => "string", "enum" => @kinds},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "importance" => %{"type" => "integer"},
            "confidence" => %{"type" => "number"},
            "pinned" => %{"type" => "boolean"},
            "visibility" => %{"type" => "string", "enum" => @visibilities},
            "valid_until" => %{"type" => "string"},
            "source" => %{"type" => "object"}
          },
          "required" => ["id"]
        }
      },
      %{
        "name" => "retire_memory",
        "description" =>
          "Soft-retire a memory that's no longer true or has been superseded — never a " <>
            "hard delete. Use this instead of remembering a contradiction on top of it.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "The memory's id."},
            "reason" => %{"type" => "string", "description" => "Why it's being retired."},
            "superseded_by" => %{
              "type" => "string",
              "description" => "Optional id of the memory that replaces it."
            }
          },
          "required" => ["id", "reason"]
        }
      },
      %{
        "name" => "verify_memory",
        "description" =>
          "Mark a memory as freshly re-confirmed (bumps last_verified_at) without " <>
            "changing its content. Use after checking that an old memory is still accurate.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string", "description" => "The memory's id."}},
          "required" => ["id"]
        }
      },
      %{
        "name" => "merge_memories",
        "description" =>
          "Combine several related or duplicate memories into one, superseding the " <>
            "originals. Use when recall/remember's near_duplicates surface overlapping " <>
            "memories that should really be a single one.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "source_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "The memories being merged (and superseded)."
            },
            "text" => %{"type" => "string", "description" => "The merged memory's text."},
            "kind" => %{"type" => "string", "enum" => @kinds},
            "hook" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "importance" => %{"type" => "integer"},
            "visibility" => %{"type" => "string", "enum" => @visibilities}
          },
          "required" => ["source_ids", "text", "kind"]
        }
      },
      %{
        "name" => "list_memories",
        "description" =>
          "List/browse this project's memories with filters — for maintenance/auditing " <>
            "what's remembered. Use recall instead for normal \"do we know anything about " <>
            "X\" search.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "kind" => %{"type" => "string", "enum" => @kinds},
            "status" => %{"type" => "string", "enum" => ~w(active superseded retired)},
            "pinned" => %{"type" => "boolean"},
            "tag" => %{"type" => "string"},
            "sort" => %{"type" => "string", "enum" => ~w(updated_at times_recalled)},
            "page" => %{"type" => "integer"},
            "per_page" => %{"type" => "integer"}
          }
        }
      }
    ]
  end

  def call("remember", args, state) do
    with_calling_session(state, fn session_id, session ->
      do_remember(session_id, session, args)
    end)
  end

  def call("recall", args, state) do
    with_calling_session(state, fn _session_id, session ->
      do_recall(session, args)
    end)
  end

  def call("update_memory", args, _state) do
    case blank_to_nil(args["id"]) do
      nil -> error("update_memory requires a non-empty `id` string argument.")
      id -> do_update(id, args)
    end
  end

  def call("retire_memory", args, _state) do
    with {:ok, id} <- require_field(args, "id"),
         {:ok, reason} <- require_field(args, "reason") do
      opts =
        case blank_to_nil(args["superseded_by"]) do
          nil -> []
          val -> [superseded_by: val]
        end

      handle_result(MemoryClient.retire(id, reason, opts))
    else
      {:error, reason} -> error(reason)
    end
  end

  def call("verify_memory", args, _state) do
    case blank_to_nil(args["id"]) do
      nil -> error("verify_memory requires a non-empty `id` string argument.")
      id -> handle_result(MemoryClient.verify(id))
    end
  end

  def call("merge_memories", args, _state) do
    with {:ok, source_ids} <- require_list(args, "source_ids"),
         {:ok, text} <- require_field(args, "text"),
         {:ok, kind} <- require_field(args, "kind") do
      attrs =
        %{"text" => text, "kind" => kind}
        |> maybe_put_field("hook", blank_to_nil(args["hook"]))
        |> maybe_put_field("tags", args["tags"])
        |> maybe_put_field("importance", args["importance"])
        |> maybe_put_field("visibility", blank_to_nil(args["visibility"]))

      handle_result(MemoryClient.merge(source_ids, attrs))
    else
      {:error, reason} -> error(reason)
    end
  end

  def call("list_memories", args, state) do
    with_calling_session(state, fn _session_id, session ->
      params =
        %{"project_slug" => project_slug(session)}
        |> maybe_put_field("kind", blank_to_nil(args["kind"]))
        |> maybe_put_field("status", blank_to_nil(args["status"]))
        |> maybe_put_field("pinned", args["pinned"])
        |> maybe_put_field("tag", blank_to_nil(args["tag"]))
        |> maybe_put_field("sort", blank_to_nil(args["sort"]))
        |> maybe_put_field("page", args["page"])
        |> maybe_put_field("per_page", args["per_page"])

      handle_result(MemoryClient.list(params))
    end)
  end

  # -------------------------------------------------------------------
  # remember
  # -------------------------------------------------------------------

  defp do_remember(session_id, session, args) do
    with {:ok, text} <- require_field(args, "text"),
         {:ok, kind} <- require_field(args, "kind") do
      attrs =
        %{
          "text" => text,
          "kind" => kind,
          "app" => "orcahub",
          "project" => resolve_project(session),
          "session_id" => session_id,
          "backend" => session.backend,
          "node" => session.runner_node || to_string(Node.self()),
          "created_by" => "agent"
        }
        |> maybe_put_field("hook", blank_to_nil(args["hook"]))
        |> maybe_put_field("tags", args["tags"])
        |> maybe_put_field("importance", args["importance"])
        |> maybe_put_field("pinned", args["pinned"])
        |> maybe_put_field("visibility", blank_to_nil(args["visibility"]))
        |> maybe_put_field("source", args["source"])
        |> maybe_put_field("valid_until", blank_to_nil(args["valid_until"]))

      case MemoryClient.remember(attrs) do
        {:ok, %{"memory" => memory} = resp} ->
          near_duplicates = resp["near_duplicates"] || []

          result =
            %{"memory" => slim_memory(memory), "near_duplicates" => near_duplicates}
            |> maybe_put_field(
              "hint",
              if(near_duplicates != [],
                do:
                  "If one of these near_duplicates is the same fact, call update_memory " <>
                    "on it instead of creating a duplicate."
              )
            )

          text(Jason.encode!(result))

        other ->
          handle_result(other)
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp resolve_project(%{project_id: project_id}) when is_binary(project_id) do
    case HubRPC.get_project(project_id) do
      nil -> %{"name" => "unknown", "slug" => "unknown"}
      project -> %{"id" => project.id, "name" => project.name, "slug" => slug(project.directory)}
    end
  end

  defp resolve_project(%{directory: directory}) do
    name = directory && Path.basename(directory)
    %{"name" => name || "unknown", "slug" => slug(directory || "unknown")}
  end

  defp slug(nil), do: "unknown"
  defp slug(directory), do: String.replace(directory, ~r/[^a-zA-Z0-9]/, "-")

  defp project_slug(session), do: resolve_project(session)["slug"]

  defp slim_memory(memory) when is_map(memory) do
    Map.take(memory, ~w(id text hook kind tags importance confidence pinned status visibility))
  end

  defp slim_memory(other), do: other

  # -------------------------------------------------------------------
  # recall
  # -------------------------------------------------------------------

  defp do_recall(session, args) do
    with {:ok, query} <- require_field(args, "query") do
      params =
        %{
          "query" => query,
          "project_slug" => project_slug(session),
          "include_global" => true,
          "include_shared" => true,
          "include_other_projects" => args["include_other_projects"] || false
        }
        |> maybe_put_field("kinds", args["kinds"])
        |> maybe_put_field("limit", args["limit"])

      handle_result(MemoryClient.search(params))
    else
      {:error, reason} -> error(reason)
    end
  end

  # -------------------------------------------------------------------
  # update_memory
  # -------------------------------------------------------------------

  defp do_update(id, args) do
    attrs =
      %{}
      |> maybe_put_field("text", blank_to_nil(args["text"]))
      |> maybe_put_field("hook", blank_to_nil(args["hook"]))
      |> maybe_put_field("kind", blank_to_nil(args["kind"]))
      |> maybe_put_field("tags", args["tags"])
      |> maybe_put_field("importance", args["importance"])
      |> maybe_put_field("confidence", args["confidence"])
      |> maybe_put_field("pinned", args["pinned"])
      |> maybe_put_field("visibility", blank_to_nil(args["visibility"]))
      |> maybe_put_field("valid_until", blank_to_nil(args["valid_until"]))
      |> maybe_put_field("source", args["source"])

    if attrs == %{} do
      error("update_memory requires at least one field to update besides `id`.")
    else
      handle_result(MemoryClient.update(id, attrs))
    end
  end

  # -------------------------------------------------------------------
  # Shared
  # -------------------------------------------------------------------

  defp with_calling_session(state, fun) do
    case state[:orca_session_id] do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      session_id ->
        case HubRPC.get_session(session_id) do
          nil -> error("Session #{session_id} not found (may have been deleted).")
          session -> fun.(session_id, session)
        end
    end
  end

  defp handle_result({:ok, result}), do: text(Jason.encode!(result))
  defp handle_result({:error, :disabled}), do: error(disabled_message())

  defp handle_result({:error, {:http_error, status, body}}),
    do: error("Memory service returned HTTP #{status}: #{inspect(body)}")

  defp handle_result({:error, reason}),
    do: error("Memory service call failed: #{inspect(reason)}")

  defp disabled_message,
    do:
      "Memory service is not configured on the hub (MEMORY_SERVICE_URL/MEMORY_SERVICE_TOKEN " <>
        "unset) — memory tools are unavailable."

  defp require_field(args, key) do
    case blank_to_nil(args[key]) do
      nil -> {:error, "#{key} is required and cannot be empty."}
      val -> {:ok, val}
    end
  end

  defp require_list(args, key) do
    case args[key] do
      list when is_list(list) and list != [] -> {:ok, list}
      _ -> {:error, "#{key} is required and must be a non-empty array."}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(str) when is_binary(str), do: if(String.trim(str) == "", do: nil, else: str)
  defp blank_to_nil(other), do: other
end
