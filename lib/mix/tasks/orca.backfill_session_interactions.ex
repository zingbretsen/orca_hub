defmodule Mix.Tasks.Orca.BackfillSessionInteractions do
  @moduledoc """
  Backfills `session_interactions` edges from historical messages that
  predate the live write in `OrcaHub.MCP.Tools.Sessions`.

  `send_message_to_session` has always prefixed delivered text with
  `[Message from session <uuid>]\\n\\n` — this scans every persisted user
  message for that prefix and inserts a matching edge, stamped with the
  message's own `inserted_at` so backfilled edges land at their real time
  rather than "now".

  Idempotent: safe to re-run. Skips a match whose sender uuid isn't an
  existing session id, and skips inserting an edge that already exists for
  the same (sender, recipient, kind, inserted_at) tuple.

  Scans in batches via `Repo.stream/2` rather than loading every message at
  once. Only intended for local/dev use — there is no `mix` in the prod OTP
  release, so this can't run there by accident.

      mix orca.backfill_session_interactions
  """

  use Mix.Task
  import Ecto.Query

  alias OrcaHub.Repo
  alias OrcaHub.Sessions.{Message, Session, SessionInteraction}

  @shortdoc "Backfill session_interactions edges from historical [Message from session ...] text"

  @prefix_regex ~r/^\[Message from session ([0-9a-fA-F-]{36})\]\n\n/
  @batch_size 500

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    existing_session_ids = MapSet.new(Repo.all(from s in Session, select: s.id))

    stats =
      Repo.transaction(fn ->
        Message
        |> where([m], fragment("? ->> 'type' = 'user'", m.data))
        |> Repo.stream(max_rows: @batch_size)
        |> Stream.chunk_every(@batch_size)
        |> Enum.reduce(init_stats(), fn batch, acc ->
          process_batch(batch, existing_session_ids, acc)
        end)
      end)
      |> case do
        {:ok, stats} -> stats
        {:error, reason} -> Mix.raise("Backfill failed: #{inspect(reason)}")
      end

    report(stats)
  end

  defp init_stats do
    %{scanned: 0, matched: 0, inserted: 0, skipped_no_sender: 0, skipped_duplicate: 0}
  end

  defp process_batch(messages, existing_session_ids, stats) do
    stats = Map.update!(stats, :scanned, &(&1 + length(messages)))

    {stats, candidates} =
      messages
      |> Enum.reduce({stats, []}, fn message, {stats, acc} ->
        case extract_candidate(message, existing_session_ids) do
          nil ->
            {stats, acc}

          :no_sender ->
            {stats |> bump(:matched) |> bump(:skipped_no_sender), acc}

          {:ok, candidate} ->
            {bump(stats, :matched), [candidate | acc]}
        end
      end)

    insert_candidates(candidates, stats)
  end

  defp extract_candidate(message, existing_session_ids) do
    case extract_user_text(message.data) do
      nil ->
        nil

      text ->
        case Regex.run(@prefix_regex, text) do
          [_, sender_id] ->
            sender_id = String.downcase(sender_id)

            if MapSet.member?(existing_session_ids, sender_id) do
              {:ok,
               %{
                 sender_session_id: sender_id,
                 recipient_session_id: message.session_id,
                 kind: "message",
                 inserted_at: message.inserted_at
               }}
            else
              :no_sender
            end

          nil ->
            nil
        end
    end
  end

  defp extract_user_text(%{"message" => %{"content" => content}}) when is_binary(content),
    do: content

  defp extract_user_text(%{"message" => %{"content" => content}}) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => text} -> text
      _ -> nil
    end)
  end

  defp extract_user_text(_data), do: nil

  defp insert_candidates([], stats), do: stats

  defp insert_candidates(candidates, stats) do
    existing = existing_edge_signatures(candidates)

    {rows, dup_count} =
      Enum.reduce(candidates, {[], 0}, fn candidate, {rows, dup_count} ->
        signature =
          {candidate.sender_session_id, candidate.recipient_session_id, candidate.kind,
           candidate.inserted_at}

        if MapSet.member?(existing, signature) do
          {rows, dup_count + 1}
        else
          {[row_from_candidate(candidate) | rows], dup_count}
        end
      end)

    if rows != [], do: Repo.insert_all(SessionInteraction, rows)

    stats
    |> Map.update!(:inserted, &(&1 + length(rows)))
    |> Map.update!(:skipped_duplicate, &(&1 + dup_count))
  end

  defp existing_edge_signatures(candidates) do
    recipient_ids = candidates |> Enum.map(& &1.recipient_session_id) |> Enum.uniq()

    SessionInteraction
    |> where([i], i.recipient_session_id in ^recipient_ids and i.kind == "message")
    |> select([i], {i.sender_session_id, i.recipient_session_id, i.kind, i.inserted_at})
    |> Repo.all()
    |> MapSet.new()
  end

  defp row_from_candidate(candidate) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    candidate
    |> Map.put(:id, Ecto.UUID.generate())
    |> Map.put(:updated_at, now)
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp report(stats) do
    Mix.shell().info("""
    Backfill complete:
      Messages scanned:                #{stats.scanned}
      Prefix matches:                  #{stats.matched}
      Edges inserted:                  #{stats.inserted}
      Skipped (sender session absent): #{stats.skipped_no_sender}
      Skipped (already backfilled):    #{stats.skipped_duplicate}
    """)
  end
end
