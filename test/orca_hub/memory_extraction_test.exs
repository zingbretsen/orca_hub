defmodule OrcaHub.MemoryExtractionTest do
  @moduledoc """
  Pure-function coverage for `OrcaHub.MemoryExtraction`'s scope rule,
  threshold/watermark decision, and transcript building — none of these
  touch the DB or the memory service, so this is a plain `ExUnit.Case`.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.MemoryExtraction

  describe "in_scope?/1 — default scope rule" do
    test "orchestrator sessions are in scope regardless of parentage" do
      assert MemoryExtraction.in_scope?(%{
               orchestrator: true,
               parent_session_id: Ecto.UUID.generate(),
               memory_extract: nil
             })
    end

    test "root (no parent) sessions are in scope" do
      assert MemoryExtraction.in_scope?(%{
               orchestrator: false,
               parent_session_id: nil,
               memory_extract: nil
             })
    end

    test "a non-orchestrator child session is out of scope" do
      refute MemoryExtraction.in_scope?(%{
               orchestrator: false,
               parent_session_id: Ecto.UUID.generate(),
               memory_extract: nil
             })
    end

    test "memory_extract: true overrides an out-of-scope child" do
      assert MemoryExtraction.in_scope?(%{
               orchestrator: false,
               parent_session_id: Ecto.UUID.generate(),
               memory_extract: true
             })
    end

    test "memory_extract: false overrides an in-scope root session" do
      refute MemoryExtraction.in_scope?(%{
               orchestrator: false,
               parent_session_id: nil,
               memory_extract: false
             })
    end

    test "memory_extract: false overrides an in-scope orchestrator" do
      refute MemoryExtraction.in_scope?(%{
               orchestrator: true,
               parent_session_id: nil,
               memory_extract: false
             })
    end
  end

  describe "decide/2 — threshold + watermark" do
    defp user_row(text) do
      %{"type" => "user", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
    end

    defp assistant_row(text) do
      %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => text}]}
      }
    end

    defp tool_result_row do
      %{
        "type" => "user",
        "message" => %{"content" => [%{"type" => "tool_result", "content" => "output"}]}
      }
    end

    test "no rows at all is a silent skip" do
      assert MemoryExtraction.decide([], false) == {:skip, :empty}
    end

    test "only tool-result echoes (no genuine user text) is a silent skip" do
      rows = [tool_result_row(), tool_result_row()]
      assert MemoryExtraction.decide(rows, false) == {:skip, :empty}
    end

    test "below 2 user turns is a skip even with plenty of chars" do
      rows = [user_row(String.duplicate("x", 1000)), assistant_row(String.duplicate("y", 1000))]
      assert MemoryExtraction.decide(rows, false) == {:skip, :below_threshold}
    end

    test "below 600 chars is a skip even with 2+ user turns" do
      rows = [user_row("hi"), assistant_row("hello"), user_row("thanks"), assistant_row("np")]
      assert MemoryExtraction.decide(rows, false) == {:skip, :below_threshold}
    end

    test "2+ user turns and 600+ chars dispatches" do
      rows = [
        user_row(String.duplicate("a", 400)),
        assistant_row(String.duplicate("b", 400)),
        user_row(String.duplicate("c", 400))
      ]

      assert {:dispatch, entries} = MemoryExtraction.decide(rows, false)
      assert length(entries) == 3
    end

    test "force: true dispatches below the threshold, but not on truly empty content" do
      rows = [user_row("hi")]
      assert {:dispatch, _entries} = MemoryExtraction.decide(rows, true)
      assert MemoryExtraction.decide([], true) == {:skip, :empty}
      assert MemoryExtraction.decide([tool_result_row()], true) == {:skip, :empty}
    end

    test "an assistant message with only tool_use (no text) contributes zero chars" do
      # 2 user turns totaling 500 chars — below the 600 threshold on its own;
      # the tool_use-only assistant message must NOT push it over (no markers).
      rows = [
        user_row(String.duplicate("a", 250)),
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "tool_use", "name" => "Bash", "input" => %{}}]}
        },
        user_row(String.duplicate("c", 250))
      ]

      assert MemoryExtraction.decide(rows, false) == {:skip, :below_threshold}
    end
  end

  describe "build_entries/1 — transcript rendering" do
    test "renders user text and assistant text as labeled lines, with no tool markers" do
      rows = [
        %{
          "type" => "user",
          "message" => %{"content" => [%{"type" => "text", "text" => "do the thing"}]}
        },
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "on it"},
              %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "ls"}}
            ]
          }
        }
      ]

      assert MemoryExtraction.build_entries(rows) == ["User: do the thing", "Assistant: on it"]
    end

    test "drops thinking blocks and a tool_use-only assistant message with no text" do
      rows = [
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "thinking", "text" => "hmm"}]}
        },
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "tool_use", "name" => "Bash", "input" => %{}}]}
        }
      ]

      assert MemoryExtraction.build_entries(rows) == []
    end

    test "drops a user row that carries only a tool_result (no text blocks)" do
      rows = [
        %{
          "type" => "user",
          "message" => %{"content" => [%{"type" => "tool_result", "content" => "output"}]}
        }
      ]

      assert MemoryExtraction.build_entries(rows) == []
    end

    test "ignores non-user/assistant rows entirely" do
      rows = [
        %{"type" => "system", "subtype" => "compaction_start"},
        %{"type" => "result", "result" => "done"}
      ]

      assert MemoryExtraction.build_entries(rows) == []
    end

    for prefix <- [
          "[Session lifecycle] Child session abc is now idle.",
          "[Worker alert] churn on Foo (abc): ...",
          "[Message from session abc]\n\nhello",
          "[Message from another session]\n\nhello",
          "[Message delivery note]\n\nThis message was sent...",
          "[Message delivery note - escalated]\n\nThis message was queued...",
          "[Heartbeat]\n\nCheck on worker sessions.",
          "[System] This node restarted..."
        ] do
      test "drops a hub-injected user message: #{inspect(prefix)}" do
        rows = [user_row(unquote(prefix))]
        assert MemoryExtraction.build_entries(rows) == []
      end
    end

    test "keeps an [Artifact ...interaction] user message — that's genuine human input" do
      text = ~s([Artifact "dashboard" interaction] {"action":"click"})
      rows = [user_row(text)]
      assert MemoryExtraction.build_entries(rows) == ["User: #{text}"]
    end

    test "a leading/trailing-whitespace hub prefix is still caught" do
      rows = [user_row("  [Heartbeat]\n\nCheck on worker sessions.")]
      assert MemoryExtraction.build_entries(rows) == []
    end
  end

  describe "chunk_entries/2" do
    test "empty entries produces an empty list of chunks" do
      assert MemoryExtraction.chunk_entries([], 100) == []
    end

    test "groups entries under the chunk budget together" do
      entries = ["a", "b", "c"]
      assert MemoryExtraction.chunk_entries(entries, 100) == [["a", "b", "c"]]
    end

    test "starts a new chunk once the budget would be exceeded, in order" do
      entries = ["12345", "12345", "12345"]
      # Each chunk holds at most 2 entries (10 chars) before a 3rd would exceed 12.
      assert MemoryExtraction.chunk_entries(entries, 12) == [
               ["12345", "12345"],
               ["12345"]
             ]
    end

    test "a single entry bigger than the budget is still its own chunk" do
      huge = String.duplicate("z", 50)
      assert MemoryExtraction.chunk_entries(["a", huge, "b"], 10) == [["a"], [huge], ["b"]]
    end
  end

  describe "build_transcript_file/3" do
    test "includes the header, hooks, and every chunk with Part N of M headings" do
      source = %{id: "src-1", directory: "/tmp/proj", title: "root session"}
      entries = ["User: hi", "Assistant: hello"]

      file = MemoryExtraction.build_transcript_file(entries, ["existing hook"], source)

      assert file =~ "Session: src-1"
      assert file =~ "Title: root session"
      assert file =~ "Directory: /tmp/proj"
      assert file =~ "existing hook"
      assert file =~ "## Part 1 of 1"
      assert file =~ "User: hi"
      assert file =~ "Assistant: hello"
    end

    test "placeholders when there are no existing hooks" do
      source = %{id: "src-2", directory: "/tmp/p", title: nil}
      file = MemoryExtraction.build_transcript_file(["User: hi"], [], source)
      assert file =~ "(none yet for this project)"
      assert file =~ "Title: (untitled)"
    end
  end

  describe "build_prompt/3" do
    test "references the transcript file path, the source session, and the created_by/source directive" do
      source = %{id: "src-123", directory: "/tmp/proj", title: "root session"}
      path = "/tmp/proj/.agents/memory-extraction/src-123.md"
      prompt = MemoryExtraction.build_prompt(path, ["existing hook one"], source)

      assert prompt =~ "src-123"
      assert prompt =~ path
      assert prompt =~ "existing hook one"
      assert prompt =~ "\"created_by\" => \"extraction\""
      assert prompt =~ "\"session_id\" => \"src-123\""
    end

    test "instructs weighing later/corrected messages over earlier ones" do
      source = %{id: "src-1", directory: "/tmp/p", title: nil}
      prompt = MemoryExtraction.build_prompt("/tmp/p/x.md", [], source)

      assert prompt =~ "Weigh LATER messages over earlier ones"
      assert prompt =~ "CORRECTION is the memory"
      assert prompt =~ "explicitly stated this"
    end
  end
end
