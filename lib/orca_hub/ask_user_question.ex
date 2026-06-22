defmodule OrcaHub.AskUserQuestion do
  @moduledoc """
  Helpers for Claude's built-in `AskUserQuestion` tool.

  When a (non-orchestrator) session runs the Claude CLI, the model can call the
  built-in `AskUserQuestion` tool to ask the user a multiple-choice question.
  Under headless `claude -p`, the CLI emits the `AskUserQuestion` tool_use, then
  auto-injects a synthetic `tool_result` with `is_error: true` ("Answer
  questions?"), the model acknowledges, and the run exits with code 0.

  Because that synthetic error result is *always* present, it must NOT count as
  "answered". Only a NON-error `tool_result` for the same `tool_use_id` clears a
  pending question. In practice the user's answer arrives as a fresh user turn
  (via `send_message`), never as a real tool_result, so `pending_questions/1`
  will keep finding the last question "unanswered" — display is gated on the
  session `status == "waiting"`, not on the message history.

  The tool input looks like:

      %{"questions" => [
        %{"header" => "...", "question" => "...", "multiSelect" => false,
          "options" => [%{"label" => "...", "description" => "..."}, ...]}, ...]}

  (Note: options carry a `"label"` field — earlier drafts referred to `"name"`.)
  """

  @tool_name "AskUserQuestion"

  @doc """
  Scans a message list and returns the most recent `AskUserQuestion` tool_use
  that has no matching *non-error* `tool_result` after it.

  Returns `%{tool_use_id: id, questions: [...]}` or `nil`.

  `messages` is the flat list of message `data` maps (as stored / streamed),
  oldest first.
  """
  @spec pending_questions([map()]) :: %{tool_use_id: String.t(), questions: [map()]} | nil
  def pending_questions(messages) when is_list(messages) do
    answered_ids = answered_tool_use_ids(messages)

    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      case ask_user_question_block(message) do
        %{"id" => id, "input" => %{"questions" => questions}}
        when is_list(questions) and is_binary(id) ->
          if MapSet.member?(answered_ids, id) do
            nil
          else
            %{tool_use_id: id, questions: normalize_questions(questions)}
          end

        _ ->
          nil
      end
    end)
  end

  def pending_questions(_), do: nil

  @doc """
  Formats the user's selections into a clear text prompt to send back via the
  normal `send_message` path.

  `questions` is the (normalized) list of question maps. `selections` is a map
  of `question_index => [selected_label, ...]` (a list even for single-select).

  Returns a human-readable string Claude can act on.
  """
  @spec format_answers([map()], %{optional(non_neg_integer()) => [String.t()]}) :: String.t()
  def format_answers(questions, selections) when is_list(questions) and is_map(selections) do
    lines =
      questions
      |> Enum.with_index()
      |> Enum.map(fn {question, idx} ->
        label = question["header"] || question["question"] || "Question #{idx + 1}"

        answers =
          selections
          |> Map.get(idx, [])
          |> List.wrap()
          |> Enum.reject(&(&1 in [nil, ""]))

        answer_text =
          case answers do
            [] -> "(no answer)"
            list -> Enum.join(list, ", ")
          end

        "#{idx + 1}. #{label}: #{answer_text}"
      end)

    "Here are my answers to your questions:\n\n" <> Enum.join(lines, "\n")
  end

  @doc """
  Toggles a selection for a question page.

  `multi?` true → checkbox semantics (toggle the label in/out of the list).
  `multi?` false → radio semantics (the label replaces any prior selection).

  Returns the updated selections map (`page_index => [label, ...]`).
  """
  @spec toggle_selection(map(), non_neg_integer(), String.t(), boolean()) :: map()
  def toggle_selection(selections, page, label, true) do
    current = Map.get(selections, page, [])

    updated =
      if label in current, do: List.delete(current, label), else: current ++ [label]

    Map.put(selections, page, updated)
  end

  def toggle_selection(selections, page, label, false) do
    Map.put(selections, page, [label])
  end

  @doc """
  The set of question maps for a given pending result, normalized so that every
  option has `"label"` and `"description"` keys and every question has
  `"multiSelect"`, `"options"`, etc.
  """
  @spec normalize_questions([map()]) :: [map()]
  def normalize_questions(questions) when is_list(questions) do
    Enum.map(questions, fn question ->
      options =
        (question["options"] || [])
        |> Enum.map(fn opt ->
          %{
            "label" => opt["label"] || opt["name"] || "",
            "description" => opt["description"] || ""
          }
        end)

      %{
        "header" => question["header"] || "",
        "question" => question["question"] || "",
        "multiSelect" => question["multiSelect"] == true,
        "options" => options
      }
    end)
  end

  def normalize_questions(_), do: []

  # -- private --

  # Find an AskUserQuestion tool_use block within a single message's content.
  defp ask_user_question_block(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.find(content, fn
      %{"type" => "tool_use", "name" => @tool_name} -> true
      _ -> false
    end)
  end

  defp ask_user_question_block(_), do: nil

  # tool_use_ids that have a NON-error tool_result somewhere in the history.
  defp answered_tool_use_ids(messages) do
    messages
    |> Enum.flat_map(&tool_results/1)
    |> Enum.reduce(MapSet.new(), fn result, acc ->
      case result do
        %{"tool_use_id" => id} = r when is_binary(id) ->
          if r["is_error"] == true, do: acc, else: MapSet.put(acc, id)

        _ ->
          acc
      end
    end)
  end

  defp tool_results(%{"type" => "user", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.filter(content, fn
      %{"type" => "tool_result"} -> true
      _ -> false
    end)
  end

  defp tool_results(_), do: []
end
