defmodule OrcaHub.MCP.CodeExec.MediaSink do
  @moduledoc """
  Renders a raw MCP `content` block list into the plain-text form `run_elixir`
  snippets actually see, writing any binary media to disk instead of dropping
  it or inlining base64.

  Media is written under the session's own project directory —
  `<session_directory>/.agents/media/<sanitized_orca_session_id>/` — so a
  human can actually find the file: the app process's own `$TMPDIR` is not a
  reliable place to look (the local systemd service runs with
  `PrivateTmp=yes`, and each k3s pod has its own ephemeral `/tmp`), and the
  project directory is a filesystem location the model's `Read` tool can
  already reach. When the session's directory can't be resolved (no
  `orca_session_id`, session lookup fails, or the session has no directory /
  the directory doesn't exist on this host), this falls back to the previous
  `$TMPDIR/orca_hub/tool_media/<segment>/` location.

  Content blocks:

    * `text` → passed through verbatim.
    * `image` / `audio` → base64-decoded and written to disk, replaced with a
      `[<type> saved to <path> — view it with the Read tool]` line. The
      session id comes from the `/mcp` URL query string, so it's run through
      the same filename sanitizer as the tool name before being used as a
      path segment — a path-traversal-shaped id (`../../foo`) can't escape
      the media root.
    * `resource` (embedded resource) → its `text` is passed through like a
      text block; its `blob` (base64) is written to disk like an image/audio
      block.
    * `resource_link` → rendered as a `[resource_link] <title> — <uri>` line.
    * anything else → rendered as `[dropped unsupported content block: <type>]`
      so drops are visible instead of silent.

  A base64 payload that fails to decode never raises — it renders as
  `[failed to decode <type> block]`. Callers (`Dispatcher.unwrap!/2`) must
  never see an exception out of a tool-result content quirk; that would
  masquerade as a real `Tools.Error`/eval failure.

  Safety caps (`@max_media_blocks` writes, `@max_media_bytes` decoded bytes
  per call) protect the sandbox host's disk — blocks over cap render as
  `[skipped <type>: over media cap]` instead of writing.

  The code-exec dispatcher (`Dispatcher.dispatch/3`) strips the `filename` arg
  off calls to a handful of playwright tools before forwarding upstream
  (playwright-mcp writes the file inside its own pod when `filename` is set,
  returning only a link — unreachable from here) and stashes the requested
  name + mode via `put_requested_filename/1`:

    * `{:media, name}` (`browser_take_screenshot`) — the first media block of
      the *next* `render/2` call is saved under `name` (with a mime-derived
      extension appended) instead of the default `<tool>-<ms>-<idx>` pattern.
    * `{:text, name}` (`browser_snapshot`, `browser_console_messages`,
      `browser_network_requests`/`_request`, `browser_evaluate`) — read via
      `peek_requested_filename/0` and acted on by `Dispatcher.unwrap!/2`,
      which saves the tool's full joined text output to disk with `save_text/2`
      instead of returning it inline. `render/2` itself ignores this mode (it
      only recognizes `{:media, _}`), so text-mode blocks still render
      normally on the way to `save_text/2`.
  """

  alias OrcaHub.MCP.CodeExec

  @max_media_blocks 8
  @max_media_bytes 20 * 1024 * 1024
  @filename_key {__MODULE__, :requested_filename}

  @mime_ext %{
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/jpg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp",
    "image/svg+xml" => "svg",
    "audio/wav" => "wav",
    "audio/wave" => "wav",
    "audio/x-wav" => "wav",
    "audio/mpeg" => "mp3",
    "audio/mp3" => "mp3",
    "audio/ogg" => "ogg",
    "audio/webm" => "webm",
    "application/pdf" => "pdf",
    "text/plain" => "txt",
    "text/html" => "html",
    "application/json" => "json"
  }

  @doc """
  Render `content` (a raw MCP `content` block list) for `tool_name`.

  Returns `{parts, has_notes?}` where `parts` is the ordered list of text
  segments (text/resource-text passed through, everything else turned into a
  bracketed note) and `has_notes?` is `true` when at least one block wasn't
  plain text — the caller uses this to decide whether it's still safe to
  attempt a JSON-decode of the joined text.
  """
  def render(content, tool_name) when is_list(content) do
    ctx = %{
      count: 0,
      bytes: 0,
      tool_name: tool_name,
      ts_ms: System.system_time(:millisecond),
      media_root: media_root(),
      requested_filename: take_requested_filename()
    }

    {parts, has_notes?, _ctx} =
      Enum.reduce(content, {[], false, ctx}, fn block, {parts, notes?, ctx} ->
        case process_block(block, ctx) do
          {:text, text, ctx} -> {[text || "" | parts], notes?, ctx}
          {:note, note, ctx} -> {[note | parts], true, ctx}
          {:media, note, ctx} -> {[note | parts], true, ctx}
        end
      end)

    {Enum.reverse(parts), has_notes?}
  end

  @doc """
  Stash a caller-requested filename + mode for the code-exec dispatcher to
  carry a stripped `filename` arg through after removing it from the upstream
  call. `mode` is `nil` (no pending request), `{:media, name}` (consumed by
  the next `render/2` call's first media block), or `{:text, name}` (consumed
  by `Dispatcher.unwrap!/2` via `peek_requested_filename/0` + `save_text/2`).
  Pass `nil` to clear any pending request.
  """
  def put_requested_filename(nil), do: Process.delete(@filename_key)

  def put_requested_filename({mode, name}) when mode in [:media, :text] and is_binary(name),
    do: Process.put(@filename_key, {mode, name})

  @doc """
  Peek at the pending requested-filename mode (`nil | {:media, name} |
  {:text, name}`) without consuming it. Used by `Dispatcher.unwrap!/2` to
  decide, before calling `render/2` (which consumes the stash), whether the
  upcoming content should be saved to disk as a whole via `save_text/2`
  instead of rendered block-by-block.
  """
  def peek_requested_filename, do: Process.get(@filename_key)

  # Consumed by render/2's ctx setup on every call regardless of mode, so the
  # stash never survives past the render it was set for — only `{:media, _}`
  # is meaningful here; `{:text, _}` is handled upstream in Dispatcher and is
  # simply discarded (there's no per-block filename to honor).
  defp take_requested_filename do
    mode = Process.get(@filename_key)
    Process.delete(@filename_key)

    case mode do
      {:media, name} -> name
      _ -> nil
    end
  end

  @doc """
  Write the full joined text output of a text-output tool call (e.g.
  `browser_snapshot`, `browser_evaluate`) to disk under the same media root
  `render/2` uses, named after the sanitized `requested_filename` verbatim —
  no extension is forced (unlike media blocks there's no mime type to derive
  one from; the agent chose the name). Returns a single note describing what
  happened; never raises.
  """
  def save_text(text, requested_filename) do
    text = text || ""

    if byte_size(text) > @max_media_bytes do
      "[output not saved: over the media cap]"
    else
      filename = sanitize_for_filename(requested_filename)
      path = save_media_file(text, filename, media_root())
      "[output saved to #{path} — view it with the Read tool]"
    end
  end

  @doc """
  Resolve where media/text files for the current session should be saved:
  `<session_directory>/.agents/media/<sanitized_session_id>/`, falling back to
  a tmp-dir location when the session's directory can't be resolved. Public
  because `save_text/2` is the same kind of save-to-disk operation as the
  per-block media writes and must resolve the identical root.
  """
  def media_root do
    case CodeExec.get_state() do
      %{orca_session_id: id} when is_binary(id) ->
        segment = safe_dir_segment(sanitize_for_filename(id))

        case project_media_dir(id) do
          {:ok, directory} -> Path.join([directory, ".agents", "media", segment])
          :error -> tmp_media_root(segment)
        end

      _ ->
        tmp_media_root("shared")
    end
  end

  defp project_media_dir(id) do
    case fetch_session(id) do
      %{directory: directory} when is_binary(directory) ->
        if File.dir?(directory), do: {:ok, directory}, else: :error

      _ ->
        :error
    end
  end

  # A hub-unreachable erpc failure (agent mode) must never surface as a crash
  # here — it just means "fall back to the tmp dir", same as a nil session.
  defp fetch_session(id) do
    OrcaHub.HubRPC.get_session(id)
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp tmp_media_root(segment),
    do: Path.join([System.tmp_dir!(), "orca_hub", "tool_media", segment])

  # sanitize_for_filename/1 keeps "." (it's a legal filename char), so an id
  # of exactly "", ".", or ".." sanitizes to itself — and unlike a slash-laden
  # id, that's a single path *component* the filesystem interprets specially
  # (Path.join(root, "..") climbs OUT of root). Catch those exact values here.
  defp safe_dir_segment(seg) when seg in ["", ".", ".."], do: "shared"
  defp safe_dir_segment(seg), do: seg

  defp process_block(%{"type" => "text"} = block, ctx), do: {:text, block["text"], ctx}

  defp process_block(%{"type" => "image"} = block, ctx),
    do: handle_media(block["data"], block["mimeType"], "image", ctx)

  defp process_block(%{"type" => "audio"} = block, ctx),
    do: handle_media(block["data"], block["mimeType"], "audio", ctx)

  defp process_block(%{"type" => "resource"} = block, ctx),
    do: handle_resource(block["resource"] || %{}, ctx)

  defp process_block(%{"type" => "resource_link"} = block, ctx) do
    title = block["title"] || block["name"] || "resource"
    uri = block["uri"] || "?"
    {:note, "[resource_link] #{title} — #{uri}", ctx}
  end

  defp process_block(%{"type" => type}, ctx),
    do: {:note, "[dropped unsupported content block: #{type}]", ctx}

  defp process_block(_block, ctx),
    do: {:note, "[dropped unsupported content block: unknown]", ctx}

  defp handle_resource(%{"text" => text}, ctx) when is_binary(text), do: {:text, text, ctx}

  defp handle_resource(%{"blob" => blob} = resource, ctx) when is_binary(blob),
    do: handle_media(blob, resource["mimeType"], "resource", ctx)

  defp handle_resource(_resource, ctx),
    do: {:note, "[dropped unsupported content block: resource (no text/blob)]", ctx}

  defp handle_media(data, _mime, kind, ctx) when not is_binary(data) do
    {:note, "[failed to decode #{kind} block]", ctx}
  end

  defp handle_media(data, mime, kind, ctx) do
    cond do
      ctx.count >= @max_media_blocks ->
        {:note, "[skipped #{kind}: over media cap]", ctx}

      true ->
        case decode_base64(data) do
          {:ok, bytes} -> write_or_cap(bytes, mime, kind, ctx)
          :error -> {:note, "[failed to decode #{kind} block]", ctx}
        end
    end
  end

  defp write_or_cap(bytes, mime, kind, ctx) do
    if ctx.bytes + byte_size(bytes) > @max_media_bytes do
      {:note, "[skipped #{kind}: over media cap]", ctx}
    else
      idx = ctx.count + 1
      {filename, ctx} = filename_for(ctx, mime, idx)
      path = save_media_file(bytes, filename, ctx.media_root)
      note = "[#{kind} saved to #{path} — view it with the Read tool]"
      {:media, note, %{ctx | count: idx, bytes: ctx.bytes + byte_size(bytes)}}
    end
  end

  # Only the very first media block of a call may honor a requested filename
  # (e.g. `browser_take_screenshot`'s stripped `filename` arg) — clearing it
  # from ctx afterward means any further blocks fall back to default naming.
  defp filename_for(%{count: 0, requested_filename: name} = ctx, mime, _idx)
       when is_binary(name) do
    sanitized = sanitize_for_filename(name)
    ext = ext_for_mime(mime)

    filename =
      if String.ends_with?(sanitized, ".#{ext}"), do: sanitized, else: "#{sanitized}.#{ext}"

    {filename, %{ctx | requested_filename: nil}}
  end

  defp filename_for(ctx, mime, idx) do
    filename = "#{sanitize_for_filename(ctx.tool_name)}-#{ctx.ts_ms}-#{idx}.#{ext_for_mime(mime)}"
    {filename, ctx}
  end

  defp decode_base64(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> Base.decode64(data, padding: false)
    end
  end

  defp save_media_file(bytes, filename, media_root) do
    File.mkdir_p!(media_root)
    path = Path.join(media_root, filename)
    File.write!(path, bytes)
    path
  end

  defp sanitize_for_filename(name) when is_binary(name),
    do: String.replace(name, ~r/[^a-zA-Z0-9_.-]/, "_")

  defp sanitize_for_filename(_name), do: "tool"

  defp ext_for_mime(mime) when is_binary(mime), do: Map.get(@mime_ext, mime, fallback_ext(mime))
  defp ext_for_mime(_mime), do: "bin"

  defp fallback_ext(mime) do
    case String.split(mime, "/", parts: 2) do
      [_type, subtype] when byte_size(subtype) in 1..10 ->
        case Regex.replace(~r/[^a-zA-Z0-9]/, subtype, "") do
          "" -> "bin"
          ext -> ext
        end

      _other ->
        "bin"
    end
  end
end
