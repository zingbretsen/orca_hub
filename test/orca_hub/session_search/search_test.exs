defmodule OrcaHub.SessionSearch.SearchTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.SessionSearch.Search
  alias OrcaHub.SessionSearchStub, as: Stub
  alias OrcaHub.Sessions

  defp session(attrs \\ %{}) do
    {:ok, s} = Sessions.create_session(Map.merge(%{directory: "/tmp/ss-test"}, attrs))
    s
  end

  test "maps opts to contract filters and drops empty ones" do
    Stub.install({:ok, %{"results" => [], "degraded" => nil}})

    assert {:ok, %{results: [], degraded: nil}} =
             Search.search("hello",
               project_id: "p1",
               directory: "/x",
               backend: "claude",
               node: "debian",
               role: "user",
               since: ~U[2026-10-01 00:00:00Z],
               until: "2026-10-05T00:00:00Z",
               limit: 5,
               include_archived: true,
               include_background: true
             )

    assert_received {:session_search_params, params}

    assert params == %{
             "query" => "hello",
             "limit" => 5,
             "snippets" => 3,
             "filters" => %{
               "project_id" => "p1",
               "directory" => "/x",
               "backend" => "claude",
               "node" => "debian",
               "role" => "user",
               "since" => "2026-10-01T00:00:00Z",
               "until" => "2026-10-05T00:00:00Z"
             }
           }
  end

  test "joins sessions, drops unknown ids, returns snippets with markers" do
    s = session(%{title: "found me"})
    ghost = Ecto.UUID.generate()

    Stub.install(
      {:ok,
       %{
         "results" => [
           Stub.result(ghost),
           Stub.result(s.id, score: 0.5),
           Stub.result("not-a-uuid")
         ],
         "degraded" => "bm25_only"
       }}
    )

    assert {:ok, %{results: [r], degraded: "bm25_only"}} = Search.search("needle")
    assert r.session.id == s.id
    assert r.session.title == "found me"
    assert r.score == 0.5
    assert r.legs == ["bm25", "knn"]
    assert [%{role: "user", text: "the \u0002needle\u0003 here"}] = r.snippets
  end

  test "falls back to hit text when there is no highlight" do
    s = session()

    hit = %{"id" => "m1", "text" => "plain text", "fields" => %{"role" => "assistant"}}
    Stub.install({:ok, %{"results" => [%{"group_id" => s.id, "score" => 1, "hits" => [hit]}]}})

    assert {:ok, %{results: [%{snippets: [%{text: "plain text", role: "assistant"}]}]}} =
             Search.search("x")
  end

  test "pushes Postgres-only filters down as group_ids instead of oversampling" do
    live = session(%{status: "idle"})
    running = session(%{status: "running"})

    archived =
      session(%{status: "idle", archived_at: DateTime.utc_now() |> DateTime.truncate(:second)})

    bg = session(%{kind: "memory_extraction", status: "idle"})
    scope = [session_ids: [live.id, running.id, archived.id, bg.id]]

    ids = [archived.id, bg.id, running.id, live.id]
    Stub.install({:ok, %{"results" => Enum.map(ids, &Stub.result/1)}})

    assert {:ok, %{results: rs}} = Search.search("x", [limit: 2] ++ scope)
    assert_received {:session_search_params, %{"limit" => 2, "filters" => %{"group_ids" => g}}}
    assert Enum.sort(g) == Enum.sort([live.id, running.id])
    assert Enum.map(rs, & &1.session.id) == [running.id, live.id]

    assert {:ok, %{results: [only]}} = Search.search("x", [limit: 2, status: "idle"] ++ scope)
    assert_received {:session_search_params, %{"filters" => %{"group_ids" => [gid]}}}
    assert gid == live.id
    assert only.session.id == live.id

    assert {:ok, %{results: [a]}} = Search.search("x", [archived_only: true] ++ scope)
    assert a.session.id == archived.id

    assert {:ok, %{results: all}} =
             Search.search("x", [include_archived: true, include_background: true] ++ scope)

    assert length(all) == 4
  end

  test "include_archived keeps archived hits and sends no oversampling" do
    archived = session(%{archived_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    Stub.install({:ok, %{"results" => [Stub.result(archived.id)]}})

    assert {:ok, %{results: [r]}} = Search.search("x", limit: 5, include_archived: true)
    assert r.session.id == archived.id
    assert_received {:session_search_params, %{"limit" => 5, "filters" => filters}}
    refute Map.has_key?(filters, "group_ids")
  end

  test "parent_session_id is pushed down" do
    parent = session()
    child = session(%{parent_session_id: parent.id})
    other = session()
    Stub.install({:ok, %{"results" => [Stub.result(child.id)]}})

    assert {:ok, %{results: [r]}} =
             Search.search("x",
               parent_session_id: parent.id,
               include_archived: true,
               session_ids: [child.id, other.id]
             )

    assert r.session.id == child.id
    assert_received {:session_search_params, %{"filters" => %{"group_ids" => [gid]}}}
    assert gid == child.id
  end

  test "no candidate session means no service call" do
    Stub.install({:ok, %{"results" => []}})
    assert {:ok, %{results: []}} = Search.search("x", session_ids: [Ecto.UUID.generate()])
    refute_received {:session_search_params, _}
  end

  test "service limit is capped at 50 (memory-service's own clamp)" do
    Stub.install({:ok, %{"results" => []}})
    Search.search("x", limit: 80, include_archived: true)
    assert_received {:session_search_params, %{"limit" => 50}}
  end

  test "blank query short-circuits without calling the service" do
    Stub.install({:ok, %{"results" => []}})
    assert {:ok, %{results: []}} = Search.search("   ")
    refute_received {:session_search_params, _}
  end

  test "errors are returned, never raised" do
    Stub.install({:error, :disabled})
    assert {:error, :disabled} = Search.search("x")
    assert Search.error_message(:disabled) =~ "not configured"

    Stub.install({:error, {:http_status, 503}})
    assert {:error, {:http_status, 503}} = Search.search("x")
    assert Search.error_message({:http_status, 503}) =~ "unavailable"

    Stub.install(fn _ -> raise "boom" end)
    assert {:error, {:exception, "boom"}} = Search.search("x")

    Stub.install({:ok, %{"nope" => 1}})
    assert {:error, {:unexpected_response, _}} = Search.search("x")
  end

  describe "highlight rendering" do
    test "highlight_html escapes everything first, then swaps markers" do
      out = Search.highlight_html("<script>alert(1)</script> \u0002hit\u0003 & <b>")
      refute out =~ "<script>"
      assert out =~ "&lt;script&gt;"
      assert out =~ "<mark>hit</mark>"
      assert out =~ "&amp;"
      assert out =~ "&lt;b&gt;"
    end

    test "highlight_plain swaps markers for the given delimiters" do
      assert Search.highlight_plain("a \u0002b\u0003 c") == "a **b** c"
      assert Search.highlight_plain("a \u0002b\u0003", {"[", "]"}) == "a [b]"
    end
  end
end
