defmodule OrcaHub.Repo.Migrations.CreateSessionSearchIndexing do
  use Ecto.Migration

  # Durable state for OrcaHub.SessionSearch.Indexer (ORCAHUB3-137), which
  # pushes conversation text into memory-service's `session-messages`
  # collection. Postgres rather than app env/a file because the hub owns the
  # DB, the cursor must survive restarts/redeploys on every instance, and a
  # row is the one thing a deploy can't lose.
  #
  # `session_search_cursors`: one row per sweep name (prod uses
  # "session-messages"; tests use their own names so they never touch the
  # real cursor). `(last_inserted_at, last_message_id)` is the keyset
  # position in `messages ORDER BY inserted_at, id` — everything at or before
  # it has been posted (or deliberately skipped). NULL = start of history, so
  # the backfill is just the same sweep from the beginning.
  def change do
    create table(:session_search_cursors, primary_key: false) do
      add :name, :string, primary_key: true
      add :last_inserted_at, :naive_datetime_usec
      add :last_message_id, :binary_id
      add :indexed_total, :bigint, null: false, default: 0
      timestamps(type: :naive_datetime_usec)
    end

    # Per-document errors memory-service reports with an HTTP 200. The cursor
    # moves past them (one bad doc must not wedge the sweep); this table is the
    # durable retry queue. No FK (to messages or sessions): the indexer drops a
    # row whose message no longer exists, and `Sessions.delete_session` clears
    # a session's rows by session_id.
    create table(:session_search_failures, primary_key: false) do
      add :message_id, :binary_id, primary_key: true
      add :session_id, :binary_id, null: false
      add :reason, :text
      add :attempts, :integer, null: false, default: 1
      timestamps(type: :naive_datetime_usec)
    end

    create index(:session_search_failures, [:session_id])

    # Backs the cursor sweep's keyset scan (messages are otherwise only indexed
    # per session). Deliberately NOT `concurrently: true`: k3s `orca-hub` runs
    # `strategy: Recreate` and migrates in the entrypoint before `server`, the
    # old pod is already gone, and the hub is the only DB writer (agents write
    # through HubRPC), so the SHARE lock blocks nobody. Measured on prod, a full
    # scan + sort of (inserted_at, id) over 1.46M rows takes ~1.3 s, so the
    # build adds only a few seconds of downtime. A CONCURRENTLY build that gets
    # interrupted by the entrypoint (liveness kill, OOM) would leave an INVALID
    # index and crash-loop the next boot, which is worse.
    create index(:messages, [:inserted_at, :id])
  end
end
