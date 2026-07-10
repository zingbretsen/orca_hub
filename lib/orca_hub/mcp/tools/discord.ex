defmodule OrcaHub.MCP.Tools.Discord do
  @moduledoc """
  MCP tool letting a Discord-bridged session post messages/attachments back to
  its channel out-of-band.

  This is the ONLY write direction the bridge (`OrcaHub.Discord.Bridge`) was
  missing: it already auto-posts the session's final assistant text when the
  session goes idle (`Bridge.post_reply/3`), but had no way to send anything
  mid-turn, and no way at all to send attachments. `send_discord_message`
  fills that gap.

  The MCP server for a session always runs on the session's own runner node,
  and Discord-bridged sessions always run on the Discord pod (the project's
  `node` is pinned there at provisioning time — see `Bridge`), so a LOCAL
  `Nostrum.Api` call from `call/3` is correct with no cross-node routing.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.Discord.Bridge
  alias OrcaHub.HubRPC

  # Discord's hard attachment-count limit, and a conservative total-size cap to
  # stay under Discord's default (non-boosted-server) 8MB per-file upload limit
  # even when several small files are sent together.
  @max_files 10
  @max_total_bytes 8 * 1024 * 1024
  @discord_max_len 2000

  def list do
    [
      %{
        "name" => "send_discord_message",
        "description" =>
          "Send a message and/or file attachments to the Discord channel this session " <>
            "is bridged to (only works for Discord-bridged sessions). Provide `message`, " <>
            "`file_paths`, or both — at least one is required. `file_paths` are resolved " <>
            "relative to the session's working directory (absolute paths are also " <>
            "accepted). Note: when this session finishes its turn, the bridge " <>
            "automatically posts the session's final assistant text to the channel — so " <>
            "this tool is mainly for attachments and interim/progress updates mid-turn; " <>
            "avoid using it to duplicate your final reply. Pass `reply_to_message_id` to " <>
            "thread the post as a Discord reply to a specific earlier message.",
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
                "Files to attach, relative to the session's working directory (or " <>
                  "absolute). Up to #{@max_files} files, #{div(@max_total_bytes, 1_048_576)}MB total."
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
         {:ok, resolved_paths} <- resolve_files(session_id, file_paths) do
      post_to_discord(mapping.discord_channel_id, message, resolved_paths, reply_to)
    else
      {:error, reason} -> error(reason)
    end
  rescue
    e -> error("send_discord_message failed unexpectedly: #{Exception.message(e)}")
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

  @doc "True unless both `message` and `file_paths` are empty — MCP inputSchema can't express anyOf portably, so this is checked here."
  def validate_present(nil, []),
    do: {:error, "Provide a `message` and/or `file_paths` — at least one is required."}

  def validate_present(_message, _file_paths), do: :ok

  @doc """
  Validate the optional `reply_to_message_id` arg. Omitting it (`nil`) is
  valid and means "not a reply". Otherwise it must be a numeric snowflake
  string — Discord message ids are 64-bit integers that MCP/JSON callers pass
  as strings to avoid precision loss. Returns `{:ok, integer_or_nil}` or
  `{:error, message}`.
  """
  def validate_reply_to_message_id(nil), do: {:ok, nil}

  def validate_reply_to_message_id(id) when is_binary(id) do
    if String.match?(id, ~r/^\d+$/) do
      {:ok, String.to_integer(id)}
    else
      {:error, reply_to_error(id)}
    end
  end

  def validate_reply_to_message_id(id), do: {:error, reply_to_error(id)}

  defp reply_to_error(id),
    do:
      "`reply_to_message_id` must be a numeric Discord message id (e.g. \"123456789012345678\"), " <>
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

  defp resolve_files(_session_id, []), do: {:ok, []}

  defp resolve_files(session_id, file_paths) do
    directory = HubRPC.get_session(session_id).directory
    validate_file_paths(directory, file_paths)
  end

  @doc """
  Validate and resolve `file_paths` against the session's working `directory`.
  Aside from filesystem reads (`File.regular?/1`, `File.stat!/1`) this has no
  Nostrum/HubRPC dependency, so it's directly unit-testable with real tmp
  files. Returns `{:ok, resolved_absolute_paths}` or `{:error, message}`.
  """
  def validate_file_paths(directory, file_paths) do
    if length(file_paths) > @max_files do
      {:error,
       "Too many files (#{length(file_paths)}) — Discord allows at most #{@max_files} attachments per message."}
    else
      resolved = Enum.map(file_paths, &{&1, resolve_path(directory, &1)})

      case Enum.reject(resolved, fn {_orig, abs} -> File.regular?(abs) end) do
        [] -> check_total_size(resolved)
        missing -> {:error, "File(s) not found: " <> Enum.map_join(missing, ", ", &elem(&1, 0))}
      end
    end
  end

  defp resolve_path(directory, path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(directory, path)
  end

  defp check_total_size(resolved) do
    sized = Enum.map(resolved, fn {orig, abs} -> {orig, abs, File.stat!(abs).size} end)
    total = Enum.reduce(sized, 0, fn {_orig, _abs, size}, acc -> acc + size end)

    if total > @max_total_bytes do
      offenders =
        sized
        |> Enum.sort_by(fn {_orig, _abs, size} -> -size end)
        |> Enum.map_join(", ", fn {orig, _abs, size} -> "#{orig} (#{format_bytes(size)})" end)

      {:error,
       "Total attachment size #{format_bytes(total)} exceeds the #{format_bytes(@max_total_bytes)} " <>
         "limit. Files: #{offenders}"}
    else
      {:ok, Enum.map(sized, fn {_orig, abs, _size} -> abs end)}
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
end
