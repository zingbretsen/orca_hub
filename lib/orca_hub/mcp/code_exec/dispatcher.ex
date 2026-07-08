defmodule OrcaHub.MCP.CodeExec.Dispatcher do
  @moduledoc """
  Routing + result-unwrapping for the generated `Tools.*` surface.

  ## Routing (`dispatch/3`)

  The single dispatch entry point. It does **not** reimplement routing: it
  reuses the exact decision the live MCP server makes in `OrcaHub.MCP.Server` —

    * upstream tool (namespaced, e.g. `github__get_issue`) →
      `OrcaHub.MCP.UpstreamClient.call_tool/3` (passing the caller's
      `orca_session_id` so session-scoped upstreams route correctly)
    * otherwise → `OrcaHub.MCP.Tools.call/3`

  and returns the raw MCP result map (`%{"content" => [...], "isError" => bool}`).
  `dispatch/3` is the swappable seam: `ToolGen` bakes the dispatcher module into
  the generated functions, so tests can inject a stub returning canned envelopes
  without a live upstream.

  ## Unwrapping (`unwrap!/2`, `try/3`)

  The generated **named** functions (`Tools.github__get_issue/1`) auto-unwrap the
  MCP envelope and RAISE on `isError`:

    * text content → the concatenated string;
    * JSON content (text that decodes to a map/list) → the decoded term;
    * `isError == true` → `raise Tools.Error` carrying the tool name + the
      upstream error text.

  This makes tool calls compose with `|>` / `Enum`. The faithful full envelope
  is still reachable via `Tools.call/2`, and `Tools.try_call/2` (→ `try/3`)
  returns `{:ok, val} | {:error, reason}` for explicit `with`-style handling.

  Non-text content blocks (images, audio, embedded resources, resource links)
  are rendered by `OrcaHub.MCP.CodeExec.MediaSink` rather than silently
  dropped: binary blocks are written to disk and replaced with a `saved to
  <path>` note the model can hand to its `Read` tool, and anything else
  unsupported becomes a visible `[dropped ...]` note. Whenever a result
  contains at least one such block, the JSON-decode shortcut is skipped and
  `unwrap!/2` returns the concatenated text + notes as a plain string — a
  pure-text result is completely unaffected.

  A handful of upstream tools return huge *text* output (page snapshots,
  console/network logs) inline unless the caller passes `filename`, in which
  case they write it out-of-reach in their own pod. `dispatch/3` strips that
  arg and `unwrap!/2` saves the tool's full text output to disk itself (via
  `MediaSink.save_text/2`), replacing it with a single saved-to note — same
  goal as the media case, keeping large output out of the model's context.
  """

  alias OrcaHub.MCP.UpstreamClient
  alias OrcaHub.MCP.CodeExec
  alias OrcaHub.MCP.CodeExec.MediaSink

  # NOTE: `Tools` is intentionally NOT aliased to `OrcaHub.MCP.Tools` here — in
  # this module `Tools.Error` must resolve to the top-level exception module
  # (the one the model sees in error messages), so first-party dispatch uses the
  # fully-qualified `OrcaHub.MCP.Tools.call/3`.

  @doc """
  Dispatch a tool call by raw MCP name through the existing MCP path.

  `state` is the same `%{orca_session_id: ..., orchestrator: ...}` map the live
  MCP server threads into `OrcaHub.MCP.Tools.call/3`.

  When `name` is an upstream call to a tool in `@media_filename_tools` or
  `@text_filename_tools` with a `filename` arg, the arg is stripped before
  forwarding upstream — playwright-mcp writes the file inside its own pod when
  `filename` is set and returns only a link, unreachable from here (verified
  empirically: omit `filename` and these tools return their full output
  inline instead — an `image/png` content block for `browser_take_screenshot`,
  a text block for the rest). The requested name + mode is stashed via
  `MediaSink.put_requested_filename/1`:

    * `{:media, name}` — `unwrap!/2`'s call to `MediaSink.render/2` saves the
      screenshot locally under that name.
    * `{:text, name}` — `unwrap!/2` saves the tool's full joined text output
      to disk under that name via `MediaSink.save_text/2` and replaces it with
      a single saved-to note, instead of returning potentially huge output
      (snapshots, network logs) inline.

  This is reset (to `nil` when not applicable) on every dispatch call, so it
  can never leak into an unrelated tool's result.
  """
  def dispatch(name, args, state) when is_binary(name) and is_map(args) do
    if UpstreamClient.upstream_tool?(name) do
      {args, mode} = extract_requested_filename(name, args)
      MediaSink.put_requested_filename(mode)
      UpstreamClient.call_tool(name, args, orca_session_id: state[:orca_session_id])
    else
      MediaSink.put_requested_filename(nil)
      OrcaHub.MCP.Tools.call(name, args, state)
    end
  end

  # Tools that return an image content block when `filename` is omitted.
  @media_filename_tools ["browser_take_screenshot"]

  # Tools that return a text content block when `filename` is omitted. Suffix
  # match against the raw upstream name (e.g. `playwright__browser_evaluate`),
  # so both `browser_network_requests` (plural, list) and
  # `browser_network_request` (singular, single item) are covered distinctly.
  @text_filename_tools [
    "browser_snapshot",
    "browser_console_messages",
    "browser_network_requests",
    "browser_network_request",
    "browser_evaluate"
  ]

  @doc """
  If `name` is an upstream call (matched by suffix) to one of the known
  filename-trap tools carrying a `filename` arg, strip it and return it
  alongside the remaining args, tagged with its mode (`{:media, name}` or
  `{:text, name}`); otherwise return `args` unchanged with a `nil` mode.
  Exposed (rather than private) so its logic is directly unit-testable
  without a live upstream connection.
  """
  def extract_requested_filename(name, args) do
    cond do
      is_binary(args["filename"]) and suffix_match?(name, @media_filename_tools) ->
        {Map.delete(args, "filename"), {:media, args["filename"]}}

      is_binary(args["filename"]) and suffix_match?(name, @text_filename_tools) ->
        {Map.delete(args, "filename"), {:text, args["filename"]}}

      true ->
        {args, nil}
    end
  end

  defp suffix_match?(name, suffixes), do: Enum.any?(suffixes, &String.ends_with?(name, &1))

  @doc """
  Dispatch `name` (via `dispatcher`) using the process-installed MCP state, then
  auto-unwrap the result. Raises `Tools.Error` on an error envelope. Used by the
  generated named functions.
  """
  def invoke!(dispatcher, name, args) do
    dispatcher.dispatch(name, args, CodeExec.get_state()) |> unwrap!(name)
  end

  @doc "Like `invoke!/3` but returns `{:ok, value} | {:error, reason}`."
  def try(dispatcher, name, args) do
    {:ok, invoke!(dispatcher, name, args)}
  rescue
    e in Tools.Error -> {:error, e.message}
    e -> {:error, Exception.message(e)}
  end

  @doc "Dispatch `name` (via `dispatcher`) and return the faithful MCP envelope."
  def raw(dispatcher, name, args) do
    dispatcher.dispatch(name, args, CodeExec.get_state())
  end

  @doc """
  Auto-unwrap an MCP result map for `name`.

    * `isError == true` → `raise Tools.Error` (a pending `{:text, _}` request
      is discarded, unused, by the `extract_text/2` → `MediaSink.render/2`
      call below — no file is written for an error result)
    * a pending `{:text, name}` request (non-error only) → the full joined
      text output is saved to disk via `MediaSink.save_text/2` and replaced
      with a single saved-to note
    * content that decodes to a JSON map/list → the decoded term
    * otherwise → the concatenated text string (plus any `MediaSink` notes,
      e.g. a `{:media, name}` screenshot save)
  """
  def unwrap!(%{"isError" => true} = result, name) do
    raise Tools.Error, name: name, upstream: extract_text(result, name)
  end

  def unwrap!(%{"content" => content}, name) when is_list(content) do
    case MediaSink.peek_requested_filename() do
      {:text, filename} ->
        {parts, _has_notes?} = MediaSink.render(content, name)
        MediaSink.save_text(Enum.join(parts, "\n"), filename)

      _ ->
        {parts, has_notes?} = MediaSink.render(content, name)
        text = Enum.join(parts, "\n")

        if has_notes? do
          text
        else
          case Jason.decode(text) do
            {:ok, term} when is_map(term) or is_list(term) -> term
            _ -> text
          end
        end
    end
  end

  def unwrap!(other, _name), do: other

  defp extract_text(%{"content" => content}, name) when is_list(content) do
    {parts, _has_notes?} = MediaSink.render(content, name)
    Enum.join(parts, "\n")
  end

  defp extract_text(other, _name), do: inspect(other)
end
