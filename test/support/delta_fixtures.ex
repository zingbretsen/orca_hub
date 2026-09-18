defmodule OrcaHub.DeltaFixtures do
  @moduledoc """
  Loads the native frame fixtures under `test/support/fixtures/deltas/`.

  See that directory's `PROVENANCE.md` for where each file came from (two are
  live captures; the Claude one is hand-written to a schema read out of the
  installed CLI binary).
  """

  @dir Path.expand("fixtures/deltas", __DIR__)

  @doc "Every frame of `<name>.ndjson`, decoded, in file order."
  @spec frames(String.t()) :: [map]
  def frames(name) do
    @dir
    |> Path.join(name <> ".ndjson")
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Runs `backend.normalize/2` over `frames`, threading `ctx` through, and
  returns `{all_emitted_events, final_ctx}` — the same reduce `SessionRunner`
  does, minus the persistence.
  """
  @spec normalize_all(module, [map], map) :: {[map], map}
  def normalize_all(backend, frames, ctx) do
    {events, ctx} =
      Enum.reduce(frames, {[], ctx}, fn frame, {acc, ctx} ->
        {events, ctx} = backend.normalize(frame, ctx)
        {acc ++ events, ctx}
      end)

    {events, ctx}
  end

  @doc "Just the normalized delta events (`\"orca_delta\"`) out of a normalize walk."
  @spec deltas_only([map]) :: [map]
  def deltas_only(events), do: Enum.filter(events, &(&1["type"] == "orca_delta"))

  @doc """
  Compact `{kind, ...}` tuples for asserting a whole stream in one go:
  `{:stream_start, id}` / `{:block_start, index, type, name}` /
  `{:delta, index, text}` / `{:block_stop, index}` / `{:stream_stop, id}`.
  """
  @spec shape([map]) :: [tuple]
  def shape(events) do
    events
    |> deltas_only()
    |> Enum.map(fn
      %{"kind" => "stream_start", "stream_id" => id} ->
        {:stream_start, id}

      %{"kind" => "block_start"} = e ->
        {:block_start, e["block_index"], e["block_type"], e["name"]}

      %{"kind" => "delta"} = e ->
        {:delta, e["block_index"], e["text"]}

      %{"kind" => "block_stop"} = e ->
        {:block_stop, e["block_index"]}

      %{"kind" => "stream_stop", "stream_id" => id} ->
        {:stream_stop, id}
    end)
  end
end
