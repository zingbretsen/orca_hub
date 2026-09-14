defmodule OrcaHub.Issues.IssueChunk do
  @moduledoc """
  Schema for one embeddable slice of an issue's text — the unit
  `OrcaHub.Issues.Chunker` produces and a (later) indexer upserts.

  Identity is `(issue_id, field, chunk_index)`, which is unique in the DB.
  Re-indexing compares `content_hash` (sha256 hex of `content`) against the
  stored row and can skip re-embedding an unchanged chunk — which is the
  whole reason the hash is persisted rather than recomputed on read.

  `embedding` is NULLABLE by design: a chunk may be written before, or
  entirely without, its vector when the embedding endpoint is unavailable,
  so chunking and embedding fail independently. **Any search query must
  filter `not is_nil(embedding)`** — a NULL row means "not embedded yet",
  not "no match". `embedding_model`/`embedded_at` record which model
  produced a stored vector, so a model change is detectable without
  guessing from the dimension.

  `content` carries the field-labelled text that was actually embedded
  (e.g. `"resolution: ..."`) — see `Chunker`'s moduledoc for why the label
  is part of the embedded text and how the raw slice stays recoverable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @fields ~w(title description plan premise resolution notes approaches_tried)

  @doc "The issue fields that are eligible for chunking/indexing."
  def indexable_fields, do: @fields

  schema "issue_chunks" do
    field :field, :string
    field :chunk_index, :integer
    field :content, :string
    field :content_hash, :string

    field :embedding, Pgvector.Ecto.Vector
    field :embedding_model, :string
    field :embedded_at, :utc_datetime

    belongs_to :issue, OrcaHub.Issues.Issue

    timestamps()
  end

  @doc """
  Builds a changeset. `content_hash` is derived from `content` whenever
  `content` is present and no hash was supplied explicitly — callers should
  not hand-compute it (see `content_hash/1`).
  """
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :issue_id,
      :field,
      :chunk_index,
      :content,
      :content_hash,
      :embedding,
      :embedding_model,
      :embedded_at
    ])
    |> put_content_hash()
    |> validate_required([:issue_id, :field, :chunk_index, :content, :content_hash])
    |> validate_inclusion(:field, @fields)
    |> validate_number(:chunk_index, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:issue_id)
    |> unique_constraint([:issue_id, :field, :chunk_index])
  end

  @doc "sha256 hex digest of a chunk's content — the reindex skip key."
  def content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp put_content_hash(changeset) do
    case {get_change(changeset, :content_hash), get_field(changeset, :content)} do
      {nil, content} when is_binary(content) ->
        put_change(changeset, :content_hash, content_hash(content))

      _ ->
        changeset
    end
  end
end
