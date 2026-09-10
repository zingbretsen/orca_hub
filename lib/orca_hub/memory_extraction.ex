defmodule OrcaHub.MemoryExtraction do
  @moduledoc """
  Automatic memory extraction: on a session's natural "end of work" —
  archiving, or an on-demand `extract_memories` tool call — spawn a cheap
  child session that reads the new (human + assistant text only) transcript
  since the last extraction and decides what's worth remembering long-term
  via the existing `remember`/`recall`/`update_memory` memory tools
  (`OrcaHub.MCP.Tools.Memory`).

  Deliberately NOT hooked into any `OrcaHub.SessionRunner` state transition
  — a streaming session's warm port going cold on the 15-minute idle timer
  was considered and rejected (it says nothing about whether the
  conversation is actually done, and would fire far too often). The two
  triggers today are `OrcaHub.Sessions.archive_session/2` (default on) and
  the orchestrator-only `extract_memories` MCP tool (always forced). A
  future scheduled sweep — not yet implemented — is expected to call
  `dispatch/2`/`dispatch_many/2` directly for every eligible session with
  new content past its watermark, rather than adding another SessionRunner
  hook.

  The intelligence lives in the spawned agent session, not here — this
  module's job is scope/threshold gating, building the transcript, writing
  it to a file on the source session's own node (see "Transcript delivery"
  below), spawning the child, and reporting back to the source session's
  message feed when the child finishes. It never raises to its callers:
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
  messages inserted after it are considered, and only their genuine human/
  assistant TEXT (see "Transcript content" below). Below 2 user turns or 600
  chars of new text, dispatch is a silent no-op (one debug log line, no
  spawn) — unless `force: true`, which still uses the watermark but ignores
  the size threshold. The watermark is set the moment extraction is
  DISPATCHED, not when the child finishes, so two triggers landing within
  minutes of each other can't double-extract the same window.

  ## Transcript content

  Tool calls and tool results are dropped entirely — no inline `[tool: ...]`
  markers either, just the human's and the assistant's own words. Messages
  the HUB itself injected rather than a genuine human are also dropped:
  heartbeat wake-ups, `[Session lifecycle]`, `[Worker alert]`,
  `[Message from session ...]`/`[Message from another session]` (another,
  possibly off-the-rails, session's words — not this human's), and
  `[Message delivery note]`. There's no structured provenance marker on a
  message distinguishing these from genuine human text (every one of them
  is just a plain "user" turn with a recognizable text prefix), so this is
  prefix matching, not a `data` field check — see `automated_prefix?/1`.
  `[Artifact "..." interaction]` messages ARE included — that's the human's
  own input via an artifact's UI, not a hub notification.

  ## Transcript delivery

  Unlike an early design that inlined a capped transcript into the child's
  prompt, the (unbounded, un-truncated) filtered transcript is written to a
  markdown file on the SOURCE session's own node/directory —
  `<directory>/.agents/memory-extraction/<source_session_id>.md` — chunked
  into `## Part N of M` sections of roughly 12k chars each, with a header
  (session id/title/directory, extraction time, existing memory hooks) up
  top. The prompt just points the child at this path; the child reads it
  with its own Read tool, part by part, and only calls `remember`/
  `update_memory` once it's seen the whole thing. The file is written (and
  later deleted, once the child is done) via `Cluster.rpc/5` so the actual
  disk I/O always happens on the right node regardless of which node
  `dispatch/2` itself runs on.

  ## Model fallback

  The extraction child's backend/model (`:memory_extraction_backend`/
  `:memory_extraction_model` app env, `MEMORY_EXTRACTION_BACKEND`/
  `MEMORY_EXTRACTION_MODEL` at runtime — see `config/runtime.exs`) may be
  configured to something other than the Claude/Haiku default, e.g. a local
  pi model. If that first turn errors out before making a single tool call
  (the "model isn't loaded"/HTTP 400 signature of a misconfigured or
  unavailable local endpoint), the archived failed attempt is retried
  EXACTLY ONCE using the hardcoded Claude/Haiku default, logged loudly. A
  session that already used the default, or that made at least one tool
  call before erroring, is never retried.
  """

  require Logger

  alias OrcaHub.{AgentMemory, Cluster, HubRPC, MemoryClient}

  @fallback_backend "claude"
  @fallback_model "claude-haiku-4-5-20251001"
  @min_user_turns 2
  @min_chars 600
  @chunk_chars 12_000
  @hooks_per_page 100
  @completion_timeout :timer.minutes(30)

  # Plain-text prefixes the hub itself injects into what otherwise looks
  # like an ordinary "user" turn — see moduledoc's "Transcript content".
  # Deliberately NOT `[Artifact` — an artifact interaction is genuine human
  # input and must stay in the transcript.
  @automated_prefixes [
    "[Session lifecycle]",
    "[Worker alert]",
    "[Message from session ",
    "[Message from another session]",
    "[Message delivery note]",
    "[Message delivery note - escalated]",
    "[Heartbeat]",
    "[System]"
  ]

  @doc """
  Dispatch extraction for `session`, unless out of scope (see moduledoc) or
  below the new-content threshold — both skippable via `opts[:force]`.
  Fire-and-forget: spawns the extraction child and a completion watcher,
  then returns. Never raises.

  `opts`:
    - `:force` — bypass the scope rule and the size threshold.
    - `:trigger` — atom, logging only (`:archive` | `:manual` | whatever a
      future scheduled sweep names itself).
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

  @doc """
  Dispatch extraction for each of `sessions` — the seam a future scheduled
  sweep (not yet implemented, see moduledoc) will call for every session
  with new content past its watermark. Each call is independently rescued
  by `dispatch/2` itself, so one bad session can't stop the batch. Returns
  `[{session_id, dispatch/2's result}]`.
  """
  def dispatch_many(sessions, opts \\ []) do
    Enum.map(sessions, fn session -> {session.id, dispatch(session, opts)} end)
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
  # Transcript (pure — test seam)
  # -------------------------------------------------------------------

  # Renders raw "user"/"assistant" message `data` rows (oldest first) into
  # "User: ..."/"Assistant: ..." lines — text blocks ONLY, no tool_use/
  # tool_result/thinking content and no "[tool: ...]" markers (see
  # moduledoc's "Transcript content"). A "user" row with no text blocks (a
  # pure tool-result echo) or whose text is a hub-injected notification
  # (automated_prefix?/1) is dropped rather than rendered.
  @doc false
  def build_entries(rows) do
    rows
    |> Enum.map(&render_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp render_entry(%{"type" => "user"} = data) do
    case extract_text(data) do
      "" -> nil
      text -> if automated_prefix?(text), do: nil, else: "User: " <> text
    end
  end

  defp render_entry(%{"type" => "assistant"} = data) do
    case extract_text(data) do
      "" -> nil
      text -> "Assistant: " <> text
    end
  end

  defp render_entry(_), do: nil

  defp extract_text(data) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  defp automated_prefix?(text) do
    trimmed = String.trim_leading(text)
    Enum.any?(@automated_prefixes, &String.starts_with?(trimmed, &1))
  end

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "…[truncated]"
    else
      text
    end
  end

  # Partitions a chronologically-ordered (oldest-first) list of entries into
  # chunks of roughly `chunk_size` chars each — the WHOLE list is preserved
  # (unlike the old cap_total/2, nothing is dropped), just grouped for
  # "## Part N of M" file sections. Always makes forward progress even on a
  # single entry bigger than `chunk_size` (it becomes its own chunk).
  @doc false
  def chunk_entries([], _chunk_size), do: []

  def chunk_entries(entries, chunk_size) do
    {chunks, last, _len} =
      Enum.reduce(entries, {[], [], 0}, fn entry, {chunks, current, len} ->
        entry_len = String.length(entry)

        cond do
          current == [] -> {chunks, [entry], entry_len}
          len + entry_len > chunk_size -> {chunks ++ [Enum.reverse(current)], [entry], entry_len}
          true -> {chunks, [entry | current], len + entry_len}
        end
      end)

    chunks ++ [Enum.reverse(last)]
  end

  @doc false
  def transcript_file_path(session) do
    Path.join([session.directory, ".agents", "memory-extraction", "#{session.id}.md"])
  end

  # Builds the full markdown file content: header (id/title/directory/time,
  # existing hooks) + chunked "## Part N of M" transcript sections.
  @doc false
  def build_transcript_file(entries, existing_hooks, source_session) do
    chunks = chunk_entries(entries, @chunk_chars)
    total = length(chunks)

    parts =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, idx} ->
        "## Part #{idx} of #{total}\n\n" <> Enum.join(chunk, "\n\n")
      end)

    transcript_header(existing_hooks, source_session) <> "\n\n" <> parts
  end

  defp transcript_header(existing_hooks, source_session) do
    hooks_block =
      case existing_hooks do
        [] -> "(none yet for this project)"
        hooks -> Enum.map_join(hooks, "\n", &"- #{&1}")
      end

    """
    # Memory Extraction Transcript

    Session: #{source_session.id}
    Title: #{source_session.title || "(untitled)"}
    Directory: #{source_session.directory}
    Extracted: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}

    ## Existing memory hooks for this project

    #{hooks_block}
    """
    |> String.trim()
  end

  # RPC entry points (Cluster.rpc/5 needs a real exported function on the
  # target node) — actual disk I/O, always executed on the source session's
  # own node via write_transcript_file!/2 / delete_transcript_file/1 below.
  @doc false
  def write_transcript_file!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    :ok
  end

  @doc false
  def delete_transcript_file(path) do
    File.rm(path)
    :ok
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
    file_path = transcript_file_path(session)
    file_content = build_transcript_file(entries, hooks, session)

    case Cluster.rpc(runner_node, __MODULE__, :write_transcript_file!, [file_path, file_content]) do
      :ok ->
        ctx = %{
          source: session,
          runner_node: runner_node,
          trigger: trigger,
          file_path: file_path,
          prompt: build_prompt(file_path, hooks, session),
          backend: Application.get_env(:orca_hub, :memory_extraction_backend, @fallback_backend),
          model: Application.get_env(:orca_hub, :memory_extraction_model, @fallback_model),
          retried?: false
        }

        spawn_child(ctx)

      {:error, reason} ->
        Logger.warning(
          "MemoryExtraction: failed to write transcript file for source #{session.id}: " <>
            "#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp spawn_child(ctx) do
    attrs = %{
      directory: ctx.source.directory,
      project_id: ctx.source.project_id,
      runner_node: Atom.to_string(ctx.runner_node),
      title: "Memory extraction: #{ctx.source.title || "untitled"}",
      backend: ctx.backend,
      model: ctx.model,
      orchestrator: false,
      code_exec: true,
      notify_parent: false,
      parent_session_id: ctx.source.id,
      # Forced off regardless of the scope rule — an extraction child must
      # never itself trigger extraction (also true independently: it's a
      # non-orchestrator child, so in_scope?/1 would already say no).
      memory_extract: false,
      status: "ready"
    }

    case HubRPC.create_session(attrs) do
      {:ok, child} ->
        case Cluster.start_session(ctx.runner_node, child.id, child) do
          {:ok, _} ->
            Cluster.send_message(ctx.runner_node, child.id, ctx.prompt, :queue)
            watch_and_report(child.id, ctx)
            {:ok, :dispatched}

          {:error, reason} ->
            Logger.warning(
              "MemoryExtraction: failed to start extraction session #{child.id} for source " <>
                "#{ctx.source.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, changeset} ->
        Logger.warning(
          "MemoryExtraction: failed to create extraction session for source #{ctx.source.id}: " <>
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
  def build_prompt(file_path, existing_hooks, source_session) do
    hooks_block =
      case existing_hooks do
        [] -> "(none yet for this project)"
        hooks -> Enum.map_join(hooks, "\n", &"- #{&1}")
      end

    """
    # Memory Extraction

    You are a background memory-extraction agent. Your ONLY job this turn is to \
    review the transcript for OrcaHub session #{source_session.id} (directory: \
    #{source_session.directory}) and decide what — if anything — is worth \
    remembering across FUTURE sessions in this project.

    The transcript is written to `#{file_path}`, split into `## Part N of M` \
    sections. Read the whole file with your Read tool (use offset/limit for \
    later parts if it's long) BEFORE deciding anything — keep a running \
    candidate list as you go, but don't call remember/update_memory until \
    you've seen every part.

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

    Weigh LATER messages over earlier ones: if the human pushed back on or \
    corrected something the assistant said, the CORRECTION is the memory (as a \
    preference or fact) — never the original, superseded claim. A decision \
    that was reversed later in the conversation is not a memory; only the \
    final state is. Distinguish "the human explicitly stated this" (high \
    confidence) from "the assistant merely asserted this" (lower confidence) \
    and set each memory's `importance`/tone accordingly.

    When you're done — including if you decide there's nothing worth saving — \
    end your turn with a one-paragraph summary of what you saved and why.
    """
    |> String.trim()
  end

  # -------------------------------------------------------------------
  # Completion watcher, model fallback, and visibility (mirrors
  # OrcaHub.TriggerExecutor's subscribe_for_completion/wait_for_completion)
  # -------------------------------------------------------------------

  defp watch_and_report(child_id, ctx) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{child_id}")
      await_completion(child_id, ctx)
    end)
  end

  defp await_completion(child_id, ctx) do
    receive do
      {:status, status} when status in [:idle, :error] ->
        finalize(child_id, status, ctx)

      _ ->
        await_completion(child_id, ctx)
    after
      @completion_timeout ->
        Logger.warning(
          "MemoryExtraction: extraction session #{child_id} (source #{ctx.source.id}, " <>
            "trigger #{ctx.trigger}) timed out waiting for completion"
        )
    end
  end

  defp finalize(child_id, :error, ctx) do
    if retryable_failure?(child_id, ctx) do
      Logger.warning(
        "MemoryExtraction: extraction session #{child_id} for source #{ctx.source.id} " <>
          "failed on its first turn using #{ctx.backend}/#{ctx.model} with no tool calls — " <>
          "retrying once with the default #{@fallback_backend}/#{@fallback_model}"
      )

      archive_child(child_id)
      spawn_child(%{ctx | backend: @fallback_backend, model: @fallback_model, retried?: true})
    else
      report_and_cleanup(child_id, :error, ctx)
    end
  rescue
    e ->
      Logger.warning(
        "MemoryExtraction: failed to finalize extraction session #{child_id} (source " <>
          "#{ctx.source.id}): #{Exception.message(e)}"
      )
  end

  defp finalize(child_id, :idle, ctx) do
    report_and_cleanup(child_id, :idle, ctx)
  rescue
    e ->
      Logger.warning(
        "MemoryExtraction: failed to finalize extraction session #{child_id} (source " <>
          "#{ctx.source.id}): #{Exception.message(e)}"
      )
  end

  defp retryable_failure?(_child_id, %{retried?: true}), do: false

  defp retryable_failure?(child_id, %{backend: backend, model: model}) do
    {backend, model} != {@fallback_backend, @fallback_model} and no_tool_calls?(child_id)
  end

  defp no_tool_calls?(child_id) do
    case HubRPC.session_tail(child_id, tool_call_limit: 1) do
      %{recent_tool_calls: []} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp report_and_cleanup(child_id, status, ctx) do
    source = HubRPC.get_session(ctx.source.id)
    if source, do: post_visibility_message(source, child_id, status)

    archive_child(child_id)
    Cluster.rpc(ctx.runner_node, __MODULE__, :delete_transcript_file, [ctx.file_path])
  end

  defp archive_child(child_id) do
    case HubRPC.get_session(child_id) do
      nil -> :ok
      child -> HubRPC.archive_session(child, extract_memories: false)
    end
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
