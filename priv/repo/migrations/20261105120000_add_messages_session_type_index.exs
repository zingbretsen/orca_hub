defmodule OrcaHub.Repo.Migrations.AddMessagesSessionTypeIndex do
  use Ecto.Migration

  # First of three expression indexes for SessionLive.Show's mount-time
  # derived-state queries (Sessions.latest_event_of_type/2,
  # latest_message_with_tool_use/2, latest_context_percent/1, the
  # AskUserQuestion answered check, ...). Each one filters
  # `data ->> 'type' = ...` and orders by `inserted_at DESC`; with only
  # `(session_id, inserted_at, id)` to go on, Postgres walked and detoasted
  # EVERY message in the session to find none (`Rows Removed by Filter:
  # 3592`, ~25 ms each at 3,592 messages). The expression must stay
  # byte-for-byte the shape the queries use, `data ->> 'type'`, or the
  # planner cannot match it.
  #
  # Full, not partial: ANALYZE only gathers statistics for the expression of
  # a NON-partial index, and the planner needs those (see the
  # parent_tool_use_id migration next to this one).
  #
  # CONCURRENTLY, one index per migration, no DDL transaction, no migration
  # lock — prod's messages table is ~1.8 M rows / 4.6 GB. At deploy the k3s
  # hub runs `bin/migrate` in its entrypoint BEFORE `bin/server` (strategy:
  # Recreate), so the hub is down for the build either way; what
  # CONCURRENTLY buys is that the same statement can be run by hand against
  # the live DB AHEAD of the deploy without blocking the running hub's
  # message inserts, and then this migration is a no-op.
  #
  # A build that dies part-way (the pod's liveness probe, an OOM) leaves an
  # INVALID index under this name, and a plain re-run would then fail on
  # "already exists" at every boot. `up/0` drops an abandoned invalid
  # leftover first and uses IF NOT EXISTS, so a re-run either finishes the
  # job or no-ops.
  #
  # Measured on the dev DB (52 K rows, 145 MB heap + TOAST): ~0.2-0.25 s per
  # index, nearly all of it detoasting `data` for every row. Scaled by row
  # count to prod's ~1.8 M rows that is ~7-9 s per index warm, more with a
  # cold cache.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "messages_session_id_type_inserted_at_index"

  def up do
    if abandoned_invalid_index?(@name),
      do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")

    create_if_not_exists index(:messages, [:session_id, "(data ->> 'type')", "inserted_at DESC"],
                           name: @name,
                           concurrently: true
                         )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@name}"
  end

  # Invalid AND no backend is still building it. A pod killed mid-build
  # leaves its server-side CREATE INDEX CONCURRENTLY running to completion
  # (Postgres only notices the dead client when it next writes to it), so an
  # invalid index with a build in progress is left alone: IF NOT EXISTS then
  # no-ops and the in-flight build finishes on its own.
  defp abandoned_invalid_index?(name) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT NOT i.indisvalid
           AND NOT EXISTS (SELECT 1 FROM pg_stat_progress_create_index p
                           WHERE p.index_relid = i.indexrelid)
        FROM pg_index i
        WHERE i.indexrelid = to_regclass($1)
        """,
        [name]
      )

    rows == [[true]]
  end
end
