defmodule OrcaHub.IssuesIndexingHooksTest do
  @moduledoc """
  Coverage for the pgvector index maintenance hook in `OrcaHub.Issues` —
  `after_write/1`, which fires `OrcaHub.Issues.Indexer.reindex_async/1` after
  every successful write.

  Three properties are what this file is really defending:

    * with no embedder configured (the default in `config/test.exs`, and on
      any node without `EMBEDDING_URL`) a write spawns NOTHING — no Task to
      outlive a test's sandbox, no HTTP, no DB work;
    * every write entry point named in the brief reaches the indexer, which
      is checked by going through the funnel the hook sits on rather than by
      trusting that it does;
    * an embedder that is broken, or simply slow to answer, cannot fail or
      delay an interactive issue write.
  """
  # async: false — global :embedding_url/:issue_indexing app env.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Issues, Projects}
  alias OrcaHub.Issues.{Indexer, Issue, IssueChunk}

  @stub OrcaHub.IssuesIndexingHooksStub
  @dims 1024

  setup do
    on_exit(fn ->
      Application.put_env(:orca_hub, :embedding_url, nil)
      Application.delete_env(:orca_hub, :embedding_req_options)
      Application.delete_env(:orca_hub, :issue_indexing)
    end)

    {:ok, project} =
      Projects.create_project(%{
        name: "issue-index-hooks",
        directory: System.tmp_dir!(),
        node: Atom.to_string(node()),
        key_prefix: "HK" <> Integer.to_string(System.unique_integer([:positive]))
      })

    {:ok, project: project}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp enable_embedder(mode) do
    Application.put_env(:orca_hub, :embedding_url, "http://embeddings.example.com")
    Application.put_env(:orca_hub, :embedding_req_options, plug: {Req.Test, @stub})
    Application.put_env(:orca_hub, :issue_indexing, mode)
  end

  defp stub_ok do
    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      inputs = Jason.decode!(raw)["input"]

      data =
        inputs
        |> Enum.with_index()
        |> Enum.map(fn {_t, i} -> %{"index" => i, "embedding" => List.duplicate(0.1, @dims)} end)

      Req.Test.json(conn, %{"data" => data})
    end)
  end

  defp create_issue(project, attrs) do
    {:ok, issue} = Issues.create_issue(Map.merge(%{project_id: project.id}, attrs))
    issue
  end

  defp chunk_count(issue_id) do
    Repo.aggregate(from(c in IssueChunk, where: c.issue_id == ^issue_id), :count, :id)
  end

  defp chunk_contents(issue_id) do
    from(c in IssueChunk, where: c.issue_id == ^issue_id, select: c.content) |> Repo.all()
  end

  defp reload(issue), do: Repo.get!(Issue, issue.id)

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never became true")
      true -> Process.sleep(20)
    end
    |> case do
      :ok -> :ok
      _ -> do_wait_until(fun, deadline)
    end
  end

  # ── the no-embedder case: the one that must cost nothing ────────────

  describe "with no embedder configured (config/test.exs default)" do
    test "mode/0 is :off, so no Task is ever spawned by a write", %{project: project} do
      refute Indexer.enabled?()
      assert Indexer.mode() == :off

      # A flunking stub proves no HTTP is attempted even if a Task did run.
      Req.Test.stub(@stub, fn _conn -> flunk("the endpoint must not be called") end)

      issue = create_issue(project, %{title: "Unindexed", description: "text"})
      {:ok, updated} = Issues.update_issue(issue, %{description: "other text"})
      {:ok, _} = Issues.append_note(updated, "a note")

      assert chunk_count(issue.id) == 0
      assert reload(issue).indexed_at == nil
    end

    test "an explicit :off kill switch also disables an otherwise-live embedder", %{
      project: project
    } do
      enable_embedder(:off)
      Req.Test.stub(@stub, fn _conn -> flunk("the endpoint must not be called") end)

      assert Indexer.enabled?()
      assert Indexer.mode() == :off

      issue = create_issue(project, %{title: "Switched off"})
      assert chunk_count(issue.id) == 0
    end

    test "`false` is accepted as the kill switch too" do
      enable_embedder(false)
      assert Indexer.mode() == :off
    end
  end

  # ── every write path reaches the indexer ────────────────────────────

  describe "write hooks (sync mode)" do
    setup do
      enable_embedder(:sync)
      stub_ok()
      :ok
    end

    test "create_issue/1 indexes the new issue", %{project: project} do
      issue = create_issue(project, %{title: "Created", description: "described"})

      assert chunk_count(issue.id) == 2
      assert %DateTime{} = reload(issue).indexed_at
    end

    test "update_issue/2 reindexes", %{project: project} do
      issue = create_issue(project, %{title: "Updated"})
      {:ok, _} = Issues.update_issue(reload(issue), %{description: "now has a description"})

      assert Enum.any?(chunk_contents(issue.id), &(&1 =~ "now has a description"))
    end

    test "update_issue/3 reindexes", %{project: project} do
      issue = create_issue(project, %{title: "Updated with session"})
      {:ok, _} = Issues.update_issue(reload(issue), %{plan: "the plan text"}, nil)

      assert Enum.any?(chunk_contents(issue.id), &(&1 =~ "the plan text"))
    end

    test "append_note/2 reindexes", %{project: project} do
      issue = create_issue(project, %{title: "Noted"})
      {:ok, _} = Issues.append_note(reload(issue), "an appended note")

      assert Enum.any?(chunk_contents(issue.id), &(&1 =~ "an appended note"))
    end

    test "close_issue/2 indexes the resolution it writes", %{project: project} do
      issue = create_issue(project, %{title: "Closed"})

      {:ok, closed} =
        Issues.close_issue(reload(issue), %{outcome: "resolved", resolution: "fixed it properly"})

      assert closed.status == "closed"
      assert Enum.any?(chunk_contents(issue.id), &(&1 =~ "fixed it properly"))
      assert %DateTime{} = reload(issue).indexed_at
    end

    test "reopen_issue/2 indexes the archive note it appends", %{project: project} do
      issue = create_issue(project, %{title: "Reopened"})

      {:ok, closed} =
        Issues.close_issue(reload(issue), %{outcome: "resolved", resolution: "was fixed"})

      {:ok, reopened} = Issues.reopen_issue(closed, nil)

      assert reopened.status == "open"
      # The resolution was cleared, and the archive note preserving it was
      # appended to notes — the index must reflect both.
      contents = chunk_contents(issue.id)
      refute Enum.any?(contents, &String.starts_with?(&1, "resolution: "))
      assert Enum.any?(contents, &(&1 =~ "Previously closed as resolved"))
    end

    test "a write whose indexing fails still succeeds", %{project: project} do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:ok, issue} = Issues.create_issue(%{project_id: project.id, title: "Embedder down"})
      assert {:ok, _} = Issues.append_note(issue, "still writable")

      assert reload(issue).notes =~ "still writable"
      assert chunk_count(issue.id) == 0
      assert reload(issue).indexed_at == nil
      # ...and it is queued for the sweep.
      assert issue.id in Indexer.stale_issue_ids(500)
    end
  end

  # ── async mode: the interactive-write latency guarantee ─────────────

  describe "async mode" do
    test "the write returns before the embedder answers, then the index lands", %{
      project: project
    } do
      enable_embedder(:async)
      test_pid = self()

      # A stub that parks until this test lets it go — a deterministic stand-in
      # for a slow/hanging embedder, with no sleeps or timing margins.
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        inputs = Jason.decode!(raw)["input"]
        send(test_pid, {:embedding_requested, self()})

        receive do
          :proceed -> :ok
        after
          5_000 -> :ok
        end

        data =
          inputs
          |> Enum.with_index()
          |> Enum.map(fn {_t, i} ->
            %{"index" => i, "embedding" => List.duplicate(0.1, @dims)}
          end)

        Req.Test.json(conn, %{"data" => data})
      end)

      issue = create_issue(project, %{title: "Async write"})

      # The write has already returned while the embedder is still parked.
      assert_receive {:embedding_requested, embedder}, 2_000
      assert chunk_count(issue.id) == 0

      send(embedder, :proceed)

      wait_until(fn -> chunk_count(issue.id) > 0 end)
      wait_until(fn -> reload(issue).indexed_at != nil end)
    end
  end
end
