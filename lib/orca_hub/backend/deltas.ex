defmodule OrcaHub.Backend.Deltas do
  @moduledoc """
  The normalized assistant-delta event vocabulary shared by every backend.

  Backends stream partial assistant output at wildly different granularities
  (Claude forwards the raw Anthropic API `stream_event` frames, Codex sends
  `item/agentMessage/delta` JSON-RPC notifications, pi sends `message_update`
  with an `assistantMessageEvent`). Each adapter's `normalize/2` translates
  its native shape into the ONE normalized kind built here — `"orca_delta"` —
  and `SessionRunner` owns a single clause that turns those into the
  `{:assistant_*, payload}` PubSub tuples the UI consumes.

  ## Invariants

    * **Never persisted.** `"orca_delta"` events are broadcast-only: they
      never reach `messages`, never append to the runner's accumulator, and
      never influence `turn_result`. The persisted `assistant` event that
      follows remains the single source of truth for the feed; a client that
      missed the deltas (page loaded mid-turn) just renders that.
    * **`stream_id` correlates the two.** It MUST equal the `message.id` of
      the persisted `assistant` event for the same API message, so the client
      can swap its live bubble for the real render. Claude gets the id for
      free (the API's `message_start.message.id`); Codex and pi have no
      message id of their own, so their adapters mint one UUID per assistant
      message and stamp it into the normalized `assistant` event as well.
    * **Text blocks only.** `:delta` is emitted for assistant TEXT. Tool-input
      JSON deltas and thinking deltas are dropped — a `tool_use`/`thinking`
      block still gets a `block_start`/`block_stop` pair (so the UI can show a
      "running <name>…" chip), but never its payload.
    * **Best-effort.** A backend that cannot stream emits nothing at all
      rather than faking deltas out of a completed message.

  ## Shape

  The envelope carries the block type under `"block_type"` (the envelope's own
  `"type"` is taken by `"orca_delta"`); `broadcast_payload/1` renames it back
  to `"type"` in the payload, per the phase-2 C1 contract.
  """

  @type kind :: :stream_start | :block_start | :delta | :block_stop | :stream_stop

  # The two `backend_state` shapes adapters use to remember an in-flight
  # stream id: Claude and pi keep exactly ONE (`:delta_stream_id`, since a
  # single assistant message is in flight at a time), Codex keys a map by its
  # own item id (`:delta_streams`). `open_stream_ids/1` below is the one place
  # that knows both, so a caller sweeping a turn's leftovers never has to
  # branch on the backend.
  @single_stream_key :delta_stream_id
  @multi_stream_key :delta_streams

  @doc "Source event for the `:assistant_stream_start` broadcast."
  @spec stream_start(String.t()) :: map
  def stream_start(stream_id) when is_binary(stream_id) do
    %{"type" => "orca_delta", "kind" => "stream_start", "stream_id" => stream_id}
  end

  @doc """
  Start of one content block. `block_type` is the C1 vocabulary
  (`"text" | "tool_use" | "thinking"`); `name` is the tool name for a
  `tool_use` block and `nil` otherwise.
  """
  @spec block_start(String.t(), non_neg_integer, String.t(), String.t() | nil) :: map
  def block_start(stream_id, index, block_type, name \\ nil)
      when is_binary(stream_id) and is_integer(index) and is_binary(block_type) do
    %{
      "type" => "orca_delta",
      "kind" => "block_start",
      "stream_id" => stream_id,
      "block_index" => index,
      "block_type" => block_type,
      "name" => name
    }
  end

  @doc "One chunk of assistant TEXT for an already-started block."
  @spec delta(String.t(), non_neg_integer, String.t()) :: map
  def delta(stream_id, index, text)
      when is_binary(stream_id) and is_integer(index) and is_binary(text) do
    %{
      "type" => "orca_delta",
      "kind" => "delta",
      "stream_id" => stream_id,
      "block_index" => index,
      "text" => text
    }
  end

  @spec block_stop(String.t(), non_neg_integer) :: map
  def block_stop(stream_id, index) when is_binary(stream_id) and is_integer(index) do
    %{
      "type" => "orca_delta",
      "kind" => "block_stop",
      "stream_id" => stream_id,
      "block_index" => index
    }
  end

  @spec stream_stop(String.t()) :: map
  def stream_stop(stream_id) when is_binary(stream_id) do
    %{"type" => "orca_delta", "kind" => "stream_stop", "stream_id" => stream_id}
  end

  @doc "Whether an event is a normalized delta (and so must never be persisted)."
  @spec delta_event?(map) :: boolean
  def delta_event?(%{"type" => "orca_delta"}), do: true
  def delta_event?(_), do: false

  @doc """
  Maps a normalized delta event to the `{tag, payload}` pair `SessionRunner`
  broadcasts on `"session:<id>"`, or `:ignore` for an unrecognized kind
  (forward-compatible: a newer adapter's kind can never crash an older runner).
  """
  @spec broadcast_payload(map) :: {atom, map} | :ignore
  def broadcast_payload(%{"kind" => "stream_start", "stream_id" => id}) do
    {:assistant_stream_start, %{"stream_id" => id}}
  end

  def broadcast_payload(%{"kind" => "block_start"} = event) do
    {:assistant_block_start,
     %{
       "stream_id" => event["stream_id"],
       "block_index" => event["block_index"],
       "type" => event["block_type"],
       "name" => event["name"]
     }}
  end

  def broadcast_payload(%{"kind" => "delta"} = event) do
    {:assistant_delta,
     %{
       "stream_id" => event["stream_id"],
       "block_index" => event["block_index"],
       "text" => event["text"]
     }}
  end

  def broadcast_payload(%{"kind" => "block_stop"} = event) do
    {:assistant_block_stop,
     %{"stream_id" => event["stream_id"], "block_index" => event["block_index"]}}
  end

  def broadcast_payload(%{"kind" => "stream_stop", "stream_id" => id}) do
    {:assistant_stream_stop, %{"stream_id" => id}}
  end

  def broadcast_payload(_event), do: :ignore

  @doc """
  Every stream id an adapter currently holds open in `backend_state`.

  Reads both bookkeeping shapes (see `@single_stream_key`/`@multi_stream_key`)
  and tolerates anything else it finds there — `backend_state` is an opaque
  per-adapter map, so an unexpected value means "no open stream", never a
  crash on a teardown path.
  """
  @spec open_stream_ids(map) :: [String.t()]
  def open_stream_ids(backend_state) when is_map(backend_state) do
    single =
      case Map.get(backend_state, @single_stream_key) do
        id when is_binary(id) -> [id]
        _ -> []
      end

    multi =
      case Map.get(backend_state, @multi_stream_key) do
        streams when is_map(streams) -> streams |> Map.values() |> Enum.filter(&is_binary/1)
        _ -> []
      end

    Enum.uniq(single ++ multi)
  end

  def open_stream_ids(_backend_state), do: []

  @doc """
  Closes out every stream still open in `backend_state`: returns the synthetic
  `stream_stop` events to broadcast, plus the state with the bookkeeping keys
  dropped (so a second sweep is a no-op).

  ORCAHUB3-114. A `stream_stop` is otherwise emitted ONLY by the adapter clause
  that sees the backend's own end-of-message frame — Claude's `message_stop`,
  Codex's `item/completed`, pi's `message_end`. An interrupt, a port teardown
  or a crash mid-message means that frame never arrives, and the client's live
  bubble has no other removal trigger, so it outlives the persisted message and
  shows the same text twice until a full page refresh. Every path that ends a
  turn or discards `backend_state` has to sweep it through here first.
  """
  @spec close_open_streams(map) :: {[map], map}
  def close_open_streams(backend_state) when is_map(backend_state) do
    stops = backend_state |> open_stream_ids() |> Enum.map(&stream_stop/1)

    {stops, backend_state |> Map.delete(@single_stream_key) |> Map.delete(@multi_stream_key)}
  end

  def close_open_streams(backend_state), do: {[], backend_state}
end
