defmodule OrcaHub.Backend.PiTest do
  @moduledoc """
  Normalization fixtures for `OrcaHub.Backend.Pi` (backend_abstraction_spec.md
  §12.2). Frames below are copied verbatim (field-for-field) from a LIVE
  capture against the installed `pi` 0.80.3 binary (`pi --mode rpc` and
  `pi -p --mode json`, real Fireworks-provider turns) — see `pi.ex`'s
  moduledoc "Verified against 0.80.3" section for the capture methodology and
  every deviation found vs. the pre-implementation research draft.

  Covers: capabilities row, spawn args (model/session-dir/session-id/system-
  prompt flags for both engines), `on_open/1`'s get_state write,
  `encode_user_turn/2`/`encode_interrupt/2` framing, the full normalize walk
  (session-id capture via both the one-shot header and the streaming
  get_state response, assistant content mapping incl. tool-name/argument
  translation, tool_execution_end -> tool_result id pairing, agent_end ->
  synthesized result with summed usage/cost and error/abort handling), peer
  request handling (dialog vs. fire-and-forget extension UI methods),
  prepare/cleanup session lifecycle, and system_prompt content.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Backend.Pi, as: Backend

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

  defp expected_pi_executable do
    Application.get_env(:orca_hub, :pi_executable) || System.find_executable("pi")
  end

  # ── capabilities/0 (spec §12.2 capability row) ────────────────────────

  describe "capabilities/0" do
    test "matches the pi row of spec §12.2" do
      caps = Backend.capabilities()

      assert caps.streaming == true
      assert caps.interrupt == :protocol
      assert caps.mcp == false
      assert caps.resume == true
      assert caps.usage == false
      assert caps.system_prompt == :flag
      assert caps.warmup_turn == false
      assert caps.plan_mode == false
      assert caps.ask_user_question == true
      assert caps.session_stats == true
      assert caps.steering == true
    end
  end

  # ── models/0 ───────────────────────────────────────────────────────────

  describe "models/0 — live catalog via `pi --list-models`" do
    @list_models_stub Path.expand("../../support/fixtures/pi_stub_list_models.sh", __DIR__)

    test "shells out to the (seamed) executable and parses the table" do
      previous = Application.get_env(:orca_hub, :pi_executable)
      Application.put_env(:orca_hub, :pi_executable, @list_models_stub)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:orca_hub, :pi_executable, previous),
          else: Application.delete_env(:orca_hub, :pi_executable)
      end)

      assert Backend.models() == [
               {"fireworks/accounts/fireworks/models/glm-5p2", "glm-5p2 (fireworks)"},
               {"fireworks/accounts/fireworks/models/kimi-k2p6", "kimi-k2p6 (fireworks)"}
             ]
    end

    test "degrades to [] when the executable can't answer" do
      previous = Application.get_env(:orca_hub, :pi_executable)

      Application.put_env(
        :orca_hub,
        :pi_executable,
        "/nonexistent/pi-#{System.unique_integer([:positive])}"
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:orca_hub, :pi_executable, previous),
          else: Application.delete_env(:orca_hub, :pi_executable)
      end)

      assert Backend.models() == []
    end
  end

  describe "parse_model_list/1" do
    test "parses provider/model rows into {combined_id, basename_label} pairs" do
      output = """
      provider   model                                context  max-out  thinking  images
      fireworks  accounts/fireworks/models/glm-5p2    1.0M     131.1K   yes       no
      anthropic  claude-sonnet-4-20250514             200K     64K      yes       yes
      """

      assert Backend.parse_model_list(output) == [
               {"fireworks/accounts/fireworks/models/glm-5p2", "glm-5p2 (fireworks)"},
               {"anthropic/claude-sonnet-4-20250514", "claude-sonnet-4-20250514 (anthropic)"}
             ]
    end

    test "tolerates blank lines and short/malformed rows" do
      assert Backend.parse_model_list("provider model\n\nonlyonecolumn\n") == []
      assert Backend.parse_model_list("") == []
    end
  end

  # ── spawn_spec/2 ────────────────────────────────────────────────────────

  describe "spawn_spec/2 — :streaming" do
    test "pi --mode rpc, :ndjson framing, session-dir baked in" do
      c = ctx()
      spec = Backend.spawn_spec(:streaming, c)

      assert spec.executable == expected_pi_executable()
      assert spec.framing == :ndjson
      assert spec.port_opts == [cd: String.to_charlist(c.directory)]
      assert List.starts_with?(spec.args, ["--mode", "rpc"])

      assert "--session-dir" in spec.args

      dir_index = Enum.find_index(spec.args, &(&1 == "--session-dir"))

      assert Enum.at(spec.args, dir_index + 1) ==
               Path.join([c.directory, ".pi_sessions", c.session_id])
    end

    test "no --session-id flag when claude_session_id is nil (fresh session)" do
      spec = Backend.spawn_spec(:streaming, ctx())
      refute "--session-id" in spec.args
    end

    test "--session-id <id> when resuming" do
      c = ctx(%{claude_session_id: "prior-session-abc"})
      spec = Backend.spawn_spec(:streaming, c)

      idx = Enum.find_index(spec.args, &(&1 == "--session-id"))
      assert Enum.at(spec.args, idx + 1) == "prior-session-abc"
    end

    test "a non-Claude model is passed through via --model; a Claude model id is omitted" do
      spec =
        Backend.spawn_spec(:streaming, ctx(%{model: "fireworks/accounts/fireworks/models/glm-5"}))

      idx = Enum.find_index(spec.args, &(&1 == "--model"))
      assert Enum.at(spec.args, idx + 1) == "fireworks/accounts/fireworks/models/glm-5"

      spec2 = Backend.spawn_spec(:streaming, ctx(%{model: "claude-sonnet-4-6"}))
      refute "--model" in spec2.args
    end

    test "--append-system-prompt carries the built system prompt" do
      c = ctx()
      spec = Backend.spawn_spec(:streaming, c)
      idx = Enum.find_index(spec.args, &(&1 == "--append-system-prompt"))
      prompt = Enum.at(spec.args, idx + 1)
      assert prompt =~ "Your OrcaHub session ID is #{c.session_id}"
    end

    test "-e loads priv/pi/orca.ts, resolved via Application.app_dir/2 (release-safe)" do
      spec = Backend.spawn_spec(:streaming, ctx())
      idx = Enum.find_index(spec.args, &(&1 == "-e"))
      refute is_nil(idx)

      expected = Application.app_dir(:orca_hub, "priv/pi/orca.ts")
      assert Enum.at(spec.args, idx + 1) == expected
      assert File.exists?(expected)
    end
  end

  describe "spawn_spec/2 — :one_shot" do
    test "pi -p --mode json, prompt is the last positional arg" do
      c = ctx(%{prompt: "hello there"})
      spec = Backend.spawn_spec(:one_shot, c)

      assert spec.executable == expected_pi_executable()
      assert spec.framing == :ndjson
      assert List.starts_with?(spec.args, ["-p", "--mode", "json"])
      assert List.last(spec.args) == "hello there"
    end
  end

  # ── on_open/1 ────────────────────────────────────────────────────────────

  describe "on_open/1" do
    test "writes a get_state command and leaves ctx otherwise unchanged" do
      c = ctx()
      {iodata, out} = Backend.on_open(c)
      assert decode_write(iodata) == %{"type" => "get_state"}
      assert out == c
    end
  end

  # ── encode_user_turn/2 and encode_interrupt/2 ───────────────────────────

  describe "encode_user_turn/2" do
    test "writes a plain prompt command every time (no handshake to wait on)" do
      c = ctx()
      {iodata, out} = Backend.encode_user_turn("do the thing", c)
      assert decode_write(iodata) == %{"type" => "prompt", "message" => "do the thing"}
      assert out == c
    end
  end

  describe "encode_interrupt/2" do
    test ":one_shot ctx returns :signal" do
      assert Backend.encode_interrupt("int_1", %{engine: :one_shot}) == :signal
    end

    test "streaming ctx returns an abort frame" do
      iodata = Backend.encode_interrupt("int_1", ctx())
      assert decode_write(iodata) == %{"type" => "abort"}
    end
  end

  # ── normalize/2 — session id capture ────────────────────────────────────

  describe "normalize/2 — session id capture" do
    test "one-shot's unprompted session header -> synthesized system/init" do
      c = ctx()

      {events, out} =
        Backend.normalize(
          %{
            "type" => "session",
            "version" => 3,
            "id" => "a71400c3-462b-46a9-bdc0-d63f02316172",
            "timestamp" => "2026-07-03T14:18:59.749Z",
            "cwd" => "/tmp/x"
          },
          c
        )

      assert events == [
               %{
                 "type" => "system",
                 "session_id" => "a71400c3-462b-46a9-bdc0-d63f02316172",
                 "subtype" => "init"
               }
             ]

      assert Backend.session_id(hd(events)) == "a71400c3-462b-46a9-bdc0-d63f02316172"
      assert out == c
    end

    test "streaming's get_state response -> synthesized system/init" do
      {events, _out} =
        Backend.normalize(
          %{
            "type" => "response",
            "command" => "get_state",
            "success" => true,
            "data" => %{
              "sessionId" => "019f2851-8a6e-79a2-974b-5624f3d14173",
              "sessionFile" => "/tmp/x/019f2851.jsonl",
              "messageCount" => 0
            }
          },
          ctx()
        )

      assert events == [
               %{
                 "type" => "system",
                 "session_id" => "019f2851-8a6e-79a2-974b-5624f3d14173",
                 "subtype" => "init"
               }
             ]
    end

    test "a get_state response with no sessionId (defensive) drops silently" do
      {events, _out} =
        Backend.normalize(
          %{"type" => "response", "command" => "get_state", "success" => true, "data" => %{}},
          ctx()
        )

      assert events == []
    end
  end

  # ── normalize/2 — rejected prompt (defensive, never hang) ───────────────

  describe "normalize/2 — rejected prompt command" do
    test "success:false on the prompt response surfaces an error result" do
      {[event], _out} =
        Backend.normalize(
          %{
            "type" => "response",
            "command" => "prompt",
            "success" => false,
            "error" => "already streaming"
          },
          ctx()
        )

      assert event == %{"type" => "result", "is_error" => true, "result" => "already streaming"}
    end

    test "other command responses (e.g. abort ack) emit nothing" do
      {events, _out} =
        Backend.normalize(
          %{"type" => "response", "command" => "abort", "success" => true},
          ctx()
        )

      assert events == []
    end
  end

  # ── normalize/2 — message_end -> assistant content ──────────────────────

  describe "normalize/2 — message_end (assistant)" do
    test "text + toolCall content maps to a single assistant event with translated blocks" do
      msg = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "thinking", "thinking" => "Need to run bash.", "thinkingSignature" => ""},
          %{
            "type" => "toolCall",
            "id" => "call_lIlrGChG3WVTy3FGI76LNS8z",
            "name" => "bash",
            "arguments" => %{"command" => "echo hi", "timeout" => 5}
          }
        ],
        "stopReason" => "toolUse"
      }

      {[event], _out} =
        Backend.normalize(%{"type" => "message_end", "message" => msg}, ctx())

      assert event == %{
               "type" => "assistant",
               "message" => %{
                 "content" => [
                   %{"type" => "thinking", "thinking" => "Need to run bash."},
                   %{
                     "type" => "tool_use",
                     "id" => "call_lIlrGChG3WVTy3FGI76LNS8z",
                     "name" => "Bash",
                     "input" => %{"command" => "echo hi", "timeout" => 5}
                   }
                 ]
               }
             }
    end

    test "final text-only assistant message" do
      msg = %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "The output is: hi"}],
        "stopReason" => "stop"
      }

      {[event], _out} = Backend.normalize(%{"type" => "message_end", "message" => msg}, ctx())

      assert event == %{
               "type" => "assistant",
               "message" => %{"content" => [%{"type" => "text", "text" => "The output is: hi"}]}
             }
    end

    test "an aborted assistant message with empty content emits nothing" do
      msg = %{"role" => "assistant", "content" => [], "stopReason" => "aborted"}
      {events, _out} = Backend.normalize(%{"type" => "message_end", "message" => msg}, ctx())
      assert events == []
    end

    test "a user or toolResult message_end (echo) emits nothing — not the source of truth" do
      user_msg = %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}
      {events, _out} = Backend.normalize(%{"type" => "message_end", "message" => user_msg}, ctx())
      assert events == []

      tr_msg = %{
        "role" => "toolResult",
        "toolCallId" => "call_1",
        "content" => [%{"type" => "text", "text" => "hi"}]
      }

      {events2, _out} = Backend.normalize(%{"type" => "message_end", "message" => tr_msg}, ctx())
      assert events2 == []
    end
  end

  # ── Built-in tool name/argument translation ─────────────────────────────

  describe "normalize/2 — built-in tool argument translation" do
    defp tool_use_from(name, arguments) do
      msg = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "toolCall", "id" => "call_x", "name" => name, "arguments" => arguments}
        ]
      }

      {[event], _out} = Backend.normalize(%{"type" => "message_end", "message" => msg}, ctx())
      [tool_use] = get_in(event, ["message", "content"])
      tool_use
    end

    test "read: path -> file_path, name -> Read" do
      tu = tool_use_from("read", %{"path" => "lib/foo.ex", "limit" => 100})
      assert tu["name"] == "Read"
      assert tu["input"]["file_path"] == "lib/foo.ex"
    end

    test "write: path -> file_path, name -> Write" do
      tu = tool_use_from("write", %{"path" => "lib/foo.ex", "content" => "defmodule Foo"})
      assert tu["name"] == "Write"
      assert tu["input"]["file_path"] == "lib/foo.ex"
      assert tu["input"]["content"] == "defmodule Foo"
    end

    test "edit: path -> file_path, single edits[] entry -> old_string/new_string" do
      tu =
        tool_use_from("edit", %{
          "path" => "lib/foo.ex",
          "edits" => [%{"oldText" => "1 + 1", "newText" => "2 + 2"}]
        })

      assert tu["name"] == "Edit"
      assert tu["input"]["file_path"] == "lib/foo.ex"
      assert tu["input"]["old_string"] == "1 + 1"
      assert tu["input"]["new_string"] == "2 + 2"
    end

    test "edit: multiple edits[] entries are separator-joined" do
      tu =
        tool_use_from("edit", %{
          "path" => "lib/foo.ex",
          "edits" => [
            %{"oldText" => "a", "newText" => "b"},
            %{"oldText" => "c", "newText" => "d"}
          ]
        })

      assert tu["input"]["old_string"] == "a\n---\nc"
      assert tu["input"]["new_string"] == "b\n---\nd"
    end

    test "grep/find/ls (no Claude analogue) pass through unchanged" do
      tu = tool_use_from("grep", %{"pattern" => "foo", "path" => "lib"})
      assert tu["name"] == "grep"
      assert tu["input"] == %{"pattern" => "foo", "path" => "lib"}
    end
  end

  # ── normalize/2 — tool_execution_end -> tool_result (§3.3 pairing) ──────

  describe "normalize/2 — tool_execution_end" do
    test "successful tool result, ids paired with the tool_use" do
      {[event], _out} =
        Backend.normalize(
          %{
            "type" => "tool_execution_end",
            "toolCallId" => "call_lIlrGChG3WVTy3FGI76LNS8z",
            "toolName" => "bash",
            "result" => %{"content" => [%{"type" => "text", "text" => "hi\n"}]},
            "isError" => false
          },
          ctx()
        )

      assert event == %{
               "type" => "user",
               "message" => %{
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "call_lIlrGChG3WVTy3FGI76LNS8z",
                     "content" => [%{"type" => "text", "text" => "hi\n"}],
                     "is_error" => false
                   }
                 ]
               }
             }
    end

    test "a failed tool result -> is_error true" do
      {[event], _out} =
        Backend.normalize(
          %{
            "type" => "tool_execution_end",
            "toolCallId" => "call_2",
            "toolName" => "bash",
            "result" => %{"content" => [%{"type" => "text", "text" => "boom"}]},
            "isError" => true
          },
          ctx()
        )

      assert get_in(event, ["message", "content", Access.at(0), "is_error"]) == true
    end
  end

  # ── normalize/2 — agent_start / agent_end -> synthesized result ─────────

  describe "normalize/2 — agent_start/agent_end" do
    test "agent_start stashes a start timestamp, emits nothing" do
      {events, out} = Backend.normalize(%{"type" => "agent_start"}, ctx())
      assert events == []
      assert is_integer(out.backend_state.agent_start_ms)
    end

    test "agent_end synthesizes a result with duration_ms, total_cost_usd, and usage" do
      base = %{
        ctx()
        | backend_state: %{agent_start_ms: System.monotonic_time(:millisecond) - 25}
      }

      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]},
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "hi back"}],
          "usage" => %{
            "input" => 100,
            "output" => 20,
            "cacheRead" => 10,
            "cacheWrite" => 0,
            "cost" => %{"total" => 0.0001}
          },
          "stopReason" => "stop"
        }
      ]

      {[event], out} =
        Backend.normalize(
          %{"type" => "agent_end", "messages" => messages, "willRetry" => false},
          base
        )

      assert event["type"] == "result"
      assert event["is_error"] == false
      assert event["duration_ms"] >= 20
      assert_in_delta event["total_cost_usd"], 0.0001, 0.0000001

      assert event["usage"] == %{
               "input_tokens" => 100,
               "output_tokens" => 20,
               "cache_read_input_tokens" => 10
             }

      refute Map.has_key?(out.backend_state, :agent_start_ms)
    end

    test "sums usage/cost across multiple assistant messages in the same run" do
      messages = [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "toolCall", "id" => "c1", "name" => "bash", "arguments" => %{}}
          ],
          "usage" => %{
            "input" => 100,
            "output" => 20,
            "cacheRead" => 0,
            "cost" => %{"total" => 0.0001}
          },
          "stopReason" => "toolUse"
        },
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "done"}],
          "usage" => %{
            "input" => 50,
            "output" => 5,
            "cacheRead" => 40,
            "cost" => %{"total" => 0.00005}
          },
          "stopReason" => "stop"
        }
      ]

      {[event], _out} = Backend.normalize(%{"type" => "agent_end", "messages" => messages}, ctx())

      assert event["usage"] == %{
               "input_tokens" => 150,
               "output_tokens" => 25,
               "cache_read_input_tokens" => 40
             }

      assert_in_delta event["total_cost_usd"], 0.00015, 0.0000001
    end

    test "stopReason:error on the last assistant message -> is_error true, result from errorMessage" do
      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]},
        %{
          "role" => "assistant",
          "content" => [],
          "usage" => %{"input" => 0, "output" => 0, "cacheRead" => 0, "cost" => %{"total" => 0}},
          "stopReason" => "error",
          "errorMessage" => "404 Model not found"
        }
      ]

      {[event], _out} = Backend.normalize(%{"type" => "agent_end", "messages" => messages}, ctx())

      assert event["is_error"] == true
      assert event["result"] == "404 Model not found"
    end

    test "stopReason:aborted -> is_error false (user stop, not an error)" do
      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]},
        %{
          "role" => "assistant",
          "content" => [],
          "usage" => %{"input" => 0, "output" => 0, "cacheRead" => 0, "cost" => %{"total" => 0}},
          "stopReason" => "aborted",
          "errorMessage" => "Request was aborted."
        }
      ]

      {[event], _out} = Backend.normalize(%{"type" => "agent_end", "messages" => messages}, ctx())

      assert event["is_error"] == false
      refute Map.has_key?(event, "result")
    end

    test "no assistant messages at all (defensive) omits total_cost_usd and usage" do
      messages = [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]
      {[event], _out} = Backend.normalize(%{"type" => "agent_end", "messages" => messages}, ctx())

      refute Map.has_key?(event, "total_cost_usd")
      refute Map.has_key?(event, "usage")
    end

    test "queues a get_session_stats command onto backend_state.pending_writes (spec §12.3)" do
      messages = [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]
      {_events, out} = Backend.normalize(%{"type" => "agent_end", "messages" => messages}, ctx())

      assert [write] = out.backend_state.pending_writes
      assert decode_write(write) == %{"type" => "get_session_stats"}
    end
  end

  # ── normalize/2 — get_session_stats response -> pi_session_stats event ──

  describe "normalize/2 — get_session_stats response" do
    test "success -> a pi_session_stats event carrying tokens/cost/context_usage verbatim" do
      data = %{
        "sessionFile" => "/tmp/x/session.jsonl",
        "sessionId" => "abc123",
        "tokens" => %{
          "input" => 50_000,
          "output" => 10_000,
          "cacheRead" => 40_000,
          "total" => 105_000
        },
        "cost" => 0.45,
        "contextUsage" => %{"tokens" => 60_000, "contextWindow" => 200_000, "percent" => 30}
      }

      {[event], _out} =
        Backend.normalize(
          %{
            "type" => "response",
            "command" => "get_session_stats",
            "success" => true,
            "data" => data
          },
          ctx()
        )

      assert event == %{
               "type" => "pi_session_stats",
               "tokens" => data["tokens"],
               "cost" => 0.45,
               "context_usage" => data["contextUsage"]
             }
    end

    test "a failed get_session_stats response emits nothing" do
      {events, _out} =
        Backend.normalize(
          %{"type" => "response", "command" => "get_session_stats", "success" => false},
          ctx()
        )

      assert events == []
    end
  end

  # ── normalize/2 — deltas and unknown frames drop silently ───────────────

  describe "normalize/2 — deltas and unrecognized frames" do
    test "message_update, tool_execution_start/update, turn_start/end all drop" do
      c = ctx()

      frames = [
        %{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_delta"}},
        %{"type" => "tool_execution_start", "toolCallId" => "x", "toolName" => "bash"},
        %{"type" => "tool_execution_update", "toolCallId" => "x", "toolName" => "bash"},
        %{"type" => "turn_start"},
        %{"type" => "turn_end", "message" => %{}, "toolResults" => []},
        %{"type" => "extension_error", "error" => "boom"}
      ]

      for frame <- frames do
        assert Backend.normalize(frame, c) == {[], c}
      end
    end
  end

  # ── normalize/2 — mid-turn steering (spec §12.6) ────────────────────────

  describe "encode_steer_turn/2" do
    test "writes a steer command carrying the message" do
      c = ctx()
      {iodata, out} = Backend.encode_steer_turn("actually do X instead", c)
      assert decode_write(iodata) == %{"type" => "steer", "message" => "actually do X instead"}
      assert out == c
    end
  end

  describe "normalize/2 — queue_update" do
    test "synthesizes a system/queue_update event carrying the current queue, snake_cased" do
      c = ctx()

      {[event], out} =
        Backend.normalize(
          %{
            "type" => "queue_update",
            "steering" => ["Focus on error handling"],
            "followUp" => ["After that, summarize the result"]
          },
          c
        )

      assert event == %{
               "type" => "system",
               "subtype" => "queue_update",
               "steering" => ["Focus on error handling"],
               "follow_up" => ["After that, summarize the result"]
             }

      assert out == c
    end

    test "defaults missing steering/followUp to []" do
      {[event], _out} = Backend.normalize(%{"type" => "queue_update"}, ctx())
      assert event["steering"] == []
      assert event["follow_up"] == []
    end
  end

  describe "normalize/2 — compaction_start/compaction_end" do
    test "compaction_start carries the reason" do
      {[event], _out} =
        Backend.normalize(%{"type" => "compaction_start", "reason" => "threshold"}, ctx())

      assert event == %{
               "type" => "system",
               "subtype" => "compaction_start",
               "reason" => "threshold"
             }
    end

    test "compaction_end (success) carries reason, aborted:false, and token counts" do
      {[event], _out} =
        Backend.normalize(
          %{
            "type" => "compaction_end",
            "reason" => "threshold",
            "result" => %{
              "summary" => "Summary of conversation...",
              "firstKeptEntryId" => "abc123",
              "tokensBefore" => 150_000,
              "estimatedTokensAfter" => 32_000,
              "details" => %{}
            },
            "aborted" => false,
            "willRetry" => false
          },
          ctx()
        )

      assert event == %{
               "type" => "system",
               "subtype" => "compaction_end",
               "reason" => "threshold",
               "aborted" => false,
               "tokens_before" => 150_000,
               "estimated_tokens_after" => 32_000
             }
    end

    test "compaction_end (aborted) has no result fields" do
      {[event], _out} =
        Backend.normalize(
          %{"type" => "compaction_end", "reason" => "manual", "result" => nil, "aborted" => true},
          ctx()
        )

      assert event == %{
               "type" => "system",
               "subtype" => "compaction_end",
               "reason" => "manual",
               "aborted" => true
             }
    end

    test "compaction_end (failed) carries error_message, aborted:false" do
      {[event], _out} =
        Backend.normalize(
          %{
            "type" => "compaction_end",
            "reason" => "overflow",
            "result" => nil,
            "aborted" => false,
            "errorMessage" => "API quota exceeded"
          },
          ctx()
        )

      assert event["error_message"] == "API quota exceeded"
      assert event["aborted"] == false
      refute Map.has_key?(event, "tokens_before")
    end
  end

  describe "normalize/2 — rejected steer command" do
    test "success:false surfaces a non-terminal system note (does NOT end the turn)" do
      {[event], _out} =
        Backend.normalize(
          %{
            "type" => "response",
            "command" => "steer",
            "success" => false,
            "error" => "steering disabled"
          },
          ctx()
        )

      assert event == %{
               "type" => "system",
               "subtype" => "steer_failed",
               "message" => "steering disabled"
             }
    end
  end

  # ── handle_peer_request/2 + encode_ui_response/3 (extension UI reply loop,
  # "pi backend groundwork" slice) ────────────────────────────────────────

  describe "handle_peer_request/2 — dialog methods (select/confirm/input/editor)" do
    test "no immediate reply — stashes the request and emits a pi_ui_request event" do
      for method <- ~w(select confirm input editor) do
        c = ctx()

        {reply, events, out} =
          Backend.handle_peer_request(
            %{
              "id" => "uuid-1",
              "method" => method,
              "title" => "Red or blue?",
              "options" => ["Red", "Blue"]
            },
            c
          )

        assert reply == ""

        assert events == [
                 %{
                   "type" => "pi_ui_request",
                   "id" => "uuid-1",
                   "method" => method,
                   "title" => "Red or blue?",
                   "message" => nil,
                   "options" => ["Red", "Blue"],
                   "placeholder" => nil,
                   "prefill" => nil
                 }
               ]

        assert out.backend_state.pending_ui_request == %{id: "uuid-1", method: method}
      end
    end
  end

  describe "handle_peer_request/2 — fire-and-forget methods" do
    test "notify surfaces as a passive system/pi_notify event, no reply" do
      {reply, events, out} =
        Backend.handle_peer_request(
          %{
            "id" => "uuid-2",
            "method" => "notify",
            "message" => "heads up",
            "notifyType" => "warning"
          },
          ctx()
        )

      assert reply == ""

      assert events == [
               %{
                 "type" => "system",
                 "subtype" => "pi_notify",
                 "message" => "heads up",
                 "notify_type" => "warning"
               }
             ]

      refute Map.has_key?(out.backend_state, :pending_ui_request)
    end

    test "setStatus/setWidget/setTitle/set_editor_text get no reply and no event" do
      for method <- ~w(setStatus setWidget setTitle set_editor_text) do
        {reply, events, _out} =
          Backend.handle_peer_request(%{"id" => "uuid-3", "method" => method}, ctx())

        assert reply == ""
        assert events == []
      end
    end
  end

  describe "encode_ui_response/3" do
    test "matching pending request -> writes extension_ui_response and clears pending state" do
      c = %{ctx() | backend_state: %{pending_ui_request: %{id: "uuid-1", method: "select"}}}

      assert {:ok, iodata, out} =
               Backend.encode_ui_response("uuid-1", %{"value" => "Blue"}, c)

      assert decode_write(iodata) == %{
               "type" => "extension_ui_response",
               "id" => "uuid-1",
               "value" => "Blue"
             }

      refute Map.has_key?(out.backend_state, :pending_ui_request)
    end

    test "unknown request id -> :noop" do
      c = %{ctx() | backend_state: %{pending_ui_request: %{id: "uuid-1", method: "select"}}}
      assert Backend.encode_ui_response("some-other-id", %{"value" => "x"}, c) == :noop
    end

    test "no pending request at all -> :noop" do
      assert Backend.encode_ui_response("uuid-1", %{"value" => "x"}, ctx()) == :noop
    end
  end

  describe "normalize/2 — tool_execution_end clears a stale pending_ui_request" do
    test "defensively drops backend_state.pending_ui_request (pi's own dialog timeout has no wire signal)" do
      c = %{ctx() | backend_state: %{pending_ui_request: %{id: "uuid-1", method: "select"}}}

      {_events, out} =
        Backend.normalize(
          %{
            "type" => "tool_execution_end",
            "toolCallId" => "call_1",
            "toolName" => "question",
            "result" => %{"content" => [%{"type" => "text", "text" => "no answer"}]},
            "isError" => false
          },
          c
        )

      refute Map.has_key?(out.backend_state, :pending_ui_request)
    end
  end

  # ── session_id/1 ─────────────────────────────────────────────────────────

  describe "session_id/1" do
    test "extracts session_id from the synthesized system/init event" do
      assert Backend.session_id(%{"type" => "system", "session_id" => "abc"}) == "abc"
    end

    test "nil otherwise" do
      assert Backend.session_id(%{"type" => "assistant"}) == nil
      assert Backend.session_id(%{}) == nil
    end
  end

  # ── prepare_session/1 + cleanup_session/1 ───────────────────────────────

  describe "prepare_session/1 and cleanup_session/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "pi_backend_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, directory: dir}
    end

    test "creates and removes the per-session --session-dir", %{directory: dir} do
      c = ctx(%{directory: dir})
      assert Backend.prepare_session(c) == :ok

      session_dir = Path.join([dir, ".pi_sessions", c.session_id])
      assert File.dir?(session_dir)

      assert Backend.cleanup_session(c) == :ok
      refute File.exists?(session_dir)
    end

    test "cleanup_session only removes its own session's subdir, never a sibling's", %{
      directory: dir
    } do
      c1 = ctx(%{directory: dir})
      c2 = ctx(%{directory: dir})

      assert Backend.prepare_session(c1) == :ok
      assert Backend.prepare_session(c2) == :ok
      assert Backend.cleanup_session(c1) == :ok

      refute File.exists?(Path.join([dir, ".pi_sessions", c1.session_id]))
      assert File.dir?(Path.join([dir, ".pi_sessions", c2.session_id]))
    end
  end

  # ── system_prompt/1 ──────────────────────────────────────────────────────

  describe "system_prompt/1" do
    test "includes the session id line, commit trailer, drops MCP-dependent fragments" do
      c = ctx()
      prompt = Backend.system_prompt(c)

      assert prompt =~ "Your OrcaHub session ID is #{c.session_id}"
      assert prompt =~ "OrcaHub-Session: #{c.session_id}"
      refute prompt =~ "mcp__orca"
      refute prompt =~ "Orchestrator Session"
      refute prompt =~ "AskUserQuestion"
      refute prompt =~ "search_sessions"
    end

    test "orchestrator flag has no effect (no MCP-dependent orchestrator prompt to gate)" do
      c = ctx(%{orchestrator: true})
      prompt = Backend.system_prompt(c)
      refute prompt =~ "Orchestrator Session"
    end
  end
end
