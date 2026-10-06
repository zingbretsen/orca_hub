defmodule OrcaHub.SessionSearch.IndexerTest do
  # The dev DB is shared with real data, so every sweep here is scoped to the
  # test's own sessions (`:session_ids`) and uses its own cursor name.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.Repo
  alias OrcaHub.SessionSearch.{Cursor, Failure, Indexer}
  alias OrcaHub.Sessions
  alias OrcaHub.Sessions.Message

  setup do
    {:ok, s1} = Sessions.create_session(%{directory: "/tmp/ss1", runner_node: "debian"})
    {:ok, s2} = Sessions.create_session(%{directory: "/tmp/ss2", kind: "memory_extraction"})
    {:ok, test_pid} = Agent.start_link(fn -> [] end)

    %{s1: s1, s2: s2, calls: test_pid, name: "test-" <> Ecto.UUID.generate()}
  end

  defp put_msg(session, n, content, type \\ "user") do
    ts = NaiveDateTime.add(~N[2026-01-01 00:00:00.000000], n, :second)

    Repo.insert!(%Message{
      session_id: session.id,
      inserted_at: ts,
      updated_at: ts,
      data: %{"type" => type, "message" => %{"content" => content}}
    })
  end

  defp texts(n_from, n_to), do: for(i <- n_from..n_to, do: "message #{i}")

  defp seed(session, count) do
    for i <- 1..count, do: put_msg(session, i, "message #{i}")
  end

  defp opts(ctx, extra \\ []) do
    calls = ctx.calls

    fun = fn docs ->
      Agent.update(calls, &(&1 ++ [docs]))

      Keyword.get(extra, :respond, fn d ->
        {:ok,
         %{"indexed" => length(d), "chunks" => length(d), "embedded" => length(d), "errors" => []}}
      end).(docs)
    end

    Keyword.delete(extra, :respond) ++
      [
        name: ctx.name,
        session_ids: [ctx.s1.id, ctx.s2.id],
        settle_seconds: 0,
        batch_size: 3,
        index_fun: fun
      ]
  end

  defp posted(ctx),
    do: ctx.calls |> Agent.get(& &1) |> Enum.map(fn b -> Enum.map(b, & &1["text"]) end)

  defp cursor(ctx), do: Repo.get(Cursor, ctx.name)

  test "sweeps in (inserted_at, id) order, batch-bounded, cursor advances each tick", ctx do
    seed(ctx.s1, 7)

    assert {:ok, %{docs: 3, behind: true}} = Indexer.run_tick(opts(ctx))
    assert posted(ctx) == [["message 1", "message 2", "message 3"]]
    assert cursor(ctx).indexed_total == 3

    assert {:ok, %{docs: 3, behind: true}} = Indexer.run_tick(opts(ctx))
    assert {:ok, %{docs: 1, behind: false}} = Indexer.run_tick(opts(ctx))
    assert {:ok, %{docs: 0, behind: false}} = Indexer.run_tick(opts(ctx))

    assert posted(ctx) |> List.flatten() == texts(1, 7)
    assert Enum.all?(posted(ctx), &(length(&1) <= 3))
    assert cursor(ctx).indexed_total == 7
  end

  test "a failed post holds the cursor; the next tick re-sends the same docs", ctx do
    seed(ctx.s1, 2)
    down = fn _ -> {:error, {:request_failed, :econnrefused}} end

    assert {:error, _} = Indexer.run_tick(opts(ctx, respond: down))
    assert cursor(ctx) == nil

    assert {:error, {:http_error, 503, _}} =
             Indexer.run_tick(opts(ctx, respond: fn _ -> {:error, {:http_error, 503, %{}}} end))

    assert cursor(ctx) == nil

    assert {:ok, %{docs: 2}} = Indexer.run_tick(opts(ctx))
    assert List.last(posted(ctx)) == ["message 1", "message 2"]
    assert cursor(ctx).indexed_total == 2
  end

  test "restart resumes from the durable cursor (no in-process state)", ctx do
    seed(ctx.s1, 5)
    assert {:ok, %{docs: 3}} = Indexer.run_tick(opts(ctx))
    Agent.update(ctx.calls, fn _ -> [] end)

    # a "restarted" indexer is just another run_tick: it reads the row
    assert {:ok, %{docs: 2}} = Indexer.run_tick(opts(ctx))
    assert posted(ctx) == [["message 4", "message 5"]]
  end

  test "background-kind sessions and non-text rows are scanned past, never posted", ctx do
    put_msg(ctx.s2, 1, "replayed transcript")
    put_msg(ctx.s1, 2, [%{"type" => "tool_result", "tool_use_id" => "t", "content" => "dump"}])
    put_msg(ctx.s1, 3, [%{"type" => "tool_use", "name" => "Bash"}], "assistant")
    put_msg(ctx.s1, 4, "<orca-memory>\nm\n</orca-memory>\n\nreal prompt")
    put_msg(ctx.s1, 5, [%{"type" => "text", "text" => "reply"}], "assistant")

    assert {:ok, %{docs: 2}} = Indexer.run_tick(opts(ctx))
    assert posted(ctx) == [["real prompt", "reply"]]

    assert [%{"fields" => %{"role" => "user", "node" => "debian"}}, _] =
             hd(Agent.get(ctx.calls, & &1))
  end

  test "an all-skipped page advances the cursor without a post", ctx do
    put_msg(ctx.s1, 1, [%{"type" => "tool_use", "name" => "Bash"}], "assistant")
    put_msg(ctx.s1, 2, [%{"type" => "text", "text" => "   "}], "assistant")

    assert {:ok, %{docs: 0, scanned: scanned}} = Indexer.run_tick(opts(ctx))
    assert scanned == 1
    assert posted(ctx) == []
    assert cursor(ctx).last_message_id
  end

  test "messages newer than the settle window are not scanned yet", ctx do
    Repo.insert!(%Message{
      session_id: ctx.s1.id,
      data: %{"type" => "user", "message" => %{"content" => "just now"}}
    })

    assert {:ok, %{docs: 0}} = Indexer.run_tick(opts(ctx, settle_seconds: 60))
    assert {:ok, %{docs: 1}} = Indexer.run_tick(opts(ctx, settle_seconds: 0))
  end

  test "per-doc errors do not wedge the cursor and are recorded for retry", ctx do
    [m1, m2, _m3] = seed(ctx.s1, 3)

    respond = fn docs ->
      {:ok,
       %{
         "indexed" => 2,
         "chunks" => 2,
         "embedded" => 2,
         "errors" => [%{"id" => hd(docs)["id"], "reason" => "boom"}]
       }}
    end

    assert {:ok, %{docs: 3, errors: 1}} = Indexer.run_tick(opts(ctx, respond: respond))
    assert cursor(ctx).indexed_total == 2
    assert %Failure{attempts: 1, reason: "boom", session_id: sid} = Repo.get(Failure, m1.id)
    assert sid == ctx.s1.id
    refute Repo.get(Failure, m2.id)

    # inside the backoff: not retried
    Agent.update(ctx.calls, fn _ -> [] end)

    assert {:ok, %{docs: 0, retried: 0}} =
             Indexer.run_tick(opts(ctx, retry_backoff_seconds: 3600))

    assert posted(ctx) == []

    # past the backoff: retried alone; success clears the row
    assert {:ok, %{retried: 1}} = Indexer.run_tick(opts(ctx, retry_backoff_seconds: 0))
    assert posted(ctx) == [["message 1"]]
    refute Repo.get(Failure, m1.id)
  end

  test "retries stop at the attempt cap and the row stays as a dead letter", ctx do
    [m1] = seed(ctx.s1, 1)

    always_bad = fn docs ->
      {:ok, %{"errors" => [%{"id" => hd(docs)["id"], "reason" => "bad"}]}}
    end

    Indexer.run_tick(opts(ctx, respond: always_bad))

    for _ <- 1..10, do: Indexer.run_tick(opts(ctx, respond: always_bad, retry_backoff_seconds: 0))

    assert %Failure{attempts: attempts} = Repo.get(Failure, m1.id)
    assert attempts == Indexer.max_attempts()
    n = length(posted(ctx))
    Indexer.run_tick(opts(ctx, respond: always_bad, retry_backoff_seconds: 0))
    assert length(posted(ctx)) == n
  end

  test "a failure row whose message vanished is dropped", ctx do
    Repo.insert!(%Failure{message_id: Ecto.UUID.generate(), session_id: ctx.s1.id, reason: "x"})
    {_, _} = Repo.update_all(Failure, set: [updated_at: ~N[2020-01-01 00:00:00.000000]])
    Indexer.run_tick(opts(ctx, retry_backoff_seconds: 0))
    assert Repo.all(Failure) |> Enum.filter(&(&1.session_id == ctx.s1.id)) == []
  end

  test "reindex_session/2 re-posts a session without touching the cursor", ctx do
    seed(ctx.s1, 4)
    assert {:ok, 4} = Indexer.reindex_session(ctx.s1.id, opts(ctx))
    assert posted(ctx) |> Enum.map(&length/1) == [3, 1]
    assert cursor(ctx) == nil
  end

  describe "kill switch / enabled?" do
    setup do
      on_exit(fn ->
        Application.delete_env(:orca_hub, :session_search_indexing)
        Application.put_env(:orca_hub, :memory_service_url, nil)
        Application.put_env(:orca_hub, :memory_service_token, nil)
      end)
    end

    test "off without a memory service; on with one; off again via the kill switch" do
      refute Indexer.enabled?()
      Application.put_env(:orca_hub, :memory_service_url, "https://m.example.com")
      Application.put_env(:orca_hub, :memory_service_token, "t")
      assert Indexer.enabled?()
      Application.put_env(:orca_hub, :session_search_indexing, false)
      refute Indexer.enabled?()
    end

    test "a disabled GenServer tick performs no sweep and keeps ticking", ctx do
      seed(ctx.s1, 1)
      refute Indexer.enabled?()
      assert {:noreply, %{error_streak: 0}} = Indexer.handle_info(:tick, %{error_streak: 0})
    end
  end

  describe "hard delete" do
    test "clears the session's failure rows", ctx do
      Repo.insert!(%Failure{message_id: Ecto.UUID.generate(), session_id: ctx.s1.id, reason: "x"})
      assert {:ok, _} = Sessions.delete_session(ctx.s1)
      assert Repo.all(Failure) |> Enum.filter(&(&1.session_id == ctx.s1.id)) == []
    end

    test "asks memory-service to delete the session's docs when enabled", ctx do
      stub = OrcaHub.SessionSearchDeleteStub
      test = self()
      Application.put_env(:orca_hub, :memory_service_url, "https://m.example.com")
      Application.put_env(:orca_hub, :memory_service_token, "t")
      Application.put_env(:orca_hub, :memory_service_req_options, plug: {Req.Test, stub})

      on_exit(fn ->
        Application.put_env(:orca_hub, :memory_service_url, nil)
        Application.put_env(:orca_hub, :memory_service_token, nil)
        Application.delete_env(:orca_hub, :memory_service_req_options)
      end)

      Req.Test.stub(stub, fn conn ->
        send(test, {:deleted, conn.method, conn.request_path})
        Req.Test.json(conn, %{"deleted" => 1})
      end)

      Req.Test.allow(stub, self(), Process.whereis(OrcaHub.TaskSupervisor))
      sid = ctx.s1.id
      assert {:ok, _} = Sessions.delete_session(ctx.s1)
      assert_receive {:deleted, "DELETE", path}, 2000
      assert path == "/v1/collections/session-messages/groups/#{sid}"
    end
  end
end
