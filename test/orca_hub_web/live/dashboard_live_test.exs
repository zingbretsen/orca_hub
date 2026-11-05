defmodule OrcaHubWeb.DashboardLiveTest do
  @moduledoc """
  The dashboard used to load every unarchived session to count statuses and
  keep 8, and reloaded all of it for ANY message on the "sessions" topic,
  which carries every agent event. It now reads grouped counts plus a
  LIMIT 8 list (`OrcaHub.Dashboard`), and reloads only on status/title
  changes, coalesced.
  """

  # async: false: the page reads whole-table counts, and this repo's tests
  # share the dev DB.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{Dashboard, Projects, Repo, Sessions}
  alias OrcaHubWeb.DashboardLive

  defp session(attrs) do
    {:ok, s} = Sessions.create_session(Map.merge(%{directory: "/tmp/dashboard_test"}, attrs))
    s
  end

  defp set_updated_at(s, updated_at),
    do: Repo.update!(Ecto.Changeset.change(s, updated_at: updated_at))

  describe "OrcaHub.Dashboard" do
    setup do
      {:ok, runner_node: "dash-test-#{System.unique_integer([:positive])}@host"}
    end

    test "session_counts/0 groups the listed sessions by runner_node and status", %{
      runner_node: rn
    } do
      for status <- ~w(idle idle running error), do: session(%{runner_node: rn, status: status})
      session(%{runner_node: rn, status: "idle", archived_at: ~U[2026-01-01 00:00:00Z]})
      session(%{runner_node: rn, status: "idle", kind: "memory_extraction"})

      {:ok, deleted} =
        Projects.create_project(%{name: "gone", directory: "/tmp/dash_gone_#{rn}"})

      {:ok, _} = Projects.delete_project(deleted)
      session(%{runner_node: rn, status: "idle", project_id: deleted.id})

      mine =
        for {^rn, status, count} <- Dashboard.session_counts(), into: %{}, do: {status, count}

      assert mine == %{"idle" => 2, "running" => 1, "error" => 1}
    end

    test "recent_sessions/2 returns the newest listed sessions, bounded, with the node filter",
         %{runner_node: rn} do
      sessions =
        for k <- 1..10 do
          session(%{runner_node: rn, title: "recent-#{k}"})
          |> set_updated_at(NaiveDateTime.add(~N[2099-01-01 00:00:00], k))
        end

      session(%{runner_node: rn, archived_at: ~U[2026-01-01 00:00:00Z]})
      |> set_updated_at(~N[2099-02-01 00:00:00])

      recent = Dashboard.recent_sessions(8, [rn])

      assert Enum.map(recent, & &1.title) ==
               sessions |> Enum.reverse() |> Enum.take(8) |> Enum.map(& &1.title)

      refute match?(%Ecto.Association.NotLoaded{}, hd(recent).project)
      assert length(Dashboard.recent_sessions(3, :all)) == 3
      assert Dashboard.recent_sessions(8, []) == []
    end
  end

  describe "session_summary/3" do
    test "keeps only the nodes the filter selects and sums per display name" do
      counts = [
        {"a@h1", "running", 2},
        {"a@h1", "idle", 3},
        {"b@h2", "error", 1},
        {"c@h2", "idle", 4},
        {nil, "idle", 5}
      ]

      names = %{"a@h1" => "one", "b@h2" => "two", "c@h2" => "two", nil => "nil"}

      assert DashboardLive.session_summary(counts, names, :all) == %{
               running: 2,
               idle: 12,
               error: 1,
               total: 15,
               per_node: [{"nil", 5}, {"one", 5}, {"two", 5}]
             }

      assert DashboardLive.session_summary(counts, names, MapSet.new(["two"])) == %{
               running: 0,
               idle: 4,
               error: 1,
               total: 5,
               per_node: [{"two", 5}]
             }
    end
  end

  describe "page" do
    test "shows the same counts the full session list gives, and the newest sessions", %{
      conn: conn
    } do
      newest =
        session(%{runner_node: Atom.to_string(node()), title: "dash-newest", status: "running"})
        |> set_updated_at(~N[2099-12-31 00:00:00])

      all = Sessions.list_sessions(:all)
      running = Enum.count(all, &(&1.status == "running"))

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ newest.title
      assert html =~ "#{running} running"
      assert html =~ ~s(<div class="text-2xl font-bold">#{length(all)}</div>)
    end

    test "agent events run no query; a burst of status changes reloads once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      test_pid = self()
      lv_pid = view.pid
      handler_id = "dashboard-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:orca_hub, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == lv_pid, do: send(test_pid, {:lv_query, metadata[:source]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      id = Ecto.UUID.generate()
      for _ <- 1..20, do: send(view.pid, {id, {:event, %{"type" => "assistant"}}})
      for _ <- 1..3, do: send(view.pid, {id, {:progress, "phase", "note"}})
      render(view)
      refute_received {:lv_query, _}

      newest =
        session(%{runner_node: Atom.to_string(node()), title: "dash-arrived"})
        |> set_updated_at(~N[2099-12-31 00:00:00])

      for _ <- 1..5, do: send(view.pid, {newest.id, {:status, :idle}})
      send(view.pid, {newest.id, {:title_updated, "dash-arrived"}})
      refute render(view) =~ "dash-arrived"

      Process.sleep(700)
      assert render(view) =~ "dash-arrived"

      # One grouped count query and one LIMIT 8 query (its project preload
      # rides the same join).
      assert_received {:lv_query, "sessions"}
      assert_received {:lv_query, "sessions"}
      refute_received {:lv_query, _}
    end
  end
end
