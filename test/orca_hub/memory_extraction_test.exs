defmodule OrcaHub.MemoryExtractionTest do
  @moduledoc """
  Pure-function coverage for `OrcaHub.MemoryExtraction`'s scope rule,
  threshold/watermark decision, and transcript slice building — none of
  these touch the DB or the memory service, so this is a plain `ExUnit.Case`.
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
    defp user_row(text), do: %{"type" => "user", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
    defp assistant_row(text), do: %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
    defp tool_result_row, do: %{"type" => "user", "message" => %{"content" => [%{"type" => "tool_result", "content" => "output"}]}}

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
  end

  describe "build_entries/1 — transcript slice rendering" do
    test "renders user text and assistant text as labeled lines" do
      rows = [
        %{"type" => "user", "message" => %{"content" => [%{"type" => "text", "text" => "do the thing"}]}},
        %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "done"}]}}
      ]

      assert MemoryExtraction.build_entries(rows) == ["User: do the thing", "Assistant: done"]
    end

    test "reduces assistant tool_use blocks to [tool: Name] markers" do
      rows = [
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "let me check"},
              %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "ls"}},
              %{"type" => "tool_use", "name" => "Read", "input" => %{"file_path" => "x"}}
            ]
          }
        }
      ]

      assert MemoryExtraction.build_entries(rows) == [
               "Assistant: let me check [tool: Bash] [tool: Read]"
             ]
    end

    test "drops thinking blocks and a tool_use-only assistant message with no text" do
      rows = [
        %{"type" => "assistant", "message" => %{"content" => [%{"type" => "thinking", "text" => "hmm"}]}},
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "tool_use", "name" => "Bash", "input" => %{}}]}
        }
      ]

      assert MemoryExtraction.build_entries(rows) == ["Assistant: [tool: Bash]"]
    end

    test "drops a user row that carries only a tool_result (no text blocks)" do
      rows = [
        %{"type" => "user", "message" => %{"content" => [%{"type" => "tool_result", "content" => "output"}]}}
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

    test "caps a single message at the per-message char limit" do
      huge = String.duplicate("z", 10_000)
      rows = [%{"type" => "user", "message" => %{"content" => [%{"type" => "text", "text" => huge}]}}]

      [entry] = MemoryExtraction.build_entries(rows)
      assert entry =~ "…[truncated]"
      # "User: " (6) + 4_000 capped chars + the truncation suffix.
      assert String.length(entry) < String.length(huge)
    end
  end

  describe "cap_total/2 — total slice budget" do
    test "returns everything when under budget" do
      entries = ["a", "b", "c"]
      assert MemoryExtraction.cap_total(entries, 100) == entries
    end

    test "drops from the OLDEST end first, keeping the most recent entries" do
      entries = ["oldest", "middle", "newest"]
      # "middle" + "newest" == 12 chars, fits; adding "oldest" (6 more) doesn't.
      assert MemoryExtraction.cap_total(entries, 12) == ["middle", "newest"]
    end

    test "always keeps at least the single newest entry, even over budget" do
      entries = ["a", String.duplicate("z", 50)]
      assert MemoryExtraction.cap_total(entries, 10) == [String.duplicate("z", 50)]
    end

    test "preserves chronological (oldest-first) order in the surviving slice" do
      entries = ["1", "2", "3", "4"]
      assert MemoryExtraction.cap_total(entries, 3) == ["2", "3", "4"]
    end
  end

  describe "build_prompt/3" do
    test "includes the source session id/directory, existing hooks, and the created_by/source directive" do
      source = %{id: "src-123", directory: "/tmp/proj", title: "root session"}
      prompt = MemoryExtraction.build_prompt("User: hi\n\nAssistant: hello", ["existing hook one"], source)

      assert prompt =~ "src-123"
      assert prompt =~ "/tmp/proj"
      assert prompt =~ "existing hook one"
      assert prompt =~ "\"created_by\" => \"extraction\""
      assert prompt =~ "\"session_id\" => \"src-123\""
      assert prompt =~ "User: hi\n\nAssistant: hello"
    end

    test "renders a placeholder when there are no existing hooks" do
      source = %{id: "src-1", directory: "/tmp/p", title: nil}
      prompt = MemoryExtraction.build_prompt("transcript", [], source)
      assert prompt =~ "(none yet for this project)"
    end
  end
end
