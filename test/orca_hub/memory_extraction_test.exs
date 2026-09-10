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
    defp user_row(text, id \\ "m-user") do
      %{
        id: id,
        data: %{
          "type" => "user",
          "message" => %{"content" => [%{"type" => "text", "text" => text}]}
        }
      }
    end

    defp assistant_row(text, id \\ "m-assistant") do
      %{
        id: id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => text}]}
        }
      }
    end

    defp tool_result_row do
      %{
        id: "m-tool-result",
        data: %{
          "type" => "user",
          "message" => %{"content" => [%{"type" => "tool_result", "content" => "output"}]}
        }
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
          id: "m-tool-use",
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [%{"type" => "tool_use", "name" => "Bash", "input" => %{}}]
            }
          }
        },
        user_row(String.duplicate("c", 250))
      ]

      assert MemoryExtraction.decide(rows, false) == {:skip, :below_threshold}
    end

    test "the [msg:<id>] marker's own characters do not count toward the 600-char threshold" do
      # 300 + 300 == 600 genuine chars of text — right at the threshold — but
      # each row's id is deliberately huge, so if the marker leaked into the
      # count this would easily clear 600 and dispatch instead of skipping.
      huge_id = String.duplicate("x", 5000)

      rows = [
        user_row(String.duplicate("a", 300), huge_id),
        assistant_row(String.duplicate("b", 299), huge_id)
      ]

      assert MemoryExtraction.decide(rows, false) == {:skip, :below_threshold}
    end
  end

  describe "build_entries/1 — transcript rendering" do
    test "renders user text and assistant text as labeled lines, each prefixed with its own " <>
           "[msg:<id>] marker, with no tool markers" do
      rows = [
        %{
          id: "row-1",
          data: %{
            "type" => "user",
            "message" => %{"content" => [%{"type" => "text", "text" => "do the thing"}]}
          }
        },
        %{
          id: "row-2",
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "text", "text" => "on it"},
                %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "ls"}}
              ]
            }
          }
        }
      ]

      assert MemoryExtraction.build_entries(rows) == [
               "[msg:row-1] User: do the thing",
               "[msg:row-2] Assistant: on it"
             ]
    end

    test "the marker prefers the message's own uuid/id over the row id — same fallback chain " <>
           "MessageComponents.tts_message_id/1 anchors that message's DOM node by" do
      rows = [
        %{
          id: "row-1",
          data: %{
            "type" => "assistant",
            "uuid" => "native-uuid-1",
            "id" => "should-not-win",
            "message" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
          }
        },
        %{
          id: "row-2",
          data: %{
            "type" => "assistant",
            "id" => "native-id-2",
            "message" => %{"content" => [%{"type" => "text", "text" => "there"}]}
          }
        }
      ]

      assert MemoryExtraction.build_entries(rows) == [
               "[msg:native-uuid-1] Assistant: hi",
               "[msg:native-id-2] Assistant: there"
             ]
    end

    test "drops thinking blocks and a tool_use-only assistant message with no text" do
      rows = [
        %{
          id: "row-1",
          data: %{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "thinking", "text" => "hmm"}]}
          }
        },
        %{
          id: "row-2",
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [%{"type" => "tool_use", "name" => "Bash", "input" => %{}}]
            }
          }
        }
      ]

      assert MemoryExtraction.build_entries(rows) == []
    end

    test "drops a user row that carries only a tool_result (no text blocks)" do
      rows = [tool_result_row()]
      assert MemoryExtraction.build_entries(rows) == []
    end

    test "ignores non-user/assistant rows entirely" do
      rows = [
        %{id: "row-1", data: %{"type" => "system", "subtype" => "compaction_start"}},
        %{id: "row-2", data: %{"type" => "result", "result" => "done"}}
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
      rows = [user_row(text, "row-artifact")]
      assert MemoryExtraction.build_entries(rows) == ["[msg:row-artifact] User: #{text}"]
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

  describe "build_transcript_file/4" do
    test "includes the header, hooks, tags, and every chunk with Part N of M headings" do
      source = %{id: "src-1", directory: "/tmp/proj", title: "root session"}
      entries = ["[msg:row-1] User: hi", "[msg:row-2] Assistant: hello"]
      tags = [%{"tag" => "trunk-based-dev", "count" => 4}]

      file = MemoryExtraction.build_transcript_file(entries, ["existing hook"], tags, source)

      assert file =~ "Session: src-1"
      assert file =~ "Title: root session"
      assert file =~ "Directory: /tmp/proj"
      assert file =~ "existing hook"
      assert file =~ "## Existing tags for this project"
      assert file =~ "trunk-based-dev (4)"
      assert file =~ "## Part 1 of 1"
      assert file =~ "[msg:row-1] User: hi"
      assert file =~ "[msg:row-2] Assistant: hello"
    end

    test "placeholders when there are no existing hooks" do
      source = %{id: "src-2", directory: "/tmp/p", title: nil}
      file = MemoryExtraction.build_transcript_file(["User: hi"], [], [], source)
      assert file =~ "(none yet for this project)"
      assert file =~ "Title: (untitled)"
    end

    test "omits the tags section entirely when there are no existing tags" do
      source = %{id: "src-3", directory: "/tmp/p", title: nil}
      file = MemoryExtraction.build_transcript_file(["User: hi"], [], [], source)
      refute file =~ "Existing tags"
    end
  end

  describe "build_prompt/4" do
    test "references the transcript file path, the source session, and the created_by/source directive" do
      source = %{id: "src-123", directory: "/tmp/proj", title: "root session"}
      path = "/tmp/proj/.agents/memory-extraction/src-123.md"
      prompt = MemoryExtraction.build_prompt(path, ["existing hook one"], [], source)

      assert prompt =~ "src-123"
      assert prompt =~ path
      assert prompt =~ "existing hook one"
      assert prompt =~ "\"created_by\" => \"extraction\""
      assert prompt =~ "\"session_id\" => \"src-123\""
    end

    test "instructs weighing later/corrected messages over earlier ones" do
      source = %{id: "src-1", directory: "/tmp/p", title: nil}
      prompt = MemoryExtraction.build_prompt("/tmp/p/x.md", [], [], source)

      assert prompt =~ "Weigh LATER messages over earlier ones"
      assert prompt =~ "CORRECTION is the memory"
      assert prompt =~ "explicitly stated this"
    end

    test "instructs the child to cite the [msg:<uuid>] marker of the best-evidence message in " <>
           "source.url" do
      source = %{id: "src-9", directory: "/tmp/p", title: nil}
      prompt = MemoryExtraction.build_prompt("/tmp/p/x.md", [], [], source)

      assert prompt =~ "\"url\" => \"/sessions/src-9#feed-<uuid>\""
      assert prompt =~ "[msg:<uuid>]"
      assert prompt =~ "FIRST one"
    end

    test "instructs 1-3 lowercase kebab-case tags, preferring existing ones, and lists them" do
      source = %{id: "src-9", directory: "/tmp/p", title: nil}
      tags = [%{"tag" => "homelab-postgres", "count" => 7}]
      prompt = MemoryExtraction.build_prompt("/tmp/p/x.md", [], tags, source)

      assert prompt =~ "1-3 `tags`"
      assert prompt =~ "lowercase kebab-case"
      assert prompt =~ "homelab-postgres (7)"
    end
  end
end
