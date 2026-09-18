defmodule OrcaHub.Claude.Deltas do
  @moduledoc """
  Translates the Claude CLI's `stream_event` frames into the normalized
  `OrcaHub.Backend.Deltas` vocabulary.

  With `--include-partial-messages` (added to both spawn modes by
  `OrcaHub.Claude.Config`), the CLI wraps the RAW Anthropic Messages-API
  streaming events in one extra envelope:

      {"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_…",…}},
       "session_id":"…","parent_tool_use_id":null,"uuid":"…"}

  and then emits the usual whole `assistant` event once the message completes.
  The `assistant` event's `message.id` is the SAME id as `message_start`'s —
  which is what makes it a valid C1 `stream_id` with no minting on our side
  (`claude_message_id_matches_stream_id` in the tests pins that).

  ## What we keep

  Only what the C1 contract asks for:

  | API event | normalized |
  |---|---|
  | `message_start` | `stream_start` (id from `message.id`) |
  | `content_block_start` | `block_start` (index, mapped block type, tool name) |
  | `content_block_delta` with `delta.type == "text_delta"` | `delta` |
  | `content_block_stop` | `block_stop` |
  | `message_stop` | `stream_stop` |

  Everything else is DROPPED: `input_json_delta` (tool-input JSON), `thinking_delta`
  / `signature_delta`, `message_delta` (stop_reason + usage — the persisted
  `result` event already carries usage), and any frame we don't recognize.

  ## State

  Only `message_start` carries the message id, so the current `stream_id` is
  stashed in the adapter's `backend_state` (`:delta_stream_id`) and read back
  by every subsequent frame of the same message. `SessionRunner` resets
  `backend_state` to `%{}` on every port teardown/crash, so a cold reopen can
  never resume a half-finished stream.

  Frames carrying a non-nil `parent_tool_use_id` (a nested/subagent stream)
  are dropped outright: they interleave a second message's blocks into the
  same block-index space, which the single-bubble client contract has no way
  to render. Claude's subagent tools (`Task`/`Workflow`) are disallowed for
  every OrcaHub spawn anyway, so this is a guard, not a live path.
  """

  alias OrcaHub.Backend.Deltas

  @stream_id_key :delta_stream_id

  @doc """
  Translates one `stream_event` frame. Returns `{events, backend_state}` —
  `events` is `[]` for every frame we deliberately drop.
  """
  @spec normalize(map, map) :: {[map], map}
  def normalize(%{"type" => "stream_event"} = frame, backend_state) do
    case frame["parent_tool_use_id"] do
      nil -> translate(frame["event"], backend_state)
      _subagent -> {[], backend_state}
    end
  end

  def normalize(_frame, backend_state), do: {[], backend_state}

  defp translate(%{"type" => "message_start", "message" => %{"id" => id}}, bs)
       when is_binary(id) do
    {[Deltas.stream_start(id)], Map.put(bs, @stream_id_key, id)}
  end

  defp translate(%{"type" => "content_block_start", "index" => index} = event, bs) do
    with_stream(bs, fn stream_id ->
      block = event["content_block"] || %{}
      [Deltas.block_start(stream_id, index, block_type(block["type"]), block["name"])]
    end)
  end

  defp translate(
         %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => %{"type" => "text_delta", "text" => text}
         },
         bs
       )
       when is_binary(text) do
    with_stream(bs, fn stream_id -> [Deltas.delta(stream_id, index, text)] end)
  end

  defp translate(%{"type" => "content_block_stop", "index" => index}, bs) do
    with_stream(bs, fn stream_id -> [Deltas.block_stop(stream_id, index)] end)
  end

  defp translate(%{"type" => "message_stop"}, bs) do
    case Map.pop(bs, @stream_id_key) do
      {stream_id, bs} when is_binary(stream_id) -> {[Deltas.stream_stop(stream_id)], bs}
      {_, bs} -> {[], bs}
    end
  end

  # input_json_delta / thinking_delta / signature_delta / message_delta / ping
  # / anything unrecognized.
  defp translate(_event, bs), do: {[], bs}

  # A frame that arrives before (or after) its `message_start` has no stream to
  # belong to — drop it rather than invent an id the persisted `assistant`
  # event could never match.
  defp with_stream(bs, fun) do
    case bs[@stream_id_key] do
      stream_id when is_binary(stream_id) -> {fun.(stream_id), bs}
      _ -> {[], bs}
    end
  end

  # Anthropic's content-block types collapsed onto C1's three-value vocabulary.
  defp block_type("text"), do: "text"
  defp block_type("thinking"), do: "thinking"
  defp block_type("redacted_thinking"), do: "thinking"
  defp block_type(_tool_ish), do: "tool_use"
end
