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
end
