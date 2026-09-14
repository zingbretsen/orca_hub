defmodule OrcaHubWeb.SessionLive.IndexBackgroundTest do
  @moduledoc """
  Coverage for `/sessions`' "Show background sessions" toggle — a
  `kind == "memory_extraction"` session (see `OrcaHub.MemoryExtraction`) is
  hidden from the index by default and only appears once the toggle is on,
  same UX shape as the archived-sessions toggle elsewhere in the app.
  """

  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "orca-idx-bg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "Background Toggle", directory: dir})

    {:ok, ordinary} =
      Sessions.create_session(%{directory: dir, project_id: project.id, title: "Ordinary One"})

    {:ok, background} =
      Sessions.create_session(%{
        directory: dir,
        project_id: project.id,
        title: "Memory extraction: Ordinary One",
        kind: "memory_extraction",
        parent_session_id: ordinary.id
      })

    %{ordinary: ordinary, background: background}
  end

  test "hides a memory_extraction session by default", %{
    conn: conn,
    ordinary: ordinary,
    background: background
  } do
    {:ok, _view, html} = live(conn, ~p"/sessions")

    assert html =~ ordinary.title
    refute html =~ background.title
  end

  test "show_background_init (client hydration) reveals it", %{
    conn: conn,
    background: background
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions")

    html = render_hook(view, "show_background_init", %{"enabled" => true})
    assert html =~ background.title
  end

  test "toggling the checkbox reveals it, and toggling again hides it", %{
    conn: conn,
    background: background
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions")

    html =
      view
      |> element("input[phx-click=toggle_show_background]")
      |> render_click()

    assert html =~ background.title

    html =
      view
      |> element("input[phx-click=toggle_show_background]")
      |> render_click()

    refute html =~ background.title
  end
end
