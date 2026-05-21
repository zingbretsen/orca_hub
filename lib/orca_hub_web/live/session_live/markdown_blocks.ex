defmodule OrcaHubWeb.SessionLive.MarkdownBlocks do
  @moduledoc """
  Helpers for mapping line numbers within a markdown file to the index of
  the editable block that contains them.
  """

  alias OrcaHubWeb.Markdown

  @doc """
  Returns the index of the markdown block containing the given 1-based
  `line`, or `nil` if it cannot be determined.
  """
  def line_to_block_index(content, line) when is_integer(line) and line > 0 do
    lines = String.split(content, "\n")
    target_text = lines |> Enum.take(line) |> Enum.join("\n")
    blocks = Markdown.split_blocks(content)

    blocks
    |> Enum.reduce_while({0, nil}, fn block, acc ->
      block_match_step(content, target_text, block, acc)
    end)
    |> elem(1)
  end

  def line_to_block_index(_, _), do: nil

  defp block_match_step(content, target_text, {idx, block_text}, {search_from, _}) do
    scope = {search_from, byte_size(content) - search_from}

    case :binary.match(content, String.trim(block_text), [{:scope, scope}]) do
      {pos, len} -> advance_to_block(target_text, idx, pos, len)
      :nomatch -> {:cont, {search_from, idx}}
    end
  end

  defp advance_to_block(target_text, idx, pos, len) do
    block_end = pos + len

    if byte_size(target_text) <= block_end do
      {:halt, {0, idx}}
    else
      {:cont, {block_end, idx}}
    end
  end
end
