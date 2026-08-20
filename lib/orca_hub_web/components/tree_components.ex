defmodule OrcaHubWeb.TreeComponents do
  @moduledoc """
  Function components + data-shaping helpers for rendering a session's spawn
  tree (grouped by `parent_session_id`, recursively) overlaid with
  cross-session message edges (`session_interactions`). Used by
  `OrcaHubWeb.SessionLive.Show`'s Tree view — scoped to the tree containing
  whatever session is being viewed, unlike the removed standalone
  `/sessions/tree` page this was extracted from.
  """

  use OrcaHubWeb, :html

  @doc """
  Groups `members` (every session in a tree, root included) by
  `parent_session_id`, newest-updated first — the map `tree_node/1` recurses
  through to find each node's children, however deep the chain goes.
  """
  def group_children_by_parent(members) do
    members
    |> Enum.reject(&is_nil(&1.parent_session_id))
    |> Enum.group_by(& &1.parent_session_id)
    |> Map.new(fn {parent_id, kids} ->
      {parent_id, Enum.sort_by(kids, & &1.updated_at, {:desc, NaiveDateTime})}
    end)
  end

  # One chip per ordered (sender, recipient, kind) triple, folding repeat
  # edges of the SAME kind into a count instead of one chip per row — a
  # "message" edge and a "handoff" edge between the same pair stay as two
  # separate chips rather than being merged (kind is otherwise unrelated
  # information and folding them together would hide it). Resolves the
  # OTHER end's title from `sessions_by_id` when it's a member of this tree
  # (`clickable: true`); when it points outside the tree, does a single bulk
  # id->title lookup for every such id (never per-chip) and falls back to a
  # short id if even that comes up empty (a session that's been fully
  # deleted, if that's ever possible, or a lookup timing gap).
  @doc """
  Builds `%{session_id => %{sent: [...], received: [...]}}` chip lists from
  `session_interactions` edges touching this tree. `sessions_by_id` is every
  member of the tree (see `group_children_by_parent/1`); the far end of an
  edge that isn't a member renders disabled with its title resolved via a
  single bulk lookup. Each chip carries the edge's `kind` (`"message"`,
  `"handoff"`, `"fork"`, ...) so the caller can render non-"message" kinds
  distinctly.
  """
  def build_edges(interactions, sessions_by_id) do
    missing_ids =
      interactions
      |> Enum.flat_map(&[&1.sender_session_id, &1.recipient_session_id])
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(sessions_by_id, &1))

    extra_titles =
      case missing_ids do
        [] -> %{}
        ids -> OrcaHub.HubRPC.list_sessions_by_ids(ids) |> Map.new(&{&1.id, &1.title})
      end

    interactions
    |> Enum.group_by(fn i -> {i.sender_session_id, i.recipient_session_id, i.kind} end)
    |> Enum.reduce(%{}, fn {{sender_id, recipient_id, kind}, edges}, acc ->
      count = length(edges)

      acc
      |> maybe_add_chip(sender_id, sessions_by_id, :sent, %{
        target_id: recipient_id,
        title: title_for(recipient_id, sessions_by_id, extra_titles),
        count: count,
        kind: kind,
        clickable: Map.has_key?(sessions_by_id, recipient_id)
      })
      |> maybe_add_chip(recipient_id, sessions_by_id, :received, %{
        target_id: sender_id,
        title: title_for(sender_id, sessions_by_id, extra_titles),
        count: count,
        kind: kind,
        clickable: Map.has_key?(sessions_by_id, sender_id)
      })
    end)
  end

  # A chip only renders on a node that's actually a member of this tree —
  # the far end of an edge whose OWN node isn't a member contributes titles
  # (via extra_titles above) but never gets a chip list of its own.
  defp maybe_add_chip(acc, owner_id, sessions_by_id, direction, chip) do
    if Map.has_key?(sessions_by_id, owner_id) do
      default = Map.put(%{sent: [], received: []}, direction, [chip])

      Map.update(acc, owner_id, default, fn edges ->
        Map.update!(edges, direction, &[chip | &1])
      end)
    else
      acc
    end
  end

  defp title_for(id, sessions_by_id, extra_titles) do
    title =
      case Map.get(sessions_by_id, id) do
        %{title: t} -> t
        nil -> Map.get(extra_titles, id)
      end

    if title in [nil, ""], do: short_id(id), else: title
  end

  def short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  def short_id(id), do: to_string(id)

  @doc """
  Background-color class for the compact status dot on a node's primary
  line (mobile-friendly stand-in for the old full status badge — see
  `node_title_and_badges/1`).
  """
  def status_dot_class(status) do
    case status do
      "running" -> "bg-warning"
      "compacting" -> "bg-warning"
      "waiting" -> "bg-info"
      "idle" -> "bg-success"
      "ready" -> "bg-base-300"
      "error" -> "bg-error"
      _ -> "bg-base-300"
    end
  end

  def truncate(nil, _len), do: ""

  def truncate(text, len) do
    if String.length(text) > len do
      String.slice(text, 0, len) <> "…"
    else
      text
    end
  end

  # -------------------------------------------------------------------
  # Recursive tree rendering. One session per node; children rendered by
  # recursing into `<.tree_node>` again for whatever's under
  # `children_by_parent[session.id]` — covers arbitrary spawn depth (child,
  # grandchild, ...) without the caller needing to know how deep the chain
  # goes.
  #
  # The per-node compose button lives OUTSIDE the `<summary>` (as a flex
  # sibling of the `<details>`/leaf row, not nested inside it) — a button
  # nested inside a `<summary>` would have its click bubble up and toggle
  # the disclosure too, since the whole summary is natively one click
  # target.
  # -------------------------------------------------------------------

  attr :root, :map, required: true
  attr :children_by_parent, :map, required: true
  attr :edges_by_session, :map, required: true
  attr :subagents, :map, required: true
  attr :has_subagents, :map, required: true
  attr :current_session_id, :string, required: true

  def tree_view(assigns) do
    ~H"""
    <div id="session-tree-root" phx-hook="ScrollHighlightTarget" class="space-y-1">
      <.tree_node
        session={@root}
        children_by_parent={@children_by_parent}
        edges_by_session={@edges_by_session}
        subagents={@subagents}
        has_subagents={@has_subagents}
        current_session_id={@current_session_id}
      />
    </div>
    """
  end

  attr :session, :map, required: true
  attr :children_by_parent, :map, required: true
  attr :edges_by_session, :map, required: true
  attr :subagents, :map, required: true
  attr :has_subagents, :map, required: true
  attr :current_session_id, :string, required: true

  defp tree_node(assigns) do
    children = Map.get(assigns.children_by_parent, assigns.session.id, [])
    edges = Map.get(assigns.edges_by_session, assigns.session.id, %{sent: [], received: []})

    assigns =
      assigns
      |> assign(:children, children)
      |> assign(:edges, edges)
      |> assign(:subagent_list, Map.get(assigns.subagents, assigns.session.id))
      |> assign(:subagent_count, Map.get(assigns.has_subagents, assigns.session.id))
      |> assign(:current?, assigns.session.id == assigns.current_session_id)

    ~H"""
    <div
      id={"session-node-#{@session.id}"}
      class={
        [
          "rounded-lg transition-shadow",
          # outline-*, not ring-* — ScrollHighlightTarget's flash-on-click
          # (app.js) toggles ring-* classes via classList, which would
          # otherwise clobber this session's permanent "you are here"
          # highlight after its 1.5s timeout fires.
          @current? && "outline outline-2 outline-primary outline-offset-2"
        ]
      }
    >
      <div class="flex items-center gap-1">
        <%= if @children != [] do %>
          <details class="group/node min-w-0 flex-1" open>
            <summary class="list-none cursor-pointer flex items-center gap-1.5 rounded-lg px-1.5 py-1 hover:bg-base-200 transition-colors min-w-0">
              <.icon
                name="hero-chevron-right-micro"
                class="size-4 shrink-0 transition-transform group-open/node:rotate-90"
              />
              <.node_title_and_badges session={@session} />
            </summary>
            <div class="ml-3 sm:ml-6 mt-0.5">
              <.node_chips_and_subagents
                edges={@edges}
                session={@session}
                subagent_list={@subagent_list}
                subagent_count={@subagent_count}
              />
              <div class="border-l border-base-300 pl-1.5 ml-1.5 sm:pl-2 sm:ml-2 mt-1 space-y-1">
                <.tree_node
                  :for={child <- @children}
                  session={child}
                  children_by_parent={@children_by_parent}
                  edges_by_session={@edges_by_session}
                  subagents={@subagents}
                  has_subagents={@has_subagents}
                  current_session_id={@current_session_id}
                />
              </div>
            </div>
          </details>
        <% else %>
          <div class="flex items-center gap-1.5 rounded-lg px-1.5 py-1 min-w-0 flex-1">
            <span class="size-4 shrink-0"></span>
            <.node_title_and_badges session={@session} />
          </div>
        <% end %>
        <.compose_button session={@session} />
      </div>
      <div :if={@children == []} class="ml-3 sm:ml-6 mt-0.5">
        <.node_chips_and_subagents
          edges={@edges}
          session={@session}
          subagent_list={@subagent_list}
          subagent_count={@subagent_count}
        />
      </div>
    </div>
    """
  end

  # Compact node row: one primary line (status dot + truncated title) plus,
  # when there's anything to say, ONE secondary muted line for everything
  # else (status word, backend, model, runner node, archived, progress
  # phase) — replaces the old pile of wrapping outline badges, which is what
  # made mobile nodes sprawl over many lines.
  attr :session, :map, required: true

  defp node_title_and_badges(assigns) do
    assigns = assign(assigns, :meta_line, node_meta_line(assigns.session))

    ~H"""
    <div class="min-w-0 flex-1">
      <div class="flex items-center gap-1.5 min-w-0">
        <span
          class={["inline-block size-2.5 rounded-full shrink-0", status_dot_class(@session.status)]}
          title={@session.status}
        >
        </span>
        <.link
          navigate={~p"/sessions/#{@session.id}"}
          class="link link-hover font-medium truncate min-w-0"
        >
          {@session.title || @session.directory}
        </.link>
      </div>
      <div :if={@meta_line != ""} class="text-xs text-base-content/50 truncate pl-4">
        {@meta_line}
      </div>
    </div>
    """
  end

  defp node_meta_line(session) do
    [
      session.status,
      session.backend,
      (session.model not in [nil, ""] && session.model) || nil,
      (session.runner_node not in [nil, ""] &&
         OrcaHub.Cluster.node_name(session.runner_node)) || nil,
      (session.archived_at && "archived") || nil,
      (session.progress_phase not in [nil, ""] && session.progress_phase) || nil
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join(" · ")
  end

  attr :session, :map, required: true

  defp compose_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_tree_compose"
      phx-value-id={@session.id}
      phx-value-title={@session.title || @session.directory}
      class="btn btn-ghost btn-xs btn-circle shrink-0"
      title="Message this session"
    >
      <.icon name="hero-paper-airplane-micro" class="size-3" />
    </button>
    """
  end

  attr :edges, :map, required: true
  attr :session, :map, required: true
  attr :subagent_list, :list, default: nil
  attr :subagent_count, :integer, default: nil

  defp node_chips_and_subagents(assigns) do
    assigns =
      assigns
      |> assign(:sent_total, Enum.sum(Enum.map(assigns.edges.sent, & &1.count)))
      |> assign(:received_total, Enum.sum(Enum.map(assigns.edges.received, & &1.count)))

    ~H"""
    <details :if={@sent_total > 0 or @received_total > 0} class="group/edges mb-1">
      <summary class="list-none cursor-pointer inline-flex items-center gap-1 text-xs opacity-60 hover:opacity-100 transition-opacity">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 transition-transform group-open/edges:rotate-90"
        />
        <span :if={@sent_total > 0}>→ {@sent_total} sent</span>
        <span :if={@sent_total > 0 and @received_total > 0}>·</span>
        <span :if={@received_total > 0}>← {@received_total} received</span>
      </summary>
      <div class="ml-4 mt-1 flex flex-wrap gap-1">
        <.edge_chip :for={chip <- @edges.sent} chip={chip} arrow="→" />
        <.edge_chip :for={chip <- @edges.received} chip={chip} arrow="←" />
      </div>
    </details>

    <details :if={@subagent_count} class="group/subagents mb-1">
      <summary
        phx-click="toggle_subagents"
        phx-value-id={@session.id}
        class="list-none cursor-pointer inline-flex items-center gap-1 text-xs opacity-60 hover:opacity-100 transition-opacity"
      >
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 transition-transform group-open/subagents:rotate-90"
        /> Subagents ({@subagent_count})
      </summary>
      <div class="ml-4 mt-1 space-y-0.5">
        <p :if={@subagent_list == nil} class="text-xs text-base-content/40 italic">Loading…</p>
        <p :if={@subagent_list == []} class="text-xs text-base-content/40 italic">
          No subagent invocations.
        </p>
        <div :for={sa <- @subagent_list || []} class="text-xs">
          <span class="font-mono text-primary">{sa.subagent_type || "subagent"}</span>
          <span class="opacity-60">— {truncate(sa.description, 100)}</span>
        </div>
      </div>
    </details>
    """
  end

  # `max-w` + `truncate` on the title span (rather than letting the whole
  # chip wrap) is what fixes the old bug where a long title, especially on a
  # disabled/out-of-tree chip, wrapped onto multiple lines and visually
  # overlapped its neighbors.
  attr :chip, :map, required: true
  attr :arrow, :string, required: true

  defp edge_chip(assigns) do
    assigns = assign(assigns, :kind_label, chip_kind_label(assigns.chip.kind))

    ~H"""
    <button
      type="button"
      disabled={!@chip.clickable}
      phx-click={
        @chip.clickable &&
          JS.dispatch("orca:scroll-to-session",
            to: "#session-tree-root",
            detail: %{id: @chip.target_id}
          )
      }
      class={[
        "badge badge-sm badge-outline gap-1 max-w-[10rem] sm:max-w-[16rem] overflow-hidden",
        @chip.clickable && "cursor-pointer hover:badge-primary",
        !@chip.clickable && "opacity-40 cursor-not-allowed"
      ]}
      title={
        (if @chip.clickable, do: "", else: "Outside this tree — ") <>
          @chip.title <> (if @kind_label, do: " (#{@kind_label})", else: "")
      }
    >
      <span class="shrink-0">{@arrow}</span>
      <span :if={@kind_label} class="shrink-0 uppercase text-[0.6rem] tracking-wide opacity-70">
        {@kind_label}
      </span>
      <span class="truncate">{@chip.title}</span>
      <span :if={@chip.count > 1} class="shrink-0">×{@chip.count}</span>
    </button>
    """
  end

  # "message" is the overwhelmingly common kind and gets no visual tag at
  # all — only a non-default kind (currently "handoff" or "fork") earns one.
  defp chip_kind_label(kind) when kind in [nil, "message"], do: nil
  defp chip_kind_label(kind), do: kind
end
