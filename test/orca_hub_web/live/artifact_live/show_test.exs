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

  # ORCAHUB3-128: the iframe loads the token-scoped /api route, never the
  # Authelia-gated /artifacts/:id/raw — the opaque-origin iframe's own asset
  # requests can't carry the Authelia cookie.
  test "renders the sandboxed iframe pointed at the token-scoped raw url", %{
    conn: conn,
    artifact: artifact
  } do
    {:ok, view, html} = live(conn, ~p"/artifacts/#{artifact.id}")

    assert {:ok, artifact.id} == view |> iframe_src() |> src_token(artifact.version)
    refute html =~ "/artifacts/#{artifact.id}/raw"
    assert html =~ ~s(sandbox="allow-scripts")
    refute html =~ "allow-same-origin"
    assert html =~ artifact.name
  end

  test "renders a download link pointed at the download route", %{conn: conn, artifact: artifact} do
    {:ok, _view, html} = live(conn, ~p"/artifacts/#{artifact.id}")

    assert html =~ ~s(href="/artifacts/#{artifact.id}/download")
    assert html =~ "Download"
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

    assert {:ok, artifact.id} == view |> iframe_src() |> src_token(updated.version)
  end

  # The src is an assign minted on a version bump, not recomputed per
  # render: a re-mint after the token's hour bucket rolls over would change
  # it and reload the iframe. Changing max_age changes what a fresh mint
  # produces (it's embedded in the token), which makes a re-mint visible.
  test "the iframe src is re-minted only on a version bump", %{
    conn: conn,
    project: project,
    artifact: artifact
  } do
    {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")
    original = iframe_src(view)

    Application.put_env(:orca_hub, :artifact_url_max_age_seconds, 7200)
    on_exit(fn -> Application.delete_env(:orca_hub, :artifact_url_max_age_seconds) end)
    refute OrcaHubWeb.ArtifactURL.raw_path(artifact) == original

    send(view.pid, {:artifact_updated, artifact})
    send(view.pid, {:artifact_data_updated, artifact})
    assert iframe_src(view) == original

    {:ok, updated} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        name: artifact.name,
        content: "<p>updated</p>"
      })

    src = iframe_src(view)
    refute src == original
    assert src == OrcaHubWeb.ArtifactURL.raw_path(updated)
  end

  defp iframe_src(view) do
    [_, src] =
      Regex.run(~r/src="([^"]+)"/, view |> element("#artifact-fullscreen-frame") |> render())

    src
  end

  defp src_token(src, version) do
    [_, token] = Regex.run(~r{\A/api/artifacts/view/([^/]+)/raw\?v=#{version}\z}, src)
    OrcaHubWeb.ArtifactURL.verify(token)
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

  describe "user-state persistence (orca.setState/[data-orca-persist])" do
    test "an \"artifact_state\" hook event for the viewed artifact is merged into _user_state", %{
      conn: conn,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

      render_hook(view, "artifact_state", %{
        "artifact_id" => artifact.id,
        "patch" => %{"done" => true}
      })

      assert Artifacts.get_artifact(artifact.id).data["_user_state"] == %{"done" => true}
    end

    test "is ignored for a different artifact_id than the one being viewed", %{
      conn: conn,
      project: project,
      artifact: artifact
    } do
      {:ok, other} =
        Artifacts.save_artifact(%{project_id: project.id, name: "other", content: "<p>x</p>"})

      {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

      render_hook(view, "artifact_state", %{
        "artifact_id" => other.id,
        "patch" => %{"done" => true}
      })

      assert Artifacts.get_artifact(other.id).data == %{}
    end

    test "an oversized patch is dropped with a flash and never persisted", %{
      conn: conn,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

      big_patch = %{"blob" => String.duplicate("x", 17 * 1024)}

      html =
        render_hook(view, "artifact_state", %{
          "artifact_id" => artifact.id,
          "patch" => big_patch
        })

      assert html =~ "too large"
      assert Artifacts.get_artifact(artifact.id).data == %{}
    end
  end

  test "the Edit in session button renders on /artifacts/:id", %{conn: conn, artifact: artifact} do
    {:ok, _view, html} = live(conn, ~p"/artifacts/#{artifact.id}")

    assert html =~ "Edit in session"
    assert html =~ ~s(phx-click="open_edit_session")
  end

  test "submitting a blank instruction does not create a session and shows an error flash", %{
    conn: conn,
    project: project,
    artifact: artifact
  } do
    {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

    render_click(view, "open_edit_session")
    html = render_submit(view, "start_edit_session", %{"instruction" => "   "})

    assert html =~ "Describe what you want changed."

    assert Sessions.list_sessions(:all) |> Enum.filter(&(&1.project_id == project.id)) == []
  end

  describe "start_edit_session with a real instruction" do
    @claude_stub Path.expand("../../../support/fixtures/claude_stub_noop.sh", __DIR__)

    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      dir =
        Path.join(
          System.tmp_dir!(),
          "artifact_edit_session_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      # No `node:` — falls back to the local node via `Cluster.project_node_for/1`,
      # which `Cluster.node_available?/1` reports as available.
      {:ok, project} =
        Projects.create_project(%{name: "artifact-edit-session-test", directory: dir})

      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "edit-me",
          kind: "html",
          content: "<p>hi</p>"
        })

      {:ok, project: project, artifact: artifact}
    end

    test "creates exactly one new session and redirects to it", %{
      conn: conn,
      project: project,
      artifact: artifact
    } do
      {:ok, view, _html} = live(conn, ~p"/artifacts/#{artifact.id}")

      render_click(view, "open_edit_session")

      {:error, {:live_redirect, %{to: to}}} =
        render_submit(view, "start_edit_session", %{"instruction" => "add a total row"})

      # `project` is freshly created per-test, so scoping to its id (rather
      # than diffing all sessions) is exact even under sibling test/session
      # activity on the shared dev DB.
      project_sessions =
        :all
        |> Sessions.list_sessions()
        |> Enum.filter(&(&1.project_id == project.id))

      assert [session] = project_sessions
      assert session.project_id == project.id
      assert session.directory == project.directory
      assert to == "/sessions/#{session.id}"

      on_exit(fn ->
        if SessionSupervisor.session_alive?(session.id),
          do: SessionSupervisor.stop_session(session.id)
      end)
    end
  end
end
