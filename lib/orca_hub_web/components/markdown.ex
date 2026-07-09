defmodule OrcaHubWeb.Markdown do
  @moduledoc """
  Renders markdown strings as HTML using Earmark.
  """

  def render(nil), do: ""
  def render(""), do: ""

  def render(markdown) when is_binary(markdown) do
    markdown
    |> Earmark.as_html!(
      code_class_prefix: "language-",
      registered_processors: [
        {"a",
         fn node ->
           Earmark.AstTools.merge_atts_in_node(node, target: "_blank", rel: "noopener noreferrer")
         end}
      ]
    )
    |> Phoenix.HTML.raw()
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
