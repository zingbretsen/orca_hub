defmodule OrcaHub.MemoryExtraction do
  @moduledoc """
  Automatic memory extraction: on a session's natural "end of work" (archive,
  or a streaming warm port going cold via the 15-minute idle timeout — never
  a mere turn-end idle transition, which would be far too noisy), spawn a
  cheap child session that reads the new transcript since the last
  extraction and decides what's worth remembering long-term via the
  existing `remember`/`recall`/`update_memory` memory tools
  (`OrcaHub.MCP.Tools.Memory`).

  The intelligence lives in the spawned agent session, not here — this
  module's job is scope/threshold gating, building the transcript slice and
  prompt, spawning the child, and reporting back to the source session's
  message feed when the child finishes. It never raises to its callers
  (`OrcaHub.SessionRunner`'s idle-teardown handlers, `OrcaHub.Sessions.archive_session/2`):
  every failure is caught, logged, and returned as `{:error, _}`.

  ## Scope (`in_scope?/1`)

  By default: `orchestrator == true` OR `parent_session_id == nil` (a root,
  human-driven session). Child worker sessions are skipped — they may have
  gone off the rails, and their content is usually redundant with what the
  orchestrator itself will extract. `session.memory_extract` is a per-session
  override: `nil` (default) applies the rule above, `true`/`false` force it
  on/off. `dispatch/2`'s `force: true` (the on-demand `extract_memories` MCP
  tool) bypasses this rule entirely.

  ## Threshold + watermark

  `session.memory_extracted_at` is a watermark — only `"user"`/`"assistant"`
  messages inserted after it are considered. Below 2 user turns or 600 chars
  of new text, dispatch is a silent no-op (one debug log line, no spawn) —
  unless `force: true`, which still uses the watermark but ignores the size
  threshold. The watermark is set the moment extraction is DISPATCHED, not
  when the child finishes, so an idle-teardown followed by an archive a few
  minutes later can't double-extract the same window.
  """

  require Logger

  alias OrcaHub.{AgentMemory, Cluster, HubRPC, MemoryClient}

  @default_model "claude-haiku-4-5-20251001"
  @min_user_turns 2
  @min_chars 600
  @per_message_chars 4_000
  @slice_cap_chars 40_000
  @hooks_per_page 100
  @completion_timeout :timer.minutes(30)

  @doc """
  Dispatch extraction for `session`, unless out of scope (see moduledoc) or
  below the new-content threshold — both skippable via `opts[:force]`.
  Fire-and-forget: spawns the extraction child and a completion watcher,
  then returns. Never raises.

  `opts`:
    - `:force` — bypass the scope rule and the size threshold.
    - `:trigger` — atom, logging only (`:archive` | `:idle_teardown` | `:manual`).
  """
  def dispatch(session, opts \\ [])

  def dispatch(session, opts) do
    force? = Keyword.get(opts, :force, false)
    trigger = Keyword.get(opts, :trigger, :manual)

    cond do
      not MemoryClient.enabled?() ->
        {:ok, :skipped}

      not force? and not in_scope?(session) ->
        Logger.debug(
          "MemoryExtraction: session #{session.id} out of scope for trigger #{trigger}, skipping"
        )

        {:ok, :skipped}

      true ->
        do_dispatch(session, force?, trigger)
    end
  rescue
    e ->
      Logger.warning(
        "MemoryExtraction.dispatch failed for session #{session.id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  # The default scope rule (see moduledoc). Pure — a test seam.
  @doc false
  def in_scope?(%{memory_extract: override}) when is_boolean(override), do: override
  def in_scope?(%{orchestrator: true}), do: true
  def in_scope?(%{parent_session_id: nil}), do: true
  def in_scope?(_), do: false

  defp do_dispatch(session, force?, trigger) do
    since = session.memory_extracted_at
    rows = HubRPC.list_messages_since(session.id, since)

    case decide(rows, force?) do
      {:skip, :empty} ->
        Logger.debug(
          "MemoryExtraction: session #{session.id} has no new user/assistant content since " <>
            "watermark, skipping (trigger: #{trigger})"
        )

        {:ok, :skipped}

      {:skip, :below_threshold} ->
        Logger.debug(
          "MemoryExtraction: session #{session.id} below extraction threshold, skipping " <>
            "(trigger: #{trigger})"
        )

        {:ok, :skipped}

      {:dispatch, entries} ->
        spawn_extraction(session, entries, trigger)
    end
  end

  # Pure decision over raw message `data` rows — a test seam independent of
  # the DB/HubRPC. Returns `{:skip, :empty | :below_threshold} | {:dispatch, entries}`.
  @doc false
  def decide(rows, force?) do
    entries = build_entries(rows)

    user_turns =
      Enum.count(rows, fn row -> row["type"] == "user" and extract_text(row) != "" end)

    total_chars = Enum.reduce(entries, 0, fn entry, acc -> acc + String.length(entry) end)

    cond do
      entries == [] ->
        {:skip, :empty}

      not force? and (user_turns < @min_user_turns or total_chars < @min_chars) ->
        {:skip, :below_threshold}

      true ->
        {:dispatch, entries}
    end
  end

  # -------------------------------------------------------------------
  # Transcript slice (pure — test seam)
  # -------------------------------------------------------------------

  # Renders raw "user"/"assistant" message `data` rows (oldest first) into
  # "User: ..."/"Assistant: ..." lines — tool_use blocks become [tool: Name]
  # markers, tool_result/thinking blocks are dropped entirely, and a "user"
  # row with no text blocks (a pure tool-result echo) is dropped rather than
  # rendered as an empty turn. Each line is capped at @per_message_chars
  # chars. NOT yet capped to the total slice budget — see cap_total/2.
  @doc false
  def build_entries(rows) do
    rows
    |> Enum.map(&render_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp render_entry(%{"type" => "user"} = data) do
    case extract_text(data) do
      "" -> nil
      text -> "User: " <> truncate(text, @per_message_chars)
    end
  end

  defp render_entry(%{"type" => "assistant"} = data) do
    text =
      data
      |> get_in(["message", "content"])
      |> List.wrap()
      |> Enum.map(&render_assistant_block/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    case text do
      "" -> nil
      _ -> "Assistant: " <> truncate(text, @per_message_chars)
    end
  end

  defp render_entry(_), do: nil

  defp render_assistant_block(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp render_assistant_block(%{"type" => "tool_use", "name" => name}), do: "[tool: #{name}]"
  defp render_assistant_block(_), do: nil

  defp extract_text(data) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "…[truncated]"
    else
      text
    end
  end

  # Caps a chronologically-ordered (oldest-first) list of rendered entries to
  # `cap` total chars, dropping from the OLDEST end first — the most recent
  # entries always survive. Always keeps at least the single newest entry,
  # even if it alone exceeds `cap`.
  @doc false
  def cap_total(entries, cap) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn entry, {acc, len} ->
      entry_len = String.length(entry)

      cond do
        acc == [] -> {:cont, {[entry], entry_len}}
        len + entry_len > cap -> {:halt, {acc, len}}
        true -> {:cont, {[entry | acc], len + entry_len}}
      end
    end)
    |> elem(0)
  end

  # -------------------------------------------------------------------
  # Spawn + prompt
  # -------------------------------------------------------------------

  defp spawn_extraction(session, entries, trigger) do
    runner_node = Cluster.runner_node_for(session)

    cond do
      is_nil(runner_node) ->
        Logger.warning("MemoryExtraction: session #{session.id} has no runner_node, skipping")
        {:error, :no_runner_node}

      not Cluster.node_available?(runner_node) ->
        Logger.warning(
          "MemoryExtraction: node #{inspect(runner_node)} unavailable for source session " <>
            "#{session.id}, skipping (trigger: #{trigger})"
        )

        {:error, :node_unavailable}

      true ->
        do_spawn_extraction(session, entries, runner_node, trigger)
    end
  end

  defp do_spawn_extraction(session, entries, runner_node, trigger) do
    # Watermark advances the moment we commit to dispatching — see moduledoc.
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    HubRPC.update_session(session, %{memory_extracted_at: now})

    slug = AgentMemory.slugify(session.directory)
    hooks = existing_hooks(slug)
    transcript = entries |> cap_total(@slice_cap_chars) |> Enum.join("\n\n")
    prompt = build_prompt(transcript, hooks, session)

    attrs = %{
      directory: session.directory,
      project_id: session.project_id,
      runner_node: Atom.to_string(runner_node),
      title: "Memory extraction: #{session.title || "untitled"}",
      backend: "claude",
      model: Application.get_env(:orca_hub, :memory_extraction_model, @default_model),
      orchestrator: false,
      code_exec: true,
      notify_parent: false,
      parent_session_id: session.id,
      # Forced off regardless of the scope rule — an extraction child must
      # never itself trigger extraction (also true independently: it's a
      # non-orchestrator child, so in_scope?/1 would already say no).
      memory_extract: false,
      status: "ready"
    }

    case HubRPC.create_session(attrs) do
      {:ok, child} ->
        case Cluster.start_session(runner_node, child.id, child) do
          {:ok, _} ->
            Cluster.send_message(runner_node, child.id, prompt, :queue)
            watch_and_report(child.id, session.id, trigger)
            {:ok, :dispatched}

          {:error, reason} ->
            Logger.warning(
              "MemoryExtraction: failed to start extraction session #{child.id} for source " <>
                "#{session.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, changeset} ->
        Logger.warning(
          "MemoryExtraction: failed to create extraction session for source #{session.id}: " <>
            "#{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp existing_hooks(slug) do
    case MemoryClient.list(%{"project_slug" => slug, "per_page" => @hooks_per_page}) do
      {:ok, %{"memories" => memories}} when is_list(memories) -> memories
      {:ok, memories} when is_list(memories) -> memories
      _ -> []
    end
    |> Enum.map(&memory_hook/1)
  end

  defp memory_hook(%{"hook" => hook}) when is_binary(hook) and hook != "", do: hook
  defp memory_hook(%{"text" => text}) when is_binary(text), do: truncate(text, 80)
  defp memory_hook(_), do: "(untitled memory)"

  @doc false
  def build_prompt(transcript, existing_hooks, source_session) do
    hooks_block =
      case existing_hooks do
        [] -> "(none yet for this project)"
        hooks -> Enum.map_join(hooks, "\n", &"- #{&1}")
      end

    """
    # Memory Extraction

    You are a background memory-extraction agent. Your ONLY job this turn is to \
    review the transcript slice below from OrcaHub session #{source_session.id} \
    (directory: #{source_session.directory}) and decide what — if anything — is \
    worth remembering across FUTURE sessions in this project.

    ## Existing memory hooks for this project

    #{hooks_block}

    ## What to save

    Call `Tools.remember(...)` for any durable fact, preference, procedure, \
    decision, or notable episode that would help a future session — NEVER task \
    progress, TODOs, or anything ephemeral to this one conversation. Be \
    CONSERVATIVE about merging into or retiring an existing memory (only do so \
    when you're confident it's genuinely the same fact) and LIBERAL about \
    capturing genuinely new durable facts. If something is already covered by \
    an existing hook above, call `Tools.update_memory(...)` on it to enrich or \
    re-confirm instead of creating a duplicate. Every `Tools.remember(...)` \
    call you make MUST include `"created_by" => "extraction"` and `"source" \
    => %{"session_id" => "#{source_session.id}"}`.

    When you're done — including if you decide there's nothing worth saving — \
    end your turn with a one-paragraph summary of what you saved and why.

    ## Transcript slice (oldest to newest; tool calls reduced to [tool: name] markers)

    #{transcript}
    """
    |> String.trim()
  end

  # -------------------------------------------------------------------
  # Completion watcher + visibility (mirrors
  # OrcaHub.TriggerExecutor's subscribe_for_completion/wait_for_completion)
  # -------------------------------------------------------------------

  defp watch_and_report(child_id, source_id, trigger) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{child_id}")
      await_completion(child_id, source_id, trigger)
    end)
  end

  defp await_completion(child_id, source_id, trigger) do
    receive do
      {:status, status} when status in [:idle, :error] ->
        finalize(child_id, source_id, status)

      _ ->
        await_completion(child_id, source_id, trigger)
    after
      @completion_timeout ->
        Logger.warning(
          "MemoryExtraction: extraction session #{child_id} (source #{source_id}, trigger " <>
            "#{trigger}) timed out waiting for completion"
        )
    end
  end

  defp finalize(child_id, source_id, status) do
    source = HubRPC.get_session(source_id)
    if source, do: post_visibility_message(source, child_id, status)

    case HubRPC.get_session(child_id) do
      nil -> :ok
      child -> HubRPC.archive_session(child, extract_memories: false)
    end
  rescue
    e ->
      Logger.warning(
        "MemoryExtraction: failed to finalize extraction session #{child_id} (source " <>
          "#{source_id}): #{Exception.message(e)}"
      )
  end

  # `message` here is shown as-is after the "Memory extraction" label the
  # system_message component derives from `subtype` (message_components.ex) —
  # it must NOT repeat that prefix itself.
  defp post_visibility_message(source, child_id, :error) do
    persist_system_message(source.id, "failed — see session #{child_id} for details.")
  end

  defp post_visibility_message(source, _child_id, :idle) do
    memories = extracted_memories(source)
    persist_system_message(source.id, extraction_summary(memories))
  end

  defp extracted_memories(source) do
    slug = AgentMemory.slugify(source.directory)

    case MemoryClient.list(%{
           "project_slug" => slug,
           "per_page" => @hooks_per_page,
           "sort" => "updated_at"
         }) do
      {:ok, %{"memories" => memories}} when is_list(memories) -> memories
      {:ok, memories} when is_list(memories) -> memories
      _ -> []
    end
    |> Enum.filter(fn m ->
      m["created_by"] == "extraction" and get_in(m, ["source", "session_id"]) == source.id
    end)
  end

  defp extraction_summary([]), do: "no new memories"

  defp extraction_summary(memories) do
    count = length(memories)
    hooks = memories |> Enum.map(&memory_hook/1) |> Enum.join("; ")
    noun = if count == 1, do: "memory", else: "memories"
    "#{count} #{noun} saved (#{hooks})"
  end

  # Direct persistence, not a real turn: this must NOT go through
  # send_message_to_session (which would auto-unarchive an archived source
  # and queue a live turn) — it's the same "write a message, broadcast it"
  # shape SessionRunner itself uses for system-level events like a turn
  # error, just invoked from outside a runner process.
  defp persist_system_message(session_id, message) do
    event = %{
      "type" => "system",
      "subtype" => "memory_extraction",
      "message" => message,
      "timestamp" => NaiveDateTime.utc_now()
    }

    HubRPC.create_message(%{session_id: session_id, data: event})
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", {:event, event})
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session_id, {:event, event}})
  end
end
