defmodule OrcaHub.Claude.DeltasTest do
  @moduledoc """
  `OrcaHub.Claude.Deltas` — the `--include-partial-messages` `stream_event`
  frames translated into the normalized C1 delta vocabulary.

  Driven through `OrcaHub.Backend.Claude.normalize/2` (rather than the helper
  directly) wherever possible, so the adapter wiring is covered too.

  The frame fixture is hand-written to a schema read out of the installed CLI
  binary, NOT a live capture — see
  `test/support/fixtures/deltas/PROVENANCE.md` for exactly which parts were
  verified and how.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Backend.Claude
  alias OrcaHub.DeltaFixtures

  defp ctx, do: %{backend_state: %{}}

  defp walk do
    DeltaFixtures.normalize_all(Claude, DeltaFixtures.frames("claude_stream_events"), ctx())
  end

  test "translates a whole message's stream_event frames into the C1 delta shape" do
    {events, _ctx} = walk()

    assert DeltaFixtures.shape(events) == [
             {:stream_start, "msg_01Ky7bJqPu9Ld3Vn2cXr8TqW"},
             {:block_start, 0, "text", nil},
             {:delta, 0, "one\n"},
             {:delta, 0, "two\n"},
             {:delta, 0, "three"},
             {:block_stop, 0},
             {:block_start, 1, "thinking", nil},
             {:block_stop, 1},
             {:block_start, 2, "tool_use", "Bash"},
             {:block_stop, 2},
             {:stream_stop, "msg_01Ky7bJqPu9Ld3Vn2cXr8TqW"}
           ]
  end

  test "drops every stream_event that is not a text delta or a block/stream boundary" do
    {events, _ctx} = walk()

    # The fixture carries an input_json_delta, a thinking_delta and a
    # message_delta; none of them may reach the normalized stream (C1: TEXT
    # blocks only, no tool-input JSON, no thinking payloads).
    texts =
      events |> DeltaFixtures.deltas_only() |> Enum.map(& &1["text"]) |> Enum.reject(&is_nil/1)

    assert texts == ["one\n", "two\n", "three"]
    refute Enum.any?(texts, &String.contains?(&1, "echo hi"))
    refute Enum.any?(texts, &String.contains?(&1, "bash command"))
  end

  test "stream_id equals the message.id of the persisted assistant event that follows" do
    {events, _ctx} = walk()

    assistant = Enum.find(events, &(&1["type"] == "assistant"))

    stream_ids =
      events |> DeltaFixtures.deltas_only() |> Enum.map(& &1["stream_id"]) |> Enum.uniq()

    # The C1 correlation invariant: one id for the whole stream, and it is
    # exactly what the feed's own assistant event carries.
    assert [stream_id] = stream_ids
    assert assistant["message"]["id"] == stream_id
  end

  test "passes every non-stream_event frame through untouched" do
    {events, _ctx} = walk()

    # system/init and the whole assistant message survive the new clause
    # byte-for-byte — nothing about the persisted feed changed.
    assert Enum.find(events, &(&1["type"] == "system"))["subtype"] == "init"

    assistant = Enum.find(events, &(&1["type"] == "assistant"))
    assert length(assistant["message"]["content"]) == 3
  end

  test "drops subagent frames (non-nil parent_tool_use_id) rather than interleaving them" do
    {events, _ctx} = walk()

    stream_ids = events |> DeltaFixtures.deltas_only() |> Enum.map(& &1["stream_id"])

    refute "msg_01SubAgentShouldBeIgnored" in stream_ids
    refute Enum.any?(events, &(&1["text"] == "nested output"))
  end

  test "drops block frames that arrive with no message_start to belong to" do
    orphan = %{
      "type" => "stream_event",
      "parent_tool_use_id" => nil,
      "event" => %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "orphan"}
      }
    }

    assert {[], _ctx} = Claude.normalize(orphan, ctx())
  end

  test "carries the stream id across frames in backend_state, and clears it at message_stop" do
    [_system, message_start | _rest] = DeltaFixtures.frames("claude_stream_events")

    {_events, ctx} = Claude.normalize(message_start, ctx())
    assert ctx.backend_state[:delta_stream_id] == "msg_01Ky7bJqPu9Ld3Vn2cXr8TqW"

    stop = %{
      "type" => "stream_event",
      "parent_tool_use_id" => nil,
      "event" => %{"type" => "message_stop"}
    }

    {_events, ctx} = Claude.normalize(stop, ctx)

    refute Map.has_key?(ctx.backend_state, :delta_stream_id)
  end
end
