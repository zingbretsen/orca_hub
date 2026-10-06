defmodule OrcaHubWeb.SessionLive.IndexSearchTest do
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.SessionSearchStub, as: Stub
  alias OrcaHub.Sessions

  defp search(view, q) do
    view |> form("#session-search-form", %{"q" => q}) |> render_change()
    render_async(view)
  end

  test "search renders ranked results with snippets, links and mark highlights", %{conn: conn} do
    {:ok, s} = Sessions.create_session(%{directory: "/tmp/ss-live", title: "Needle session"})
    Stub.install({:ok, %{"results" => [Stub.result(s.id)], "degraded" => nil}})

    {:ok, view, html} = live(conn, ~p"/sessions")
    assert html =~ ~s(id="session-search-form")
    refute html =~ "session-search-results"

    html = search(view, "needle")
    assert_received {:session_search_params, %{"query" => "needle"}}
    assert html =~ "Needle session"
    assert html =~ "/tmp/ss-live"
    assert html =~ "the <mark>needle</mark> here"
    refute html =~ "keyword matches only"
    assert has_element?(view, ~s(#search-result-#{s.id} a[href="/sessions/#{s.id}"]))
  end

  test "highlights are HTML-escaped before markers become <mark>", %{conn: conn} do
    {:ok, s} = Sessions.create_session(%{directory: "/tmp/ss-live", title: "xss"})

    evil = "<script>alert(1)</script> \u0002<img src=x onerror=alert(2)>\u0003"
    Stub.install({:ok, %{"results" => [Stub.result(s.id, highlight: evil)]}})

    {:ok, view, _} = live(conn, ~p"/sessions")
    html = search(view, "alert")

    refute html =~ "<script>alert(1)"
    refute html =~ "<img src=x"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "<mark>&lt;img src=x onerror=alert(2)&gt;</mark>"
  end

  test "clearing the box restores the grouped view", %{conn: conn} do
    {:ok, s} = Sessions.create_session(%{directory: "/tmp/ss-live-grp", title: "grouped one"})
    Stub.install({:ok, %{"results" => [Stub.result(s.id)]}})

    {:ok, view, _} = live(conn, ~p"/sessions")
    search(view, "needle")
    assert has_element?(view, "#session-search-results")
    refute has_element?(view, "details")

    html = search(view, "")
    refute has_element?(view, "#session-search-results")
    assert html =~ "grouped one"
  end

  test "archived sessions are searchable and show the archived badge", %{conn: conn} do
    {:ok, s} = Sessions.create_session(%{directory: "/tmp/ss-live", title: "Old archived one"})
    {:ok, s} = Sessions.archive_session(s)
    Stub.install({:ok, %{"results" => [Stub.result(s.id)]}})

    {:ok, view, _} = live(conn, ~p"/sessions")
    html = search(view, "needle")
    assert html =~ "Old archived one"
    assert has_element?(view, "#search-result-#{s.id} .badge", "archived")
  end

  test "queries shorter than 3 characters do not search", %{conn: conn} do
    Stub.install({:ok, %{"results" => []}})
    {:ok, view, _} = live(conn, ~p"/sessions")
    search(view, "ab")
    refute_received {:session_search_params, _}
    refute has_element?(view, "#session-search-results")
  end

  test "a stale result for an earlier query is dropped", %{conn: conn} do
    {:ok, s} = Sessions.create_session(%{directory: "/tmp/ss-live", title: "stale hit"})
    Stub.install({:ok, %{"results" => [Stub.result(s.id)]}})

    {:ok, view, _} = live(conn, ~p"/sessions")
    view |> form("#session-search-form", %{"q" => "first query"}) |> render_change()
    # the user clears the box before the async result lands
    view |> form("#session-search-form", %{"q" => ""}) |> render_change()
    render_async(view)

    refute has_element?(view, "#session-search-results")
    refute has_element?(view, "#search-result-#{s.id}")
  end

  test "shows a notice when results are degraded to keyword-only", %{conn: conn} do
    {:ok, s} = Sessions.create_session(%{directory: "/tmp/ss-live"})
    Stub.install({:ok, %{"results" => [Stub.result(s.id)], "degraded" => "bm25_only"}})

    {:ok, view, _} = live(conn, ~p"/sessions")
    assert search(view, "needle") =~ "keyword matches only"
  end

  test "shows a notice when the search service is unavailable", %{conn: conn} do
    Stub.install({:error, :disabled})

    {:ok, view, _} = live(conn, ~p"/sessions")
    html = search(view, "needle")
    assert html =~ "not configured"
    refute html =~ "No sessions match"
  end

  test "empty results show a no-match message", %{conn: conn} do
    Stub.install({:ok, %{"results" => []}})
    {:ok, view, _} = live(conn, ~p"/sessions")
    assert search(view, "zzz") =~ "No sessions match"
  end
end
