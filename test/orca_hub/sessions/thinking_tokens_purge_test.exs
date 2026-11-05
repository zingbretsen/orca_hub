defmodule OrcaHub.Sessions.ThinkingTokensPurgeTest do
  # async: false because one test flips the global :mode env to :agent.
  use OrcaHub.DataCase, async: false

  import Ecto.Query

  alias OrcaHub.{Projects, Repo, Sessions}
  alias OrcaHub.Sessions.{Message, ThinkingTokensPurge}

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Purge",
        directory: "/tmp/test-purge-#{System.unique_integer([:positive])}"
      })

    # a: 7 ticks + 4 other events, b: 4 ticks + 1 other, c: no ticks.
    a =
      seed_session(project, 7, [system("init"), system("compact_boundary"), assistant(), user()])

    b = seed_session(project, 4, [system("init")])
    c = seed_session(project, 0, [system("init"), assistant()])

    %{a: a, b: b, c: c, ids: [a.id, b.id, c.id]}
  end

  defp seed_session(project, ticks, others) do
    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        directory: "/tmp/test-purge-#{System.unique_integer([:positive])}"
      })

    for i <- 1..ticks//1, do: insert!(session, tick(i))
    for data <- others, do: insert!(session, data)
    session
  end

  defp insert!(session, data) do
    {:ok, _} = Sessions.create_message(%{session_id: session.id, data: data})
  end

  defp tick(i) do
    %{
      "type" => "system",
      "subtype" => "thinking_tokens",
      "estimated_tokens" => i * 40,
      "estimated_tokens_delta" => 40
    }
  end

  defp system(subtype), do: %{"type" => "system", "subtype" => subtype}
  defp assistant, do: %{"type" => "assistant", "message" => %{"content" => []}}
  defp user, do: %{"type" => "user", "message" => %{"content" => []}}

  defp ticks_left(ids) do
    Repo.aggregate(
      from(m in Message,
        where: m.session_id in ^ids,
        where: fragment("? ->> 'subtype'", m.data) == "thinking_tokens"
      ),
      :count
    )
  end

  defp others_left(ids) do
    from(m in Message,
      where: m.session_id in ^ids,
      where: fragment("coalesce(? ->> 'subtype', '')", m.data) != "thinking_tokens",
      select:
        {m.session_id, fragment("? ->> 'type'", m.data), fragment("? ->> 'subtype'", m.data)}
    )
    |> Repo.all()
    |> Enum.sort()
  end

  defp run(opts) do
    opts
    |> Keyword.put_new(:sleep_ms, 0)
    |> Keyword.put_new(:progress, fn _line -> :ok end)
    |> ThinkingTokensPurge.run()
  end

  test "dry_run returns the count and deletes nothing", %{ids: ids} do
    others = others_left(ids)

    assert %{dry_run: true, rows: 11, sessions: 2, deleted: 0, batches: 0} =
             run(dry_run: true, session_ids: ids)

    assert ticks_left(ids) == 11
    assert others_left(ids) == others
  end

  test "deletes only the ticks, across several batches, and a second run deletes nothing",
       %{ids: ids} do
    others = others_left(ids)
    assert length(others) == 7

    # batch_size 3: a (7 ticks) takes 3+3+1, b (4) takes 3+1.
    assert %{dry_run: false, rows: 11, sessions: 2, deleted: 11, batches: 5} =
             run(batch_size: 3, session_ids: ids)

    assert ticks_left(ids) == 0
    assert others_left(ids) == others

    assert %{rows: 0, sessions: 0, deleted: 0, batches: 0} = run(batch_size: 3, session_ids: ids)
  end

  test "sessions smaller than a batch share one DELETE", %{ids: ids} do
    assert %{deleted: 11, batches: 1} = run(batch_size: 20, session_ids: ids)
    assert ticks_left(ids) == 0
  end

  test "logs one line per batch plus the count and the total", %{ids: ids} do
    test_pid = self()

    run(batch_size: 5, session_ids: ids, progress: &send(test_pid, {:line, &1}))

    lines = collect_lines()
    assert hd(lines) =~ "11 row(s) in 2 session(s)"
    assert Enum.count(lines, &(&1 =~ ~r/batch \d+: deleted/)) == 3
    assert List.last(lines) =~ ~r/done: deleted 11 row\(s\) in 3 batch\(es\)/
  end

  test "with no :session_ids it walks every session", %{ids: ids} do
    %{rows: all} = run(dry_run: true)
    # The shared dev DB may hold committed ticks of its own.
    assert all >= 11

    assert %{deleted: ^all} = run([])
    assert ticks_left(ids) == 0
    assert %{rows: 0, deleted: 0} = run([])
  end

  test "refuses on an agent node", %{ids: ids} do
    prev = Application.fetch_env(:orca_hub, :mode)
    Application.put_env(:orca_hub, :mode, :agent)

    on_exit(fn ->
      case prev do
        {:ok, mode} -> Application.put_env(:orca_hub, :mode, mode)
        :error -> Application.delete_env(:orca_hub, :mode)
      end
    end)

    assert_raise RuntimeError, ~r/must run on the hub/, fn -> run(session_ids: ids) end
    assert ticks_left(ids) == 11
  end

  test "refuses when the index is missing", %{ids: ids} do
    assert_raise RuntimeError, ~r/index no_such_index is missing/, fn ->
      run(session_ids: ids, index: "no_such_index")
    end

    assert ticks_left(ids) == 11
  end

  test "an unknown or out-of-range option raises before anything runs", %{ids: ids} do
    assert_raise ArgumentError, fn -> run(dryrun: true, session_ids: ids) end

    assert_raise ArgumentError, ~r/batch_size/, fn ->
      run(batch_size: 40_000, session_ids: ids)
    end

    assert_raise ArgumentError, ~r/batch_size/, fn -> run(batch_size: 0, session_ids: ids) end
    assert_raise ArgumentError, ~r/sleep_ms/, fn -> run(sleep_ms: -1, session_ids: ids) end
    assert ticks_left(ids) == 11
  end

  test "progress prints to the caller's group leader by default", %{ids: ids} do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        ThinkingTokensPurge.run(dry_run: true, session_ids: ids)
      end)

    assert output =~
             "[thinking_tokens purge] 11 row(s) in 2 session(s) (dry run, nothing deleted)"
  end

  test "Sessions.purge_thinking_tokens_events/1 delegates", %{ids: ids} do
    assert %{rows: 11, deleted: 0} =
             Sessions.purge_thinking_tokens_events(dry_run: true, session_ids: ids)
  end

  defp collect_lines(acc \\ []) do
    receive do
      {:line, line} -> collect_lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
