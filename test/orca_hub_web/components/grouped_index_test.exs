defmodule OrcaHubWeb.GroupedIndexTest do
  @moduledoc """
  Renderer tests for `OrcaHubWeb.GroupedIndex`. Two of these are direct
  regression tests for defects that would otherwise ship invisibly: column
  labels being dropped when forwarded to `<.table>`, and a caller-supplied
  column `class` landing on a nested `<span>` instead of the actual table
  cell (which silently defeats any width class like `w-2/5`).

  Slots can't be built by hand as plain maps and fed to `render_component/2`
  — `render_slot/2` expects each entry's `:inner_block` to be a compiled
  HEEx closure, which only exists when the slot is written with `<:col>`
  syntax. So every test renders `GroupedIndex.grouped_index/1` through a
  small `~H` wrapper component that owns the real slots.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component

  alias OrcaHubWeb.GroupedIndex

  defp render_two_col(assigns) do
    assigns = Map.put_new(assigns, :pinned, [])

    render_component(
      fn assigns ->
        ~H"""
        <GroupedIndex.grouped_index id={@id} groups={@groups} pinned={@pinned}>
          <:col :let={row} label="Title" class="w-2/5">{row.title}</:col>
          <:col :let={row} label="Status">{row.status}</:col>
        </GroupedIndex.grouped_index>
        """
      end,
      assigns
    )
  end

  test "renders two groups as two tables, with column labels present" do
    html =
      render_two_col(%{
        id: "sessions",
        groups: [
          %{key: "running", label: "Running", rows: [%{title: "Session 1", status: "running"}]},
          %{key: "idle", label: "Idle", rows: [%{title: "Session 2", status: "idle"}]}
        ]
      })

    assert html =~ ~s(id="sessions-running")
    assert html =~ ~s(id="sessions-idle")
    assert html =~ "Running"
    assert html =~ "Idle"
    assert html =~ "Session 1"
    assert html =~ "Session 2"

    # Regression for defect 1: labels must reach <.table>'s <th>, not be dropped.
    assert html =~ ~r{<th[^>]*>\s*Title\s*</th>}
    assert html =~ ~r{<th[^>]*>\s*Status\s*</th>}
  end

  test "a caller-supplied :col class lands on the table cell, not a nested span" do
    html =
      render_two_col(%{
        id: "sessions",
        groups: [
          %{key: "running", label: "Running", rows: [%{title: "Session 1", status: "running"}]}
        ]
      })

    # Regression for defect 2: `w-2/5` must be a <th>/<td> class attribute,
    # never wrapped around the cell content in a <span class="w-2/5">.
    assert html =~ ~s(class="w-2/5")
    refute html =~ ~s(<span class="w-2/5")
  end

  test "a group with neither :badges nor :navigate renders without raising" do
    html =
      render_two_col(%{
        id: "sessions",
        groups: [
          %{key: "plain", label: "Plain Group", rows: [%{title: "Session 1", status: "idle"}]}
        ]
      })

    assert html =~ "Plain Group"
  end

  test "pinned section appears only when pinned rows are given, sharing column labels" do
    with_pinned =
      render_two_col(%{
        id: "artifacts",
        pinned: [%{title: "Pinned Item", status: "pinned"}],
        groups: [
          %{key: "other", label: "Other", rows: [%{title: "Other Item", status: "idle"}]}
        ]
      })

    assert with_pinned =~ "Pinned"
    assert with_pinned =~ ~s(id="artifacts-pinned")
    assert with_pinned =~ "Pinned Item"
    assert with_pinned =~ ~r{<th[^>]*>\s*Title\s*</th>}

    without_pinned =
      render_two_col(%{
        id: "artifacts",
        groups: [
          %{key: "other", label: "Other", rows: [%{title: "Other Item", status: "idle"}]}
        ]
      })

    refute without_pinned =~ ~s(id="artifacts-pinned")
  end

  test ":group_actions renders and receives the group" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <GroupedIndex.grouped_index id="sessions" groups={@groups}>
            <:col :let={row} label="Title">{row.title}</:col>
            <:group_actions :let={group}>
              <span class="group-action-marker">actions-for-{group.key}</span>
            </:group_actions>
          </GroupedIndex.grouped_index>
          """
        end,
        %{
          groups: [
            %{key: "running", label: "Running", rows: [%{title: "Session 1"}]}
          ]
        }
      )

    assert html =~ "group-action-marker"
    assert html =~ "actions-for-running"
  end

  test "empty_message shows only when both groups and pinned are empty" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <GroupedIndex.grouped_index id="sessions" groups={@groups} empty_message="Nothing here.">
            <:col :let={row} label="Title">{row.title}</:col>
          </GroupedIndex.grouped_index>
          """
        end,
        %{groups: []}
      )

    assert html =~ "Nothing here."

    non_empty =
      render_two_col(%{
        id: "sessions",
        groups: [%{key: "running", label: "Running", rows: [%{title: "Session 1", status: "x"}]}]
      })

    refute non_empty =~ "Nothing here."
  end
end
