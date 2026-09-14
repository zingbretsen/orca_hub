defmodule OrcaHub.Issues.IndexerTest do
  @moduledoc """
  Coverage for `OrcaHub.Issues.Indexer` — the incremental `issue_chunks`
  writer. The embedding endpoint is stubbed via `Req.Test`; nothing here
  touches the real one.

  The properties that matter most (and that the live end-to-end check on the
  dev DB also verified): an unchanged chunk is never re-embedded, a
  shrinking field leaves no orphan rows, and an embedder failure writes
  NOTHING and leaves `indexed_at` unset so the sweep retries.
  """
  # async: false — sets the global :embedding_url/:embedding_req_options app
  # env, exactly like OrcaHub.EmbeddingsTest.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Issues, Projects}
  alias OrcaHub.Issues.{Chunker, Indexer, Issue, IssueChunk}

  @stub OrcaHub.Issues.IndexerStub
  @dims 1024

  setup do
    Application.put_env(:orca_hub, :embedding_url, "http://embeddings.example.com")
    Application.put_env(:orca_hub, :embedding_req_options, plug: {Req.Test, @stub})
    # Keep the write hooks in OrcaHub.Issues out of this file entirely — they
    # are covered in issues_indexing_hooks_test.exs. Here every reindex is
    # driven explicitly so the assertions about *what got embedded* are
    # about this module's own decisions.
    Application.put_env(:orca_hub, :issue_indexing, :off)

    on_exit(fn ->
      Application.put_env(:orca_hub, :embedding_url, nil)
      Application.delete_env(:orca_hub, :embedding_req_options)
      Application.delete_env(:orca_hub, :issue_indexing)
    end)

    {:ok, project} =
      Projects.create_project(%{
        name: "indexer-test",
        directory: System.tmp_dir!(),
        node: Atom.to_string(node()),
        key_prefix: "IDX" <> Integer.to_string(System.unique_integer([:positive]))
      })

    {:ok, project: project}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp stub_embedder(opts \\ []) do
    counter = :counters.new(1, [])

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      inputs = Jason.decode!(raw)["input"]
      :counters.add(counter, 1, length(inputs))

      case opts[:fail] do
        nil ->
          data =
            inputs
            |> Enum.with_index()
            |> Enum.map(fn {_text, i} ->
              %{"index" => i, "embedding" => List.duplicate(0.25, @dims)}
            end)

          Req.Test.json(conn, %{"data" => data})

        :transport ->
          Req.Test.transport_error(conn, :econnrefused)

        {:status, status} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "nope"})
      end
    end)

    counter
  end

  defp embedded_texts(counter), do: :counters.get(counter, 1)

  defp create_issue(project, attrs) do
    {:ok, issue} = Issues.create_issue(Map.merge(%{project_id: project.id}, attrs))
    issue
  end

  defp chunks_for(issue_id) do
    from(c in IssueChunk,
      where: c.issue_id == ^issue_id,
      order_by: [asc: c.field, asc: c.chunk_index]
    )
    |> Repo.all()
  end

  defp reload(issue), do: Repo.get!(Issue, issue.id)

  # A field long enough that Chunker splits it into several chunks.
  defp long_text(paragraphs) do
    1..paragraphs
    |> Enum.map(fn n -> "Paragraph #{n}. " <> String.duplicate("filler words here. ", 90) end)
    |> Enum.join("\n\n")
  end

  # ── the happy path ──────────────────────────────────────────────────

  describe "reindex_issue/1 on a fresh issue" do
    test "writes one embedded chunk row per chunk and stamps indexed_at", %{project: project} do
      counter = stub_embedder()
      issue = create_issue(project, %{title: "Indexer smoke", description: "a short description"})

      assert {:ok, stats} = Indexer.reindex_issue(issue)

      expected = length(Chunker.chunk(issue))
      assert stats.chunks == expected
      assert stats.embedded == expected
      assert stats.unchanged == 0
      assert stats.deleted == 0
      refute stats.stale_write
      assert embedded_texts(counter) == expected

      rows = chunks_for(issue.id)
      assert length(rows) == expected

      for row <- rows do
        assert row.embedding_model == "qwen3-embedding-0.6b"
        assert %DateTime{} = row.embedded_at
        assert length(Pgvector.to_list(row.embedding)) == @dims
        assert row.content_hash == IssueChunk.content_hash(row.content)
      end

      assert %DateTime{} = reload(issue).indexed_at
      assert stats.indexed_at == reload(issue).indexed_at
    end

    test "accepts an issue id as well as a struct", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "By id"})

      assert {:ok, %{chunks: n}} = Indexer.reindex_issue(issue.id)
      assert n > 0
    end

    test "chunk rows carry the field label Chunker produced", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Labelled", description: "described"})

      {:ok, _} = Indexer.reindex_issue(issue)

      fields = chunks_for(issue.id) |> Enum.map(& &1.field) |> Enum.sort()
      assert fields == ["description", "title"]
      assert Enum.all?(chunks_for(issue.id), &String.starts_with?(&1.content, &1.field <> ": "))
    end
  end

  # ── incrementality: the whole point of the content hash ─────────────

  describe "idempotence and incrementality" do
    test "a second pass embeds nothing and leaves embedded_at untouched", %{project: project} do
      counter = stub_embedder()
      issue = create_issue(project, %{title: "Twice", description: "same text both times"})

      {:ok, first} = Indexer.reindex_issue(issue)
      before = chunks_for(issue.id) |> Map.new(&{{&1.field, &1.chunk_index}, &1.embedded_at})
      calls_after_first = embedded_texts(counter)

      {:ok, second} = Indexer.reindex_issue(reload(issue))

      assert second.embedded == 0
      assert second.unchanged == first.chunks
      assert second.deleted == 0
      assert embedded_texts(counter) == calls_after_first, "no text should have been re-embedded"

      after_second =
        chunks_for(issue.id) |> Map.new(&{{&1.field, &1.chunk_index}, &1.embedded_at})

      assert after_second == before
    end

    test "changing one field re-embeds only that field's chunks", %{project: project} do
      counter = stub_embedder()

      issue =
        create_issue(project, %{
          title: "Selective",
          description: "the description stays exactly as it is",
          notes: "note one"
        })

      {:ok, _} = Indexer.reindex_issue(issue)
      baseline = embedded_texts(counter)

      desc_before =
        chunks_for(issue.id)
        |> Enum.filter(&(&1.field == "description"))
        |> Enum.map(& &1.embedded_at)

      {:ok, appended} = Issues.append_note(reload(issue), "note two")
      {:ok, stats} = Indexer.reindex_issue(appended)

      # notes became a different single chunk; title/description did not move.
      assert stats.embedded == 1
      assert stats.unchanged == stats.chunks - 1
      assert embedded_texts(counter) == baseline + 1

      desc_after =
        chunks_for(issue.id)
        |> Enum.filter(&(&1.field == "description"))
        |> Enum.map(& &1.embedded_at)

      assert desc_after == desc_before

      notes_row = chunks_for(issue.id) |> Enum.find(&(&1.field == "notes"))
      assert notes_row.content =~ "note two"
    end

    test "a model change invalidates every stored vector", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Model swap", description: "text"})
      {:ok, first} = Indexer.reindex_issue(issue)

      Application.put_env(:orca_hub, :embedding_model, "some-other-model")
      on_exit(fn -> Application.put_env(:orca_hub, :embedding_model, "qwen3-embedding-0.6b") end)

      {:ok, second} = Indexer.reindex_issue(reload(issue))

      assert second.embedded == first.chunks
      assert second.unchanged == 0
      assert Enum.all?(chunks_for(issue.id), &(&1.embedding_model == "some-other-model"))
    end

    test "a row left with a NULL embedding is re-embedded", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Null vector"})
      {:ok, _} = Indexer.reindex_issue(issue)

      {1, _} =
        from(c in IssueChunk, where: c.issue_id == ^issue.id)
        |> Repo.update_all(set: [embedding: nil])

      assert {:ok, %{embedded: 1, unchanged: 0}} = Indexer.reindex_issue(reload(issue))
      assert Enum.all?(chunks_for(issue.id), &(not is_nil(&1.embedding)))
    end
  end

  # ── orphans ─────────────────────────────────────────────────────────

  describe "orphan deletion" do
    test "a shrinking field deletes the chunk rows it no longer produces", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Shrink", notes: long_text(6)})
      {:ok, first} = Indexer.reindex_issue(issue)

      notes_chunks_before = chunks_for(issue.id) |> Enum.count(&(&1.field == "notes"))
      assert notes_chunks_before > 1, "fixture must produce a multi-chunk notes field"

      {:ok, shrunk} = Issues.update_issue(reload(issue), %{notes: "just one short note now"})
      {:ok, stats} = Indexer.reindex_issue(shrunk)

      assert stats.deleted == notes_chunks_before - 1
      assert stats.chunks < first.chunks

      notes_indexes =
        chunks_for(issue.id) |> Enum.filter(&(&1.field == "notes")) |> Enum.map(& &1.chunk_index)

      assert notes_indexes == [0]
      assert length(chunks_for(issue.id)) == stats.chunks
    end

    test "clearing a field entirely removes its rows", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Cleared", description: "goes away"})
      {:ok, _} = Indexer.reindex_issue(issue)
      assert Enum.any?(chunks_for(issue.id), &(&1.field == "description"))

      {:ok, cleared} = Issues.update_issue(reload(issue), %{description: nil})
      assert {:ok, %{deleted: 1}} = Indexer.reindex_issue(cleared)

      refute Enum.any?(chunks_for(issue.id), &(&1.field == "description"))
    end
  end

  # ── failure isolation ───────────────────────────────────────────────

  describe "embedder failure" do
    test "an unreachable endpoint writes nothing and leaves indexed_at unset", %{project: project} do
      stub_embedder(fail: :transport)
      issue = create_issue(project, %{title: "Down", description: "never embedded"})

      assert {:error, {:request_failed, _}} = Indexer.reindex_issue(issue)
      assert chunks_for(issue.id) == []
      assert reload(issue).indexed_at == nil
    end

    test "an HTTP error leaves a previously good index intact", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Was good", notes: long_text(4)})
      {:ok, _} = Indexer.reindex_issue(issue)
      good_rows = chunks_for(issue.id)
      good_indexed_at = reload(issue).indexed_at

      # Now the endpoint starts rejecting, and the issue's text changes.
      stub_embedder(fail: {:status, 400})
      {:ok, changed} = Issues.update_issue(reload(issue), %{notes: "completely different notes"})

      assert {:error, {:http_error, 400, _}} = Indexer.reindex_issue(changed)

      assert chunks_for(issue.id) == good_rows, "the stale-but-working index must survive"
      assert reload(issue).indexed_at == good_indexed_at

      # ...and the issue is now in the sweep's candidate set, since its
      # updated_at is at or past the old watermark.
      assert changed.id in Indexer.stale_issue_ids(200)
    end

    test "no chunk row is ever persisted without a vector", %{project: project} do
      stub_embedder(fail: :transport)
      issue = create_issue(project, %{title: "Vectorless", description: "x", notes: "y"})

      assert {:error, _} = Indexer.reindex_issue(issue)

      assert Repo.aggregate(
               from(c in IssueChunk, where: c.issue_id == ^issue.id and is_nil(c.embedding)),
               :count,
               :id
             ) == 0
    end
  end

  describe "disabled embedder" do
    test "returns {:error, :disabled} and touches nothing", %{project: project} do
      Req.Test.stub(@stub, fn _conn -> flunk("should not have called the endpoint") end)
      Application.put_env(:orca_hub, :embedding_url, nil)
      issue = create_issue(project, %{title: "No embedder"})

      assert {:error, :disabled} = Indexer.reindex_issue(issue)
      assert chunks_for(issue.id) == []
      assert reload(issue).indexed_at == nil
    end
  end

  describe "bad input" do
    test "an unknown id is {:error, :issue_not_found}" do
      stub_embedder()
      assert {:error, :issue_not_found} = Indexer.reindex_issue(Ecto.UUID.generate())
    end

    test "reindex_issue/1 never raises on nonsense input" do
      assert {:error, {:invalid_issue, 42}} = Indexer.reindex_issue(42)
    end
  end

  # ── the optimistic watermark guard ──────────────────────────────────

  describe "concurrent write to the issue" do
    test "a pass against a stale struct writes chunks but not the watermark", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Raced", description: "first text"})

      # Someone else updates the issue after we loaded `issue` — the same
      # shape as an interactive write landing while we were embedding. The
      # explicit later updated_at is what a write a second or more after our
      # read produces; `updated_at` is second-precision, so a same-second
      # write is indistinguishable here by design and is covered by the
      # `>=` staleness comparison instead (see stale_query/0).
      {:ok, newer} = Issues.update_issue(reload(issue), %{description: "second text"})

      {1, _} =
        from(i in Issue, where: i.id == ^newer.id)
        |> Repo.update_all(set: [updated_at: NaiveDateTime.add(newer.updated_at, 5)])

      assert {:ok, stats} = Indexer.reindex_issue(issue)
      assert stats.stale_write
      assert stats.indexed_at == nil
      assert reload(issue).indexed_at == nil
      refute chunks_for(issue.id) == []

      # Still stale, so the sweep will come back for it with fresh content.
      assert issue.id in Indexer.stale_issue_ids(200)
    end
  end

  # ── the sweep's candidate query ─────────────────────────────────────

  describe "stale_issue_ids/1 and stale_count/0" do
    # Backdates updated_at so the next pass's `indexed_at` lands strictly
    # later — i.e. the ordinary case of an issue indexed a moment after it
    # was written, rather than inside the same one-second tick.
    defp backdate(issue, seconds \\ 5) do
      {1, _} =
        from(i in Issue, where: i.id == ^issue.id)
        |> Repo.update_all(set: [updated_at: NaiveDateTime.add(issue.updated_at, -seconds)])

      reload(issue)
    end

    test "an unindexed issue is stale, an indexed one is not", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Watermark"}) |> backdate()

      assert issue.id in Indexer.stale_issue_ids(200)
      before_count = Indexer.stale_count()

      {:ok, _} = Indexer.reindex_issue(issue)

      refute issue.id in Indexer.stale_issue_ids(200)
      assert Indexer.stale_count() == before_count - 1
    end

    test "a write after indexing makes the issue stale again", %{project: project} do
      stub_embedder()
      issue = create_issue(project, %{title: "Restale"}) |> backdate()
      {:ok, _} = Indexer.reindex_issue(issue)
      refute issue.id in Indexer.stale_issue_ids(200)

      {:ok, updated} = Issues.update_issue(reload(issue), %{description: "new text"})
      assert updated.id in Indexer.stale_issue_ids(200)
    end

    test "a same-second write is NOT missed, and costs exactly one extra no-op pass",
         %{project: project} do
      counter = stub_embedder()
      # No backdating: the write and the index pass land in the same second,
      # so updated_at == indexed_at. Under a `>` comparison this issue would
      # drop out of the sweep and a write racing that same second would be
      # invisible forever — hence `>=`.
      issue = create_issue(project, %{title: "Same second"})
      {:ok, _} = Indexer.reindex_issue(issue)
      assert issue.id in Indexer.stale_issue_ids(200)

      embedded_before = embedded_texts(counter)

      # The extra pass does no real work, and it settles the watermark so the
      # issue stops being a candidate — the loop terminates rather than
      # reindexing this issue on every tick forever. The sleep is the point
      # of the test (a real sweep tick is ~10 minutes later, so it only needs
      # to cross a one-second boundary), not incidental slowness.
      Process.sleep(1_100)

      assert {:ok, %{embedded: 0, deleted: 0}} = Indexer.reindex_issue(reload(issue))
      assert embedded_texts(counter) == embedded_before
      refute issue.id in Indexer.stale_issue_ids(200)
    end

    test "the limit is respected", %{project: project} do
      for n <- 1..3, do: create_issue(project, %{title: "Limit #{n}"})
      assert length(Indexer.stale_issue_ids(2)) == 2
    end
  end
end
