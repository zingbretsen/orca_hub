defmodule OrcaHubWeb.ProjectLive.ShowTest do
  @moduledoc """
  Regression for the same node-availability bug as
  SessionLive.ShowTest's "incident regression" describe block: a project
  assigned to an offline node used to have its git_log/git_branch/
  git_worktree_list/git_branches results silently computed on the LOCAL
  node instead (via the old runner_node_for/project_node_for fallback).
  With that fallback removed for an unreachable-but-assigned node,
  Cluster.rpc/5 now returns a clean {:error, ...} tuple instead — this
  covers the mount code that must not choke on that tuple (it used to
  crash rendering `length(@branches)` / `:for={_ <- @worktrees}` etc.
  directly on the raw rpc result).
  """
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "project_show_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "offline-node-project",
        directory: dir,
        node: "debian@totally-offline-host"
      })

    {:ok, project: project}
  end

  test "mount with a project assigned to an offline node does not crash", %{
    conn: conn,
    project: project
  } do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

    assert html =~ "not currently connected"
  end

  # The picker used to run two server_in_project? queries per server on every
  # render while open; it now reads the already-loaded project server list.
  test "the MCP server picker marks added servers without a query per server", %{
    conn: conn,
    project: project
  } do
    uniq = System.unique_integer([:positive])

    # Inserted directly: create_upstream_server/1 also pokes the global
    # UpstreamClient, which has no sandbox access.
    server = fn name ->
      %OrcaHub.UpstreamServers.UpstreamServer{}
      |> OrcaHub.UpstreamServers.UpstreamServer.changeset(%{
        name: "picker-#{name}-#{uniq}",
        url: "https://#{name}-#{uniq}.example.com/mcp"
      })
      |> OrcaHub.Repo.insert!()
    end

    added = server.("added")
    other = server.("other")

    OrcaHub.UpstreamServers.add_server_to_project(project.id, added.id)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    count_view_queries(view)

    html = view |> element("button", "Add Server") |> render_click()

    assert html =~ ~r/picker-added-#{uniq}.*?already added/s
    assert has_element?(view, "button[phx-click='add_mcp_server'][phx-value-id='#{other.id}']")
    refute has_element?(view, "button[phx-click='add_mcp_server'][phx-value-id='#{added.id}']")
    assert drain_lv_queries() == 0
  end

  # Counts the queries the LiveView process itself runs (async: true, so
  # other tests' queries run in other processes and are ignored).
  defp count_view_queries(view) do
    test_pid = self()
    lv_pid = view.pid
    handler_id = "project-show-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:orca_hub, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == lv_pid, do: send(test_pid, :lv_query)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp drain_lv_queries(count \\ 0) do
    receive do
      :lv_query -> drain_lv_queries(count + 1)
    after
      0 -> count
    end
  end

  describe "sessions table" do
    defp project_session(project, title, attrs \\ %{}) do
      {:ok, session} =
        Sessions.create_session(
          Map.merge(%{directory: project.directory, project_id: project.id, title: title}, attrs)
        )

      session
    end

    test "lists live sessions, and archived ones only while the toggle is on", %{
      conn: conn,
      project: project
    } do
      project_session(project, "live-session")
      project_session(project, "archived-session", %{archived_at: ~U[2026-01-01 00:00:00Z]})

      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ "live-session"
      refute html =~ "archived-session"

      html = view |> element("input[phx-click='toggle_archived_sessions']") |> render_click()
      assert html =~ "archived-session"
      assert html =~ "live-session"

      html = view |> element("input[phx-click='toggle_archived_sessions']") |> render_click()
      refute html =~ "archived-session"
      assert html =~ "live-session"
    end

    test "agent events run no query; a burst of status changes reloads the list once", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
      count_view_queries(view)

      # Every agent event is also broadcast on "sessions"; this page used to
      # reload the whole project (every session, archived included) per event.
      for _ <- 1..20,
          do: send(view.pid, {Ecto.UUID.generate(), {:event, %{"type" => "assistant"}}})

      render(view)
      assert drain_lv_queries() == 0

      new_session = project_session(project, "arrived-later")

      for _ <- 1..5, do: send(view.pid, {new_session.id, {:status, :idle}})
      render(view)
      refute render(view) =~ "arrived-later"

      Process.sleep(700)
      assert render(view) =~ "arrived-later"
      assert drain_lv_queries() == 1
    end
  end
end
