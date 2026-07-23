defmodule OrcaHubWeb.SessionLive.ArtifactTest do
  @moduledoc """
  Coverage for the session split-panel artifact viewer: an
  `{:open_artifact, id, mode}` broadcast on `"session:<id>"` (the same
  pattern `open_file` uses — see `OrcaHub.MCP.Tools.Artifacts`) opens an
  artifact tab in the split panel, `mode: "full"` navigates to the
  fullscreen viewer instead, and `{:artifact_updated, ...}` live-reloads an
  open tab's iframe (via its `?v=` cache-buster).
  """

  # async: false — ensure_runner_started/3 starts a real SessionRunner
  # under the shared OrcaHub.SessionSupervisor (see show_test.exs).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{Artifacts, Projects, SessionSupervisor, Sessions}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "artifact_panel_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "artifact-panel-test", directory: dir, node: "n1@x"})

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        project_id: project.id,
        code_exec: false,
        runner_node: Atom.to_string(node())
      })

    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        session_id: session.id,
        name: "dashboard",
        kind: "html",
        content: "<p>hi</p>"
      })

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id),
        do: SessionSupervisor.stop_session(session.id)
    end)

    {:ok, session: session, artifact: artifact}
  end

  describe "{:open_artifact, id, \"split\"} broadcast" do
    test "opens an artifact tab with a sandboxed iframe pointed at the raw url", %{
      conn: conn,
      session: session,
      artifact: artifact
    } do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      refute html =~ "artifact-iframe-desktop-#{artifact.id}"

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:open_artifact, artifact.id, "split"}
      )

      html = render(view)
      assert html =~ "artifact-iframe-desktop-#{artifact.id}"
      assert html =~ "/artifacts/#{artifact.id}/raw?v=#{artifact.version}"
      assert html =~ ~s(sandbox="allow-scripts")
      refute html =~ "allow-same-origin"
      assert html =~ artifact.name
    end

    test "reopening the same artifact reuses the existing tab (doesn't duplicate it)", %{
      conn: conn,
      session: session,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:open_artifact, artifact.id, "split"}
      )

      render(view)

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:open_artifact, artifact.id, "split"}
      )

      html = render(view)

      # One tab-strip button per open tab, per (desktop/mobile) rendering —
      # exactly 2 (not 4) confirms the second broadcast switched to the
      # already-open tab instead of appending a duplicate.
      tab_buttons =
        html
        |> Floki.parse_document!()
        |> Floki.find("button[phx-value-path='artifact:#{artifact.id}']")

      assert length(tab_buttons) == 2
    end

    test "closing the tab removes the iframe", %{
      conn: conn,
      session: session,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:open_artifact, artifact.id, "split"}
      )

      render(view)

      html = render_click(view, "close_tab", %{"path" => "artifact:#{artifact.id}"})

      refute html =~ "artifact-iframe-desktop-#{artifact.id}"
    end
  end

  describe "{:open_artifact, id, \"full\"} broadcast" do
    test "navigates to the fullscreen artifact viewer", %{
      conn: conn,
      session: session,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:open_artifact, artifact.id, "full"}
      )

      assert_redirect(view, ~p"/artifacts/#{artifact.id}")
    end
  end

  describe "{:artifact_updated, artifact} broadcast" do
    test "live-reloads an open tab's iframe src (version bump busts the cache)", %{
      conn: conn,
      session: session,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:open_artifact, artifact.id, "split"}
      )

      render(view)

      {:ok, updated} =
        Artifacts.save_artifact(%{
          project_id: artifact.project_id,
          name: artifact.name,
          content: "<p>updated</p>"
        })

      assert updated.version == artifact.version + 1

      html = render(view)
      assert html =~ "/artifacts/#{artifact.id}/raw?v=#{updated.version}"
      refute html =~ "/artifacts/#{artifact.id}/raw?v=#{artifact.version}\""
    end
  end
end
