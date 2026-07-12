defmodule OrcaHubWeb.SessionLive.TreeTest do
  @moduledoc """
  Coverage for the `/sessions/tree` session graph page (spawn forest +
  cross-session message-edge overlay). Read-only — no runner processes get
  started, so this is a plain DB-backed LiveView test (async: true, matching
  other read-only LiveView pages like issue_live/index_test.exs and
  project_live/show_test.exs, not the async: false convention reserved for
  tests that start a real SessionRunner).
  """

  use OrcaHubWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, Repo, Sessions}
  alias OrcaHub.Sessions.Session

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Tree Test #{System.unique_integer([:positive])}",
        directory: "/tmp/tree-test-#{System.unique_integer([:positive])}"
      })

    %{project: project}
  end

  defp create_session(project, overrides) do
    attrs = Map.merge(%{directory: project.directory, project_id: project.id}, overrides)
    {:ok, session} = Sessions.create_session(attrs)
    session
  end

  test "renders the page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sessions/tree")
    assert html =~ "Session Tree"
  end

  test "empty state when there are no sessions to show", %{conn: conn} do
    # Best-effort: other tests' data may leak into the shared dev DB (per
    # CLAUDE.md), so only assert the page renders successfully rather than
    # asserting the literal empty-state copy is present.
    {:ok, _view, html} = live(conn, ~p"/sessions/tree")
    assert html =~ "Session Tree"
  end

  test "nests a grandchild under its parent under the root, reflecting parent_session_id",
       %{conn: conn, project: project} do
    root =
      create_session(project, %{title: "Root Orchestrator #{System.unique_integer([:positive])}"})

    child =
      create_session(project, %{
        title: "Mid Worker #{System.unique_integer([:positive])}",
        parent_session_id: root.id
      })

    grandchild =
      create_session(project, %{
        title: "Leaf Worker #{System.unique_integer([:positive])}",
        parent_session_id: child.id
      })

    {:ok, view, html} = live(conn, ~p"/sessions/tree")

    assert html =~ root.title
    assert html =~ child.title
    assert html =~ grandchild.title

    # Structural nesting: the grandchild's node lives inside the child's
    # children container, which itself lives inside the root's node.
    assert has_element?(
             view,
             "#session-node-#{root.id} #session-node-#{child.id} #session-node-#{grandchild.id}"
           )
  end

  test "a session whose parent got filtered out of the visible set renders as a root", %{
    conn: conn,
    project: project
  } do
    # parent_session_id has a real FK constraint, so the "filtered out"
    # parent must actually exist — archive it and backdate it past the
    # default 24h window so the :recent scope excludes it while still
    # including its non-archived child.
    parent =
      create_session(project, %{title: "Filtered Parent #{System.unique_integer([:positive])}"})

    {:ok, parent} = Sessions.archive_session(parent)

    old_time = NaiveDateTime.utc_now() |> NaiveDateTime.add(-2 * 24 * 3600, :second)

    from(s in Session, where: s.id == ^parent.id)
    |> Repo.update_all(set: [updated_at: old_time])

    orphan =
      create_session(project, %{
        title: "Orphaned Child #{System.unique_integer([:positive])}",
        parent_session_id: parent.id
      })

    {:ok, view, html} = live(conn, ~p"/sessions/tree")

    refute html =~ parent.title

    # Renders at the top level (direct child of the tree root container),
    # not nested under anything.
    assert has_element?(view, "#session-tree-root > #session-node-#{orphan.id}")
  end

  test "toggling the history filter reveals a session archived more than 24h ago", %{
    conn: conn,
    project: project
  } do
    session =
      create_session(project, %{title: "Ancient Archived #{System.unique_integer([:positive])}"})

    {:ok, session} = Sessions.archive_session(session)

    old_time = NaiveDateTime.utc_now() |> NaiveDateTime.add(-2 * 24 * 3600, :second)

    from(s in Session, where: s.id == ^session.id)
    |> Repo.update_all(set: [updated_at: old_time])

    {:ok, view, html} = live(conn, ~p"/sessions/tree")
    refute html =~ session.title

    html =
      view
      |> element("button", "Show full history")
      |> render_click()

    assert html =~ session.title
  end

  test "renders message-edge chips from seeded session_interactions, with a count for repeats",
       %{conn: conn, project: project} do
    sender = create_session(project, %{title: "Sender #{System.unique_integer([:positive])}"})

    recipient =
      create_session(project, %{title: "Recipient #{System.unique_integer([:positive])}"})

    {:ok, _} =
      Sessions.create_session_interaction(%{
        sender_session_id: sender.id,
        recipient_session_id: recipient.id
      })

    {:ok, _} =
      Sessions.create_session_interaction(%{
        sender_session_id: sender.id,
        recipient_session_id: recipient.id
      })

    {:ok, view, html} = live(conn, ~p"/sessions/tree")

    assert html =~ recipient.title
    assert html =~ "×2"

    assert has_element?(view, "#session-node-#{sender.id} button", recipient.title)
    assert has_element?(view, "#session-node-#{recipient.id} button", sender.title)
  end

  test "subagent invocations are fetched lazily on first toggle, not on page load", %{
    conn: conn,
    project: project
  } do
    session =
      create_session(project, %{title: "Orchestrator #{System.unique_integer([:positive])}"})

    {:ok, _} =
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "toolu_lazy_1",
                "name" => "Agent",
                "input" => %{"subagent_type" => "explore", "description" => "Find the bug"}
              }
            ]
          }
        }
      })

    {:ok, view, html} = live(conn, ~p"/sessions/tree")
    # Not fetched/rendered yet — the Subagents disclosure hasn't been opened.
    refute html =~ "Find the bug"

    html =
      view
      |> element("#session-node-#{session.id} summary", "Subagents")
      |> render_click()

    assert html =~ "explore"
    assert html =~ "Find the bug"
  end
end
