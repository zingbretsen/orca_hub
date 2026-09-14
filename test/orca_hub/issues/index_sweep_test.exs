defmodule OrcaHub.Issues.IndexSweepTest do
  @moduledoc """
  Coverage for `OrcaHub.Issues.IndexSweep` — the bounded reconciliation pass.

  `run_sweep/1` is driven directly (the house pattern from
  `OrcaHub.ChurnSamplerTest`) rather than through the singleton GenServer's
  timer, so nothing here waits on a 10-minute tick.
  """
  # async: false — global :embedding_url/:issue_indexing app env.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Issues, Projects}
  alias OrcaHub.Issues.{Indexer, IndexSweep, Issue, IssueChunk}

  @stub OrcaHub.Issues.IndexSweepStub
  @dims 1024

  setup do
    Application.put_env(:orca_hub, :embedding_url, "http://embeddings.example.com")
    Application.put_env(:orca_hub, :embedding_req_options, plug: {Req.Test, @stub})
    # The write hooks stay off so each test decides exactly what the sweep
    # finds; otherwise creating a fixture would index it before the sweep ran.
    Application.put_env(:orca_hub, :issue_indexing, :off)

    on_exit(fn ->
      Application.put_env(:orca_hub, :embedding_url, nil)
      Application.delete_env(:orca_hub, :embedding_req_options)
      Application.delete_env(:orca_hub, :issue_indexing)
    end)

    {:ok, project} =
      Projects.create_project(%{
        name: "index-sweep-test",
        directory: System.tmp_dir!(),
        node: Atom.to_string(node()),
        key_prefix: "SW" <> Integer.to_string(System.unique_integer([:positive]))
      })

    {:ok, project: project}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp stub(fun), do: Req.Test.stub(@stub, fun)

  defp ok_stub do
    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      inputs = Jason.decode!(raw)["input"]

      data =
        inputs
        |> Enum.with_index()
        |> Enum.map(fn {_t, i} -> %{"index" => i, "embedding" => List.duplicate(0.3, @dims)} end)

      Req.Test.json(conn, %{"data" => data})
    end)
  end

  defp create_issue(project, attrs) do
    {:ok, issue} = Issues.create_issue(Map.merge(%{project_id: project.id}, attrs))
    issue
  end

  # The dev DB this suite runs against holds a real issue corpus, and the
  # sandbox rolls back but does not hide it — so a sweep with the default
  # limit would pick up other issues. Every assertion here is scoped to the
  # ids this test created.
  defp sweep_only(ids) do
    # Park every issue except the ones under test by stamping a watermark far
    # in the future, so they are not candidates.
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {_, _} =
      from(i in Issue, where: i.id not in ^ids)
      |> Repo.update_all(set: [indexed_at: future])

    IndexSweep.run_sweep()
  end

  defp chunk_count(issue_id) do
    Repo.aggregate(from(c in IssueChunk, where: c.issue_id == ^issue_id), :count, :id)
  end

  defp reload(issue), do: Repo.get!(Issue, issue.id)

  # ── the normal pass ─────────────────────────────────────────────────

  describe "run_sweep/0" do
    test "indexes stale issues and stamps their watermarks", %{project: project} do
      ok_stub()
      a = create_issue(project, %{title: "Sweep me", description: "some text"})
      b = create_issue(project, %{title: "Sweep me too"})

      assert {:ok, summary} = sweep_only([a.id, b.id])

      assert summary.candidates == 2
      assert summary.indexed == 2
      assert summary.failed == 0
      assert summary.embedded == 3
      assert summary.aborted == nil

      assert chunk_count(a.id) == 2
      assert chunk_count(b.id) == 1
      assert %DateTime{} = reload(a).indexed_at
      assert %DateTime{} = reload(b).indexed_at
    end

    test "an already-indexed issue is not re-embedded", %{project: project} do
      ok_stub()
      issue = create_issue(project, %{title: "Once"})
      {:ok, _} = Indexer.reindex_issue(issue)

      # Still a candidate (same-second stamp), but there is nothing to embed.
      assert {:ok, summary} = sweep_only([issue.id])
      assert summary.indexed == 1
      assert summary.embedded == 0
      assert summary.deleted == 0
    end

    test "nothing stale is a clean no-op" do
      stub(fn _conn -> flunk("must not call the endpoint with nothing to do") end)

      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      {_, _} = Repo.update_all(Issue, set: [indexed_at: future])

      assert {:ok, %{candidates: 0, indexed: 0, embedded: 0, failed: 0}} = IndexSweep.run_sweep()
    end

    test "does nothing at all when the embedder is unconfigured", %{project: project} do
      Application.put_env(:orca_hub, :embedding_url, nil)
      stub(fn _conn -> flunk("must not call the endpoint while disabled") end)
      issue = create_issue(project, %{title: "No embedder"})

      assert {:ok, %{candidates: 0, indexed: 0}} = IndexSweep.run_sweep()
      assert chunk_count(issue.id) == 0
    end
  end

  # ── bounded work ────────────────────────────────────────────────────

  describe "bounding" do
    test "a tick reindexes at most batch_size issues", %{project: project} do
      ok_stub()
      ids = for n <- 1..5, do: create_issue(project, %{title: "Batch #{n}"}).id

      assert {:ok, summary} = sweep_only_with_limit(ids, 3)
      assert summary.candidates == 3
      assert summary.indexed == 3

      indexed = Enum.count(ids, &(Repo.get!(Issue, &1).indexed_at != nil))
      assert indexed == 3
    end

    test "the default per-tick caps are the documented ones" do
      assert IndexSweep.batch_size() == 20
      assert IndexSweep.chunk_budget() == 400
      assert IndexSweep.interval_seconds() == 600
    end
  end

  defp sweep_only_with_limit(ids, limit) do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {_, _} =
      from(i in Issue, where: i.id not in ^ids)
      |> Repo.update_all(set: [indexed_at: future])

    IndexSweep.run_sweep(limit: limit)
  end

  # ── failure isolation ───────────────────────────────────────────────

  describe "failures" do
    test "one bad issue does not stop the others (per-issue 400)", %{project: project} do
      good_a = create_issue(project, %{title: "Good A"})
      bad = create_issue(project, %{title: "Poison"})
      good_b = create_issue(project, %{title: "Good B"})

      # A 400 only for the poison issue's text — the shape of a chunk the
      # server refuses outright, which must not abort the tick.
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        inputs = Jason.decode!(raw)["input"]

        if Enum.any?(inputs, &(&1 =~ "Poison")) do
          conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "too long"})
        else
          data =
            inputs
            |> Enum.with_index()
            |> Enum.map(fn {_t, i} ->
              %{"index" => i, "embedding" => List.duplicate(0.3, @dims)}
            end)

          Req.Test.json(conn, %{"data" => data})
        end
      end)

      assert {:ok, summary} = sweep_only([good_a.id, bad.id, good_b.id])

      assert summary.candidates == 3
      assert summary.indexed == 2
      assert summary.failed == 1
      assert summary.aborted == nil

      assert chunk_count(good_a.id) == 1
      assert chunk_count(good_b.id) == 1
      assert chunk_count(bad.id) == 0
      # The poison issue stays stale — it costs one slot per tick, and newest
      # -first ordering keeps it from pinning the whole batch.
      assert reload(bad).indexed_at == nil
    end

    test "an unreachable endpoint aborts the tick instead of retrying every issue", %{
      project: project
    } do
      attempts = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(attempts, 1, 1)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      ids = for n <- 1..4, do: create_issue(project, %{title: "Endpoint down #{n}"}).id

      assert {:ok, summary} = sweep_only(ids)

      assert summary.failed == 1
      assert summary.indexed == 0
      assert summary.aborted == :endpoint
      # Exactly one issue was attempted: Embeddings itself retries once, so
      # two HTTP attempts total, not one per issue.
      assert :counters.get(attempts, 1) == 2

      assert Enum.all?(ids, &(Repo.get!(Issue, &1).indexed_at == nil))
    end

    test "a 500 also aborts the tick", %{project: project} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "busy"})
      end)

      ids = for n <- 1..3, do: create_issue(project, %{title: "Server sad #{n}"}).id

      assert {:ok, %{aborted: :endpoint, failed: 1, indexed: 0}} = sweep_only(ids)
    end

    test "an unexpected exception inside the pass is logged, not raised" do
      # An impossible limit makes Indexer.stale_issue_ids/1 raise inside
      # run_sweep — stand-in for any unforeseen failure (a DB outage, a bad
      # query). The outer rescue must turn it into a neutral summary rather
      # than letting it reach the GenServer and take the timer loop with it.
      assert {:ok, %{candidates: 0, indexed: 0}} = IndexSweep.run_sweep(limit: -1)
    end
  end
end
