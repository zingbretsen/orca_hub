defmodule OrcaHub.Backend.JsonRpcFraming do
  @moduledoc """
  Decodes newline-delimited JSON-RPC-shaped frames from a `:jsonrpc`-framed
  backend's stdio (Codex `app-server`).

  Same buffering contract as `OrcaHub.Claude.StreamParser.parse/2`
  (`{data, buffer} -> {[map], new_buffer}`) so `SessionRunner` can pick the
  decoder purely off `spawn_spec.framing` without any other branching.

  Per spec §6.1, replicates `codex_sdk`'s `io/buffer.ex` approach: a manual
  binary accumulator split on `\\n` (NOT `{:packet, :line}`) that tolerates
  non-JSON noise on stdout (log-level messages, sandbox warnings, etc. — the
  port is opened with `:stderr_to_stdout`, and Codex's own ERROR/WARN lines
  land interleaved with the protocol frames). An unparseable line is logged
  and dropped — it must never crash the runner or desync framing.
  """

  require Logger

  @spec parse(String.t(), String.t()) :: {[map()], String.t()}
  def parse(data, buffer \\ "") do
    combined = buffer <> data
    lines = String.split(combined, "\n")
    {complete, [remainder]} = Enum.split(lines, -1)

    events =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(&decode_line/1)

    {events, remainder}
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) ->
        [decoded]

      {:ok, other} ->
        Logger.warning(
          "[Backend.JsonRpcFraming] dropping non-object JSON-RPC line: #{inspect(other)}"
        )

        []

      {:error, _reason} ->
        Logger.debug("[Backend.JsonRpcFraming] skipping non-JSON stdout noise: #{inspect(line)}")
        []
    end
  end
end
