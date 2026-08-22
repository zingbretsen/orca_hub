defmodule OrcaHub.Sessions.ChurnDetail do
  @moduledoc """
  Granular churn detail for a session (ORCAHUB3-44 Phase 2) — the
  actionable payload attached to a worker alert and available on demand via
  `get_session_tail`'s `include_churn_detail` arg.

  Computed from the messages table's assistant `tool_use` blocks (and
  paired `tool_result` content) over a trailing window (default
  #{30} minutes):

    - `top_edited_files` — histogram of Edit/Write/MultiEdit `file_path`
      inputs, top 5 by call count.
    - `top_repeated_signatures` — tool-call "signatures" (tool name +
      truncated input, matching the distinct-tools bucketing
      `Sessions.activity_metadata/1` already uses) that recurred 2+ times,
      top 3 by count, each with a ~80-char sample.
    - `failing_tests` — `mix test` summary lines (`N tests, M failures`)
      found in recent tool_result/user content, most-recent-first, capped
      at 3 entries, each with whatever failing test names are cheaply
      extractable from the surrounding lines (also capped at 3 per entry).

  Each sub-part is independently best-effort: a parse difficulty in one
  never affects the others, and `compute/1` never raises — it degrades to
  `[]` for whichever part(s) it couldn't make sense of.
  """

  import Ecto.Query

  alias OrcaHub.Repo
  alias OrcaHub.Sessions.Message

  @default_window_minutes 30
  @signature_input_chars 120
  @sample_chars 80
  @max_signatures 3
  @max_edited_files 5
  @max_failing_test_entries 3
  @max_failing_test_names_per_entry 3

  @doc """
  Fetches `session_id`'s messages from the last `window_minutes` (default
  #{@default_window_minutes}) and computes the granular detail block.
  """
  def fetch(session_id, opts \\ []) do
    window_minutes = Keyword.get(opts, :window_minutes, @default_window_minutes)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-window_minutes * 60, :second)

    messages =
      from(m in Message,
        where: m.session_id == ^session_id and m.inserted_at >= ^cutoff,
        order_by: [asc: m.inserted_at]
      )
      |> Repo.all()

    compute(messages)
  end

  @doc """
  Pure computation over an already-fetched, oldest-first list of message
  structs/maps (each needs only a `data` field/key) — the seam tests
  exercise directly with fabricated messages, and what `fetch/2` calls
  after its own DB query.
  """
  def compute(messages) do
    %{
      top_edited_files: safely(fn -> top_edited_files(messages) end),
      top_repeated_signatures: safely(fn -> top_repeated_signatures(messages) end),
      failing_tests: safely(fn -> failing_tests(messages) end)
    }
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> []
  end

  # -------------------------------------------------------------------
  # Top edited files
  # -------------------------------------------------------------------

  @edit_tool_names ~w(Edit Write MultiEdit)

  defp top_edited_files(messages) do
    messages
    |> Enum.flat_map(&tool_use_blocks/1)
    |> Enum.filter(&(&1["name"] in @edit_tool_names))
    |> Enum.map(&get_in(&1, ["input", "file_path"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_path, count} -> -count end)
    |> Enum.take(@max_edited_files)
    |> Enum.map(fn {path, count} -> %{path: path, count: count} end)
  end

  # -------------------------------------------------------------------
  # Top repeated signatures
  # -------------------------------------------------------------------

  defp top_repeated_signatures(messages) do
    messages
    |> Enum.flat_map(&tool_use_blocks/1)
    |> Enum.group_by(&signature/1)
    |> Enum.map(fn {_sig, blocks} -> {List.first(blocks), length(blocks)} end)
    |> Enum.filter(fn {_first, count} -> count >= 2 end)
    |> Enum.sort_by(fn {_first, count} -> -count end)
    |> Enum.take(@max_signatures)
    |> Enum.map(fn {block, count} ->
      %{tool: block["name"], count: count, sample: sample_text(block)}
    end)
  end

  defp signature(block) do
    input_json = block["input"] |> Jason.encode!() |> String.slice(0, @signature_input_chars)
    "#{block["name"]}:#{input_json}"
  end

  defp sample_text(block) do
    text = "#{block["name"]} #{Jason.encode!(block["input"])}"

    if String.length(text) > @sample_chars do
      String.slice(text, 0, @sample_chars - 1) <> "…"
    else
      text
    end
  end

  # -------------------------------------------------------------------
  # Failing tests
  # -------------------------------------------------------------------

  @summary_regex ~r/\d+ tests?, [1-9]\d* failures?/
  @failure_line_regex ~r/^\s*\d+\)\s+(.+?)\s*$/

  defp failing_tests(messages) do
    messages
    |> Enum.reverse()
    |> Enum.flat_map(&content_strings/1)
    |> Enum.flat_map(&extract_failing_entry/1)
    |> Enum.take(@max_failing_test_entries)
  end

  defp extract_failing_entry(content) when is_binary(content) do
    case Regex.run(@summary_regex, content) do
      [summary] ->
        names =
          content
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            case Regex.run(@failure_line_regex, line) do
              [_, name] -> [name]
              _ -> []
            end
          end)
          |> Enum.take(@max_failing_test_names_per_entry)

        [%{summary: summary, failing_test_names: names}]

      _ ->
        []
    end
  end

  defp extract_failing_entry(_), do: []

  # -------------------------------------------------------------------
  # Shared message parsing
  # -------------------------------------------------------------------

  defp tool_use_blocks(%{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use"))
  end

  defp tool_use_blocks(_), do: []

  # Every string worth scanning for a mix-test summary: tool_result content
  # (Bash output is the most likely home of a mix test run) and plain text
  # blocks.
  defp content_strings(%{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.flat_map(&block_strings/1)
  end

  defp content_strings(_), do: []

  defp block_strings(%{"type" => "tool_result", "content" => content}) when is_binary(content),
    do: [content]

  defp block_strings(%{"type" => "tool_result", "content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) && &1["type"] == "text" && is_binary(&1["text"])))
    |> Enum.map(& &1["text"])
  end

  defp block_strings(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]

  defp block_strings(_), do: []
end
