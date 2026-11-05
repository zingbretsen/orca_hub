defmodule OrcaHub.Repo.Migrations.AddMessagesSessionSubtypeIndex do
  use Ecto.Migration

  # Third of three (see 20261105120000_add_messages_session_type_index.exs
  # for the CONCURRENTLY / no-transaction / invalid-leftover reasoning, which
  # applies unchanged here).
  #
  # Backs every `data ->> 'subtype'` filter on a session's messages:
  # Sessions.list_memory_injected_events/1 (the header Memories panel, on
  # every Session Show mount — ~25 ms at 3,592 messages without it), the
  # `task_*` arm of list_messages_window/2's descendant fetch, and
  # annotate_fork_marker/2. Full, not partial, so ANALYZE keeps stats for the
  # expression.
  #
  # Ends with ANALYZE because index-expression statistics only exist after
  # one, and autoanalyze on a ~1.8 M-row table waits for ~180 K new rows
  # (the 10% default scale factor) — days. Without the parent_tool_use_id
  # stats the top-level page keeps its bad plan (see that migration). ANALYZE
  # samples 30 K rows, so it costs seconds, not a table scan.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "messages_session_id_subtype_index"

  def up do
    if abandoned_invalid_index?(@name),
      do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")

    create_if_not_exists index(:messages, [:session_id, "(data ->> 'subtype')"],
                           name: @name,
                           concurrently: true
                         )

    execute "ANALYZE messages"
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
