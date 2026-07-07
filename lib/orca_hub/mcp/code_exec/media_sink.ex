defmodule OrcaHub.MCP.CodeExec.MediaSink do
  @moduledoc """
  Renders a raw MCP `content` block list into the plain-text form `run_elixir`
  snippets actually see, writing any binary media to disk instead of dropping
  it or inlining base64.

  The Claude CLI always talks to `http://localhost:<port>/mcp` (see
  `OrcaHub.Backend.McpUrl`), so the dispatcher always runs on the same host as
  the session's own CLI — a file written here is directly readable by the
  agent's `Read` tool (which renders images inline), no extra transport needed.

  Content blocks:

    * `text` → passed through verbatim.
    * `image` / `audio` → base64-decoded and written to
      `$TMPDIR/orca_hub/tool_media/<sanitized_orca_session_id>/<tool>-<ms>-<idx>.<ext>`,
      replaced with a `[<type> saved to <path> — view it with the Read tool]`
      line. The session id comes from the `/mcp` URL query string, so it's run
      through the same filename sanitizer as the tool name before being used
      as a path segment — a path-traversal-shaped id (`../../foo`) can't
      escape the `tool_media` root.
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
  """

  alias OrcaHub.MCP.CodeExec

  @max_media_blocks 8
  @max_media_bytes 20 * 1024 * 1024

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
      session_dir: session_dir()
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

  defp session_dir do
    case CodeExec.get_state() do
      %{orca_session_id: id} when is_binary(id) -> sanitize_for_filename(id)
      _ -> "shared"
    end
  end

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
      path = save_media_file(bytes, mime, ctx.tool_name, ctx.ts_ms, idx, ctx.session_dir)
      note = "[#{kind} saved to #{path} — view it with the Read tool]"
      {:media, note, %{ctx | count: idx, bytes: ctx.bytes + byte_size(bytes)}}
    end
  end

  defp decode_base64(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> Base.decode64(data, padding: false)
    end
  end

  defp save_media_file(bytes, mime, tool_name, ts_ms, idx, session_dir) do
    filename = "#{sanitize_for_filename(tool_name)}-#{ts_ms}-#{idx}.#{ext_for_mime(mime)}"
    dir = Path.join([System.tmp_dir!(), "orca_hub", "tool_media", session_dir])
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
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
