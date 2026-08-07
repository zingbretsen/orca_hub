defmodule OrcaHub.Repo.Migrations.AddMessagesSessionKeysetIndex do
  use Ecto.Migration

  # Backs the windowed message feed (Sessions.list_messages_window/2): the
  # existing `[:session_id]` index alone forces a sort of every row in a long
  # session just to find the last N. `(session_id, inserted_at, id)` lets
  # Postgres satisfy "last N top-level messages" / "next page before cursor"
  # with a backward index scan instead, and covers the same
  # `(inserted_at, id)` keyset tiebreak the queries filter/sort on.
  def change do
    create index(:messages, [:session_id, :inserted_at, :id])
  end
end
