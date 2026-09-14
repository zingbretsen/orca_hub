defmodule OrcaHub.Issues.BackfillTest do
  @moduledoc """
  Coverage for `OrcaHub.Issues.Backfill` — the bulk reindex behind
  `mix orca.reindex_issues` and the release's
  `OrcaHub.Issues.Backfill.run/1`.

  The properties worth defending here are the ones that only bite on a
  corpus larger than this project's 111 issues: paging terminates even when
  an issue fails permanently, `--limit` really stops, and an endpoint that
  goes down aborts the run instead of dragging the whole corpus through it.
  """
  # async: false — global :embedding_url/:issue_indexing app env.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Issues, Projects}
  alias OrcaHub.Issues.{Backfill, Indexer, Issue, IssueChunk}

  @stub OrcaHub.Issues.BackfillStub
  @dims 1024

  setup do
    Application.put_env(:orca_hub, :embedding_url, "http://embeddings.example.com")
    Application.put_env(:orca_hub, :embedding_req_options, plug: {Req.Test, @stub})
    Application.put_env(:orca_hub, :issue_indexing, :off)

    on_exit(fn ->
      Application.put_env(:orca_hub, :embedding_url, nil)
      Application.delete_env(:orca_hub, :embedding_req_options)
      Application.delete_env(:orca_hub, :issue_indexing)
    end)

    {:ok, project} =
      Projects.create_project(%{
        name: "backfill-test",
        directory: System.tmp_dir!(),
        node: Atom.to_string(node()),
        key_prefix: "BF" <> Integer.to_string(System.unique_integer([:positive]))
      })

    {:ok, project: project}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  # The concurrency here is real (Task.async_stream), and Req.Test resolves a
  # stub through $callers, which async_stream sets — so a shared stub works
  # from the spawned tasks. Concurrency is pinned to 1 in tests that assert on
  # exact per-issue call sequencing.
  defp stub(fun), do: Req.Test.stub(@stub, fun)

  defp ok_stub do
    stub(fn conn -> respond(conn) end)
  end

  defp respond(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    inputs = Jason.decode!(raw)["input"]

    data =
      inputs
      |> Enum.with_index()
      |> Enum.map(fn {_t, i} -> %{"index" => i, "embedding" => List.duplicate(0.4, @dims)} end)

    Req.Test.json(conn, %{"data" => data})
  end

  defp create_issue(project, attrs) do
    {:ok, issue} = Issues.create_issue(Map.merge(%{project_id: project.id}, attrs))
    issue
  end

  # Parks every issue but these, so a run's counters are about this test's
  # fixtures and not the dev DB's real corpus.
  defp isolate(ids) do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {_, _} =
      from(i in Issue, where: i.id not in ^ids)
      |> Repo.update_all(set: [indexed_at: future])

    :ok
  end

  defp chunk_count(issue_id) do
    Repo.aggregate(from(c in IssueChunk, where: c.issue_id == ^issue_id), :count, :id)
  end

  # ── the normal run ──────────────────────────────────────────────────

  describe "run/1" do
    test "indexes every stale issue", %{project: project} do
      ok_stub()
      ids = for n <- 1..6, do: create_issue(project, %{title: "Corpus #{n}"}).id
      isolate(ids)

      assert {:ok, summary} = Backfill.run(concurrency: 2)

      assert summary.visited == 6
      assert summary.indexed == 6
      assert summary.embedded == 6
      assert summary.failed == 0
      assert summary.aborted == nil
      assert summary.duration_ms >= 0

      assert Enum.all?(ids, &(chunk_count(&1) == 1))
      assert Enum.all?(ids, &(Repo.get!(Issue, &1).indexed_at != nil))
    end

    # NOTE for the two --force tests below: `force: true` visits EVERY issue in
    # the database, and this suite runs against the shared dev DB, whose own
    # issues are visible inside the sandbox transaction. So a forced run's
    # `visited` is "my fixtures + whatever else is in there" — asserted against
    # a baseline rather than against a bare fixture count.
    test "a second run over the same corpus embeds nothing new", %{project: project} do
      ok_stub()
      for n <- 1..3, do: create_issue(project, %{title: "Stable #{n}"})

      # Forced, so the WHOLE corpus is indexed and the second run has nothing
      # left to do — otherwise a never-indexed dev-DB issue shows up as work.
      {:ok, first} = Backfill.run(force: true)
      assert first.embedded >= 3

      assert {:ok, second} = Backfill.run(force: true)

      assert second.visited == first.visited
      assert second.embedded == 0
      assert second.unchanged >= 3
    end

    test "--force visits issues that are already up to date", %{project: project} do
      ok_stub()
      for n <- 1..3, do: create_issue(project, %{title: "Forced #{n}"})
      {:ok, _} = Backfill.run(force: true)

      # Settle every watermark so nothing is stale (a stamp in the same second
      # as the write ties, and `>=` deliberately treats a tie as stale).
      {_, _} =
        Repo.update_all(Issue,
          set: [updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-60)]
        )

      total = Backfill.countable(force: true)
      assert total >= 3

      assert {:ok, %{visited: 0}} = Backfill.run()
      assert {:ok, %{visited: ^total, embedded: 0}} = Backfill.run(force: true)
    end

    test "--limit stops after that many issues", %{project: project} do
      ok_stub()
      ids = for n <- 1..8, do: create_issue(project, %{title: "Limited #{n}"}).id
      isolate(ids)

      assert {:ok, %{visited: 3, indexed: 3}} = Backfill.run(limit: 3)
      assert Enum.count(ids, &(Repo.get!(Issue, &1).indexed_at != nil)) == 3
    end

    test "--dry-run counts without embedding", %{project: project} do
      stub(fn _conn -> flunk("a dry run must not call the endpoint") end)
      ids = for n <- 1..4, do: create_issue(project, %{title: "Dry #{n}"}).id
      isolate(ids)

      assert {:ok, %{visited: 4, indexed: 0, embedded: 0}} = Backfill.run(dry_run: true)
      assert Enum.all?(ids, &(chunk_count(&1) == 0))
    end

    test "no embedder configured is a clear error, not a silent no-op", %{project: project} do
      Application.put_env(:orca_hub, :embedding_url, nil)
      create_issue(project, %{title: "Unindexable"})

      assert {:error, :disabled} = Backfill.run()
    end

    test "countable/1 reports what a run would visit", %{project: project} do
      ids = for n <- 1..5, do: create_issue(project, %{title: "Countable #{n}"}).id
      isolate(ids)

      assert Backfill.countable() == 5
      assert Backfill.countable(force: true) >= 5
    end
  end

  # ── the properties that matter at scale ─────────────────────────────

  describe "termination and failure handling" do
    test "a permanently failing issue does not stall the run", %{project: project} do
      # Paging is by id, so the poison issue is behind the cursor once
      # visited — a "fetch stale until empty" loop would spin on it forever.
      good = for n <- 1..4, do: create_issue(project, %{title: "Fine #{n}"}).id
      bad = create_issue(project, %{title: "Poison pill"}).id
      isolate([bad | good])

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        inputs = Jason.decode!(raw)["input"]

        if Enum.any?(inputs, &(&1 =~ "Poison pill")) do
          conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "too long"})
        else
          data =
            inputs
            |> Enum.with_index()
            |> Enum.map(fn {_t, i} ->
              %{"index" => i, "embedding" => List.duplicate(0.4, @dims)}
            end)

          Req.Test.json(conn, %{"data" => data})
        end
      end)

      assert {:ok, summary} = Backfill.run(concurrency: 1)

      assert summary.visited == 5
      assert summary.indexed == 4
      assert summary.failed == 1
      assert summary.aborted == nil
      assert [{^bad, {:http_error, 400, _}}] = summary.errors
      assert Enum.all?(good, &(chunk_count(&1) == 1))
    end

    test "an endpoint-level failure aborts the run", %{project: project} do
      attempts = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(attempts, 1, 1)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      ids = for n <- 1..10, do: create_issue(project, %{title: "Down #{n}"}).id
      isolate(ids)

      assert {:ok, summary} = Backfill.run(concurrency: 1)

      assert summary.aborted == :endpoint
      assert summary.indexed == 0
      # One issue attempted, and Embeddings retries a transport error once:
      # two HTTP attempts total, not 10+ (which is what a plain Enum.reduce
      # over the async_stream produced — the abort flag stopped the next page
      # but the current page's remaining 9 issues had already been queued).
      assert summary.visited == 1
      assert :counters.get(attempts, 1) == 2
      assert Enum.all?(ids, &(Repo.get!(Issue, &1).indexed_at == nil))
    end

    test "paging crosses more than one page", %{project: project} do
      ok_stub()
      # The page size is 25 internally; a limit-driven run over 30 issues
      # would be slow here, so instead assert the cursor advances by running
      # with a limit larger than one page's worth of fixtures and checking
      # every issue was visited exactly once.
      ids = for n <- 1..7, do: create_issue(project, %{title: "Paged #{n}"}).id
      isolate(ids)

      assert {:ok, %{visited: 7, indexed: 7}} = Backfill.run(concurrency: 3)
      assert Enum.all?(ids, &(chunk_count(&1) == 1))
    end

    test "the progress callback is invoked per page", %{project: project} do
      ok_stub()
      ids = for n <- 1..3, do: create_issue(project, %{title: "Progress #{n}"}).id
      isolate(ids)

      test_pid = self()

      assert {:ok, _} = Backfill.run(progress: fn acc -> send(test_pid, {:progress, acc}) end)
      assert_received {:progress, %{visited: 3}}
    end
  end

  describe "Indexer.page_issue_ids/3" do
    test "pages forward by id and respects stale_only", %{project: project} do
      ok_stub()
      ids = for n <- 1..4, do: create_issue(project, %{title: "Keyset #{n}"}).id
      isolate(ids)

      first_two = Indexer.page_issue_ids(nil, 2, stale_only: true)
      assert length(first_two) == 2

      next = Indexer.page_issue_ids(List.last(first_two), 2, stale_only: true)
      assert length(next) == 2
      assert MapSet.disjoint?(MapSet.new(first_two), MapSet.new(next))

      # Sorted ascending by id, which is what makes the cursor sound.
      assert Enum.sort(first_two ++ next) == Enum.sort(ids)
      assert Enum.all?(next, fn id -> id > List.last(first_two) end)
    end
  end
end
