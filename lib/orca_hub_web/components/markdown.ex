defmodule OrcaHubWeb.Markdown do
  @moduledoc """
  Renders markdown strings as HTML using Earmark.
  """

  def render(markdown, opts \\ [])
  def render(nil, _opts), do: ""
  def render("", _opts), do: ""

  def render(markdown, opts) when is_binary(markdown) do
    copy_code? = Keyword.get(opts, :copy_code, true)

    # NOTE: parse with the non-raising `Earmark.EarmarkParserProxy.as_ast/2`,
    # NOT `Earmark.as_ast!/2`. The `Earmark.as_html!/2` this replaced never
    # raises — it emits parser messages and returns the document anyway —
    # whereas `as_ast!/2` raises `Earmark.Error` whenever the parse status is
    # `:error`, which mere WARNINGS produce. Assistant prose containing an
    # Elixir tuple (`{:ok, nodes}`) reads as an illegal IAL and warns, so
    # `as_ast!/2` turned one such message into a 500 for the entire session
    # page. The AST is fully usable in the `:error` case, so take it either
    # way and preserve the old never-raise contract.
    {_status, ast, _messages} =
      Earmark.EarmarkParserProxy.as_ast(markdown, code_class_prefix: "language-")

    ast
    |> Earmark.Transform.map_ast(&postprocess_node(&1, copy_code?), true)
    |> Earmark.transform()
    |> Phoenix.HTML.raw()
  end

  # Applied to every AST node (see `render/1`): rewrites links to open in a
  # new tab (this used to be an `Earmark.as_html!` `registered_processors`
  # entry, moved here so `"pre"` can get the same single pass), and wraps
  # each fenced code block in the non-scrolling `code-copy-wrapper` +
  # `data-copy-code` button markup `message_components.ex`'s
  # `copy_code_wrapper/1` also emits (ORCAHUB3-58) — the two must stay in
  # sync since `assets/js/app.js`'s delegated click handler expects the same
  # `.code-copy-wrapper > pre` + `[data-copy-code]`/`[data-copy-icon]` shape
  # regardless of which one rendered it. Callers that render markdown into a
  # document with no `app.js` behind it (the artifact HTML export) pass
  # `copy_code: false` so they don't bake in a button that can never work.
  defp postprocess_node({"a", _atts, _children, _meta} = node, _copy_code?) do
    Earmark.AstTools.merge_atts_in_node(node, target: "_blank", rel: "noopener noreferrer")
  end

  defp postprocess_node({"pre", _atts, _children, _meta} = node, true) do
    {:replace, {"div", [{"class", "code-copy-wrapper relative"}], [node, copy_button_ast()], %{}}}
  end

  defp postprocess_node(node, _copy_code?), do: node

  defp copy_button_ast do
    {"button",
     [
       {"type", "button"},
       {"class",
        "copy-code-btn btn btn-ghost btn-xs btn-circle absolute top-1 right-1 opacity-70 hover:opacity-100 focus:opacity-100"},
       {"data-copy-code", "true"},
       {"title", "Copy"},
       {"aria-label", "Copy code"}
     ],
     [
       {"span", [{"class", "hero-clipboard-document-micro size-3.5"}, {"data-copy-icon", "true"}],
        [], %{}}
     ], %{}}
  end

  @doc """
  Splits a markdown string into a list of {index, raw_block_text} tuples.
  Each block is a top-level markdown element separated by blank lines.
  Fenced code blocks containing blank lines are kept intact.
  """
  def split_blocks(nil), do: []
  def split_blocks(""), do: []

  def split_blocks(markdown) do
    markdown
    |> String.split(~r/\n{2,}/)
    |> rejoin_fenced_code_blocks()
    |> Enum.with_index()
    |> Enum.map(fn {block, idx} -> {idx, String.trim(block)} end)
    |> Enum.reject(fn {_, text} -> text == "" end)
  end

  defp rejoin_fenced_code_blocks(chunks) do
    {result, current_fence} =
      Enum.reduce(chunks, {[], nil}, fn chunk, {acc, fence} ->
        fence_count = count_fences(chunk)

        case {fence, rem(fence_count, 2)} do
          # Not inside a fence, balanced fences (or none) in this chunk
          {nil, 0} -> {acc ++ [chunk], nil}
          # Not inside a fence, this chunk opens one
          {nil, 1} -> {acc, chunk}
          # Inside a fence, this chunk closes it
          {open, 1} -> {acc ++ [open <> "\n\n" <> chunk], nil}
          # Inside a fence, this chunk doesn't close it
          {open, 0} -> {acc, open <> "\n\n" <> chunk}
        end
      end)

    if current_fence, do: result ++ [current_fence], else: result
  end

  defp count_fences(text) do
    text
    |> String.split("\n")
    |> Enum.count(fn line -> Regex.match?(~r/^```/, String.trim(line)) end)
  end

  @doc "Renders a single markdown block to HTML."
  def render_block(block_text), do: render(block_text)

  @doc "Reconstructs full markdown from a list of {index, text} blocks."
  def join_blocks(blocks) do
    blocks
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map_join("\n\n", fn {_, text} -> text end)
  end

  @doc """
  Splits a leading `---`-delimited YAML frontmatter block off of `content`,
  if present. Returns `{frontmatter, body}` where `frontmatter` includes
  both delimiter lines verbatim (or `nil` if `content` has none), and
  `body` is everything after it with leading blank lines trimmed.

  Uses the same line-based delimiter detection as
  `OrcaHub.AgentMemory.parse_frontmatter/1`, but keeps the frontmatter's raw
  text instead of parsing it — so callers that only want to block-split the
  body (never the frontmatter internals) can reassemble byte-for-byte via
  `join_frontmatter/2`.
  """
  def split_frontmatter(content) when is_binary(content) do
    case String.split(content, "\n") do
      ["---" | rest] ->
        case Enum.split_while(rest, &(&1 != "---")) do
          {frontmatter_lines, ["---" | body_lines]} ->
            frontmatter = Enum.join(["---"] ++ frontmatter_lines ++ ["---"], "\n")
            body = body_lines |> Enum.join("\n") |> String.trim_leading("\n")
            {frontmatter, body}

          _ ->
            {nil, content}
        end

      _ ->
        {nil, content}
    end
  end

  @doc "Reassembles `split_frontmatter/1`'s output back into a full document."
  def join_frontmatter(nil, body), do: body
  def join_frontmatter(frontmatter, ""), do: frontmatter
  def join_frontmatter(frontmatter, body), do: frontmatter <> "\n\n" <> body
end
