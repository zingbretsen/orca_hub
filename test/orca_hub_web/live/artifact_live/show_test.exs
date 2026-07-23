defmodule OrcaHubWeb.ArtifactLive.ShowTest do
  @moduledoc """
  Coverage for the fullscreen artifact viewer at `/artifacts/:id`: renders
  the sandboxed iframe, the viewport-width toggle, live-reloads on
  `{:artifact_updated, ...}`, and (Artifacts Phase 3) the orca.send bridge
  delivering artifact interactions to the artifact's creator session.
  """

  # async: false — the orca.send describe block below starts a real
  # SessionRunner under the shared OrcaHub.SessionSupervisor (see
  # SessionLive.ArtifactTest for the same pattern).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{Artifacts, Projects, SessionSupervisor, Sessions}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "artifact_live_show_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "artifact-live-show-test", directory: dir, node: "n1@x"})

    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: "fullscreen-me",
        kind: "html",
        content: "<p>hi</p>"
      })

    {:ok, project: project, artifact: artifact}
  end

  test "renders the sandboxed iframe pointed at the raw url", %{conn: conn, artifact: artifact} do
    {:ok, _view, html} = live(conn, ~p"/artifacts/#{artifact.id}")

    assert html =~ "/artifacts/#{artifact.id}/raw?v=#{artifact.version}"
    assert html =~ ~s(sandbox="allow-scripts")
    refute html =~ "allow-same-origin"
    assert html =~ artifact.name
  end

  test "redirects to /projects with a flash for an unknown id", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(conn, ~p"/artifacts/#{Ecto.UUID.generate()}")
  end

  test "set_viewport constrains the iframe width", %{conn: conn, artifact: artifact} do
    {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

    html = render_click(view, "set_viewport", %{"viewport" => "mobile"})
    assert html =~ "width: 375px"

    html = render_click(view, "set_viewport", %{"viewport" => "full"})
    assert html =~ "width: 100%;"
  end

  test "live-reloads on {:artifact_updated, ...} broadcast", %{
    conn: conn,
    project: project,
    artifact: artifact
  } do
    {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

    {:ok, updated} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: artifact.name,
        content: "<p>updated</p>"
      })

    html = render(view)
    assert html =~ "/artifacts/#{artifact.id}/raw?v=#{updated.version}"
  end

  describe "orca.send bidirectional bridge (Phase 3)" do
    @claude_stub Path.expand("../../../support/fixtures/claude_stub_noop.sh", __DIR__)

    setup %{project: project} do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      dir =
        Path.join(
          System.tmp_dir!(),
          "artifact_send_creator_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, creator} =
        Sessions.create_session(%{
          directory: dir,
          project_id: project.id,
          code_exec: false,
          runner_node: Atom.to_string(node())
        })

      on_exit(fn ->
        if SessionSupervisor.session_alive?(creator.id),
          do: SessionSupervisor.stop_session(creator.id)
      end)

      {:ok, artifact_with_creator} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          session_id: creator.id,
          name: "creator-linked",
          kind: "html",
          content: "<p>hi</p>"
        })

      {:ok, creator: creator, artifact: artifact_with_creator}
    end

    defp delivered_text(session_id) do
      [message] = Sessions.list_messages(session_id)
      get_in(message.data, ["message", "content", Access.at(0), "text"])
    end

    test "delivers to the artifact's CREATOR session, not any viewed session (there is none)", %{
      conn: conn,
      creator: creator,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

      html =
        render_hook(view, "artifact_send", %{
          "artifact_id" => artifact.id,
          "payload" => %{"choice" => "approve"}
        })

      assert html =~ "Sent to session."

      text = delivered_text(creator.id)
      assert text =~ ~s([Artifact "#{artifact.name}" interaction])
      assert text =~ "approve"
    end

    test "flashes an explanatory message when the artifact has no creator session", %{
      conn: conn,
      project: project
    } do
      {:ok, orphan} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "no-creator",
          kind: "html",
          content: "<p>hi</p>"
        })

      {:ok, view, _html} = live(conn, ~p"/artifacts/#{orphan.id}")

      html =
        render_hook(view, "artifact_send", %{
          "artifact_id" => orphan.id,
          "payload" => %{"choice" => "approve"}
        })

      assert html =~ "creator session no longer exists"
    end

    test "an oversized payload is rejected with a flash and never delivered", %{
      conn: conn,
      creator: creator,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

      big_payload = %{"blob" => String.duplicate("x", 17 * 1024)}

      html =
        render_hook(view, "artifact_send", %{
          "artifact_id" => artifact.id,
          "payload" => big_payload
        })

      assert html =~ "too large"
      assert Sessions.list_messages(creator.id) == []
    end

    test "a second send within the throttle window is dropped", %{
      conn: conn,
      creator: creator,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

      render_hook(view, "artifact_send", %{"artifact_id" => artifact.id, "payload" => %{"n" => 1}})

      html =
        render_hook(view, "artifact_send", %{
          "artifact_id" => artifact.id,
          "payload" => %{"n" => 2}
        })

      assert html =~ "too fast"
      assert length(Sessions.list_messages(creator.id)) == 1
      assert delivered_text(creator.id) =~ ~s("n": 1)
    end
  end
end
