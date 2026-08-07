defmodule OrcaHubWeb.IssueLive.ShowTest do
  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Issues, Projects, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "issue_show_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "issue-show-test",
        directory: dir,
        # The real local test node, not a placeholder like "n1@x" —
        # OrcaHub.Issues.derive_commits/1 routes git through Cluster.rpc/4
        # to this node, so the close path below needs it resolvable.
        node: Atom.to_string(node()),
        key_prefix: unique_key_prefix()
      })

    {:ok, project: project, dir: dir}
  end

  defp unique_key_prefix(base \\ "SHW") do
    (base <> Integer.to_string(System.unique_integer([:positive]))) |> String.slice(0, 10)
  end

  defp init_git_repo(dir) do
    System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
  end

  defp commit_in(dir, filename, message) do
    File.write!(Path.join(dir, filename), filename)
    System.cmd("git", ["add", "."], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", message], cd: dir, stderr_to_stdout: true)
  end

  test "renders short key, kind, premise, plan, description, and notes", %{
    conn: conn,
    project: project
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Something broke",
        project_id: project.id,
        kind: "feature_request",
        description: "The pain point.",
        premise: "Assuming the API is stable.",
        plan: "Patch the adapter.",
        notes: "Saw it again today."
      })

    {:ok, _view, html} = live(conn, ~p"/issues/#{issue.id}")

    assert html =~ Issues.render_key(issue)
    assert html =~ "Something broke"
    assert html =~ "feature_request"
    assert html =~ "open"
    assert html =~ "The pain point."
    assert html =~ "Assuming the API is stable."
    assert html =~ "Patch the adapter."
    assert html =~ "Saw it again today."
  end

  test "resolves the route id by short key", %{conn: conn, project: project} do
    {:ok, issue} = Issues.create_issue(%{title: "Keyed lookup", project_id: project.id})
    key = Issues.render_key(issue)

    {:ok, _view, html} = live(conn, ~p"/issues/#{key}")

    assert html =~ "Keyed lookup"
  end

  test "omits the notes section when there are no notes", %{conn: conn, project: project} do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "No notes yet",
        project_id: project.id,
        description: "d"
      })

    {:ok, _view, html} = live(conn, ~p"/issues/#{issue.id}")

    refute html =~ "Notes</h3>"
  end

  test "redirects to the index with a flash for an unresolvable id", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/issues"}}} =
             live(conn, ~p"/issues/#{Ecto.UUID.generate()}")
  end

  test "closing an issue via the UI freezes commits and attempts, and swaps the button to Reopen",
       %{conn: conn, project: project, dir: dir} do
    init_git_repo(dir)
    {:ok, issue} = Issues.create_issue(%{title: "Fix the flaky thing", project_id: project.id})
    key = Issues.render_key(issue)

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        project_id: project.id,
        issue_id: issue.id,
        # Cluster.runner_node_for/1 treats a nil runner_node as
        # unassigned (not local) — needs an explicit, locally-resolvable
        # node for the close path's per-attempt git derivation to succeed.
        runner_node: Atom.to_string(node())
      })

    commit_in(
      dir,
      "a.txt",
      "Fix the flaky thing\n\nOrcaHub-Session: #{session.id}\nOrcaHub-Issue: #{key}"
    )

    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

    view |> element("button", "Close") |> render_click()

    html =
      view
      |> form("#close-issue-form", %{
        "outcome" => "resolved",
        "resolution" => "Landed the fix.",
        "superseded_by" => ""
      })
      |> render_submit()

    assert html =~ "closed"
    assert html =~ "Landed the fix."
    refute html =~ ">Close<"
    assert html =~ "Reopen"

    reloaded = Issues.get_issue!(issue.id)
    assert reloaded.status == "closed"
    assert reloaded.resolution == "Landed the fix."
    assert %DateTime{} = reloaded.closed_at

    assert [%{"subject" => "Fix the flaky thing"}] = reloaded.commits
    assert [%{"session_id" => attempt_session_id}] = reloaded.attempts
    assert attempt_session_id == session.id

    assert html =~ "Fix the flaky thing"
    assert html =~ String.slice(session.id, 0, 8)
  end

  test "closing as abandoned requires a resolution and rejects an empty one", %{
    conn: conn,
    project: project
  } do
    {:ok, issue} = Issues.create_issue(%{title: "Needs a reason", project_id: project.id})

    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
    view |> element("button", "Close") |> render_click()

    html =
      view
      |> form("#close-issue-form", %{
        "outcome" => "abandoned",
        "resolution" => "",
        "superseded_by" => ""
      })
      |> render_submit()

    assert html =~ "resolution"
    assert Issues.get_issue!(issue.id).status == "open"
  end

  test "reopening a closed issue preserves the frozen snapshot in notes, then clears it, and swaps the button to Close",
       %{conn: conn, project: project} do
    {:ok, issue} = Issues.create_issue(%{title: "Closed issue", project_id: project.id})

    {:ok, closed} =
      Issues.close_issue(issue, %{outcome: "resolved", resolution: "It shipped."})

    {:ok, view, _html} = live(conn, ~p"/issues/#{closed.id}")

    html = view |> element("button", "Reopen") |> render_click()

    assert html =~ "open"
    refute html =~ ">Reopen<"
    assert html =~ "Close"

    reloaded = Issues.get_issue!(closed.id)
    assert reloaded.status == "open"
    assert reloaded.resolution == nil
    assert reloaded.closed_at == nil
    assert reloaded.commits == []
    assert reloaded.attempts == []
    assert reloaded.notes =~ "reopened"
    assert reloaded.notes =~ "It shipped."
  end

  test "shows the superseded-by issue as a link once set", %{conn: conn, project: project} do
    {:ok, old_issue} = Issues.create_issue(%{title: "old approach", project_id: project.id})
    {:ok, new_issue} = Issues.create_issue(%{title: "new approach", project_id: project.id})

    {:ok, old_issue} =
      Issues.close_issue(old_issue, %{
        outcome: "abandoned",
        resolution: "superseded",
        superseded_by_issue_id: new_issue.id
      })

    {:ok, _view, html} = live(conn, ~p"/issues/#{old_issue.id}")

    assert html =~ "Superseded by"
    assert html =~ Issues.render_key(new_issue)
    assert html =~ "new approach"
  end
end
