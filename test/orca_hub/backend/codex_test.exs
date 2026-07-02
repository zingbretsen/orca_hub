defmodule OrcaHub.Backend.CodexTest do
  @moduledoc """
  Normalization fixtures for `OrcaHub.Backend.Codex` (backend_abstraction_spec.md
  §6/§9, Phase 2 Step 4). Frames below are hand-authored to match the field
  names ground-truthed against `codex app-server generate-json-schema`
  (codex-cli 0.142.5) and a live (no-API-key) handshake capture — see §6.1's
  updated "Verified" note.

  Drives the protocol FSM end-to-end at the unit level: `on_open/1` ->
  `initialize` response -> `initialized` + `thread/start` queued via
  `pending_writes` -> `thread/start` response -> synthesized `system`/`init`
  event (+ any stashed prompt flushed as `turn/start`) -> item/completed
  mappings -> `thread/tokenUsage/updated` stashed -> `turn/completed`
  synthesizes `result` with usage attached. Also covers approval peer
  requests and `turn/interrupt` encoding.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Backend.Codex, as: Backend

  defp ctx(overrides \\ %{}) do
    base = %{
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

    Map.merge(base, Map.new(overrides))
  end

  defp decode_write(iodata) do
    iodata |> IO.iodata_to_binary() |> String.trim_trailing("\n") |> Jason.decode!()
  end

  # Mirrors Backend.Codex's own resolution order (real PATH lookup, or the
  # `:codex_executable` test seam when CodexStubIntegrationTest has it set) —
  # NOT a call into the module under test, just independent derivation that
  # stays correct if that seam happens to be active concurrently.
  defp expected_codex_executable do
    Application.get_env(:orca_hub, :codex_executable) || System.find_executable("codex")
  end

  # ── capabilities/0 (spec §3.1 Codex column) ───────────────────────────

  describe "capabilities/0" do
    test "matches the Codex column of spec §3.1" do
      caps = Backend.capabilities()

      assert caps.streaming == true
      assert caps.interrupt == :protocol
      assert caps.mcp == true
      assert caps.resume == true
      assert caps.usage == false
      assert caps.system_prompt == :leading_message
      assert caps.warmup_turn == false
    end
  end

  # ── on_open/1 -> initialize request ───────────────────────────────────

  describe "on_open/1" do
    test "writes the initialize request (id 0) and enters :handshaking" do
      {iodata, out} = Backend.on_open(ctx())
      req = decode_write(iodata)

      assert req["id"] == 0
      assert req["method"] == "initialize"
      assert req["params"]["clientInfo"]["name"] == "orca_hub"
      assert req["params"]["capabilities"]["experimentalApi"] == true

      assert req["params"]["capabilities"]["optOutNotificationMethods"] == [
               "item/agentMessage/delta",
               "item/reasoning/textDelta",
               "item/commandExecution/outputDelta"
             ]

      assert out.backend_state.phase == :handshaking
      assert out.backend_state.pending_requests == %{0 => :initialize}
    end
  end

  # ── Handshake reaction chain (normalize/2) ────────────────────────────

  describe "normalize/2 — handshake" do
    test "initialize's response queues initialized + thread/start via pending_writes" do
      {_iodata, opened} = Backend.on_open(ctx())

      {events, out} =
        Backend.normalize(
          %{
            "id" => 0,
            "result" => %{
              "codexHome" => "/tmp/x",
              "platformFamily" => "unix",
              "platformOs" => "linux",
              "userAgent" => "orca_hub/0.1"
            }
          },
          opened
        )

      assert events == []
      assert out.backend_state.phase == :ready
      assert out.backend_state.pending_requests == %{1 => :thread_start}

      [initialized_write, thread_start_write] = out.backend_state.pending_writes
      assert decode_write(initialized_write) == %{"method" => "initialized"}

      thread_start = decode_write(thread_start_write)
      assert thread_start["id"] == 1
      assert thread_start["method"] == "thread/start"
      assert thread_start["params"]["cwd"] == opened.directory
      assert thread_start["params"]["approvalPolicy"] == "never"
      assert thread_start["params"]["sandbox"] == "danger-full-access"
      refute Map.has_key?(thread_start["params"], "model")
    end

    test "an existing claude_session_id sends thread/resume instead of thread/start" do
      base = ctx(%{claude_session_id: "prior-thread-abc"})
      {_iodata, opened} = Backend.on_open(base)

      {[], out} =
        Backend.normalize(%{"id" => 0, "result" => %{}}, opened)

      assert out.backend_state.pending_requests == %{1 => :thread_resume}
      [_initialized, resume_write] = out.backend_state.pending_writes
      resume = decode_write(resume_write)
      assert resume["method"] == "thread/resume"
      assert resume["params"] == %{"threadId" => "prior-thread-abc"}
    end

    test "a non-Claude model is passed through on thread/start; a Claude model id is omitted" do
      {_io, opened} = Backend.on_open(ctx(%{model: "gpt-5.5"}))
      {[], out} = Backend.normalize(%{"id" => 0, "result" => %{}}, opened)
      [_init, thread_start_write] = out.backend_state.pending_writes
      assert decode_write(thread_start_write)["params"]["model"] == "gpt-5.5"

      {_io2, opened2} = Backend.on_open(ctx(%{model: "claude-sonnet-4-6"}))
      {[], out2} = Backend.normalize(%{"id" => 0, "result" => %{}}, opened2)
      [_init2, thread_start_write2] = out2.backend_state.pending_writes
      refute Map.has_key?(decode_write(thread_start_write2)["params"], "model")
    end

    test "thread/start's response synthesizes the system/init event and stashes thread_id" do
      thread_id = "thread-#{Ecto.UUID.generate()}"

      base = %{
        ctx()
        | backend_state: %{
            phase: :ready,
            next_id: 2,
            pending_requests: %{1 => :thread_start},
            pending_writes: []
          }
      }

      {events, out} =
        Backend.normalize(%{"id" => 1, "result" => %{"thread" => %{"id" => thread_id}}}, base)

      assert events == [%{"type" => "system", "session_id" => thread_id, "subtype" => "init"}]
      assert Backend.session_id(hd(events)) == thread_id
      assert out.backend_state.thread_id == thread_id
      assert out.backend_state.phase == :thread_started
      assert out.backend_state.pending_requests == %{}
      assert Map.get(out.backend_state, :pending_writes, []) == []
    end

    test "a prompt stashed by encode_user_turn/2 before the thread started is flushed as turn/start, prefixed with the leading-message system prompt" do
      session_ctx = ctx()
      {empty_iodata, stashed} = Backend.encode_user_turn("do the thing", session_ctx)
      assert empty_iodata == ""
      assert stashed.backend_state.pending_prompt == "do the thing"

      thread_id = "thread-xyz"

      base = %{
        stashed
        | backend_state:
            Map.merge(stashed.backend_state, %{
              phase: :ready,
              next_id: 2,
              pending_requests: %{1 => :thread_start},
              pending_writes: []
            })
      }

      {events, out} =
        Backend.normalize(%{"id" => 1, "result" => %{"thread" => %{"id" => thread_id}}}, base)

      assert [%{"type" => "system", "subtype" => "init"}] = events
      refute Map.has_key?(out.backend_state, :pending_prompt)

      [turn_start_write] = out.backend_state.pending_writes
      turn_start = decode_write(turn_start_write)
      assert turn_start["method"] == "turn/start"
      assert turn_start["params"]["threadId"] == thread_id

      [%{"type" => "text", "text" => text}] = turn_start["params"]["input"]
      assert String.ends_with?(text, "do the thing")
      assert text =~ "Your OrcaHub session ID is #{session_ctx.session_id}"
      assert out.backend_state.system_prompt_sent == true
    end
  end

  # ── encode_user_turn/2 once the thread is already started ────────────

  describe "encode_user_turn/2 — thread already started" do
    defp thread_started_ctx(overrides \\ %{}) do
      thread_id = "thread-started-1"

      base_ctx =
        ctx(
          Map.merge(
            %{
              backend_state: %{
                phase: :thread_started,
                thread_id: thread_id,
                next_id: 5,
                pending_requests: %{}
              }
            },
            overrides
          )
        )

      {base_ctx, thread_id}
    end

    test "first turn prepends the leading-message system prompt" do
      {c, _tid} = thread_started_ctx()
      {iodata, out} = Backend.encode_user_turn("hello", c)
      req = decode_write(iodata)

      assert req["method"] == "turn/start"
      [%{"type" => "text", "text" => text}] = req["params"]["input"]
      assert String.ends_with?(text, "hello")
      assert text =~ "Your OrcaHub session ID is #{c.session_id}"
      assert out.backend_state.system_prompt_sent == true
      assert out.backend_state.pending_requests[req["id"]] == :turn_start
    end

    test "a subsequent turn (system_prompt_sent already true) sends the prompt verbatim" do
      {c, _tid} =
        thread_started_ctx(%{
          backend_state: %{
            phase: :thread_started,
            thread_id: "t1",
            next_id: 9,
            pending_requests: %{},
            system_prompt_sent: true
          }
        })

      {iodata, _out} = Backend.encode_user_turn("just this", c)
      req = decode_write(iodata)
      assert req["params"]["input"] == [%{"type" => "text", "text" => "just this"}]
    end
  end

  # ── turn/start's response -> current_turn_id ──────────────────────────

  describe "normalize/2 — turn/start response and turn/started notification" do
    test "turn/start's response stashes current_turn_id, emits no event" do
      base = %{
        ctx()
        | backend_state: %{pending_requests: %{3 => :turn_start}, thread_id: "t1"}
      }

      {events, out} =
        Backend.normalize(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-1"}}}, base)

      assert events == []
      assert out.backend_state.current_turn_id == "turn-1"
      assert out.backend_state.pending_requests == %{}
    end

    test "the turn/started notification also stashes current_turn_id (belt-and-suspenders)" do
      {events, out} =
        Backend.normalize(
          %{"method" => "turn/started", "params" => %{"turn" => %{"id" => "turn-2"}}},
          ctx()
        )

      assert events == []
      assert out.backend_state.current_turn_id == "turn-2"
    end
  end

  # ── item/completed -> Claude-shaped tool_use/tool_result (spec §6.2) ──

  describe "normalize/2 — item/completed mappings" do
    test "agentMessage -> assistant text" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{
            "type" => "agentMessage",
            "id" => "item-1",
            "text" => "final answer",
            "phase" => "final_answer"
          }),
          ctx()
        )

      assert events == [
               %{
                 "type" => "assistant",
                 "message" => %{"content" => [%{"type" => "text", "text" => "final answer"}]}
               }
             ]
    end

    test "reasoning -> assistant thinking, joined content lines" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{
            "type" => "reasoning",
            "id" => "item-2",
            "content" => ["step one", "step two"]
          }),
          ctx()
        )

      assert events == [
               %{
                 "type" => "assistant",
                 "message" => %{
                   "content" => [%{"type" => "thinking", "thinking" => "step one\nstep two"}]
                 }
               }
             ]
    end

    test "reasoning with no content/summary drops silently" do
      {events, _ctx} =
        Backend.normalize(item_completed(%{"type" => "reasoning", "id" => "item-2b"}), ctx())

      assert events == []
    end

    test "commandExecution -> Bash tool_use + tool_result, ids paired" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{
            "type" => "commandExecution",
            "id" => "cmd-1",
            "command" => "ls -la",
            "aggregatedOutput" => "file1\nfile2",
            "status" => "completed",
            "exitCode" => 0
          }),
          ctx()
        )

      assert [
               %{"type" => "assistant", "message" => %{"content" => [tool_use]}},
               %{"type" => "user", "message" => %{"content" => [tool_result]}}
             ] = events

      assert tool_use == %{
               "type" => "tool_use",
               "id" => "cmd-1",
               "name" => "Bash",
               "input" => %{"command" => "ls -la"}
             }

      assert tool_result == %{
               "type" => "tool_result",
               "tool_use_id" => "cmd-1",
               "content" => "file1\nfile2",
               "is_error" => false
             }
    end

    test "commandExecution with status failed -> tool_result is_error true" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{
            "type" => "commandExecution",
            "id" => "cmd-2",
            "command" => "false",
            "aggregatedOutput" => "",
            "status" => "failed"
          }),
          ctx()
        )

      [_tool_use, tool_result] = events
      assert get_in(tool_result, ["message", "content", Access.at(0), "is_error"]) == true
    end

    test "fileChange (add) -> Write tool_use + tool_result" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{
            "type" => "fileChange",
            "id" => "fc-1",
            "status" => "completed",
            "changes" => [
              %{"path" => "lib/foo.ex", "kind" => %{"type" => "add"}, "diff" => "+hello"}
            ]
          }),
          ctx()
        )

      assert [
               %{"type" => "assistant", "message" => %{"content" => [tool_use]}},
               %{"type" => "user", "message" => %{"content" => [tool_result]}}
             ] = events

      assert tool_use["name"] == "Write"
      assert tool_use["id"] == "fc-1"
      assert tool_use["input"]["file_path"] == "lib/foo.ex"
      assert tool_result["tool_use_id"] == "fc-1"
      assert tool_result["content"] == "+hello"
    end

    test "fileChange (update) -> Edit tool_use" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{
            "type" => "fileChange",
            "id" => "fc-2",
            "status" => "completed",
            "changes" => [
              %{"path" => "lib/bar.ex", "kind" => %{"type" => "update"}, "diff" => "-x\n+y"}
            ]
          }),
          ctx()
        )

      [%{"type" => "assistant", "message" => %{"content" => [tool_use]}}, _result] = events
      assert tool_use["name"] == "Edit"
    end

    test "mcpToolCall -> mcp__server__tool tool_use + tool_result" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{
            "type" => "mcpToolCall",
            "id" => "mcp-1",
            "server" => "orca",
            "tool" => "search_sessions",
            "arguments" => %{"query" => "foo"},
            "status" => "completed",
            "result" => %{"content" => [%{"type" => "text", "text" => "1 session found"}]}
          }),
          ctx()
        )

      assert [
               %{"type" => "assistant", "message" => %{"content" => [tool_use]}},
               %{"type" => "user", "message" => %{"content" => [tool_result]}}
             ] = events

      assert tool_use["name"] == "mcp__orca__search_sessions"
      assert tool_use["id"] == "mcp-1"
      assert tool_use["input"] == %{"query" => "foo"}
      assert tool_result["tool_use_id"] == "mcp-1"
      assert tool_result["content"] == "1 session found"
      assert tool_result["is_error"] == false
    end

    test "mcpToolCall with an error -> tool_result is_error true, content from error message" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{
            "type" => "mcpToolCall",
            "id" => "mcp-2",
            "server" => "orca",
            "tool" => "broken_tool",
            "arguments" => %{},
            "status" => "failed",
            "error" => %{"message" => "boom"}
          }),
          ctx()
        )

      [_tool_use, %{"type" => "user", "message" => %{"content" => [tool_result]}}] = events
      assert tool_result["is_error"] == true
      assert tool_result["content"] == "boom"
    end

    test "webSearch -> WebSearch tool_use + empty tool_result" do
      {events, _ctx} =
        Backend.normalize(
          item_completed(%{"type" => "webSearch", "id" => "ws-1", "query" => "elixir genstatem"}),
          ctx()
        )

      assert [
               %{"type" => "assistant", "message" => %{"content" => [tool_use]}},
               %{"type" => "user", "message" => %{"content" => [tool_result]}}
             ] = events

      assert tool_use == %{
               "type" => "tool_use",
               "id" => "ws-1",
               "name" => "WebSearch",
               "input" => %{"query" => "elixir genstatem"}
             }

      assert tool_result["tool_use_id"] == "ws-1"
    end

    test "an unmapped item type is dropped, not rendered as a foreign shape" do
      {events, _ctx} =
        Backend.normalize(item_completed(%{"type" => "sleep", "id" => "s-1"}), ctx())

      assert events == []
    end

    test "item/started never emits an event" do
      {events, _ctx} =
        Backend.normalize(
          %{"method" => "item/started", "params" => %{"item" => %{"type" => "agentMessage"}}},
          ctx()
        )

      assert events == []
    end

    defp item_completed(item) do
      %{
        "method" => "item/completed",
        "params" => %{"threadId" => "t1", "turnId" => "turn-1", "item" => item}
      }
    end
  end

  # ── turn/plan/updated -> TodoWrite ─────────────────────────────────────

  describe "normalize/2 — turn/plan/updated" do
    test "maps to a TodoWrite tool_use, camelCase inProgress -> in_progress" do
      {[event], _ctx} =
        Backend.normalize(
          %{
            "method" => "turn/plan/updated",
            "params" => %{
              "turnId" => "turn-1",
              "plan" => [
                %{"step" => "first", "status" => "completed"},
                %{"step" => "second", "status" => "inProgress"},
                %{"step" => "third", "status" => "pending"}
              ]
            }
          },
          ctx()
        )

      assert %{"type" => "assistant", "message" => %{"content" => [tool_use]}} = event
      assert tool_use["name"] == "TodoWrite"

      assert tool_use["input"]["todos"] == [
               %{"content" => "first", "status" => "completed"},
               %{"content" => "second", "status" => "in_progress"},
               %{"content" => "third", "status" => "pending"}
             ]
    end
  end

  # ── thread/tokenUsage/updated -> stashed, attached at turn/completed ──

  describe "normalize/2 — token usage + turn/completed" do
    test "tokenUsage is stashed silently (no event)" do
      {events, out} =
        Backend.normalize(
          %{
            "method" => "thread/tokenUsage/updated",
            "params" => %{
              "threadId" => "t1",
              "turnId" => "turn-1",
              "tokenUsage" => %{
                "total" => %{
                  "totalTokens" => 100,
                  "inputTokens" => 60,
                  "outputTokens" => 40,
                  "cachedInputTokens" => 10,
                  "reasoningOutputTokens" => 0
                },
                "last" => %{}
              }
            }
          },
          ctx()
        )

      assert events == []
      assert out.backend_state.latest_token_usage["total"]["totalTokens"] == 100
    end

    test "turn/completed(completed) synthesizes a result event with the latest usage attached" do
      base = %{
        ctx()
        | backend_state: %{
            current_turn_id: "turn-1",
            latest_token_usage: %{
              "total" => %{"inputTokens" => 60, "outputTokens" => 40, "cachedInputTokens" => 10}
            }
          }
      }

      {[event], out} =
        Backend.normalize(
          %{
            "method" => "turn/completed",
            "params" => %{
              "threadId" => "t1",
              "turn" => %{"id" => "turn-1", "status" => "completed", "durationMs" => 4200}
            }
          },
          base
        )

      assert event["type"] == "result"
      assert event["is_error"] == false
      assert event["duration_ms"] == 4200

      assert event["usage"] == %{
               "input_tokens" => 60,
               "output_tokens" => 40,
               "cache_read_input_tokens" => 10
             }

      assert out.backend_state.current_turn_id == nil
    end

    test "turn/completed(failed) -> is_error true, error message surfaced" do
      {[event], _out} =
        Backend.normalize(
          %{
            "method" => "turn/completed",
            "params" => %{
              "turn" => %{
                "id" => "turn-1",
                "status" => "failed",
                "error" => %{"message" => "model overloaded"}
              }
            }
          },
          ctx()
        )

      assert event["is_error"] == true
      assert event["result"] == "model overloaded"
    end

    test "turn/completed(interrupted) -> is_error false (user stop, not an error)" do
      {[event], _out} =
        Backend.normalize(
          %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"id" => "turn-1", "status" => "interrupted"}}
          },
          ctx()
        )

      assert event["is_error"] == false
    end

    test "turn/completed with no usage stashed omits the usage key (missing-field tolerance)" do
      {[event], _out} =
        Backend.normalize(
          %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"id" => "turn-1", "status" => "completed"}}
          },
          ctx()
        )

      refute Map.has_key?(event, "usage")
      refute Map.has_key?(event, "total_cost_usd")
    end
  end

  # ── Error responses to tracked requests unstick the turn ──────────────

  describe "normalize/2 — JSON-RPC error responses" do
    test "an error response to a tracked request (e.g. turn/start) surfaces an error result" do
      base = %{ctx() | backend_state: %{pending_requests: %{4 => :turn_start}}}

      {[event], out} =
        Backend.normalize(
          %{"id" => 4, "error" => %{"code" => -1, "message" => "bad model"}},
          base
        )

      assert event == %{"type" => "result", "is_error" => true, "result" => "bad model"}
      assert out.backend_state.pending_requests == %{}
    end

    test "a response/error for an untracked id is silently dropped" do
      c = ctx()
      # pop_pending_request/2 normalizes backend_state.pending_requests to
      # %{} as a side effect even on a miss — harmless, so assert on the
      # meaningful parts (no events, id lookup was a no-op) rather than
      # struct-level equality with the pristine ctx.
      {events1, out1} = Backend.normalize(%{"id" => 999, "result" => %{}}, c)
      assert events1 == []
      assert out1.backend_state.pending_requests == %{}

      {events2, out2} = Backend.normalize(%{"id" => 999, "error" => %{"message" => "?"}}, c)
      assert events2 == []
      assert out2.backend_state.pending_requests == %{}
    end
  end

  # ── Unknown notifications are dropped, never rendered as a foreign shape ─

  describe "normalize/2 — unknown/unsolicited frames" do
    test "configWarning, remoteControl/status/changed, mcpServer/startupStatus/updated all drop" do
      c = ctx()

      for method <-
            ~w(configWarning remoteControl/status/changed mcpServer/startupStatus/updated thread/started_typo) do
        assert Backend.normalize(%{"method" => method, "params" => %{}}, c) == {[], c}
      end
    end
  end

  # ── Peer requests (approvals) ─────────────────────────────────────────

  describe "handle_peer_request/2" do
    test "commandExecution approval -> acceptForSession, id echoed verbatim" do
      c = ctx()

      {reply, events, out} =
        Backend.handle_peer_request(
          %{"id" => 7, "method" => "item/commandExecution/requestApproval"},
          c
        )

      assert decode_write(reply) == %{"id" => 7, "result" => %{"decision" => "acceptForSession"}}
      assert events == []
      assert out == c
    end

    test "fileChange approval -> acceptForSession" do
      {reply, _events, _ctx} =
        Backend.handle_peer_request(
          %{"id" => "str-id-8", "method" => "item/fileChange/requestApproval"},
          ctx()
        )

      assert decode_write(reply) == %{
               "id" => "str-id-8",
               "result" => %{"decision" => "acceptForSession"}
             }
    end

    test "permissions approval -> empty granted profile (different response shape than the others)" do
      {reply, _events, _ctx} =
        Backend.handle_peer_request(
          %{"id" => 9, "method" => "item/permissions/requestApproval"},
          ctx()
        )

      assert decode_write(reply) == %{"id" => 9, "result" => %{"permissions" => %{}}}
    end

    test "an unrecognized peer-request method still gets an empty-result reply (backstop, never hangs)" do
      {reply, events, _ctx} =
        Backend.handle_peer_request(%{"id" => 10, "method" => "some/future/method"}, ctx())

      assert decode_write(reply) == %{"id" => 10, "result" => %{}}
      assert events == []
    end
  end

  # ── encode_interrupt/2 ─────────────────────────────────────────────────

  describe "encode_interrupt/2" do
    test ":one_shot ctx returns :signal" do
      assert Backend.encode_interrupt("int_1", %{engine: :one_shot}) == :signal
    end

    test "an active thread+turn -> turn/interrupt frame" do
      base = %{
        ctx()
        | backend_state: %{thread_id: "t1", current_turn_id: "turn-1"}
      }

      iodata = Backend.encode_interrupt("int_5", base)

      assert decode_write(iodata) == %{
               "id" => "int_5",
               "method" => "turn/interrupt",
               "params" => %{"threadId" => "t1", "turnId" => "turn-1"}
             }
    end

    test "no active turn yet (still handshaking) -> empty iodata, never :signal" do
      assert Backend.encode_interrupt("int_6", ctx()) == ""
    end
  end

  # ── session_id/1 ────────────────────────────────────────────────────────

  describe "session_id/1" do
    test "extracts session_id from the synthesized system/init event" do
      assert Backend.session_id(%{"type" => "system", "session_id" => "abc"}) == "abc"
    end

    test "nil otherwise" do
      assert Backend.session_id(%{"type" => "assistant"}) == nil
      assert Backend.session_id(%{}) == nil
    end
  end

  # ── spawn_spec/2 ────────────────────────────────────────────────────────

  describe "spawn_spec/2 — :streaming" do
    test "codex app-server, :jsonrpc framing, CODEX_HOME baked into env" do
      c = ctx()
      spec = Backend.spawn_spec(:streaming, c)

      assert spec.executable == expected_codex_executable()
      assert spec.args == ["app-server"]
      assert spec.framing == :jsonrpc
      assert spec.port_opts == [cd: String.to_charlist(c.directory)]

      {_key, codex_home} = Enum.find(spec.env, fn {k, _v} -> k == ~c"CODEX_HOME" end)
      assert to_string(codex_home) == Path.join([c.directory, ".codex_home", c.session_id])
    end
  end

  describe "spawn_spec/2 — :one_shot" do
    test "codex exec --json fallback, :ndjson framing" do
      c = ctx(%{prompt: "hello"})
      spec = Backend.spawn_spec(:one_shot, c)

      assert spec.executable == expected_codex_executable()
      assert spec.framing == :ndjson
      assert "exec" in spec.args
      assert "--json" in spec.args
      assert List.last(spec.args) == "hello"
    end

    test "a non-Claude model adds -m <model>" do
      c = ctx(%{prompt: "hi", model: "gpt-5.5"})
      spec = Backend.spawn_spec(:one_shot, c)

      assert Enum.find_index(spec.args, &(&1 == "-m")) |> then(&Enum.at(spec.args, &1 + 1)) ==
               "gpt-5.5"
    end
  end

  # ── prepare_session/1 + cleanup_session/1 (CODEX_HOME + config.toml) ──

  describe "prepare_session/1 and cleanup_session/1" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "codex_backend_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, directory: dir}
    end

    test "writes CODEX_HOME/config.toml with the orca MCP stanza (same URL builder as Claude)", %{
      directory: dir
    } do
      c = ctx(%{directory: dir, orchestrator: true})
      assert Backend.prepare_session(c) == :ok

      config_path = Path.join([dir, ".codex_home", c.session_id, "config.toml"])
      assert File.exists?(config_path)
      contents = File.read!(config_path)

      assert contents =~ "[mcp_servers.orca]"
      assert contents =~ "default_tools_approval_mode = \"auto\""
      assert contents =~ OrcaHub.Backend.McpUrl.orca_url(c)

      assert Backend.cleanup_session(c) == :ok
      refute File.exists?(Path.join([dir, ".codex_home", c.session_id]))
    end
  end

  # ── system_prompt/1 (leading-message, Codex-flavored) ─────────────────

  describe "system_prompt/1" do
    test "includes the session id and drops the Claude-only AskUserQuestion guidance" do
      c = ctx()
      prompt = Backend.system_prompt(c)

      assert prompt =~ "Your OrcaHub session ID is #{c.session_id}"
      refute prompt =~ "AskUserQuestion"
    end

    test "orchestrator variant includes coordination guidance without the mcp__ prefix caveat" do
      c = ctx(%{orchestrator: true})
      prompt = Backend.system_prompt(c)

      assert prompt =~ "Orchestrator Session"
      assert prompt =~ "start_session"
      refute prompt =~ "mcp__orca__start_session"
    end
  end
end
