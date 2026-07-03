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
end
