defmodule OrcaHubWeb.MessageComponentsTest do
  @moduledoc """
  Renderer check for backend_abstraction_spec.md §6.2/§9 (Phase 3, item 5):
  Codex items normalize onto EXISTING Claude tool names (Bash/Write/Edit/
  mcp__*/WebSearch/TodoWrite), so `MessageComponents` should need zero
  changes to render a Codex-backed session's feed.

  Feeds real `OrcaHub.Backend.Codex.normalize/2` output (not hand-rolled
  shapes) through `MessageComponents.message_feed/1` and asserts it renders
  without crashing and picks up the SAME tool icon/summary code paths as the
  Claude-named fixtures — no icon/summary changes were needed for Phase 3.
  Also covers §3.3's missing-field tolerance: a `result` event without
  `total_cost_usd`/`duration_ms`/`usage` (real for non-Claude backends)
  renders as "?" rather than crashing.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.Backend.Codex, as: CodexBackend
  alias OrcaHubWeb.MessageComponents

  defp ctx do
    %{
      session_id: Ecto.UUID.generate(),
      project_id: nil,
      claude_session_id: nil,
      directory: "/nonexistent-dir-#{System.unique_integer([:positive])}",
      model: nil,
      orchestrator: false,
      code_exec: false,
      db_node: nil,
      engine: :streaming,
      backend_state: %{}
    }
  end

  defp item_completed(item) do
    %{
      "method" => "item/completed",
      "params" => %{"threadId" => "t1", "turnId" => "turn-1", "item" => item}
    }
  end

  defp normalize!(native_event) do
    {events, _ctx} = CodexBackend.normalize(native_event, ctx())
    events
  end

  test "renders a full Codex-normalized feed (Bash/Write/Edit/mcp/WebSearch/TodoWrite) without crashing" do
    messages =
      [
        item_completed(%{
          "type" => "commandExecution",
          "id" => "cmd-1",
          "command" => "ls -la",
          "aggregatedOutput" => "file1\nfile2",
          "status" => "completed",
          "exitCode" => 0
        }),
        item_completed(%{
          "type" => "fileChange",
          "id" => "fc-1",
          "status" => "completed",
          "changes" => [
            %{"path" => "lib/foo.ex", "kind" => %{"type" => "add"}, "diff" => "+hello"}
          ]
        }),
        item_completed(%{
          "type" => "fileChange",
          "id" => "fc-2",
          "status" => "completed",
          "changes" => [
            %{"path" => "lib/bar.ex", "kind" => %{"type" => "update"}, "diff" => "-x\n+y"}
          ]
        }),
        item_completed(%{
          "type" => "mcpToolCall",
          "id" => "mcp-1",
          "server" => "orca",
          "tool" => "search_sessions",
          "arguments" => %{"query" => "foo"},
          "status" => "completed",
          "result" => %{"content" => [%{"type" => "text", "text" => "1 session found"}]}
        }),
        item_completed(%{"type" => "webSearch", "id" => "ws-1", "query" => "elixir genstatem"}),
        %{
          "method" => "turn/plan/updated",
          "params" => %{
            "turnId" => "turn-1",
            "plan" => [
              %{"step" => "first", "status" => "completed"},
              %{"step" => "second", "status" => "inProgress"}
            ]
          }
        }
      ]
      |> Enum.flat_map(&normalize!/1)

    # Missing-field tolerance (§3.3): non-Claude backends omit total_cost_usd
    # / duration_ms / usage on the result event.
    result_event = %{"type" => "result", "is_error" => false}

    html =
      render_component(&MessageComponents.message_feed/1, %{
        messages: messages ++ [result_event],
        session_node: nil
      })

    # Bash (commandExecution)
    assert html =~ "ls -la"
    assert html =~ "file1"
    # Write (fileChange add)
    assert html =~ "lib/foo.ex"
    # Edit (fileChange update)
    assert html =~ "lib/bar.ex"
    # mcp__orca__search_sessions (mcpToolCall)
    assert html =~ "search_sessions"
    # WebSearch
    assert html =~ "elixir genstatem"
    # TodoWrite (turn/plan/updated)
    assert html =~ "first"
    assert html =~ "second"
    # result card renders "?" for missing cost/duration instead of crashing
    assert html =~ "?"

    refute html == ""
  end

  test "an unmapped Codex item type drops silently instead of falling back to the raw-JSON dump" do
    events = normalize!(item_completed(%{"type" => "sleep", "id" => "s-1"}))
    assert events == []

    html =
      render_component(&MessageComponents.message_feed/1, %{messages: events, session_node: nil})

    refute html =~ "\"sleep\""
  end

  # tts_rewrite_spec.md §5 (Option A): the footer is dumb markup with no hook
  # of its own — a single delegated hook elsewhere resolves the target by id
  # lookup, never by DOM position, so the id has to be stable and present.
  describe "read-aloud (TTS) markup" do
    test "assistant text renders dumb data-tts-target markup, addressed by the message's own id" do
      msg = %{
        "type" => "assistant",
        "id" => "msg-abc",
        "message" => %{"content" => [%{"type" => "text", "text" => "hello there"}]}
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{messages: [msg], session_node: nil})

      assert html =~ ~s(id="tts-text-msg-abc")
      assert html =~ ~s(data-tts-text)
      assert html =~ ~s(id="tts-footer-msg-abc")
      assert html =~ ~s(data-tts-target="msg-abc")
      refute html =~ "phx-hook=\"TTSPlayer\""
      refute html =~ "data-tts-container"
    end

    test "falls back to a uuid, then a content hash, when no id is present (same order as the " <>
           "feed's own anchor id — see feed_item_anchor_id/1)" do
      with_uuid = %{
        "type" => "assistant",
        "uuid" => "u-1",
        "id" => "should-not-win",
        "message" => %{"content" => [%{"type" => "text", "text" => "a"}]}
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [with_uuid],
          session_node: nil
        })

      assert html =~ ~s(data-tts-target="u-1")

      no_id_at_all = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "b"}]}
      }

      html2 =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [no_id_at_all],
          session_node: nil
        })

      assert html2 =~ ~r/data-tts-target="h-?\d+"/
    end

    test "a tool-only assistant message (no text) renders no TTS footer at all" do
      msg = %{
        "type" => "assistant",
        "id" => "msg-tool-only",
        "message" => %{
          "content" => [%{"type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => %{}}]
        }
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{messages: [msg], session_node: nil})

      refute html =~ "tts-footer-msg-tool-only"
      refute html =~ "tts-text-msg-tool-only"
    end
  end

  test "MessageComponents.tts_message_id/1 and assistant_text/1 agree with what's rendered" do
    msg = %{
      "type" => "assistant",
      "id" => "msg-xyz",
      "message" => %{"content" => [%{"type" => "text", "text" => "hi there"}]}
    }

    assert MessageComponents.tts_message_id(msg) == "msg-xyz"
    assert MessageComponents.assistant_text(msg) == "hi there"
  end

  defp run_elixir_message(code) do
    %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "re-1",
            "name" => "mcp__orca__run_elixir",
            "input" => %{"code" => code}
          }
        ]
      }
    }
  end

  describe "run_elixir summary" do
    test "shows the statically-extracted Tools.* names when the Analyzer finds any" do
      code = ~s[Tools.search_sessions(%{"status" => "error"})]

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [run_elixir_message(code)],
          session_node: nil
        })

      assert html =~ "search_sessions"
    end

    test "falls back to the first-line code preview when nothing is extracted" do
      code = "x = [1, 2, 3]\nEnum.sum(x)"

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [run_elixir_message(code)],
          session_node: nil
        })

      assert html =~ "x = [1, 2, 3]"
    end
  end

  describe "pi backend groundwork event types (spec §12.3)" do
    test "pi_session_stats renders tokens/cost/context% instead of falling back to raw JSON" do
      stats = %{
        "type" => "pi_session_stats",
        "tokens" => %{"input" => 50_000, "output" => 10_000, "cacheRead" => 0, "total" => 60_000},
        "cost" => 0.45,
        "context_usage" => %{"tokens" => 60_000, "contextWindow" => 200_000, "percent" => 30}
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [stats],
          session_node: nil
        })

      assert html =~ "60000 tokens"
      assert html =~ "$0.45"
      assert html =~ "30% context"
      refute html =~ "pi_session_stats"
    end

    test "pi_session_stats tolerates a missing context_usage (compaction just ran)" do
      stats = %{
        "type" => "pi_session_stats",
        "tokens" => %{"total" => 100},
        "cost" => 0.0,
        "context_usage" => nil
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [stats],
          session_node: nil
        })

      assert html =~ "100 tokens"
      refute html =~ "context"
    end

    test "pi_ui_request is hidden from the feed (rendered separately as a live modal)" do
      request = %{
        "type" => "pi_ui_request",
        "id" => "ui-req-1",
        "method" => "select",
        "title" => "Red or blue?",
        "options" => ["Red", "Blue"]
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [request],
          session_node: nil
        })

      assert html =~ ~r/^\s*$/
      refute html =~ "Red or blue"
    end

    test "pi_ui_response renders the user's answer" do
      response = %{
        "type" => "pi_ui_response",
        "id" => "ui-req-1",
        "answer" => %{"value" => "Blue"}
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [response],
          session_node: nil
        })

      assert html =~ "You answered: Blue"
    end

    test "system/pi_notify (a fire-and-forget extension-UI method) shows its message" do
      notify = %{
        "type" => "system",
        "subtype" => "pi_notify",
        "message" => "Command blocked by user",
        "notify_type" => "warning"
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [notify],
          session_node: nil
        })

      assert html =~ "pi_notify"
      assert html =~ "Command blocked by user"
    end
  end

  # spec §12.6 — pi's compaction_start/compaction_end normalize onto the
  # SAME generic "system" rendering path exercised above for Codex's "init"
  # (no new component); this feeds real `Backend.Pi.normalize/2` output
  # through the renderer, same posture as the Codex coverage above.
  describe "pi compaction events (spec §12.6)" do
    alias OrcaHub.Backend.Pi, as: PiBackend

    defp pi_ctx do
      %{
        session_id: Ecto.UUID.generate(),
        project_id: nil,
        claude_session_id: nil,
        directory: "/nonexistent-dir-#{System.unique_integer([:positive])}",
        model: nil,
        orchestrator: false,
        code_exec: false,
        db_node: nil,
        engine: :streaming,
        backend_state: %{}
      }
    end

    defp pi_normalize!(native_event) do
      {events, _ctx} = PiBackend.normalize(native_event, pi_ctx())
      events
    end

    test "compaction_start renders a reason-suffixed label" do
      events = pi_normalize!(%{"type" => "compaction_start", "reason" => "threshold"})

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: events,
          session_node: nil
        })

      assert html =~ "Compacting context"
      assert html =~ "threshold"
    end

    test "compaction_end (success) renders a token-count label" do
      events =
        pi_normalize!(%{
          "type" => "compaction_end",
          "reason" => "threshold",
          "result" => %{"tokensBefore" => 150_000, "estimatedTokensAfter" => 32_000},
          "aborted" => false
        })

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: events,
          session_node: nil
        })

      assert html =~ "Compacted context"
      assert html =~ "150000"
      assert html =~ "32000"
    end

    test "compaction_end (aborted) renders an aborted label" do
      events =
        pi_normalize!(%{
          "type" => "compaction_end",
          "reason" => "manual",
          "result" => nil,
          "aborted" => true
        })

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: events,
          session_node: nil
        })

      assert html =~ "Compaction aborted"
    end

    test "compaction_end (failed, pi's message already self-describing) doesn't stutter the prefix" do
      events =
        pi_normalize!(%{
          "type" => "compaction_end",
          "reason" => "manual",
          "result" => nil,
          "aborted" => false,
          "errorMessage" => "Compaction failed: Nothing to compact (session too small)"
        })

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: events,
          session_node: nil
        })

      assert html =~ "Compaction failed: Nothing to compact (session too small)"
      refute html =~ "Compaction failed: Compaction failed:"
    end

    test "compaction_end (failed, generic error) gets our own prefix added" do
      events =
        pi_normalize!(%{
          "type" => "compaction_end",
          "reason" => "overflow",
          "result" => nil,
          "aborted" => false,
          "errorMessage" => "API quota exceeded"
        })

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: events,
          session_node: nil
        })

      assert html =~ "Compaction failed: API quota exceeded"
    end
  end

  # A windowed feed (see SessionLive.Show's @window_size) can hand
  # message_feed/1 a descendant whose subagent-anchor tool_use isn't among
  # the messages it was given — the anchor fell outside the window, was
  # never loaded, or the id is simply bad. message_feed/1 must be TOTAL: it
  # renders every message it's handed somewhere, never silently drops one
  # because it can't be nested.
  describe "orphaned subagent descendants (missing anchor tool_use)" do
    test "a descendant with no matching parent tool_use renders at top level, marked as orphaned" do
      orphan = %{
        "type" => "assistant",
        "parent_tool_use_id" => "toolu_missing",
        "message" => %{"content" => [%{"type" => "text", "text" => "orphaned descendant text"}]}
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [orphan],
          session_node: nil
        })

      assert html =~ "orphaned descendant text"
      assert html =~ "orphaned subagent fragment"
    end

    test "an orphaned task_* progress event (missing tool_use_id anchor) also renders at top level" do
      orphan_task_event = %{
        "type" => "system",
        "subtype" => "task_progress",
        "tool_use_id" => "toolu_missing",
        "message" => "orphaned task progress note"
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [orphan_task_event],
          session_node: nil
        })

      assert html =~ "orphaned task progress note"
      assert html =~ "orphaned subagent fragment"
    end

    test "normal nesting is unchanged: a descendant WITH a present parent tool_use nests, unmarked" do
      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "id" => "toolu_present", "name" => "Agent", "input" => %{}}
          ]
        }
      }

      child = %{
        "type" => "assistant",
        "parent_tool_use_id" => "toolu_present",
        "message" => %{"content" => [%{"type" => "text", "text" => "nested child reply"}]}
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [parent, child],
          session_node: nil
        })

      assert html =~ "nested child reply"
      refute html =~ "orphaned subagent fragment"
    end

    test "normal task_* progress nesting is unchanged when its tool_use anchor is present" do
      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "id" => "toolu_present2", "name" => "Agent", "input" => %{}}
          ]
        }
      }

      # subagent_block reads "description" for its progress-text header
      # (unlike the generic system_message component, which reads
      # "message" — hence the different field name from the orphaned case
      # above).
      task_event = %{
        "type" => "system",
        "subtype" => "task_progress",
        "tool_use_id" => "toolu_present2",
        "description" => "nested task progress note"
      }

      html =
        render_component(&MessageComponents.message_feed/1, %{
          messages: [parent, task_event],
          session_node: nil
        })

      assert html =~ "nested task progress note"
      refute html =~ "orphaned subagent fragment"
    end
  end
end
