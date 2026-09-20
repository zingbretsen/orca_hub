defmodule OrcaHub.Backend.DeltasTest do
  @moduledoc """
  The normalized delta vocabulary itself — constructors and the
  `broadcast_payload/1` mapping `SessionRunner`'s single delta clause uses.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Backend.Deltas

  test "every constructor produces a recognizable orca_delta event" do
    events = [
      Deltas.stream_start("s1"),
      Deltas.block_start("s1", 0, "text"),
      Deltas.delta("s1", 0, "hi"),
      Deltas.block_stop("s1", 0),
      Deltas.stream_stop("s1")
    ]

    assert Enum.all?(events, &Deltas.delta_event?/1)
    assert Enum.all?(events, &(&1["type"] == "orca_delta"))
  end

  test "broadcast_payload/1 maps each kind onto its C1 tuple" do
    assert Deltas.broadcast_payload(Deltas.stream_start("s1")) ==
             {:assistant_stream_start, %{"stream_id" => "s1"}}

    assert Deltas.broadcast_payload(Deltas.block_start("s1", 2, "tool_use", "Bash")) ==
             {:assistant_block_start,
              %{"stream_id" => "s1", "block_index" => 2, "type" => "tool_use", "name" => "Bash"}}

    assert Deltas.broadcast_payload(Deltas.delta("s1", 0, "hi")) ==
             {:assistant_delta, %{"stream_id" => "s1", "block_index" => 0, "text" => "hi"}}

    assert Deltas.broadcast_payload(Deltas.block_stop("s1", 0)) ==
             {:assistant_block_stop, %{"stream_id" => "s1", "block_index" => 0}}

    assert Deltas.broadcast_payload(Deltas.stream_stop("s1")) ==
             {:assistant_stream_stop, %{"stream_id" => "s1"}}
  end

  test "block_start defaults name to nil for a non-tool block" do
    assert Deltas.block_start("s1", 0, "text")["name"] == nil
  end

  test "an unknown kind is ignored rather than raising" do
    # Forward compatibility: a newer adapter emitting a kind this runner has
    # never heard of must not crash the turn.
    assert Deltas.broadcast_payload(%{"type" => "orca_delta", "kind" => "from_the_future"}) ==
             :ignore

    refute Deltas.delta_event?(%{"type" => "assistant"})
  end

  describe "open_stream_ids/1 + close_open_streams/1 (ORCAHUB3-114)" do
    # The sweep every turn-end / teardown path runs so a client's live bubble
    # is never left waiting for a `stream_stop` the backend will never send.
    # Driven off each adapter's REAL bookkeeping state (built below in
    # "a half-finished stream from each adapter…") as well as these unit
    # cases, so the two halves can't drift apart silently.

    test "finds the single-stream key Claude and pi use" do
      assert Deltas.open_stream_ids(%{delta_stream_id: "msg_1"}) == ["msg_1"]
    end

    test "finds every id in the multi-stream map Codex uses" do
      state = %{delta_streams: %{"item_a" => "uuid-a", "item_b" => "uuid-b"}}
      assert Enum.sort(Deltas.open_stream_ids(state)) == ["uuid-a", "uuid-b"]
    end

    test "an empty or unrecognized backend_state has no open streams" do
      assert Deltas.open_stream_ids(%{}) == []
      assert Deltas.open_stream_ids(%{pending_writes: [], latest_token_usage: %{}}) == []
      # backend_state is an opaque per-adapter map: a junk value there must
      # read as "nothing open", never crash a teardown path.
      assert Deltas.open_stream_ids(%{delta_stream_id: nil, delta_streams: :garbage}) == []
      assert Deltas.open_stream_ids(nil) == []
    end

    test "close_open_streams/1 returns a stop per open stream and drops the bookkeeping" do
      state = %{delta_stream_id: "msg_1", pending_writes: [:keep_me]}

      assert {[stop], cleaned} = Deltas.close_open_streams(state)
      assert stop == Deltas.stream_stop("msg_1")
      assert Deltas.broadcast_payload(stop) == {:assistant_stream_stop, %{"stream_id" => "msg_1"}}

      # Only the delta keys go; the rest of the adapter's state is untouched.
      refute Map.has_key?(cleaned, :delta_stream_id)
      assert cleaned[:pending_writes] == [:keep_me]
    end

    test "close_open_streams/1 is idempotent — a second sweep emits nothing" do
      {[_stop], cleaned} = Deltas.close_open_streams(%{delta_stream_id: "msg_1"})
      assert Deltas.close_open_streams(cleaned) == {[], cleaned}
    end

    test "a completed stream leaves nothing to sweep" do
      assert Deltas.close_open_streams(%{}) == {[], %{}}
    end
  end

  describe "a half-finished stream from each adapter is swept (ORCAHUB3-114)" do
    # The real defect, at the contract level: every adapter only emits a
    # `stream_stop` when it sees its backend's own end-of-message frame
    # (Claude's `message_stop`, Codex's `item/completed`, pi's `message_end`).
    # Cut the frames off just before that — exactly what an interrupt, a port
    # teardown or a crash mid-message does — and the id is left dangling in
    # `backend_state` with no stop ever emitted for it. These pin that the
    # sweep finds it for all three.

    alias OrcaHub.DeltaFixtures

    defp adapter_ctx do
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

    # Walks `take` frames of the fixture and returns {emitted_events, state}.
    defp walk_partial(backend, fixture, take) do
      frames = fixture |> DeltaFixtures.frames() |> Enum.take(take)
      {events, ctx} = DeltaFixtures.normalize_all(backend, frames, adapter_ctx())
      {events, ctx.backend_state}
    end

    defp stopped_ids(events) do
      events
      |> DeltaFixtures.deltas_only()
      |> Enum.filter(&(&1["kind"] == "stream_stop"))
      |> Enum.map(& &1["stream_id"])
    end

    test "Claude: a stream cut off before message_stop" do
      # 14 frames = everything up to but NOT including `message_stop`.
      {events, state} = walk_partial(OrcaHub.Backend.Claude, "claude_stream_events", 14)

      started =
        events |> DeltaFixtures.deltas_only() |> Enum.map(& &1["stream_id"]) |> Enum.uniq()

      assert [stream_id] = started

      # The defect: the stream was started and never stopped.
      assert stopped_ids(events) == []
      assert Deltas.open_stream_ids(state) == [stream_id]

      assert {[stop], cleaned} = Deltas.close_open_streams(state)
      assert stop["stream_id"] == stream_id
      assert Deltas.open_stream_ids(cleaned) == []
    end

    test "Codex: a stream cut off before item/completed" do
      # 12 frames = everything up to but NOT including the final
      # `item/completed` that would close the agentMessage.
      {events, state} = walk_partial(OrcaHub.Backend.Codex, "codex_agent_message", 12)

      assert stopped_ids(events) == []
      assert [stream_id] = Deltas.open_stream_ids(state)

      assert {[stop], cleaned} = Deltas.close_open_streams(state)
      assert stop["stream_id"] == stream_id
      assert Deltas.open_stream_ids(cleaned) == []
    end

    test "pi: a stream cut off before message_end" do
      # 14 frames = everything up to but NOT including the final `message_end`.
      {events, state} = walk_partial(OrcaHub.Backend.Pi, "pi_message_updates", 14)

      assert stopped_ids(events) == []
      assert [stream_id] = Deltas.open_stream_ids(state)

      assert {[stop], cleaned} = Deltas.close_open_streams(state)
      assert stop["stream_id"] == stream_id
      assert Deltas.open_stream_ids(cleaned) == []
    end
  end
end
