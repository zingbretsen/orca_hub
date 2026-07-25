defmodule OrcaHub.Repo.Migrations.WidenMessageTimestampsToMicroseconds do
  use Ecto.Migration

  # `messages.inserted_at`/`updated_at` were second-precision (`timestamp(0)`,
  # Ecto's plain `:naive_datetime` default). Every "most recent message"
  # query (Sessions.last_assistant_text/1, session_tail, activity metrics, …)
  # orders by inserted_at with no secondary tiebreaker, so two messages
  # persisted within the same wall-clock second are ordered arbitrarily by
  # Postgres — surfaced by the Agent Runs API's session continuations
  # (docs/api.md), where a fast turn can otherwise tie with the PREVIOUS
  # turn's reply and get picked as "the newest" instead of it.
  def change do
    alter table(:messages) do
      modify :inserted_at, :naive_datetime_usec
      modify :updated_at, :naive_datetime_usec
    end
  end
end
