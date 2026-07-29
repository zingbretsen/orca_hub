defmodule OrcaHub.MCP.Tools.Discord do
  @moduledoc """
  MCP tools letting a Discord-bridged session interact with its channel
  out-of-band: posting (`send_discord_message`) and retroactively pulling in
  files it didn't already receive (`list_discord_attachments`,
  `fetch_discord_attachments`).

  `send_discord_message` fills the ONE write direction the bridge
  (`OrcaHub.Discord.Bridge`) was missing: it already auto-posts the session's
  final assistant text when the session goes idle (`Bridge.post_reply/3`),
  but had no way to send anything mid-turn, and no way at all to send
  attachments.

  `list_discord_attachments`/`fetch_discord_attachments` fill the OTHER gap:
  `Bridge` only ever auto-copies attachments off the message that @-mentioned
  the bot, so a file dropped in an untagged message (or one outside the
  history backfill window) was previously invisible to the session. These
  tools make retroactive retrieval agent-initiated instead of trying to grow
  the auto-copy surface — `fetch_discord_attachments` re-fetches the message
  fresh before downloading, since Discord CDN attachment URLs are signed and
  expire, so any URL captured at backfill time would already be dead.

  The MCP server for a session always runs on the session's own runner node,
  and Discord-bridged sessions always run on the Discord pod (the project's
  `node` is pinned there at provisioning time — see `Bridge`), so a LOCAL
  `Nostrum.Api` call from `call/3` is correct with no cross-node routing.
  """

  import OrcaHub.MCP.Tools.Result

  require Logger

  alias OrcaHub.Discord.{Bridge, FileFilter}
  alias OrcaHub.HubRPC

  # Discord's hard attachment-count limit, and a conservative total-size cap to
  # stay under Discord's default (non-boosted-server) 8MB per-file upload limit
  # even when several small files are sent together. This is a Discord API
  # upload constraint, not a FileFilter abuse-prevention policy, so it stays
  # local — but the comparison itself still delegates to
  # `FileFilter.check_total/2` (see `check_total_size/1`) rather than
  # reimplementing the ">" check here too.
  @max_files 10
  @max_total_bytes 8 * 1024 * 1024
  @discord_max_len 2000

  # list_discord_attachments: how many channel messages to scan per call.
  @default_list_limit 50
  @max_list_limit 100

  # fetch_discord_attachments' per-file and total caps are
  # `FileFilter.max_file_bytes/0` and `FileFilter.max_inbound_total_bytes/0`
  # — the same ones the auto-copy path uses (see `save_with_size_cap/4` /
  # `check_fetch_total_size/5` below). No local constant here on purpose:
  # this used to keep its own separate `@max_fetch_bytes`, which is exactly
  # the kind of drift `OrcaHub.Discord.FileFilter` exists to prevent.

  def list do
    [
      %{
        "name" => "send_discord_message",
        "description" =>
          "Send a message and/or file attachments to the Discord channel this session " <>
            "is bridged to (only works for Discord-bridged sessions). Provide `message`, " <>
            "`file_paths`, or both — at least one is required. `file_paths` are resolved " <>
            "relative to the session's working directory; an absolute path is only " <>
            "accepted if it resolves inside that directory — anything outside it " <>
            "(including via `..` or a symlink) is rejected. Note: when this session " <>
            "finishes its turn, the bridge automatically posts the session's final " <>
            "assistant text to the channel — so this tool is mainly for attachments and " <>
            "interim/progress updates mid-turn; avoid using it to duplicate your final " <>
            "reply. Pass `reply_to_message_id` to thread the post as a Discord reply to a " <>
            "specific earlier message.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "message" => %{
              "type" => "string",
              "description" =>
                "Text to post. Longer than Discord's 2000-character limit is automatically " <>
                  "split across multiple messages."
            },
            "file_paths" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Files to attach, relative to the session's working directory. An " <>
                  "absolute path is accepted only if it resolves inside that directory. " <>
                  "Up to #{@max_files} files, #{div(@max_total_bytes, 1_048_576)}MB total."
            },
            "reply_to_message_id" => %{
              "type" => "string",
              "description" =>
                "Discord message id (snowflake) to reply to, threading this post under " <>
                  "that specific message in Discord. Message ids appear as `[id: ...]` " <>
                  "prefixes on the channel history and mention lines in your prompt — " <>
                  "pass one of those values here. Must be a numeric snowflake string. " <>
                  "Only applies to the first message posted (a long `message` split " <>
                  "across multiple Discord messages only threads the first chunk)."
            }
          }
        }
      },
      %{
        "name" => "list_discord_attachments",
        "description" =>
          "List recent messages in this session's bridged Discord channel that have file " <>
            "attachments (only works for Discord-bridged sessions) — the discovery path " <>
            "for files uploaded outside the backfilled history window, or in an untagged " <>
            "message. Returns each message's id, author, a short content snippet, and " <>
            "per-attachment id/filename/size/content_type. Pass a returned message id to " <>
            "`fetch_discord_attachments`, and (if two attachments on the same message " <>
            "share a filename) their attachment ids as `attachment_ids` to pick a " <>
            "specific one.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "limit" => %{
              "type" => "integer",
              "description" =>
                "Max messages to scan for attachments (not max attachments returned). " <>
                  "Default #{@default_list_limit}, capped at #{@max_list_limit}."
            },
            "before_message_id" => %{
              "type" => "string",
              "description" =>
                "Discord message id (snowflake) to page backwards from — pass the " <>
                  "oldest `id` seen in a previous page to scan further back in history. " <>
                  "Must be a numeric snowflake string."
            }
          }
        }
      },
      %{
        "name" => "fetch_discord_attachments",
        "description" =>
          "Retroactively download the attachments on a specific earlier Discord message " <>
            "into this session's inbox/ directory (only works for Discord-bridged " <>
            "sessions). Auto-copy only ever covers the message that @-mentioned the bot " <>
            "— use this for any other message, discovered via `list_discord_attachments` " <>
            "or an `[id: ...]` tag in your prompt's channel history. Re-fetches the " <>
            "message fresh before downloading (Discord CDN links are signed/expiring, so " <>
            "an old URL can't just be reused). Idempotent: re-fetching a message you " <>
            "already pulled resolves to the same path instead of writing a duplicate. " <>
            "Returns the saved paths relative to the session directory, nested under a " <>
            "per-message folder (e.g. \"inbox/123456789/report-987654321.pdf\") so you " <>
            "can Read them directly.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "message_id" => %{
              "type" => "string",
              "description" =>
                "Discord message id (snowflake) to fetch attachments from. Required. " <>
                  "Must be a numeric snowflake string, e.g. one of the `[id: ...]` " <>
                  "values in your prompt or a `list_discord_attachments` result."
            },
            "filenames" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Optional: only download attachments whose filename exactly matches one " <>
                  "of these — every attachment with that filename is downloaded (Discord " <>
                  "allows duplicate filenames on one message). Omit to download every " <>
                  "attachment on the message. Provide at most one of `filenames` / " <>
                  "`attachment_ids` — combining both is an error."
            },
            "attachment_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Optional: only download attachments with one of these exact numeric " <>
                  "attachment ids — the precise selector, needed when two attachments on " <>
                  "the same message share a filename (see the `id` field from " <>
                  "`list_discord_attachments`). Must be numeric snowflake strings. " <>
                  "Provide at most one of `filenames` / `attachment_ids` — combining both " <>
                  "is an error."
            }
          },
          "required" => ["message_id"]
        }
      }
    ]
  end

  def call("send_discord_message", args, state) do
    message = normalize_message(args["message"])
    file_paths = normalize_file_paths(args["file_paths"])

    with :ok <- validate_present(message, file_paths),
         {:ok, reply_to} <- validate_reply_to_message_id(args["reply_to_message_id"]),
         {:ok, session_id} <- require_session(state),
         :ok <- require_discord_node(),
         {:ok, mapping} <- require_mapping(session_id),
         {:ok, resolved_paths} <- resolve_files(session_id, mapping, file_paths) do
      post_to_discord(mapping.discord_channel_id, message, resolved_paths, reply_to)
    else
      {:error, reason} -> error(reason)
    end
  rescue
    e -> error("send_discord_message failed unexpectedly: #{Exception.message(e)}")
  end

  def call("list_discord_attachments", args, state) do
    limit = normalize_limit(args["limit"])

    with {:ok, before_id} <-
           validate_optional_snowflake(args["before_message_id"], "before_message_id"),
         {:ok, session_id} <- require_session(state),
         :ok <- require_discord_node(),
         {:ok, mapping} <- require_mapping(session_id) do
      list_attachments(mapping.discord_channel_id, limit, before_id)
    else
      {:error, reason} -> error(reason)
    end
  rescue
    e -> error("list_discord_attachments failed unexpectedly: #{Exception.message(e)}")
  end

  def call("fetch_discord_attachments", args, state) do
    filenames = normalize_filenames(args["filenames"])

    with {:ok, message_id} <- validate_message_id(args["message_id"]),
         {:ok, attachment_ids} <- validate_attachment_ids(args["attachment_ids"]),
         :ok <- validate_selector_exclusivity(filenames, attachment_ids),
         {:ok, session_id} <- require_session(state),
         :ok <- require_discord_node(),
         {:ok, mapping} <- require_mapping(session_id) do
      fetch_and_save(mapping, message_id, filenames, attachment_ids, session_id)
    else
      {:error, reason} -> error(reason)
    end
  rescue
    e -> error("fetch_discord_attachments failed unexpectedly: #{Exception.message(e)}")
  end

  # ------------------------------------------------------------------
  # Input validation
  # ------------------------------------------------------------------

  defp normalize_message(nil), do: nil

  defp normalize_message(message) when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_message(_message), do: nil

  defp normalize_file_paths(paths) when is_list(paths), do: Enum.map(paths, &to_string/1)
  defp normalize_file_paths(_paths), do: []

  defp normalize_filenames(names) when is_list(names), do: Enum.map(names, &to_string/1)
  defp normalize_filenames(_names), do: []

  # Clamped to `@max_list_limit` rather than erroring on an over-large value —
  # a session guessing a big number to "see everything" should just get the
  # cap, not a rejected call.
  defp normalize_limit(nil), do: @default_list_limit
  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_list_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} -> normalize_limit(n)
      _ -> @default_list_limit
    end
  end

  defp normalize_limit(_limit), do: @default_list_limit

  @doc "True unless both `message` and `file_paths` are empty — MCP inputSchema can't express anyOf portably, so this is checked here."
  def validate_present(nil, []),
    do: {:error, "Provide a `message` and/or `file_paths` — at least one is required."}

  def validate_present(_message, _file_paths), do: :ok

  @doc """
  Validate the optional `reply_to_message_id` arg. Omitting it (`nil`) is
  valid and means "not a reply". Delegates to `validate_optional_snowflake/2`
  — see there for the shared validation shape.
  """
  def validate_reply_to_message_id(id), do: validate_optional_snowflake(id, "reply_to_message_id")

  @doc """
  Validate an OPTIONAL numeric Discord snowflake string arg. `nil`
  (omitted) is valid and returns `{:ok, nil}`. Otherwise it must match
  `^\\d+$` — Discord message ids are 64-bit integers that MCP/JSON callers
  pass as strings to avoid precision loss. Shared by every optional
  message-id arg (`reply_to_message_id`, `before_message_id`) so the regex
  and error phrasing live in exactly one place. Returns
  `{:ok, integer_or_nil}` or `{:error, message}`.
  """
  def validate_optional_snowflake(nil, _field), do: {:ok, nil}

  def validate_optional_snowflake(id, field) do
    case parse_snowflake(id) do
      {:ok, int} -> {:ok, int}
      :error -> {:error, snowflake_error(field, id)}
    end
  end

  @doc """
  Validate a REQUIRED numeric Discord snowflake string arg (`message_id` on
  `fetch_discord_attachments`) — unlike `validate_optional_snowflake/2`,
  `nil`/omitted is an error here since the tool needs a specific message to
  re-fetch. Returns `{:ok, integer}` or `{:error, message}`.
  """
  def validate_message_id(nil), do: {:error, "`message_id` is required."}

  def validate_message_id(id) do
    case parse_snowflake(id) do
      {:ok, int} -> {:ok, int}
      :error -> {:error, snowflake_error("message_id", id)}
    end
  end

  @doc """
  Validate the optional `attachment_ids` arg on `fetch_discord_attachments`:
  a list of numeric Discord attachment-id (snowflake) strings — the precise
  selector for when two attachments on one message share a filename. `nil`
  (omitted) is valid and returns `{:ok, []}`. Reuses `parse_snowflake/1`, the
  same numeric-string shape as every other snowflake arg. Returns
  `{:ok, [integer]}` or `{:error, message}` naming the first invalid entry.
  """
  def validate_attachment_ids(nil), do: {:ok, []}

  def validate_attachment_ids(ids) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case parse_snowflake(id) do
        {:ok, int} -> {:cont, {:ok, [int | acc]}}
        :error -> {:halt, {:error, snowflake_error("attachment_ids", id)}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  def validate_attachment_ids(_ids),
    do: {:error, "`attachment_ids` must be a list of numeric Discord attachment ids."}

  @doc """
  `filenames` and `attachment_ids` are two ways to select the same thing —
  supporting both at once would mean picking a (silent) precedence or
  union rule, so we just reject the ambiguity outright.
  """
  def validate_selector_exclusivity([], _attachment_ids), do: :ok
  def validate_selector_exclusivity(_filenames, []), do: :ok

  def validate_selector_exclusivity(_filenames, _attachment_ids),
    do:
      {:error,
       "Provide at most one of `filenames` / `attachment_ids` — combining both is not supported."}

  defp parse_snowflake(id) when is_binary(id) do
    if String.match?(id, ~r/^\d+$/), do: {:ok, String.to_integer(id)}, else: :error
  end

  defp parse_snowflake(_id), do: :error

  defp snowflake_error(field, id),
    do:
      "`#{field}` must be a numeric Discord message id (e.g. \"123456789012345678\"), " <>
        "got: #{inspect(id)}"

  defp require_session(%{orca_session_id: session_id}) when is_binary(session_id),
    do: {:ok, session_id}

  defp require_session(_state),
    do:
      {:error,
       "No OrcaHub session linked to this MCP connection. Cannot determine the Discord channel."}

  defp require_discord_node do
    if OrcaHub.Discord.enabled?() do
      :ok
    else
      {:error,
       "This node does not run the Discord worker; only Discord-bridged sessions can use this tool."}
    end
  end

  defp require_mapping(session_id) do
    case HubRPC.get_discord_channel_by_session_id(session_id) do
      nil -> {:error, "This session is not bridged to a Discord channel."}
      mapping -> {:ok, mapping}
    end
  end

  defp resolve_files(_session_id, _mapping, []), do: {:ok, []}

  defp resolve_files(session_id, mapping, file_paths) do
    directory = HubRPC.get_session(session_id).directory
    validate_file_paths(directory, file_paths, session_id, mapping)
  end

  @doc """
  Validate and resolve `file_paths` against the session's working `directory`.
  Aside from filesystem reads (`File.lstat/1`, `File.regular?/1`,
  `File.stat!/1`) this has no Nostrum/HubRPC dependency, so it's directly
  unit-testable with real tmp files/symlinks. `session_id`/`mapping` are
  optional (default `nil`) — only used to build `OrcaHub.Discord.FileFilter`
  context for `check_outbound/1`, which today's only rule (size) doesn't
  read anyway. Returns `{:ok, resolved_absolute_paths}` or
  `{:error, message}`.

  Order: 1) path CONFINEMENT (every entry must resolve — after expanding
  `..`/symlinks — inside the session's own directory; see `confine/2`), 2)
  existence, 3) `FileFilter.check_outbound/1` per file, 4) the total-size
  cap. Confinement runs first and fails closed on the FIRST offending path,
  before any filesystem stat beyond what resolving it required — a session
  can't use a missing-file or size-cap error to distinguish "outside the
  sandbox" from "doesn't exist" for a path it's not allowed to reference.
  """
  def validate_file_paths(directory, file_paths, session_id \\ nil, mapping \\ nil) do
    if length(file_paths) > @max_files do
      {:error,
       "Too many files (#{length(file_paths)}) — Discord allows at most #{@max_files} attachments per message."}
    else
      case resolve_confined_paths(directory, file_paths) do
        {:error, reason} ->
          {:error, reason}

        {:ok, resolved} ->
          case Enum.reject(resolved, fn {_orig, abs} -> File.regular?(abs) end) do
            [] ->
              check_outbound_then_total(resolved, directory, session_id, mapping)

            missing ->
              {:error, "File(s) not found: " <> Enum.map_join(missing, ", ", &elem(&1, 0))}
          end
      end
    end
  end

  # Confine every `file_paths` entry to `directory`'s subtree, resolving
  # symlinks first so a manipulated agent can't create a symlink INSIDE its
  # own directory pointing anywhere on the filesystem and use it as an
  # escape hatch. Fails on the first offending path (in caller order).
  defp resolve_confined_paths(directory, file_paths) do
    file_paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case confine(directory, path) do
        {:ok, abs} -> {:cont, {:ok, [{path, abs} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # The confinement allow-list. Just the session directory today — structured
  # as a list so a future additional root (e.g. a shared read-only assets
  # dir) is a one-line addition here, not a signature change at every call
  # site.
  defp allowed_roots(directory), do: [directory]

  defp confine(directory, path) do
    resolved = path |> Path.expand(directory) |> realpath()

    if within_any_root?(resolved, allowed_roots(directory)) do
      {:ok, resolved}
    else
      Logger.warning(
        "send_discord_message denied file_paths entry outside session directory: #{inspect(path)}"
      )

      # Deliberately non-leaky: name the path as the CALLER supplied it, say
      # it's outside the session directory, and never echo `resolved` (a
      # real filesystem path, potentially outside the sandbox entirely) back
      # to a Discord channel.
      {:error, "File path #{inspect(path)} is outside the session directory."}
    end
  end

  defp within_any_root?(resolved, roots) do
    Enum.any?(roots, fn root ->
      resolved_root = realpath(Path.expand(root))
      resolved == resolved_root or String.starts_with?(resolved, resolved_root <> "/")
    end)
  end

  # Bounds how many symlink hops `realpath/1` will follow before giving up —
  # specifically so a symlink LOOP (a -> b -> a) can't hang this call. Well
  # above any legitimate chain length.
  @max_realpath_iterations 40

  @doc """
  A small `realpath`-style resolver: walks `path` (already absolute)
  component by component, resolving any symlink encountered along the way,
  and returns the fully-resolved absolute path. Nonexistent components are
  passed through literally (not an error) — resolving `.../missing.txt`
  still confines correctly even though the file doesn't exist yet, letting
  the caller's separate existence check report "not found" instead of a
  confusing confinement error. Bounded to `#{@max_realpath_iterations}`
  symlink hops so a loop can't hang the caller — if the bound is hit, the
  partially-resolved path is returned as-is (almost certain to then fail
  `within_any_root?/2`, which is the safe outcome for something we couldn't
  fully resolve). Public + directly unit-testable with real tmp symlinks —
  no Nostrum/HubRPC/session dependency.
  """
  def realpath(path) do
    path
    |> Path.split()
    |> do_realpath("/", 0)
  end

  defp do_realpath(_remaining, resolved, iterations) when iterations > @max_realpath_iterations,
    do: resolved

  defp do_realpath([], resolved, _iterations), do: resolved
  defp do_realpath(["/" | rest], _resolved, iterations), do: do_realpath(rest, "/", iterations)

  defp do_realpath(["." | rest], resolved, iterations),
    do: do_realpath(rest, resolved, iterations)

  defp do_realpath([".." | rest], resolved, iterations),
    do: do_realpath(rest, Path.dirname(resolved), iterations)

  defp do_realpath([comp | rest], resolved, iterations) do
    candidate = Path.join(resolved, comp)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        follow_symlink(candidate, rest, iterations)

      _not_a_symlink_or_missing ->
        do_realpath(rest, candidate, iterations)
    end
  end

  defp follow_symlink(candidate, rest, iterations) do
    case File.read_link(candidate) do
      {:ok, target} ->
        target_parts = Path.split(target)

        if Path.type(target) == :absolute do
          do_realpath(target_parts ++ rest, "/", iterations + 1)
        else
          # A relative symlink target is relative to the symlink's OWN
          # directory, not to `candidate` itself (which is the symlink, not
          # a directory).
          do_realpath(target_parts ++ rest, Path.dirname(candidate), iterations + 1)
        end

      {:error, _reason} ->
        # lstat said symlink but the link couldn't be read (race, permission)
        # — treat the path literally rather than raising.
        do_realpath(rest, candidate, iterations)
    end
  end

  defp check_outbound_then_total(resolved, directory, session_id, mapping) do
    checked =
      Enum.map(resolved, fn {orig, abs} ->
        size = File.stat!(abs).size
        {orig, abs, size, outbound_check(orig, abs, size, directory, session_id, mapping)}
      end)

    case Enum.find(checked, fn {_orig, _abs, _size, result} -> match?({:deny, _}, result) end) do
      {orig, _abs, _size, {:deny, reason}} ->
        Logger.warning("send_discord_message denied file #{inspect(orig)}: #{reason}")
        {:error, "File #{inspect(orig)} #{reason}"}

      nil ->
        check_total_size(
          Enum.map(checked, fn {orig, abs, size, _result} -> {orig, abs, size} end)
        )
    end
  end

  defp outbound_check(orig, abs, size, directory, session_id, mapping) do
    FileFilter.check_outbound(%{
      direction: :outbound,
      session_id: session_id,
      directory: directory,
      path: abs,
      filename: Path.basename(orig),
      size: size,
      content_type: MIME.from_path(orig),
      mapping: mapping
    })
  end

  defp check_total_size(sized) do
    total = Enum.reduce(sized, 0, fn {_orig, _abs, size}, acc -> acc + size end)

    case FileFilter.check_total(total, @max_total_bytes) do
      :allow ->
        {:ok, Enum.map(sized, fn {_orig, abs, _size} -> abs end)}

      {:deny, _reason} ->
        offenders =
          sized
          |> Enum.sort_by(fn {_orig, _abs, size} -> -size end)
          |> Enum.map_join(", ", fn {orig, _abs, size} -> "#{orig} (#{format_bytes(size)})" end)

        {:error,
         "Total attachment size #{format_bytes(total)} exceeds the #{format_bytes(@max_total_bytes)} " <>
           "limit. Files: #{offenders}"}
    end
  end

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)}MB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024, 1)}KB"

  # ------------------------------------------------------------------
  # Posting
  # ------------------------------------------------------------------
  #
  # A message is chunked (Bridge.chunk/2, the same 2000-char splitter the
  # auto-reply path uses) and files ride along on the FIRST chunk only —
  # everything after that is a plain content-only follow-up message. A
  # files-only call (no message) is a single message with files and no
  # content, since chunking "" would otherwise produce zero chunks.
  #
  # `reply_to` (an integer message id, or nil) is likewise applied only to
  # the FIRST posted message — Discord's message_reference threads a single
  # message, so follow-up chunks are just plain posts in the same channel.

  defp post_to_discord(discord_channel_id, message, file_paths, reply_to) do
    channel_id = String.to_integer(discord_channel_id)
    chunks = if message, do: Bridge.chunk(message, @discord_max_len), else: []
    chunk_count = length(chunks)
    messages = if chunks == [], do: [nil], else: chunks

    case send_messages(channel_id, messages, file_paths, reply_to) do
      :ok ->
        text(
          "Posted to Discord channel #{discord_channel_id} " <>
            "(#{chunk_count} chunks, #{length(file_paths)} files#{reply_suffix(reply_to)})."
        )

      {:error, reason} ->
        error(reason)
    end
  end

  defp reply_suffix(nil), do: ""
  defp reply_suffix(reply_to), do: ", replying to message #{reply_to}"

  defp send_messages(channel_id, [first | rest], file_paths, reply_to) do
    with :ok <- create_message(channel_id, first, file_paths, reply_to) do
      # reply_to only ever applies to the first message sent (see comment above).
      send_messages(channel_id, rest, [], nil)
    end
  end

  defp send_messages(_channel_id, [], _file_paths, _reply_to), do: :ok

  defp create_message(channel_id, content, file_paths, reply_to) do
    opts =
      []
      |> then(fn opts -> if content, do: Keyword.put(opts, :content, content), else: opts end)
      |> then(fn opts ->
        if file_paths == [], do: opts, else: Keyword.put(opts, :files, file_paths)
      end)
      |> then(fn opts ->
        if reply_to,
          do: Keyword.put(opts, :message_reference, %{message_id: reply_to}),
          else: opts
      end)

    case Nostrum.Api.Message.create(channel_id, opts) do
      {:ok, _msg} ->
        :ok

      {:error, %Nostrum.Error.ApiError{status_code: status, response: response}} ->
        {:error, api_error_message(status, response, reply_to)}

      {:error, reason} ->
        {:error, "Discord API error: #{inspect(reason)}"}
    end
  end

  # An unknown/deleted `reply_to` message id is indistinguishable from any
  # other Discord API rejection at this layer (it just comes back as an
  # ApiError, most commonly HTTP 400 "Unknown Message") — name the reply
  # target explicitly so the session doesn't have to guess why the post failed.
  defp api_error_message(status, response, nil),
    do: "Discord API error (HTTP #{status}): #{inspect(response)}"

  defp api_error_message(status, response, reply_to),
    do:
      "Discord API error (HTTP #{status}) while replying to message #{reply_to} " <>
        "(it may have been deleted, or the id may be invalid): #{inspect(response)}"

  # ------------------------------------------------------------------
  # Listing (discovery)
  # ------------------------------------------------------------------
  #
  # Scans recent channel history (same Nostrum call the bridge's backfill
  # uses) and surfaces only the messages that have attachments — this is
  # what lets a session find a file it never saw, without needing to already
  # know the message id.

  defp list_attachments(discord_channel_id, limit, before_id) do
    channel_id = String.to_integer(discord_channel_id)
    locator = if before_id, do: {:before, before_id}, else: {}

    case Nostrum.Api.Channel.messages(channel_id, limit, locator) do
      {:ok, messages} ->
        entries =
          messages
          |> Enum.filter(&((&1.attachments || []) != []))
          |> Enum.map(&summarize_message/1)

        text(Jason.encode!(%{"count" => length(entries), "messages" => entries}))

      {:error, %Nostrum.Error.ApiError{status_code: status, response: response}} ->
        error("Discord API error (HTTP #{status}) listing channel history: #{inspect(response)}")

      {:error, reason} ->
        error("Discord API error listing channel history: #{inspect(reason)}")
    end
  end

  @snippet_len 80

  defp summarize_message(m) do
    %{
      "id" => to_string(m.id),
      "author" => display_author(m.author),
      "content_snippet" => snippet(m.content),
      "attachments" => Enum.map(m.attachments, &summarize_attachment/1)
    }
  end

  defp summarize_attachment(a) do
    %{
      "id" => to_string(a.id),
      "filename" => a.filename,
      "size" => a.size,
      # Nostrum's Attachment struct doesn't carry Discord's raw `content_type`
      # payload field (its `to_struct/1` drops any key that isn't one of the
      # struct's own fields, and content_type isn't one) — best-effort guess
      # from the filename extension instead.
      "content_type" => MIME.from_path(a.filename)
    }
  end

  defp snippet(content) do
    trimmed = String.trim(content || "")

    if String.length(trimmed) > @snippet_len do
      String.slice(trimmed, 0, @snippet_len) <> "…"
    else
      trimmed
    end
  end

  defp display_author(%{global_name: name}) when is_binary(name) and name != "", do: name
  defp display_author(%{username: name}) when is_binary(name) and name != "", do: name
  defp display_author(_author), do: "someone"

  # ------------------------------------------------------------------
  # Retroactive fetch
  # ------------------------------------------------------------------
  #
  # Re-fetches the message fresh (never trusts a URL surfaced by an earlier
  # `list_discord_attachments` call or the history backfill) so the CDN
  # download always has a live signed URL, then hands off to
  # `Bridge.save_attachments_to_inbox/4` — the exact same identity-based
  # naming/download logic (and the same `OrcaHub.Discord.FileFilter` hooks)
  # the on-mention auto-copy path uses, nested under this `message_id` so a
  # fetch of an already-auto-copied message resolves to the same paths
  # instead of duplicating them.

  defp fetch_and_save(mapping, message_id, filenames, attachment_ids, session_id) do
    channel_id = String.to_integer(mapping.discord_channel_id)

    case Nostrum.Api.Message.get(channel_id, message_id) do
      {:ok, %{attachments: attachments}} ->
        save_selected(
          attachments || [],
          filenames,
          attachment_ids,
          message_id,
          session_id,
          mapping
        )

      {:error, %Nostrum.Error.ApiError{status_code: status, response: response}} ->
        error(
          "Discord API error (HTTP #{status}) fetching message #{message_id} " <>
            "(it may have been deleted, or belong to a different channel): #{inspect(response)}"
        )

      {:error, reason} ->
        error("Discord API error fetching message #{message_id}: #{inspect(reason)}")
    end
  end

  @doc """
  Core `fetch_discord_attachments` logic once a message's `attachments` have
  already been fetched: apply the optional `filenames`/`attachment_ids`
  filter, enforce the size cap, and save via
  `Bridge.save_attachments_to_inbox/4`. Split out from `fetch_and_save/5`
  (which owns the Nostrum re-fetch) so it's directly unit-testable with
  plain attachment maps — no live Discord connection needed for the
  filter/size-cap branches, which never reach `session_id`. `mapping`
  defaults to `nil` for callers that don't have one; only used to build
  `FileFilter` context (today's only rule doesn't read it).

  `filenames` selects by exact filename match — since Discord allows
  duplicate filenames on one message, a requested name selects EVERY
  attachment with that name, not just one. `attachment_ids` selects by
  exact attachment id, the precise selector for disambiguating those
  duplicates. Both `filenames` and `attachment_ids` are deduped so
  requesting the same value twice doesn't download it twice. Callers are
  expected to have already enforced mutual exclusivity
  (`validate_selector_exclusivity/2`); this function still refuses to guess
  a precedence if it somehow receives both non-empty.
  """
  def save_selected(
        attachments,
        filenames,
        attachment_ids,
        message_id,
        session_id,
        mapping \\ nil
      )

  def save_selected([], _filenames, _attachment_ids, _message_id, _session_id, _mapping),
    do: error("That message has no attachments.")

  def save_selected(_attachments, filenames, attachment_ids, _message_id, _session_id, _mapping)
      when filenames != [] and attachment_ids != [] do
    error(
      "Provide at most one of `filenames` / `attachment_ids` — combining both is not supported."
    )
  end

  def save_selected(attachments, [], [], message_id, session_id, mapping),
    do: save_with_size_cap(attachments, message_id, session_id, mapping)

  def save_selected(attachments, filenames, [], message_id, session_id, mapping) do
    by_name = Enum.group_by(attachments, & &1.filename)
    requested = Enum.uniq(filenames)

    case Enum.reject(requested, &Map.has_key?(by_name, &1)) do
      [] ->
        selected = Enum.flat_map(requested, &Map.fetch!(by_name, &1))
        save_with_size_cap(selected, message_id, session_id, mapping)

      missing ->
        available = Enum.map_join(attachments, ", ", & &1.filename)

        error(
          "Requested filename(s) not found on that message: #{Enum.join(missing, ", ")}. " <>
            "Attachments on that message: #{available}"
        )
    end
  end

  def save_selected(attachments, [], attachment_ids, message_id, session_id, mapping) do
    by_id = Map.new(attachments, &{&1.id, &1})
    requested = Enum.uniq(attachment_ids)

    case Enum.reject(requested, &Map.has_key?(by_id, &1)) do
      [] ->
        selected = Enum.map(requested, &Map.fetch!(by_id, &1))
        save_with_size_cap(selected, message_id, session_id, mapping)

      missing ->
        available = Enum.map_join(attachments, ", ", &to_string(&1.id))

        error(
          "Requested attachment_id(s) not found on that message: " <>
            "#{Enum.map_join(missing, ", ", &to_string/1)}. " <>
            "Attachment ids on that message: #{available}"
        )
    end
  end

  # Pre-download gate: per-file then total, both delegating the actual cap
  # comparison to `FileFilter` (`max_file_bytes/0` / `check_total/2` +
  # `max_inbound_total_bytes/0`) instead of reimplementing it — this used to
  # be the ONLY size check in this module; `Bridge.save_one/5` now applies
  # the same rule again once bytes are actually in hand (metadata here can't
  # see past a missing/lying declared size — content can), so this is a
  # cheap early rejection, not the last line of defense.
  defp save_with_size_cap(attachments, message_id, session_id, mapping) do
    directory = HubRPC.get_session(session_id).directory

    checked =
      Enum.map(attachments, &{&1, fetch_metadata_check(&1, message_id, directory, mapping)})

    case Enum.find(checked, fn {_a, result} -> match?({:deny, _}, result) end) do
      {%{filename: filename}, {:deny, reason}} ->
        Logger.warning("fetch_discord_attachments denied #{inspect(filename)}: #{reason}")
        error("Attachment #{filename} #{reason} for fetch_discord_attachments.")

      nil ->
        check_fetch_total_size(attachments, message_id, session_id, directory, mapping)
    end
  end

  defp fetch_metadata_check(attachment, message_id, directory, mapping) do
    FileFilter.check_inbound_metadata(%{
      direction: :inbound,
      project: mapping && mapping.project,
      directory: directory,
      message_id: message_id,
      original_filename: attachment.filename,
      sanitized_filename: Bridge.sanitize_filename(attachment.filename),
      size: attachment.size,
      content_type: MIME.from_path(attachment.filename),
      mapping: mapping
    })
  end

  defp check_fetch_total_size(attachments, message_id, _session_id, directory, mapping) do
    total = Enum.reduce(attachments, 0, &(&1.size + &2))

    case FileFilter.check_total(total, FileFilter.max_inbound_total_bytes()) do
      {:deny, _reason} ->
        error(
          "Total attachment size #{format_bytes(total)} exceeds the " <>
            "#{format_bytes(FileFilter.max_inbound_total_bytes())} limit for a single " <>
            "fetch_discord_attachments call. Narrow the request with `filenames` or " <>
            "`attachment_ids`."
        )

      :allow ->
        saved = Bridge.save_attachments_to_inbox(directory, message_id, attachments, mapping)
        report_saved(saved, attachments)
    end
  end

  @doc """
  `save_attachments_to_inbox/4` silently skips (and logs) individual
  download failures rather than raising, so the count of raw results can be
  fewer than the attachment count — and now, since it also runs the
  `FileFilter` hooks, some results may be `{:denied, filename, reason}`
  rather than a save at all. Surface all three outcomes distinctly instead
  of pretending everything succeeded, or lumping a policy denial in with a
  transient network/write failure. Public (not doc-hidden) so it's directly
  unit-testable with a synthetic `results` list — no live download needed to
  exercise the reporting/categorization logic itself.
  """
  def report_saved([], _attachments),
    do: error("Failed to download any of the requested attachment(s) — see server logs.")

  def report_saved(results, attachments) do
    {denied, saves} = Enum.split_with(results, &match?({:denied, _, _}, &1))
    {downloaded, existing} = Enum.split_with(saves, &match?({:downloaded, _}, &1))
    paths = Enum.map(saves, &elem(&1, 1))
    failed = length(attachments) - length(results)
    succeeded = length(saves)

    breakdown =
      [
        downloaded != [] && "#{length(downloaded)} downloaded",
        existing != [] && "#{length(existing)} already present from an earlier fetch",
        denied != [] && "#{length(denied)} blocked by the file filter",
        failed > 0 && "#{failed} failed to download — see server logs"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    text(
      "Saved #{succeeded} of #{length(attachments)} attachment(s) (#{breakdown})" <>
        paths_suffix(paths) <> denied_suffix(denied)
    )
  end

  defp paths_suffix([]), do: ""
  defp paths_suffix(paths), do: " to: " <> Enum.join(paths, ", ")

  defp denied_suffix([]), do: ""

  defp denied_suffix(denied) do
    ". Blocked: " <>
      Enum.map_join(denied, "; ", fn {:denied, filename, reason} -> "#{filename} (#{reason})" end)
  end
end
