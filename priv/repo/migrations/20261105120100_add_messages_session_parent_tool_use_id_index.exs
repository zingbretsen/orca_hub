defmodule OrcaHub.Repo.Migrations.AddMessagesSessionParentToolUseIdIndex do
  use Ecto.Migration

  # Second of three (see 20261105120000_add_messages_session_type_index.exs
  # for the CONCURRENTLY / no-transaction / invalid-leftover reasoning, which
  # applies unchanged here).
  #
  # Two jobs:
  #
  # 1. Sessions.list_messages_window/2's descendant fetch filters
  #    `data ->> 'parent_tool_use_id' = ANY(ids)`; without this it scanned
  #    every message in the session (~48 ms at 3,592 messages). With it, and
  #    the subtype index for the `task_*` arm of the same OR, it is a
  #    BitmapOr of two index lookups (~1 ms).
  # 2. Statistics. The top-level page filters
  #    `data ->> 'parent_tool_use_id' IS NULL`, and with no stats for that
  #    expression the planner guessed 18 matching rows out of 3,582 (really
  #    2,208), so it skipped the `(session_id, inserted_at, id)` keyset index
  #    and sorted the whole session instead (~43 ms). ANALYZE collects stats
  #    for an index expression only when the index is NOT partial, which is
  #    why this indexes NULLs too. With the stats it is a backward keyset
  #    scan that stops after 21 rows (~0.4 ms).
  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "messages_session_id_parent_tool_use_id_index"

  def up do
    if abandoned_invalid_index?(@name),
      do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")

    create_if_not_exists index(:messages, [:session_id, "(data ->> 'parent_tool_use_id')"],
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
