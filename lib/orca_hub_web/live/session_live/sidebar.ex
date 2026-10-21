defmodule OrcaHubWeb.SessionLive.Sidebar do
  @moduledoc """
  The session page's desktop sidebar (`lg:` and up), plus the panel lists it
  shares with the narrow layout.

  At `lg:` SessionLive.Show moves all of its chrome out of the header and
  into `sidebar/1`: title, status, metadata, pickers, the Tasks / Commits /
  Artifacts / Memories / Tool restrictions panels, and every header action.
  The sidebar is a column of its own beside the feed, so the feed and the
  composer get the window's full height. Below `lg:` the sidebar is `hidden`
  and the page is what it always was: the header, the "+N" chip, the "More
  actions" modal, and the panels stacked above the feed.

  Both layouts are in the DOM at once and CSS shows one of them. So every id
  in here is `sidebar-` or `rail-` prefixed, and the expanded sidebar's rows
  carry no `title` the header's icon buttons use. The collapsed rail's icons
  do share the header's labels as tooltips, so tests that select a header
  button by title scope it to `header`. The panel state itself
  (`show_todos`, `show_commits`, ...) is shared. A section opened here is
  the same panel that stacks above the feed below `lg:`.

  The rail's panel icons open a flyout instead (`@rail_flyout`, one at a
  time, see `rail/1`), so a panel can be read without expanding the sidebar
  beside an open file panel.

  Collapsing is client-only: the toggle dispatches
  `orca:session-sidebar-toggle`, which root.html.heex handles by flipping an
  attribute on `<html>` and saving it to localStorage. The
  `sidebar-collapsed:` variant (assets/css/app.css) reads that attribute
  against this aside's `data-sidebar-context`. It is "panel" while a file or
  terminal panel shares the row, which defaults to the rail since three
  columns don't fit at 1280px, and "chat" otherwise.
  """
  use OrcaHubWeb, :html

  alias OrcaHub.Backend
  alias OrcaHub.Cluster
  alias OrcaHubWeb.MessageComponents
  alias OrcaHubWeb.SessionLive.Show

  attr :session, :map, required: true
  attr :status, :atom, required: true
  attr :capabilities, :map, required: true
  attr :plan_mode, :atom, default: nil
  attr :editing_title, :boolean, default: false
  attr :view, :atom, required: true
  attr :session_node, :any, required: true
  attr :session_node_name, :string, required: true
  attr :cluster_nodes, :list, required: true
  attr :remote_session, :boolean, required: true
  attr :parent_session, :map, default: nil
  attr :prev_session_id, :string, default: nil
  attr :next_session_id, :string, default: nil
  attr :context_percent, :any, default: nil
  attr :todos, :list, required: true
  attr :show_todos, :boolean, required: true
  attr :commits, :list, required: true
  attr :show_commits, :boolean, required: true
  attr :expanded_commit, :string, default: nil
  attr :commit_detail, :map, default: nil
  attr :artifacts, :list, required: true
  attr :show_artifacts, :boolean, required: true
  attr :show_tool_policy, :boolean, required: true
  attr :memory_events, :list, required: true
  attr :show_memories, :boolean, required: true
  attr :created_memories, :any, required: true
  attr :heartbeat_info, :map, default: nil
  attr :show_heartbeat_modal, :boolean, required: true
  attr :show_mcp_modal, :boolean, required: true
  attr :files_open, :boolean, required: true
  attr :show_terminal, :boolean, required: true
  # A file or terminal panel is beside the feed: the sidebar's
  # `data-sidebar-context`, see the moduledoc.
  attr :side_panel_open, :boolean, required: true
  # The rail's open flyout (Show's "rail_flyout" event): nil or one of
  # :tasks, :commits, :artifacts, :memories, :tool_policy.
  attr :rail_flyout, :atom, default: nil

  def sidebar(assigns) do
    ~H"""
    <aside
      id="session-sidebar"
      aria-label="Session"
      data-sidebar-context={if @side_panel_open, do: "panel", else: "chat"}
      class="hidden lg:flex voice-view:hidden shrink-0 min-h-0"
    >
      <.rail
        session={@session}
        status={@status}
        capabilities={@capabilities}
        prev_session_id={@prev_session_id}
        next_session_id={@next_session_id}
        todos={@todos}
        commits={@commits}
        expanded_commit={@expanded_commit}
        commit_detail={@commit_detail}
        artifacts={@artifacts}
        memory_events={@memory_events}
        created_memories={@created_memories}
        heartbeat_info={@heartbeat_info}
        show_heartbeat_modal={@show_heartbeat_modal}
        show_mcp_modal={@show_mcp_modal}
        files_open={@files_open}
        show_terminal={@show_terminal}
        flyout={@rail_flyout}
      />

      <%!-- Scrolls on its own: the feed beside it owns the page height. A
      thin scrollbar, so a classic (non-overlay) one doesn't read as a second
      feed scrollbar. --%>
      <div
        id="session-sidebar-body"
        class="flex sidebar-collapsed:hidden flex-col gap-4 w-64 xl:w-72 min-h-0 overflow-y-auto overscroll-contain [scrollbar-width:thin] pr-1 pb-1"
      >
        <div class="flex items-center gap-0.5">
          <.link
            navigate={~p"/sessions"}
            class="btn btn-ghost btn-sm px-2 -ml-2 font-normal text-base-content/70"
          >
            &larr; Sessions
          </.link>
          <span class="flex-1"></span>
          <.session_step to={@prev_session_id} dir={:prev} />
          <.session_step to={@next_session_id} dir={:next} />
          <.toggle_button action={:collapse} />
        </div>

        <.title_block session={@session} status={@status} editing_title={@editing_title} />

        <.archive_control session={@session} />

        <.meta
          session={@session}
          capabilities={@capabilities}
          plan_mode={@plan_mode}
          session_node={@session_node}
          session_node_name={@session_node_name}
          cluster_nodes={@cluster_nodes}
          remote_session={@remote_session}
          parent_session={@parent_session}
          context_percent={@context_percent}
        />

        <div class="join w-full">
          <.link
            patch={~p"/sessions/#{@session.id}?view=conversation"}
            class={["btn btn-sm join-item flex-1", @view == :conversation && "btn-active"]}
          >
            Conversation
          </.link>
          <.link
            patch={~p"/sessions/#{@session.id}?view=tree"}
            class={["btn btn-sm join-item flex-1", @view == :tree && "btn-active"]}
          >
            Tree
          </.link>
        </div>

        <%!-- Same visibility rules as the header's icon toggles: a section
        exists only once it has something in it. --%>
        <div
          :if={
            @todos != [] or @commits != [] or @artifacts != [] or
              Show.tool_policy_restricted?(@session) or @memory_events != []
          }
          class="flex flex-col"
        >
          <.heading>Panels</.heading>
          <.section
            :if={@todos != []}
            id="sidebar-tasks"
            event="toggle_todos"
            open={@show_todos}
            icon="hero-clipboard-document-check"
            label="Tasks"
          >
            <:count>
              {Enum.count(@todos, &(&1["status"] == "completed"))}/{length(@todos)}
            </:count>
            <.todo_list todos={@todos} compact />
          </.section>
          <.section
            :if={@commits != []}
            id="sidebar-commits"
            event="toggle_commits"
            open={@show_commits}
            icon="hero-code-bracket"
            label="Commits"
          >
            <:count>{length(@commits)}</:count>
            <.commit_list
              commits={@commits}
              expanded_commit={@expanded_commit}
              commit_detail={@commit_detail}
              compact
            />
          </.section>
          <.section
            :if={@artifacts != []}
            id="sidebar-artifacts"
            event="toggle_artifacts"
            open={@show_artifacts}
            icon="hero-sparkles"
            label="Artifacts"
          >
            <:count>{length(@artifacts)}</:count>
            <.artifact_list artifacts={@artifacts} compact />
          </.section>
          <.section
            :if={@memory_events != []}
            id="sidebar-memories"
            event="toggle_memories"
            open={@show_memories}
            icon="hero-book-open"
            label="Memories"
          >
            <:count>{Show.memory_panel_summary(@memory_events).distinct_count}</:count>
            <.memory_details
              memory_events={@memory_events}
              created_memories={@created_memories}
              compact
            />
          </.section>
          <.section
            :if={Show.tool_policy_restricted?(@session)}
            id="sidebar-tool-policy"
            event="toggle_tool_policy"
            open={@show_tool_policy}
            icon="hero-lock-closed"
            icon_class="text-warning"
            label="Tool restrictions"
          >
            <.tool_policy_details session={@session} compact />
          </.section>
        </div>

        <.actions
          session={@session}
          capabilities={@capabilities}
          plan_mode={@plan_mode}
          parent_session={@parent_session}
          heartbeat_info={@heartbeat_info}
          show_heartbeat_modal={@show_heartbeat_modal}
          show_mcp_modal={@show_mcp_modal}
          files_open={@files_open}
          show_terminal={@show_terminal}
        />

        <%!-- `mt-auto` pins it to the bottom of a short sidebar; a tall one
        just scrolls down to it. Only Stop lives here now: Archive moved up
        to archive_control/1. --%>
        <div
          :if={@status in [:running, :waiting, :compacting] && !@session.archived_at}
          class="mt-auto flex flex-col"
        >
          <.heading>Danger zone</.heading>
          <ul class="menu menu-sm w-full p-0">
            <li>
              <button
                type="button"
                phx-click="stop_session"
                data-confirm="Stop this session? The Claude process will be terminated."
                class="text-error"
              >
                <.icon name="hero-stop-circle" class="size-4" /> Stop session
              </button>
            </li>
          </ul>
        </div>
      </div>
    </aside>
    """
  end

  # Archiving a finished session is the most frequent thing done on this
  # page, so it is a real button under the title rather than a menu row at
  # the bottom. One click archives, with memory extraction on as everywhere
  # else, and the caret offers the variant without it. It is reversible
  # (Unarchive here, Undo on the sessions page it navigates to), so there is
  # no confirm. An archived session shows Unarchive in the same slot.
  attr :session, :map, required: true

  defp archive_control(assigns) do
    ~H"""
    <button
      :if={@session.archived_at}
      type="button"
      id="sidebar-unarchive"
      phx-click="unarchive"
      class="btn btn-sm btn-soft btn-primary w-full"
    >
      <.icon name="hero-archive-box-arrow-down" class="size-4" /> Unarchive
    </button>
    <div :if={!@session.archived_at} id="sidebar-archive" class="flex w-full">
      <button
        type="button"
        phx-click="archive"
        class="btn btn-sm btn-soft btn-primary flex-1 rounded-r-none"
      >
        <.icon name="hero-archive-box" class="size-4" /> Archive
      </button>
      <%!-- A real dropdown, unlike the inline pickers further down: it opens
      just below the top of the column and is narrower than it, so the
      sidebar's scroll box has nothing to clip. --%>
      <div class="dropdown dropdown-end">
        <div
          tabindex="0"
          role="button"
          class="btn btn-sm btn-soft btn-primary rounded-l-none border-l border-l-primary/25 px-2"
          title="More archive options"
          aria-label="More archive options"
        >
          <.icon name="hero-chevron-down-micro" class="size-4" />
        </div>
        <ul
          tabindex="0"
          class="dropdown-content menu menu-sm z-10 mt-1 w-60 rounded-box bg-base-200 p-1 shadow-lg"
        >
          <li>
            <button type="button" phx-click="archive_without_extracting">
              <.icon name="hero-archive-box-x-mark" class="size-4" />
              Archive without extracting memories
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # The collapsed sidebar: icon buttons for the everyday chrome, top to
  # bottom: navigation and status, Archive (or Unarchive), the panels, the
  # tools, and Stop pinned to the bottom. The rarely used settings
  # (orchestrator, memory extraction, attach/detach, copy, model, archiving
  # without extraction) stay in the expanded sidebar.
  #
  # A panel icon opens a flyout beside the rail rather than expanding the
  # sidebar, because the rail is the default beside an open file panel,
  # where expanding squeezes the row. The icon column scrolls when it
  # outgrows a short window, so the flyout is its SIBLING: inside that
  # scroll box it would be clipped. Both sit in one wrapper, which owns the
  # click-away and Escape closes, so clicking another rail icon swaps the
  # flyout instead of racing a close against an open.
  attr :session, :map, required: true
  attr :status, :atom, required: true
  attr :capabilities, :map, required: true
  attr :prev_session_id, :string, default: nil
  attr :next_session_id, :string, default: nil
  attr :todos, :list, required: true
  attr :commits, :list, required: true
  attr :expanded_commit, :string, default: nil
  attr :commit_detail, :map, default: nil
  attr :artifacts, :list, required: true
  attr :memory_events, :list, required: true
  attr :created_memories, :any, required: true
  attr :heartbeat_info, :map, default: nil
  attr :show_heartbeat_modal, :boolean, required: true
  attr :show_mcp_modal, :boolean, required: true
  attr :files_open, :boolean, required: true
  attr :show_terminal, :boolean, required: true
  attr :flyout, :atom, default: nil

  defp rail(assigns) do
    ~H"""
    <div
      id="session-sidebar-rail"
      class="hidden sidebar-collapsed:flex relative min-h-0"
      phx-click-away={@flyout && JS.push("close_rail_flyout")}
      phx-window-keydown={@flyout && "close_rail_flyout"}
      phx-key="Escape"
    >
      <div
        id="rail-icons"
        class="flex flex-col items-center gap-1 w-13 min-h-0 overflow-y-auto overflow-x-hidden overscroll-contain [scrollbar-width:thin] pb-1"
      >
        <.toggle_button action={:expand} close_flyout={@flyout != nil} />
        <.link
          navigate={~p"/sessions"}
          class="btn btn-ghost btn-sm btn-square shrink-0"
          title="Back to sessions"
          aria-label="Back to sessions"
        >
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>
        <span
          class={["status status-lg my-1.5 shrink-0", status_dot_class(@status)]}
          title={"Status: #{@status}"}
          aria-label={"Status: #{@status}"}
        >
        </span>
        <.session_step to={@prev_session_id} dir={:prev} />
        <.session_step to={@next_session_id} dir={:next} />

        <%!-- One click, like the expanded sidebar's main Archive button (see
        archive_control/1), and set apart from the ghost icons around it. --%>
        <.rail_button
          :if={!@session.archived_at}
          id="rail-archive"
          icon="hero-archive-box"
          label="Archive"
          prominent
          class="my-1"
          phx-click="archive"
        />
        <.rail_button
          :if={@session.archived_at}
          id="rail-unarchive"
          icon="hero-archive-box-arrow-down"
          label="Unarchive"
          prominent
          class="my-1"
          phx-click="unarchive"
        />

        <%!-- Panels: the same `:if`s as the expanded sections. --%>
        <.rail_divider :if={
          @todos != [] or @commits != [] or @artifacts != [] or @memory_events != [] or
            Show.tool_policy_restricted?(@session)
        } />
        <.rail_button
          :if={@todos != []}
          id="rail-tasks"
          icon="hero-clipboard-document-check"
          label="Tasks"
          active={@flyout == :tasks}
          phx-click="rail_flyout"
          phx-value-panel="tasks"
        >
          <:badge>
            {Enum.count(@todos, &(&1["status"] == "completed"))}/{length(@todos)}
          </:badge>
        </.rail_button>
        <.rail_button
          :if={@commits != []}
          id="rail-commits"
          icon="hero-code-bracket"
          label="Commits"
          active={@flyout == :commits}
          phx-click="rail_flyout"
          phx-value-panel="commits"
        >
          <:badge>{length(@commits)}</:badge>
        </.rail_button>
        <.rail_button
          :if={@artifacts != []}
          id="rail-artifacts"
          icon="hero-sparkles"
          label="Artifacts"
          active={@flyout == :artifacts}
          phx-click="rail_flyout"
          phx-value-panel="artifacts"
        >
          <:badge>{length(@artifacts)}</:badge>
        </.rail_button>
        <.rail_button
          :if={@memory_events != []}
          id="rail-memories"
          icon="hero-book-open"
          label="Memories"
          active={@flyout == :memories}
          phx-click="rail_flyout"
          phx-value-panel="memories"
        >
          <:badge>{Show.memory_panel_summary(@memory_events).distinct_count}</:badge>
        </.rail_button>
        <.rail_button
          :if={Show.tool_policy_restricted?(@session)}
          id="rail-tool-policy"
          icon="hero-lock-closed"
          icon_class="text-warning"
          label="Tool restrictions"
          active={@flyout == :tool_policy}
          phx-click="rail_flyout"
          phx-value-panel="tool_policy"
        />

        <.rail_divider />
        <.rail_button
          id="rail-files"
          icon="hero-document-text"
          label="Browse files"
          active={@files_open}
          phx-click="toggle_file_browser"
        />
        <.rail_button
          id="rail-terminal"
          icon="hero-command-line"
          label="Open terminal"
          active={@show_terminal}
          phx-click="open_terminal"
        />
        <.rail_button
          :if={@session.claude_session_id}
          id="rail-resume"
          icon="hero-play"
          label="Resume in terminal"
          phx-click="resume_in_terminal"
        />
        <.rail_button
          id="rail-heartbeat"
          icon="hero-heart"
          label={if @heartbeat_info, do: "Heartbeat (active)", else: "Heartbeat"}
          active={@show_heartbeat_modal}
          phx-click="toggle_heartbeat_modal"
        >
          <:dot :if={@heartbeat_info} />
        </.rail_button>
        <.rail_button
          :if={@capabilities.mcp}
          id="rail-mcp"
          icon="hero-server-stack"
          label="MCP servers"
          active={@show_mcp_modal}
          phx-click="toggle_mcp_modal"
        />

        <%!-- Pinned to the bottom of a tall window; a short one scrolls down
        to it like everything else. --%>
        <div
          :if={@status in [:running, :waiting, :compacting] && !@session.archived_at}
          class="mt-auto flex flex-col items-center gap-1 pt-1"
        >
          <.rail_divider />
          <.rail_button
            id="rail-stop"
            icon="hero-stop-circle"
            label="Stop session"
            class="text-error"
            phx-click="stop_session"
            data-confirm="Stop this session? The Claude process will be terminated."
          />
        </div>
      </div>

      <.rail_flyout
        :if={@flyout}
        flyout={@flyout}
        session={@session}
        todos={@todos}
        commits={@commits}
        expanded_commit={@expanded_commit}
        commit_detail={@commit_detail}
        artifacts={@artifacts}
        memory_events={@memory_events}
        created_memories={@created_memories}
      />
    </div>
    """
  end

  # One rail icon. `title` is the expanded row's label; active marks it
  # `text-primary`, as the old header icons did. `prominent` (Archive and
  # Unarchive) swaps the ghost style for a soft primary square.
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :icon_class, :any, default: nil
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :prominent, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  # A count on the button's corner. It may hang 4px past the button and no
  # further: the icon column clips what crosses its edge, and its 52px leaves
  # 5px either side of a button once a thin scrollbar takes 10px.
  slot :badge
  # A bare status dot in the same corner (Heartbeat's "active").
  slot :dot

  defp rail_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class={[
        "btn btn-sm btn-square relative shrink-0",
        if(@prominent, do: "btn-soft btn-primary", else: "btn-ghost"),
        @active && "text-primary",
        @class
      ]}
      title={@label}
      aria-label={@label}
      {@rest}
    >
      <.icon name={@icon} class={["size-5", @icon_class]} />
      <span
        :if={@badge != []}
        class="absolute -top-1 -right-1 badge badge-xs badge-primary px-1 text-[10px] leading-none tabular-nums"
      >
        {render_slot(@badge)}
      </span>
      <span :if={@dot != []} class="absolute top-0.5 right-0.5 status status-success"></span>
    </button>
    """
  end

  defp rail_divider(assigns) do
    ~H"""
    <div class="w-6 shrink-0 border-t border-base-300 my-1"></div>
    """
  end

  # The flyout: one panel's list beside the rail, over the feed. Positioned
  # by the RailFlyout hook (assets/js/app.js) level with the icon that opened
  # it (`data-anchor`), clamped to the rail's height. `top-0` is where it sits
  # until then.
  attr :flyout, :atom, required: true
  attr :session, :map, required: true
  attr :todos, :list, required: true
  attr :commits, :list, required: true
  attr :expanded_commit, :string, default: nil
  attr :commit_detail, :map, default: nil
  attr :artifacts, :list, required: true
  attr :memory_events, :list, required: true
  attr :created_memories, :any, required: true

  defp rail_flyout(assigns) do
    {anchor, icon, label} = flyout_meta(assigns.flyout)
    assigns = assign(assigns, anchor: anchor, icon: icon, label: label)

    ~H"""
    <div
      id="rail-flyout"
      phx-hook="RailFlyout"
      data-anchor={@anchor}
      role="dialog"
      aria-label={@label}
      class="absolute left-full top-0 ml-2 z-30 flex flex-col w-80 max-h-full rounded-box border border-base-300 bg-base-100 shadow-xl"
    >
      <div class="flex items-center gap-2 px-3 py-2 border-b border-base-300 shrink-0">
        <.icon name={@icon} class="size-4" />
        <span class="flex-1 text-sm font-semibold">{@label}</span>
        <button
          type="button"
          phx-click="close_rail_flyout"
          class="btn btn-ghost btn-xs btn-square"
          aria-label="Close"
          title="Close"
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>
      <div class="min-h-0 overflow-y-auto overscroll-contain [scrollbar-width:thin] p-3">
        <%= case @flyout do %>
          <% :tasks -> %>
            <.todo_list todos={@todos} compact />
          <% :commits -> %>
            <.commit_list
              commits={@commits}
              expanded_commit={@expanded_commit}
              commit_detail={@commit_detail}
              compact
            />
          <% :artifacts -> %>
            <.artifact_list artifacts={@artifacts} compact />
          <% :memories -> %>
            <.memory_details
              memory_events={@memory_events}
              created_memories={@created_memories}
              compact
            />
          <% :tool_policy -> %>
            <.tool_policy_details session={@session} compact />
        <% end %>
      </div>
    </div>
    """
  end

  defp flyout_meta(:tasks), do: {"rail-tasks", "hero-clipboard-document-check", "Tasks"}
  defp flyout_meta(:commits), do: {"rail-commits", "hero-code-bracket", "Commits"}
  defp flyout_meta(:artifacts), do: {"rail-artifacts", "hero-sparkles", "Artifacts"}
  defp flyout_meta(:memories), do: {"rail-memories", "hero-book-open", "Memories"}

  defp flyout_meta(:tool_policy),
    do: {"rail-tool-policy", "hero-lock-closed", "Tool restrictions"}

  attr :action, :atom, required: true, values: [:collapse, :expand]
  # Expanding with a flyout open closes it too: the flyout belongs to the
  # rail and would otherwise reappear the next time the sidebar collapses.
  attr :close_flyout, :boolean, default: false

  defp toggle_button(assigns) do
    assigns =
      assign(
        assigns,
        :label,
        if(assigns.action == :collapse, do: "Collapse sidebar", else: "Expand sidebar")
      )

    ~H"""
    <button
      type="button"
      phx-click={
        if @close_flyout,
          do: JS.dispatch("orca:session-sidebar-toggle") |> JS.push("close_rail_flyout"),
          else: JS.dispatch("orca:session-sidebar-toggle")
      }
      class="btn btn-ghost btn-sm btn-square"
      title={@label}
      aria-label={@label}
    >
      <.icon
        name={
          if @action == :collapse,
            do: "hero-chevron-double-left",
            else: "hero-chevron-double-right"
        }
        class="size-4"
      />
    </button>
    """
  end

  # Previous (newer) / next (older) session, the chevron columns either side
  # of the feed below `lg:`. A disabled placeholder at either end keeps the
  # other button from shifting.
  attr :to, :string, default: nil
  attr :dir, :atom, required: true, values: [:prev, :next]

  defp session_step(assigns) do
    assigns =
      assign(assigns,
        label:
          if(assigns.dir == :prev, do: "Previous session (newer)", else: "Next session (older)"),
        icon: if(assigns.dir == :prev, do: "hero-chevron-left", else: "hero-chevron-right")
      )

    ~H"""
    <.link
      :if={@to}
      navigate={~p"/sessions/#{@to}"}
      class="btn btn-ghost btn-sm btn-square"
      title={@label}
      aria-label={@label}
    >
      <.icon name={@icon} class="size-4" />
    </.link>
    <span :if={!@to} class="btn btn-ghost btn-sm btn-square btn-disabled" aria-hidden="true">
      <.icon name={@icon} class="size-4" />
    </span>
    """
  end

  attr :session, :map, required: true
  attr :status, :atom, required: true
  attr :editing_title, :boolean, required: true

  defp title_block(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <form
        :if={@editing_title}
        id="sidebar-title-form"
        phx-submit="save_title"
        class="flex items-center gap-1"
      >
        <input
          type="text"
          name="title"
          value={@session.title || ""}
          placeholder="Session title"
          class="input input-sm input-bordered flex-1 min-w-0"
          autofocus
          phx-key="Escape"
          phx-keydown="cancel_title_edit"
        />
        <button type="submit" class="btn btn-ghost btn-sm btn-square" aria-label="Save title">
          <.icon name="hero-check-micro" class="size-4" />
        </button>
        <button
          type="button"
          phx-click="cancel_title_edit"
          class="btn btn-ghost btn-sm btn-square"
          aria-label="Cancel title edit"
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </form>
      <h1
        :if={!@editing_title}
        class="group text-base font-semibold leading-snug cursor-pointer hover:underline [overflow-wrap:anywhere]"
        phx-click="edit_title"
      >
        {@session.title || @session.directory}
        <.icon name="hero-pencil-micro" class="size-3 opacity-0 group-hover:opacity-50 inline" />
      </h1>
      <div class="flex flex-wrap items-center gap-1">
        <span
          class={["badge badge-sm", status_badge_class(@status)]}
          title={@status == :error && @session.error_detail}
        >
          {@status}
        </span>
        <span :if={@session.progress_phase} class="badge badge-sm badge-outline">
          {@session.progress_phase}
        </span>
      </div>
      <%!-- The header can only afford the note as the phase badge's tooltip;
      here it is the text itself, clamped so a long note can't push the rest
      of the sidebar out of view. --%>
      <p
        :if={@session.progress_note not in [nil, ""]}
        class="text-xs text-base-content/70 line-clamp-4 [overflow-wrap:anywhere]"
        title={@session.progress_note}
      >
        {@session.progress_note}
      </p>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :capabilities, :map, required: true
  attr :plan_mode, :atom, default: nil
  attr :session_node, :any, required: true
  attr :session_node_name, :string, required: true
  attr :cluster_nodes, :list, required: true
  attr :remote_session, :boolean, required: true
  attr :parent_session, :map, default: nil
  attr :context_percent, :any, default: nil

  defp meta(assigns) do
    assigns =
      assign(
        assigns,
        :node_moved,
        assigns.session.original_node != nil &&
          assigns.session.original_node != assigns.session.runner_node
      )

    ~H"""
    <div class="flex flex-col gap-2">
      <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1.5 text-xs">
        <%= if @session.project do %>
          <dt class="text-base-content/50">Project</dt>
          <dd>
            <.link navigate={~p"/projects/#{@session.project}"} class="link link-hover">
              {@session.project.name}
            </.link>
          </dd>
        <% end %>
        <dt class="text-base-content/50">Directory</dt>
        <dd class="font-mono [overflow-wrap:anywhere]">{@session.directory}</dd>
        <%!-- ORCAHUB3-50: no parent is a normal state, so it's stated. --%>
        <dt class="text-base-content/50">Parent</dt>
        <dd class="[overflow-wrap:anywhere]">
          <.link
            :if={@parent_session}
            navigate={~p"/sessions/#{@parent_session.id}"}
            class="link link-hover"
          >
            {@parent_session.title || @parent_session.directory}
          </.link>
          <span :if={!@parent_session} class="text-base-content/50">none</span>
        </dd>
        <%!-- The header's node rules: a picker when there is somewhere to move
        to, the bare name for a remote session on a one-node cluster. The
        pickers here are inline <details> menus rather than dropdowns, which
        this scrolling column would clip. --%>
        <%= if length(@cluster_nodes) > 1 do %>
          <dt class="text-base-content/50">Node</dt>
          <dd>
            <details id="sidebar-node-picker">
              <summary
                class={[
                  "inline-flex items-center gap-0.5 cursor-pointer hover:underline",
                  @node_moved && "text-warning"
                ]}
                title={
                  if @node_moved,
                    do:
                      "Original: #{Cluster.node_name(@session.original_node)} → Current: #{@session_node_name}",
                    else: @session.runner_node
                }
              >
                {@session_node_name}
                <.icon name="hero-chevron-down-micro" class="size-3" />
              </summary>
              <ul class="menu menu-xs w-full p-1 mt-1 bg-base-200 rounded-box">
                <li class="menu-title">Move session to:</li>
                <li :for={node_info <- @cluster_nodes}>
                  <button
                    type="button"
                    phx-click="change_node"
                    phx-value-node={node_info.node}
                    data-close-details
                    class={[Atom.to_string(node_info.node) == @session.runner_node && "menu-active"]}
                  >
                    {node_info.name}
                    <span
                      :if={@node_moved && Atom.to_string(node_info.node) == @session.original_node}
                      class="badge badge-xs badge-warning"
                    >
                      original
                    </span>
                  </button>
                </li>
                <li :if={@node_moved}>
                  <button
                    type="button"
                    phx-click="change_node"
                    phx-value-node={@session.original_node}
                    data-close-details
                    class="text-warning"
                  >
                    <.icon name="hero-arrow-uturn-left-micro" class="size-4" />
                    Restore to original node
                  </button>
                </li>
              </ul>
            </details>
          </dd>
        <% end %>
        <%= if length(@cluster_nodes) == 1 && @remote_session do %>
          <dt class="text-base-content/50">Node</dt>
          <dd title={@session.runner_node}>{@session_node_name}</dd>
        <% end %>
        <%!-- The header's combined backend + model picker: the backend half
        only when the node has more than one CLI, and switching it starts a
        fresh agent conversation. --%>
        <dt class="text-base-content/50">Agent</dt>
        <dd>
          <details id="sidebar-agent-picker">
            <summary class="inline-flex items-center gap-0.5 cursor-pointer hover:underline [overflow-wrap:anywhere]">
              {String.capitalize(@session.backend || "claude")} · {@session.model || "default"}
              <.icon name="hero-chevron-down-micro" class="size-3 shrink-0" />
            </summary>
            <ul class="menu menu-xs w-full p-1 mt-1 bg-base-200 rounded-box">
              <%= if length(Backend.available_on(@session_node)) > 1 do %>
                <li class="menu-title">Backend (switching starts a fresh conversation)</li>
                <li :for={{value, label} <- Backend.available_on(@session_node)}>
                  <button
                    type="button"
                    phx-click="set_backend"
                    phx-value-backend={value}
                    data-close-details
                    class={[(@session.backend || "claude") == value && "menu-active"]}
                  >
                    {label}
                  </button>
                </li>
              <% end %>
              <li class="menu-title">Model</li>
              <li>
                <button
                  type="button"
                  phx-click="set_model"
                  phx-value-model=""
                  data-close-details
                  class={[@session.model == nil && "menu-active"]}
                >
                  Default
                </button>
              </li>
              <li :for={{model_id, label} <- Backend.models_for(@session.backend, @session_node)}>
                <button
                  type="button"
                  phx-click="set_model"
                  phx-value-model={model_id}
                  data-close-details
                  class={[@session.model == model_id && "menu-active"]}
                >
                  {label}
                </button>
              </li>
              <li class="menu-title">Custom model</li>
              <li>
                <form phx-submit="set_model" class="flex gap-1 px-1 py-1">
                  <input
                    type="text"
                    name="model"
                    placeholder="passthrough model id"
                    class="input input-xs input-bordered flex-1 min-w-0"
                  />
                  <button type="submit" class="btn btn-xs btn-primary">Set</button>
                </form>
              </li>
            </ul>
          </details>
        </dd>
        <%!-- spec §12.8 context meter (pi only), hidden until the first
        pi_session_stats event. --%>
        <%= if @capabilities.session_stats && @context_percent do %>
          <dt class="text-base-content/50">Context</dt>
          <dd class="flex items-center gap-2">
            <progress
              class={["progress w-16 h-1.5", Show.context_meter_color(@context_percent)]}
              value={@context_percent}
              max="100"
            />
            <span>{@context_percent}%</span>
            <button type="button" phx-click="compact_session" class="btn btn-ghost btn-xs ml-auto">
              Compact now
            </button>
          </dd>
        <% end %>
      </dl>
      <div
        :if={
          @session.orchestrator or @session.kind == "memory_extraction" or
            (@capabilities.plan_mode and @plan_mode in [:planning, :review])
        }
        class="flex flex-wrap gap-1"
      >
        <span
          :if={@session.orchestrator}
          class="badge badge-primary badge-outline badge-sm"
          title="Orchestrator mode: read-only, delegates work to other sessions"
        >
          orchestrator
        </span>
        <span
          :if={@session.kind == "memory_extraction"}
          class="badge badge-ghost badge-outline badge-sm"
          title="Background memory-extraction session — self-archives when it finishes"
        >
          memory
        </span>
        <span
          :if={@capabilities.plan_mode && @plan_mode == :planning}
          class="badge badge-warning badge-outline badge-sm"
        >
          planning
        </span>
        <span
          :if={@capabilities.plan_mode && @plan_mode == :review}
          class="badge badge-info badge-outline badge-sm"
        >
          needs review
        </span>
      </div>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :capabilities, :map, required: true
  attr :plan_mode, :atom, default: nil
  attr :parent_session, :map, default: nil
  attr :heartbeat_info, :map, default: nil
  attr :show_heartbeat_modal, :boolean, required: true
  attr :show_mcp_modal, :boolean, required: true
  attr :files_open, :boolean, required: true
  attr :show_terminal, :boolean, required: true

  defp actions(assigns) do
    ~H"""
    <%!-- An open panel or modal marks its row `text-primary`, as the header's
    icon buttons do; `menu-active`'s solid fill is kept for the pickers'
    current choice. --%>
    <div class="flex flex-col">
      <.heading>Tools</.heading>
      <ul class="menu menu-sm w-full p-0">
        <li>
          <button
            type="button"
            phx-click="toggle_file_browser"
            class={[@files_open && "text-primary"]}
          >
            <.icon name="hero-document-text" class="size-4" /> Browse files
          </button>
        </li>
        <li>
          <button type="button" phx-click="open_terminal" class={[@show_terminal && "text-primary"]}>
            <.icon name="hero-command-line" class="size-4" /> Open terminal
          </button>
        </li>
        <li :if={@session.claude_session_id}>
          <button type="button" phx-click="resume_in_terminal">
            <.icon name="hero-play" class="size-4" /> Resume in terminal
          </button>
        </li>
        <li>
          <button
            type="button"
            phx-click="toggle_heartbeat_modal"
            class={[@show_heartbeat_modal && "text-primary"]}
          >
            <.icon name="hero-heart" class={["size-4", @heartbeat_info && "text-success"]} />
            Heartbeat <span :if={@heartbeat_info} class="badge badge-xs badge-success">active</span>
          </button>
        </li>
        <li :if={@capabilities.mcp}>
          <button
            type="button"
            phx-click="toggle_mcp_modal"
            class={[@show_mcp_modal && "text-primary"]}
          >
            <.icon name="hero-server-stack" class="size-4" /> MCP servers
          </button>
        </li>
      </ul>
    </div>

    <div class="flex flex-col">
      <.heading>Session</.heading>
      <ul class="menu menu-sm w-full p-0">
        <li :if={@capabilities.mcp}>
          <button
            type="button"
            phx-click="toggle_orchestrator"
            title={
              if @session.orchestrator,
                do: "Disable orchestrator mode",
                else: "Enable orchestrator mode (read-only, delegates work)"
            }
          >
            <.icon name="hero-users" class={["size-4", @session.orchestrator && "text-primary"]} />
            Orchestrator mode
            <span class={["badge badge-xs", @session.orchestrator && "badge-primary"]}>
              {if @session.orchestrator, do: "on", else: "off"}
            </span>
          </button>
        </li>
        <li>
          <button
            type="button"
            phx-click="cycle_memory_extract"
            title={Show.memory_extract_title(@session)}
          >
            <.icon
              name="hero-light-bulb"
              class={["size-4", Show.memory_extract_class(@session)]}
            /> Memory extraction
            <span class={["badge badge-xs", memory_extract_badge_class(@session)]}>
              {memory_extract_label(@session)}
            </span>
          </button>
        </li>
        <li>
          <button type="button" phx-click="extract_memories_now">
            <.icon name="hero-light-bulb" class="size-4" /> Extract memories now
          </button>
        </li>
        <%!-- pi only (spec §12.4): Claude's plan mode is model-initiated. --%>
        <li :if={@capabilities.plan_mode_toggle}>
          <button
            type="button"
            phx-click="toggle_plan_mode"
            class={[@plan_mode == :planning && "text-warning"]}
          >
            <.icon name="hero-map" class="size-4" />
            {if @plan_mode == :planning, do: "Exit plan mode", else: "Enter plan mode"}
          </button>
        </li>
        <%!-- Orchestrator parentage (ORCAHUB3-50) --%>
        <li>
          <button type="button" phx-click="open_attach_modal">
            <.icon name="hero-link" class="size-4" />
            {if @parent_session, do: "Re-attach to...", else: "Attach to..."}
          </button>
        </li>
        <li :if={@parent_session}>
          <button
            type="button"
            phx-click="detach_from_orchestrator"
            data-confirm="Detach from orchestrator? Its completion callbacks (e.g. notify_parent) will stop."
          >
            <.icon name="hero-link-slash" class="size-4" /> Detach from orchestrator
          </button>
        </li>
        <li>
          <button
            type="button"
            id="sidebar-copy-session-id"
            phx-hook="CopyToClipboard"
            data-copy-text={@session.id}
          >
            <.icon name="hero-identification" class="size-4" /> Copy session ID
          </button>
        </li>
        <li :if={@session.claude_session_id}>
          <button
            type="button"
            id="sidebar-copy-terminal-cmd"
            phx-hook="CopyToClipboard"
            data-copy-text={"cd #{@session.directory} && claude --resume #{@session.claude_session_id}"}
          >
            <.icon name="hero-clipboard" class="size-4" /> Copy CLI resume command
          </button>
        </li>
      </ul>
    </div>
    """
  end

  slot :inner_block, required: true

  defp heading(assigns) do
    ~H"""
    <h2 class="px-2 pb-1 text-[11px] font-semibold uppercase tracking-wide text-base-content/50">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  # One collapsible panel. Opening it is the same server event (and state)
  # as the header's icon toggle, so its list only renders while open.
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :open, :boolean, required: true
  attr :icon, :string, required: true
  attr :icon_class, :string, default: nil
  attr :label, :string, required: true
  slot :count
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div id={@id}>
      <ul class="menu menu-sm w-full p-0">
        <li>
          <button type="button" phx-click={@event} aria-expanded={to_string(@open)}>
            <.icon name={@icon} class={["size-4", @icon_class]} />
            {@label}
            <span :if={@count != []} class="badge badge-xs badge-primary">
              {render_slot(@count)}
            </span>
            <.icon
              name={if @open, do: "hero-chevron-down-micro", else: "hero-chevron-right-micro"}
              class="size-4 opacity-50"
            />
          </button>
        </li>
      </ul>
      <div :if={@open} id={"#{@id}-panel"} class="px-2 pt-1 pb-2">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp status_badge_class(:running), do: "badge-warning"
  defp status_badge_class(:compacting), do: "badge-warning"
  defp status_badge_class(:waiting), do: "badge-info"
  defp status_badge_class(:idle), do: "badge-success"
  defp status_badge_class(:ready), do: "badge-ghost"
  defp status_badge_class(:error), do: "badge-error"
  defp status_badge_class(_), do: nil

  defp status_dot_class(status) when status in [:running, :compacting], do: "status-warning"
  defp status_dot_class(:waiting), do: "status-info"
  defp status_dot_class(:idle), do: "status-success"
  defp status_dot_class(:error), do: "status-error"
  defp status_dot_class(_), do: nil

  # Show.memory_extract_title/1 spells out the three states for the header's
  # icon-only button; a labeled row only needs the current one.
  defp memory_extract_label(%{memory_extract: true}), do: "on"
  defp memory_extract_label(%{memory_extract: false}), do: "off"
  defp memory_extract_label(_), do: "default"

  defp memory_extract_badge_class(%{memory_extract: true}), do: "badge-primary"
  defp memory_extract_badge_class(%{memory_extract: false}), do: "badge-error"
  defp memory_extract_badge_class(_), do: nil

  # -- Panel lists, shared with the stacked panels above the feed --
  #
  # Each takes `compact` for the sidebar's copy: rows in text-xs, to sit
  # under the sidebar's 12px section rows instead of towering over them.

  defp row_text(true), do: "text-xs"
  defp row_text(false), do: "text-sm"

  @doc "The latest TodoWrite list (Tasks panel)."
  attr :todos, :list, required: true
  attr :compact, :boolean, default: false

  def todo_list(assigns) do
    ~H"""
    <ul class="space-y-1">
      <li :for={todo <- @todos} class={["flex items-start gap-2", row_text(@compact)]}>
        <.icon
          :if={todo["status"] == "completed"}
          name="hero-check-circle-solid"
          class="size-4 text-success shrink-0 mt-0.5"
        />
        <.icon
          :if={todo["status"] == "in_progress"}
          name="hero-arrow-path"
          class="size-4 text-warning shrink-0 mt-0.5"
        />
        <.icon
          :if={todo["status"] == "pending"}
          name="hero-ellipsis-horizontal-circle"
          class="size-4 text-base-content/30 shrink-0 mt-0.5"
        />
        <span class={[todo["status"] == "completed" && "line-through text-base-content/50"]}>
          {todo["content"]}
        </span>
      </li>
    </ul>
    """
  end

  @doc """
  The session's commits (Commits panel); a row expands to its body and stat.
  `compact` also drops the date column (to the row's tooltip), which a
  sidebar-width row can't spare room for next to the subject.
  """
  attr :commits, :list, required: true
  attr :expanded_commit, :string, default: nil
  attr :commit_detail, :map, default: nil
  attr :compact, :boolean, default: false

  def commit_list(assigns) do
    ~H"""
    <ul class="space-y-1">
      <li :for={commit <- @commits}>
        <button
          phx-click="toggle_commit_detail"
          phx-value-hash={commit.hash}
          class={[
            "flex items-start gap-2 w-full text-left hover:bg-base-300/50 rounded px-1 -mx-1 py-0.5 transition-colors",
            row_text(@compact)
          ]}
          title={@compact && format_commit_date(commit.date)}
        >
          <code class="text-xs text-primary shrink-0">{commit.short_hash}</code>
          <span class="truncate">{commit.subject}</span>
          <span
            :if={!@compact}
            class="text-xs text-base-content/40 shrink-0 ml-auto whitespace-nowrap"
          >
            {format_commit_date(commit.date)}
          </span>
        </button>
        <div
          :if={@expanded_commit == commit.hash && @commit_detail}
          class={["mt-1 mb-2 text-xs space-y-2", if(@compact, do: "ml-2", else: "ml-6")]}
        >
          <pre :if={@commit_detail.body != ""} class="whitespace-pre-wrap text-base-content/70">{@commit_detail.body}</pre>
          <pre
            :if={@commit_detail.stat != ""}
            class={[
              "whitespace-pre-wrap text-base-content/50 font-mono",
              @compact && "[overflow-wrap:anywhere]"
            ]}
          >{@commit_detail.stat}</pre>
        </div>
      </li>
    </ul>
    """
  end

  @doc "The session's artifacts (Artifacts panel); a row opens it in the file panel."
  attr :artifacts, :list, required: true
  attr :compact, :boolean, default: false

  def artifact_list(assigns) do
    ~H"""
    <ul class="space-y-1">
      <li :for={artifact <- @artifacts}>
        <button
          phx-click="open_session_artifact"
          phx-value-id={artifact.id}
          class={[
            "flex items-center gap-2 w-full text-left hover:bg-base-300/50 rounded px-1 -mx-1 py-0.5 transition-colors",
            row_text(@compact)
          ]}
        >
          <.icon name="hero-sparkles-micro" class="size-3 text-primary shrink-0" />
          <span class="truncate">{artifact.name}</span>
          <span class="badge badge-xs badge-outline shrink-0">{artifact.kind}</span>
          <span class="text-xs text-base-content/40 shrink-0 ml-auto whitespace-nowrap">
            v{artifact.version}
          </span>
        </button>
      </li>
    </ul>
    """
  end

  @doc "The read-only MCP tool allow/deny policy (Tool restrictions panel)."
  attr :session, :map, required: true
  attr :compact, :boolean, default: false

  def tool_policy_details(assigns) do
    assigns = assign(assigns, :tool_policy, Show.session_tool_policy(assigns.session))

    ~H"""
    <div class="text-xs text-base-content/50 mb-1">
      MCP tool restrictions in effect for this session (read-only — set when the session was
      created).
    </div>
    <ul class="space-y-1">
      <li :if={@tool_policy.allow != []} class={["flex items-start gap-2", row_text(@compact)]}>
        <span class="badge badge-xs badge-warning shrink-0 mt-0.5">allow only</span>
        <span class="font-mono break-all">{Enum.join(@tool_policy.allow, ", ")}</span>
      </li>
      <li :if={@tool_policy.deny != []} class={["flex items-start gap-2", row_text(@compact)]}>
        <span class="badge badge-xs badge-error shrink-0 mt-0.5">deny</span>
        <span class="font-mono break-all">{Enum.join(@tool_policy.deny, ", ")}</span>
      </li>
    </ul>
    <p class="text-xs text-base-content/50 mt-1">
      Deny wins over allow. <strong>MCP tools only</strong>
      — the agent CLI's own built-in tools (Bash, Read, Write, WebFetch, …) are not restricted
      by this.
    </p>
    """
  end

  @doc """
  Which memories were loaded into the session, and which it created
  (Memories panel). The created list is fetched the first time the panel
  opens, see Show's "toggle_memories".
  """
  attr :memory_events, :list, required: true
  attr :created_memories, :any, required: true
  attr :compact, :boolean, default: false

  def memory_details(assigns) do
    assigns = assign(assigns, :memory_summary, Show.memory_panel_summary(assigns.memory_events))

    ~H"""
    <div class="text-xs text-base-content/50 mb-1">
      {@memory_summary.distinct_count} distinct {if @memory_summary.distinct_count == 1,
        do: "memory",
        else: "memories"} across {@memory_summary.event_count} injection{if @memory_summary.event_count !=
                                                                              1,
                                                                            do: "s"} — {@memory_summary.pinned_total} pinned, {@memory_summary.recalled_total} recalled (totals)
    </div>
    <ul class="space-y-1">
      <li :for={row <- @memory_summary.rows} class={["flex items-start gap-2", row_text(@compact)]}>
        <.icon name="hero-book-open-micro" class="size-3 text-primary shrink-0 mt-0.5" />
        <a
          :if={MessageComponents.memory_service_public_url() && row.id}
          href={"#{MessageComponents.memory_service_public_url()}/memories/#{row.id}"}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-hover truncate"
        >
          {row.hook}
        </a>
        <span :if={!(MessageComponents.memory_service_public_url() && row.id)} class="truncate">
          {row.hook}
        </span>
        <span :if={row.kind} class="badge badge-xs badge-outline shrink-0">{row.kind}</span>
        <span
          :if={row.review_status == "pending"}
          class="badge badge-xs badge-ghost shrink-0"
        >
          pending review
        </span>
        <span class="text-xs text-base-content/40 shrink-0 ml-auto whitespace-nowrap">
          <MessageComponents.timestamp value={row.injected_at} />
        </span>
      </li>
    </ul>

    <div class="border-t border-base-300 mt-2 pt-2">
      <div class="text-xs text-base-content/50 mb-1">Created by this session</div>
      <div :if={@created_memories == :loading} class="flex items-center gap-2 text-xs opacity-60">
        <span class="loading loading-spinner loading-xs"></span> Loading…
      </div>
      <div :if={match?({:error, _}, @created_memories)} class="text-xs text-error">
        Could not reach the memory service — try again later.
      </div>
      <%= if match?({:ok, %{memories: []}}, @created_memories) do %>
        <div class="text-xs text-base-content/40">None yet.</div>
      <% end %>
      <%= if match?({:ok, %{memories: [_ | _]}}, @created_memories) do %>
        <% {:ok, %{memories: created, truncated: truncated?}} = @created_memories %>
        <ul class="space-y-1">
          <li :for={m <- created} class={["flex items-start gap-2", row_text(@compact)]}>
            <.icon name="hero-plus-circle-micro" class="size-3 text-primary shrink-0 mt-0.5" />
            <a
              :if={MessageComponents.memory_service_public_url() && m["id"]}
              href={"#{MessageComponents.memory_service_public_url()}/memories/#{m["id"]}"}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-hover truncate"
            >
              {m["hook"] || "(untitled memory)"}
            </a>
            <span
              :if={!(MessageComponents.memory_service_public_url() && m["id"])}
              class="truncate"
            >
              {m["hook"] || "(untitled memory)"}
            </span>
            <span :if={m["kind"]} class="badge badge-xs badge-outline shrink-0">{m["kind"]}</span>
            <span
              :if={m["review_status"] == "pending"}
              class="badge badge-xs badge-ghost shrink-0"
            >
              pending review
            </span>
            <span class="text-xs text-base-content/40 shrink-0 ml-auto whitespace-nowrap">
              {m["created_by"]}
            </span>
          </li>
        </ul>
        <div :if={truncated?} class="text-xs text-base-content/40 mt-1">showing 50</div>
      <% end %>
    </div>
    """
  end

  defp format_commit_date(iso_date) do
    case DateTime.from_iso8601(iso_date) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%b %d, %H:%M")

      _ ->
        iso_date
    end
  end
end
