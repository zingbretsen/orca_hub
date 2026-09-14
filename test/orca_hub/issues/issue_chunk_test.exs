defmodule OrcaHub.Issues.IssueChunkTest do
  @moduledoc """
  Foundation coverage for the `issue_chunks` table: that a `vector(1024)`
  actually round-trips through Ecto (i.e. `OrcaHub.PostgrexTypes` is wired
  into the Repo — without it a read fails with an unknown-oid error), that
  identity is `(issue_id, field, chunk_index)`, that `content_hash` is
  derived rather than hand-supplied, and that an embedding-less chunk is a
  legal row.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Issues
  alias OrcaHub.Issues.IssueChunk
  alias OrcaHub.{Projects, Repo}

  setup do
    dir = Path.join(System.tmp_dir!(), "issue_chunk_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "chunk-test", directory: dir, node: to_string(node())})

    {:ok, issue} = Issues.create_issue(%{title: "indexable issue", project_id: project.id})

    %{issue: issue}
  end

  defp insert_chunk(attrs) do
    %IssueChunk{} |> IssueChunk.changeset(attrs) |> Repo.insert()
  end

  test "derives content_hash from content", %{issue: issue} do
    {:ok, chunk} =
      insert_chunk(%{
        issue_id: issue.id,
        field: "title",
        chunk_index: 0,
        content: "title: indexable issue"
      })

    assert chunk.content_hash == IssueChunk.content_hash("title: indexable issue")
    assert String.length(chunk.content_hash) == 64
  end

  test "a chunk with no embedding is a legal row", %{issue: issue} do
    {:ok, chunk} =
      insert_chunk(%{issue_id: issue.id, field: "notes", chunk_index: 0, content: "notes: hi"})

    assert is_nil(chunk.embedding)
    assert is_nil(chunk.embedding_model)
    assert is_nil(chunk.embedded_at)
  end

  test "a vector(1024) round-trips through Ecto", %{issue: issue} do
    embedding = Enum.map(1..1024, fn i -> i / 1024 end)

    {:ok, chunk} =
      insert_chunk(%{
        issue_id: issue.id,
        field: "description",
        chunk_index: 0,
        content: "description: something searchable",
        embedding: embedding,
        embedding_model: "qwen3-embedding-0.6b",
        embedded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    reloaded = Repo.get!(IssueChunk, chunk.id)
    round_tripped = Pgvector.to_list(reloaded.embedding)

    assert length(round_tripped) == 1024
    # float4 storage, so compare with a tolerance rather than for equality.
    assert Enum.zip(round_tripped, embedding)
           |> Enum.all?(fn {a, b} -> abs(a - b) < 1.0e-6 end)
  end

  test "cosine distance ordering works against stored vectors", %{issue: issue} do
    near = List.duplicate(1.0, 1024)
    far = List.duplicate(1.0, 512) ++ List.duplicate(-1.0, 512)

    {:ok, _} =
      insert_chunk(%{
        issue_id: issue.id,
        field: "description",
        chunk_index: 0,
        content: "near",
        embedding: near
      })

    {:ok, _} =
      insert_chunk(%{
        issue_id: issue.id,
        field: "description",
        chunk_index: 1,
        content: "far",
        embedding: far
      })

    query = near

    contents =
      Repo.all(
        from c in IssueChunk,
          where: c.issue_id == ^issue.id and not is_nil(c.embedding),
          order_by: fragment("embedding <=> ?::vector", ^query),
          select: c.content
      )

    assert contents == ["near", "far"]
  end

  test "identity is (issue_id, field, chunk_index)", %{issue: issue} do
    attrs = %{issue_id: issue.id, field: "notes", chunk_index: 0, content: "notes: a"}
    {:ok, _} = insert_chunk(attrs)

    assert {:error, changeset} = insert_chunk(%{attrs | content: "notes: b"})
    refute changeset.valid?

    # A different index, or a different field, is a distinct chunk.
    assert {:ok, _} = insert_chunk(%{attrs | chunk_index: 1})
    assert {:ok, _} = insert_chunk(%{attrs | field: "description"})
  end

  test "rejects an unknown field", %{issue: issue} do
    assert {:error, changeset} =
             insert_chunk(%{issue_id: issue.id, field: "bogus", chunk_index: 0, content: "x"})

    assert %{field: ["is invalid"]} = errors_on(changeset)
  end

  test "chunks are deleted with their issue", %{issue: issue} do
    {:ok, _} =
      insert_chunk(%{issue_id: issue.id, field: "title", chunk_index: 0, content: "title: x"})

    {:ok, _} = Repo.delete(Repo.get!(OrcaHub.Issues.Issue, issue.id))

    assert Repo.all(from c in IssueChunk, where: c.issue_id == ^issue.id) == []
  end
end
