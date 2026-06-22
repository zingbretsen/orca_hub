defmodule OrcaHub.AskUserQuestionTest do
  use ExUnit.Case, async: true

  alias OrcaHub.AskUserQuestion

  defp tool_use(id, questions) do
    %{
      "type" => "assistant",
      "message" => %{
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => id,
            "name" => "AskUserQuestion",
            "input" => %{"questions" => questions}
          }
        ]
      }
    }
  end

  defp tool_result(id, is_error) do
    %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => id,
            "is_error" => is_error,
            "content" => "x"
          }
        ]
      }
    }
  end

  defp question(header, multi \\ false) do
    %{
      "header" => header,
      "question" => "#{header}?",
      "multiSelect" => multi,
      "options" => [
        %{"label" => "A", "description" => "first"},
        %{"label" => "B", "description" => "second"}
      ]
    }
  end

  describe "pending_questions/1" do
    test "returns the questions + id for an unanswered AskUserQuestion" do
      messages = [tool_use("t1", [question("Lang")])]

      assert %{tool_use_id: "t1", questions: [q]} = AskUserQuestion.pending_questions(messages)
      assert q["header"] == "Lang"
      assert q["multiSelect"] == false
      assert [%{"label" => "A"}, %{"label" => "B"}] = q["options"]
    end

    test "a synthetic is_error tool_result does NOT count as answered" do
      messages = [
        tool_use("t1", [question("Lang")]),
        tool_result("t1", true)
      ]

      assert %{tool_use_id: "t1"} = AskUserQuestion.pending_questions(messages)
    end

    test "a non-error tool_result clears the pending question" do
      messages = [
        tool_use("t1", [question("Lang")]),
        tool_result("t1", false)
      ]

      assert AskUserQuestion.pending_questions(messages) == nil
    end

    test "returns the MOST RECENT unanswered question when several exist" do
      messages = [
        tool_use("t1", [question("First")]),
        tool_use("t2", [question("Second")])
      ]

      assert %{tool_use_id: "t2", questions: [q]} = AskUserQuestion.pending_questions(messages)
      assert q["header"] == "Second"
    end

    test "handles multiple questions in a single tool_use" do
      messages = [tool_use("t1", [question("One"), question("Two", true)])]

      assert %{questions: [q1, q2]} = AskUserQuestion.pending_questions(messages)
      assert q1["header"] == "One"
      assert q2["multiSelect"] == true
    end

    test "normalizes options that use legacy \"name\" instead of \"label\"" do
      messages = [
        tool_use("t1", [
          %{
            "header" => "H",
            "question" => "Q",
            "multiSelect" => false,
            "options" => [%{"name" => "Legacy", "description" => "d"}]
          }
        ])
      ]

      assert %{questions: [q]} = AskUserQuestion.pending_questions(messages)
      assert [%{"label" => "Legacy", "description" => "d"}] = q["options"]
    end

    test "returns nil for malformed / empty input" do
      assert AskUserQuestion.pending_questions([]) == nil
      assert AskUserQuestion.pending_questions(nil) == nil
      assert AskUserQuestion.pending_questions([%{"type" => "assistant"}]) == nil
      assert AskUserQuestion.pending_questions([%{"foo" => "bar"}]) == nil
    end

    test "ignores non-AskUserQuestion tool_use blocks" do
      messages = [
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "tool_use", "name" => "Bash", "id" => "b1"}]}
        }
      ]

      assert AskUserQuestion.pending_questions(messages) == nil
    end
  end

  describe "format_answers/2" do
    test "single-select uses the chosen label" do
      questions = [question("Language")]
      selections = %{0 => ["Rust"]}

      result = AskUserQuestion.format_answers(questions, selections)

      assert result =~ "Here are my answers to your questions:"
      assert result =~ "1. Language: Rust"
    end

    test "multi-select joins labels with commas" do
      questions = [question("Features", true)]
      selections = %{0 => ["Auth", "Billing"]}

      result = AskUserQuestion.format_answers(questions, selections)

      assert result =~ "1. Features: Auth, Billing"
    end

    test "numbers multiple questions and handles a missing answer" do
      questions = [question("One"), question("Two")]
      selections = %{0 => ["A"]}

      result = AskUserQuestion.format_answers(questions, selections)

      assert result =~ "1. One: A"
      assert result =~ "2. Two: (no answer)"
    end

    test "falls back to the question text when there is no header" do
      questions = [%{"question" => "Pick one", "options" => []}]
      selections = %{0 => ["X"]}

      assert AskUserQuestion.format_answers(questions, selections) =~ "1. Pick one: X"
    end
  end

  describe "toggle_selection/4" do
    test "single-select replaces the prior selection" do
      selections = AskUserQuestion.toggle_selection(%{}, 0, "A", false)
      assert selections == %{0 => ["A"]}

      selections = AskUserQuestion.toggle_selection(selections, 0, "B", false)
      assert selections == %{0 => ["B"]}
    end

    test "multi-select toggles labels in and out" do
      selections = AskUserQuestion.toggle_selection(%{}, 0, "A", true)
      selections = AskUserQuestion.toggle_selection(selections, 0, "B", true)
      assert selections == %{0 => ["A", "B"]}

      selections = AskUserQuestion.toggle_selection(selections, 0, "A", true)
      assert selections == %{0 => ["B"]}
    end
  end
end
