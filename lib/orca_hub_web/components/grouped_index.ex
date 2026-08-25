defmodule OrcaHubWeb.GroupedIndex do
  @moduledoc """
  Renders an index page's list as collapsible per-group tables, with an
  optional "Pinned" section above the groups.

  Extracted from the grouping markup in
  `lib/orca_hub_web/live/session_live/index.html.heex` (sessions grouped by
  node/project) so other index pages — artifacts, issues, terminals,
  triggers, ... — can share ONE collapsible-group + aligned-columns
  presentation instead of re-implementing the `<details>`/`<summary>`/
  `.table` combination per page.

  ## `groups` shape

  Each entry in `groups` is a plain map:

    * `:key` (required) — unique per group, used to build DOM ids
      (`"\#{id}-\#{key}"`).
    * `:label` (required) — heading text.
    * `:rows` (required) — the list handed to the group's `<.table>`; an
      empty list renders `group_empty_message` instead of a table and
      collapses the `<details>` closed.
    * `:count` (optional) — badge count; defaults to `length(rows)`.
    * `:icon` (optional) — a `hero-*` icon name; defaults to
      `"hero-code-bracket-micro"`.
    * `:navigate` (optional) — when present, the label becomes a
      `navigate` link instead of plain text.
    * `:badges` (optional) — a list of extra strings rendered as small
      outlined badges after the count.

  ## Pinning

  The component only knows which rows belong in the `pinned` section — it
  does not render a pin/unpin star itself. Callers that support pinning
  render their own star button as their FIRST `:col` slot (see
  `lib/orca_hub_web/live/artifact_live/index.html.heex` for the pattern
  this mirrors), so the same column definitions apply to both the pinned
  table and every group table.
  """

  use Phoenix.Component

  import OrcaHubWeb.CoreComponents, only: [table: 1, icon: 1]

  attr :id, :string, required: true
  attr :groups, :list, required: true
  attr :pinned, :list, default: []
  attr :row_click, :any, default: nil
  attr :row_id, :any, default: nil
  attr :table_class, :string, default: "table-fixed"
  attr :empty_message, :string, default: nil
  attr :group_empty_message, :string, default: nil

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
  end

  slot :action
  slot :group_actions

  def grouped_index(assigns) do
    ~H"""
    <div>
      <div :if={@pinned != []} class="mt-6">
        <h3 class="text-sm font-semibold text-base-content/70 flex items-center gap-2 mb-2">
          <.icon name="hero-star-solid" class="size-4 text-warning" /> Pinned
        </h3>
        <.table
          id={"#{@id}-pinned"}
          rows={@pinned}
          row_click={@row_click}
          row_id={@row_id}
          class={@table_class}
        >
          <:col :let={row} :for={col <- @col} label={col[:label]} class={col[:class]}>
            {render_slot(col, row)}
          </:col>
          <:action :let={row} :for={action <- @action}>{render_slot(action, row)}</:action>
        </.table>
      </div>

      <div :if={@groups != []}>
        <details
          :for={group <- @groups}
          id={"group-#{group.key}"}
          class="mb-4 group"
          {if(group[:rows] != [], do: [open: true], else: [])}
        >
          <summary class="flex items-center justify-between cursor-pointer list-none mb-2 rounded-lg px-2 py-1 -mx-2 hover:bg-base-200 transition-colors">
            <h3 class="text-sm font-semibold text-base-content/70 flex items-center gap-2">
              <.icon
                name="hero-chevron-right-micro"
                class="size-4 transition-transform group-open:rotate-90"
              />
              <.icon name={group[:icon] || "hero-code-bracket-micro"} class="size-4" />
              <.link :if={group[:navigate]} navigate={group[:navigate]} class="link link-hover">
                {group[:label]}
              </.link>
              <span :if={is_nil(group[:navigate])}>{group[:label]}</span>
              <span class="badge badge-sm badge-ghost">{group[:count] || length(group[:rows])}</span>
              <span
                :for={badge <- group[:badges] || []}
                class="badge badge-sm badge-outline opacity-60"
              >
                {badge}
              </span>
            </h3>
            <div class="flex items-center gap-1">
              <span :if={@group_actions != []}>{render_slot(@group_actions, group)}</span>
            </div>
          </summary>

          <div
            :if={group[:rows] == [] && @group_empty_message}
            class="text-sm text-base-content/50 p-4"
          >
            {@group_empty_message}
          </div>

          <.table
            :if={group[:rows] != []}
            id={"#{@id}-#{group.key}"}
            rows={group[:rows]}
            row_click={@row_click}
            row_id={@row_id}
            class={@table_class}
          >
            <:col :let={row} :for={col <- @col} label={col[:label]} class={col[:class]}>
              {render_slot(col, row)}
            </:col>
            <:action :let={row} :for={action <- @action}>{render_slot(action, row)}</:action>
          </.table>
        </details>
      </div>

      <div
        :if={@groups == [] && @pinned == [] && @empty_message}
        class="text-sm text-base-content/50 p-4 text-center"
      >
        {@empty_message}
      </div>
    </div>
    """
  end
end
