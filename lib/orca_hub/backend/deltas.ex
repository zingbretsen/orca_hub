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
end
