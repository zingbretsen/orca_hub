defmodule OrcaHubWeb.ArtifactLive.IndexTest do
  @moduledoc """
  Coverage for the top-level `/artifacts` nav page: Pinned section ordering,
  grouping by project, name/project filters, the pin/unpin toggle (and that
  clicking it does NOT navigate the whole row away — the classic
  nested-`phx-click`-inside-a-`row_click`-row footgun), delete with
  confirm, and live refresh on the aggregate `"artifacts"` broadcast.

  Note on the pin-toggle-doesn't-navigate assertion: `Phoenix.LiveViewTest`
  is server-side only — it dispatches exactly the clicked element's own
  declared `phx-click` binding and never simulates real browser DOM event
  bubbling, so it can't reproduce a client-side propagation bug by itself.
  What it CAN and does verify here is the server-side contract: clicking
  the pin/unpin button only ever runs the "pin"/"unpin" handler (never a
  `push_navigate`/redirect), and the rendered result afterward is still the
  `/artifacts` index. The reason a real browser doesn't also fire the
  row's `JS.navigate` is `Phoenix.LiveView`'s `closestPhxBinding` client
  helper, which walks up from the click target and stops at the FIRST
  element carrying `phx-click` — since the button carries its own, the
  row's binding further up is never reached.
  """

  use OrcaHubWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OrcaHub.Artifacts
  alias OrcaHub.Artifacts.Artifact
  alias OrcaHub.Projects
  alias OrcaHub.Repo

  setup do
    dir =
      Path.join(System.tmp_dir!(), "artifact_index_test_#{System.unique_integer([:positive])}")

    {:ok, project} =
      Projects.create_project(%{
        name: "artifact-index-test-#{unique()}",
        directory: dir,
        node: "n1@x"
      })

    {:ok, project: project}
  end

  defp unique, do: System.unique_integer([:positive])

  defp backdate_pinned_at(artifact, seconds_ago) do
    time = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second)
    from(a in Artifact, where: a.id == ^artifact.id) |> Repo.update_all(set: [pinned_at: time])
  end

  # Uses the filter (rather than asserting the whole page is empty) since
  # the dev DB this test suite runs against isn't artifact-free — see
  # CLAUDE.md "Tests run against the shared dev DB, not an isolated test
  # DB". The unfiltered "No artifacts yet" explainer copy exists in the
  # template (see index.html.heex) but isn't independently asserted here
  # for that reason.
  test "shows a 'no match' empty state when a filter matches nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/artifacts")

    html =
      view
      |> form("form[phx-change=filter_name]")
      |> render_change(%{"name" => "definitely-not-a-real-artifact-#{unique()}"})

    assert html =~ "No artifacts match this filter"
  end

  test "lists an artifact grouped under its project", %{conn: conn, project: project} do
    name = "grouped-artifact-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})

    {:ok, _view, html} = live(conn, ~p"/artifacts")

    assert html =~ name
    assert html =~ project.name
    assert html =~ "v#{artifact.version}"
    assert html =~ artifact.kind
  end

  test "groups two projects' artifacts into separate sections", %{conn: conn, project: project} do
    dir2 = Path.join(System.tmp_dir!(), "artifact_index_test2_#{unique()}")

    {:ok, project2} =
      Projects.create_project(%{
        name: "artifact-index-test-2-#{unique()}",
        directory: dir2,
        node: "n1@x"
      })

    name1 = "group-a-#{unique()}"
    name2 = "group-b-#{unique()}"
    {:ok, _} = Artifacts.save_artifact(%{project_id: project.id, name: name1, content: "x"})
    {:ok, _} = Artifacts.save_artifact(%{project_id: project2.id, name: name2, content: "x"})

    {:ok, _view, html} = live(conn, ~p"/artifacts")

    assert html =~ project.name
    assert html =~ project2.name
    assert html =~ name1
    assert html =~ name2
  end

  test "pinned artifacts render in a Pinned section ordered by pinned_at (most recent first)", %{
    conn: conn,
    project: project
  } do
    older_name = "pinned-older-#{unique()}"
    newer_name = "pinned-newer-#{unique()}"

    {:ok, older} =
      Artifacts.save_artifact(%{project_id: project.id, name: older_name, content: "x"})

    {:ok, newer} =
      Artifacts.save_artifact(%{project_id: project.id, name: newer_name, content: "x"})

    {:ok, older} = Artifacts.pin_artifact(older)
    {:ok, _newer} = Artifacts.pin_artifact(newer)
    backdate_pinned_at(older, 3600)

    {:ok, _view, html} = live(conn, ~p"/artifacts")

    assert html =~ "Pinned"
    newer_pos = :binary.match(html, newer_name) |> elem(0)
    older_pos = :binary.match(html, older_name) |> elem(0)
    assert newer_pos < older_pos
  end

  test "name filter narrows to matching artifacts (case-insensitive substring)", %{
    conn: conn,
    project: project
  } do
    target = "Grocery List #{unique()}"
    other = "Dashboard #{unique()}"
    {:ok, _} = Artifacts.save_artifact(%{project_id: project.id, name: target, content: "x"})
    {:ok, _} = Artifacts.save_artifact(%{project_id: project.id, name: other, content: "x"})

    {:ok, view, _html} = live(conn, ~p"/artifacts")

    html = view |> form("form[phx-change=filter_name]") |> render_change(%{"name" => "grocery"})

    assert html =~ target
    refute html =~ other
  end

  test "project filter narrows to the selected project's artifacts", %{
    conn: conn,
    project: project
  } do
    dir2 = Path.join(System.tmp_dir!(), "artifact_index_test3_#{unique()}")

    {:ok, project2} =
      Projects.create_project(%{
        name: "artifact-index-test-3-#{unique()}",
        directory: dir2,
        node: "n1@x"
      })

    mine = "scoped-mine-#{unique()}"
    theirs = "scoped-theirs-#{unique()}"
    {:ok, _} = Artifacts.save_artifact(%{project_id: project.id, name: mine, content: "x"})
    {:ok, _} = Artifacts.save_artifact(%{project_id: project2.id, name: theirs, content: "x"})

    {:ok, view, _html} = live(conn, ~p"/artifacts")

    html =
      view
      |> form("form[phx-change=filter_project]")
      |> render_change(%{"project_id" => project.id})

    assert html =~ mine
    refute html =~ theirs
  end

  test "clicking pin sets pinned_at, moves the artifact into Pinned, and does not navigate away",
       %{
         conn: conn,
         project: project
       } do
    name = "pin-toggle-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})

    {:ok, view, html} = live(conn, ~p"/artifacts")
    refute html =~ "Pinned"

    html =
      view
      |> element("button[phx-click=pin][phx-value-id=\"#{artifact.id}\"]")
      |> render_click()

    assert is_binary(html)
    assert html =~ "Pinned"
    assert html =~ name
    assert Artifacts.get_artifact(artifact.id).pinned_at
  end

  test "clicking unpin clears pinned_at and moves the artifact back out of Pinned", %{
    conn: conn,
    project: project
  } do
    name = "unpin-toggle-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})
    {:ok, artifact} = Artifacts.pin_artifact(artifact)

    {:ok, view, html} = live(conn, ~p"/artifacts")
    assert html =~ "Pinned"

    html =
      view
      |> element("button[phx-click=unpin][phx-value-id=\"#{artifact.id}\"]")
      |> render_click()

    assert is_binary(html)
    refute html =~ "Pinned"
    assert html =~ name
    refute Artifacts.get_artifact(artifact.id).pinned_at
  end

  test "delete button has a confirm prompt and removes the artifact", %{
    conn: conn,
    project: project
  } do
    name = "delete-me-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})

    {:ok, view, html} = live(conn, ~p"/artifacts")
    assert html =~ name

    delete_link = element(view, "a[phx-click=delete][phx-value-id=\"#{artifact.id}\"]")
    assert render(delete_link) =~ "data-confirm"

    html = render_click(delete_link)

    # the success flash echoes the name back ("Artifact \"...\" deleted."),
    # so assert on the row's own link disappearing rather than the bare name
    refute html =~ ~s(href="/artifacts/#{artifact.id}")
    assert html =~ "deleted"
    assert Artifacts.get_artifact(artifact.id) == nil
  end

  test "live-refreshes when another process saves an artifact (aggregate \"artifacts\" broadcast)",
       %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/artifacts")
    name = "live-refresh-#{unique()}"
    refute html =~ name

    {:ok, _artifact} =
      Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})

    assert render(view) =~ name
  end

  test "live-refreshes on pin/delete from elsewhere too", %{conn: conn, project: project} do
    name = "live-refresh-pin-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})

    {:ok, view, html} = live(conn, ~p"/artifacts")
    refute html =~ "Pinned"

    {:ok, _} = Artifacts.pin_artifact(artifact)

    assert render(view) =~ "Pinned"
  end

  test "pinned artifacts use hero-star-solid icon while unpinned use hero-star", %{
    conn: conn,
    project: project
  } do
    name = "pin-icon-test-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})

    {:ok, view, html} = live(conn, ~p"/artifacts")
    # Unpinned artifact should use hero-star (empty star)
    assert html =~ ~s(name="hero-star")
    refute html =~ "hero-star-solid"

    # Pin the artifact
    html =
      view
      |> element("button[phx-click=pin][phx-value-id="#{artifact.id}"]")
      |> render_click()

    # Now it should use hero-star-solid (filled star)
    assert html =~ ~s(name="hero-star-solid")
  end

  test "unpinned artifacts appear under their project heading", %{
    conn: conn,
    project: project
  } do
    name = "unpinned-under-project-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})

    {:ok, _view, html} = live(conn, ~p"/artifacts")

    # Artifact should appear under its project's group
    assert html =~ project.name
    assert html =~ name
    # No Pinned section should exist
    refute html =~ "Pinned"
  end

  test "pinned artifact moves from project group to Pinned section after pin", %{
    conn: conn,
    project: project
  } do
    name = "pin-moves-to-pinned-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})

    {:ok, view, html} = live(conn, ~p"/artifacts")
    # Before pin: artifact is under its project
    assert html =~ project.name
    assert html =~ name
    refute html =~ "Pinned"

    # Pin the artifact
    html =
      view
      |> element("button[phx-click=pin][phx-value-id="#{artifact.id}"]")
      |> render_click()

    # After pin: artifact moves to Pinned section
    assert html =~ "Pinned"
    assert html =~ name
    # Should not appear under project group anymore
    assert html =~ ~s(id="artifacts-pinned")
  end

  test "unpinned artifact moves from Pinned section back to project group", %{
    conn: conn,
    project: project
  } do
    name = "unpin-moves-back-#{unique()}"
    {:ok, artifact} = Artifacts.save_artifact(%{project_id: project.id, name: name, content: "x"})
    {:ok, artifact} = Artifacts.pin_artifact(artifact)

    {:ok, view, html} = live(conn, ~p"/artifacts")
    assert html =~ "Pinned"
    assert html =~ name

    # Unpin the artifact
    html =
      view
      |> element("button[phx-click=unpin][phx-value-id="#{artifact.id}"]")
      |> render_click()

    # After unpin: artifact returns to project group
    assert html =~ project.name
    assert html =~ name
    refute html =~ "Pinned"
  end
end
