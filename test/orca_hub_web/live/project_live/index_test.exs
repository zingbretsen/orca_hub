defmodule OrcaHubWeb.ProjectLive.IndexTest do
  @moduledoc "Projects index grouped by node."
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Projects

  setup do
    tag = System.unique_integer([:positive])
    local = Atom.to_string(node())
    offline = "ghost#{tag}@offline-host-#{tag}.invalid"

    mk = fn name, n ->
      dir = Path.join(System.tmp_dir!(), "proj_idx_#{tag}_#{name}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, p} = Projects.create_project(%{name: "#{name}-#{tag}", directory: dir, node: n})
      p
    end

    %{
      tag: tag,
      offline: offline,
      local_p: mk.("alpha", local),
      off_p1: mk.("bravo", offline),
      off_p2: mk.("charlie", offline)
    }
  end

  defp group_ids(html) do
    Regex.scan(~r/<details[^>]*id="(group-node-[^"]+)"/, html) |> Enum.map(&List.last/1)
  end

  test "renders one group per node, local node first, offline badge on unreachable",
       %{conn: conn, offline: offline} do
    {:ok, view, html} = live(conn, ~p"/projects")

    ids = group_ids(html)
    local_key = "group-node-" <> Base.url_encode64(Atom.to_string(node()), padding: false)
    off_key = "group-node-" <> Base.url_encode64(offline, padding: false)

    assert local_key in ids
    assert off_key in ids
    assert Enum.find_index(ids, &(&1 == local_key)) == 0

    off_html = view |> element("##{off_key}") |> render()
    assert off_html =~ "offline-host-"
    assert off_html =~ "offline"
    assert off_html =~ "bravo-"
    assert off_html =~ "charlie-"
    refute off_html =~ "alpha-"

    local_html = view |> element("##{local_key}") |> render()
    assert local_html =~ "alpha-"
    refute local_html =~ "bravo-"
    refute local_html =~ ">offline<"
  end

  test "Select All spans groups and Delete Selected removes them",
       %{conn: conn, local_p: a, off_p1: b, off_p2: c} do
    {:ok, view, _} = live(conn, ~p"/projects")

    html = view |> element("button", "Select All") |> render_click()
    assert html =~ "selected"

    view |> element("button", "Delete Selected") |> render_click()

    for p <- [a, b, c], do: refute(render(view) =~ p.name)
    for p <- [a, b, c], do: assert(Projects.get_project(p.id).deleted_at != nil)
  end
end
