defmodule OrcaHub.Repo.Migrations.CreateIssueChunks do
  use Ecto.Migration

  # Backing table for pgvector-backed issue search. One row per (issue,
  # field, chunk_index) — the unit OrcaHub.Issues.Chunker produces — so a
  # later indexer can upsert on that key and skip a chunk whose
  # `content_hash` is unchanged rather than re-embedding the whole issue.
  #
  # `embedding` is NULLABLE on purpose: a chunk is allowed to exist before
  # (or without) its vector when the embedding endpoint is down, so
  # chunking and embedding can fail independently. Any consumer must
  # therefore filter `not is_nil(embedding)` — a NULL is "not embedded
  # yet", not "no match".
  #
  # 1024 dims == qwen3-embedding-0.6b, the model behind EMBEDDING_URL. The
  # dimension is baked into the column type, so changing models means a
  # migration, not just a config flip.
  @dims 1024

  def change do
    create table(:issue_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false

      # One of title/description/plan/premise/resolution/notes/
      # approaches_tried — validated in the schema, not by a DB constraint,
      # so adding an indexable field later doesn't need a migration.
      add :field, :string, null: false
      add :chunk_index, :integer, null: false
      add :content, :text, null: false
      # sha256 hex of `content`, for cheap "did this chunk actually change"
      # comparisons during reindex.
      add :content_hash, :string, null: false

      add :embedding, :vector, size: @dims
      add :embedding_model, :string
      add :embedded_at, :utc_datetime

      timestamps()
    end

    create unique_index(:issue_chunks, [:issue_id, :field, :chunk_index])
    create index(:issue_chunks, [:issue_id])

    # HNSW + vector_cosine_ops: cosine is the right metric for these
    # embeddings, and the operator class can't be expressed through Ecto's
    # index/3, so this is raw SQL (same as phx-app's).
    execute(
      "CREATE INDEX issue_chunks_embedding_hnsw_idx ON issue_chunks USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS issue_chunks_embedding_hnsw_idx"
    )

    # Reconciliation watermark for the (not-yet-built) reindex sweep:
    # reindex where `updated_at > indexed_at or indexed_at is null`. Nothing
    # writes this column yet.
    alter table(:issues) do
      add :indexed_at, :utc_datetime
    end
  end
end
