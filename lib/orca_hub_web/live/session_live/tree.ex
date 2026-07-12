defmodule OrcaHubWeb.SessionLive.Tree do
  @moduledoc """
  `/sessions/tree` — the session graph page: a collapsible spawn forest
  (grouped by `parent_session_id`, recursively) overlaid with cross-session
  message edges (`session_interactions`, backend_abstraction-adjacent data
  layer added in the "session_interactions" commit). See the module doc on
  `OrcaHub.Sessions.SessionInteraction` for how the two relationship types
  differ.

  Follows `SessionLive.Index`'s canonical live-update pattern: subscribe to
  the `"sessions"` PubSub topic once connected, and on ANY message on that
  topic just reload the whole visible set rather than diffing individual
  events — simplest correct approach for a page that's read-only anyway.
  """

  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}
  alias OrcaHubWeb.NodeFilter

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    {:ok,
     socket
     |> assign(:page_title, "Session Tree")
     |> assign(:scope, :recent)
     # session_id => list of %{id, subagent_type, description} once fetched;
     # absent key = never expanded yet (genuinely lazy, see
     # handle_event("toggle_subagents", ...) below).
     |> assign(:subagents, %{})
     |> load_tree_data()}
  end

  @impl true
  def handle_event("toggle_scope", _params, socket) do
    scope = if socket.assigns.scope == :recent, do: :all, else: :recent

    {:noreply,
     socket
     |> assign(:scope, scope)
     |> load_tree_data()}
  end

  def handle_event("toggle_subagents", %{"id" => session_id}, socket) do
    subagents = socket.assigns.subagents

    # <details>'s open/closed state lives client-side (native browser
    # behavior — see structured_editor.ex's same convention); this handler
    # only needs to run the fetch once per session, idempotently, on
    # whichever click first opens it. Re-collapsing (or re-expanding after
    # collapse) fires this event again but hits the cache, no refetch.
    subagents =
      if Map.has_key?(subagents, session_id) do
        subagents
      else
        Map.put(subagents, session_id, HubRPC.list_task_invocations(session_id))
      end

    {:noreply, assign(socket, :subagents, subagents)}
  end

  @impl true
  def handle_info({_session_id, _payload}, socket) do
    {:noreply, load_tree_data(socket)}
  end

  # Invoked by the NodeFilter on_mount hook's handle_info(:node_filter_changed, ...)
  # via function_exported?/3 — same contract as SessionLive.Index.
  def reload_for_node_filter(socket), do: {:noreply, load_tree_data(socket)}

  defp load_tree_data(socket) do
    tagged_sessions =
      Cluster.list_sessions_for_tree(socket.assigns.scope)
      |> NodeFilter.filter_tagged(socket.assigns.node_filter)

    sessions = Enum.map(tagged_sessions, fn {_node, session} -> session end)
    session_ids = Enum.map(sessions, & &1.id)
    sessions_by_id = Map.new(sessions, &{&1.id, &1})

    {roots, children_by_parent} = build_tree(sessions, sessions_by_id)

    interactions = HubRPC.list_session_interactions_for_sessions(session_ids)
    edges_by_session = build_edges(interactions, sessions_by_id)

    socket
    |> assign(:roots, roots)
    |> assign(:children_by_parent, children_by_parent)
    |> assign(:edges_by_session, edges_by_session)
  end

  # Roots = no parent, or a parent that isn't in the fetched set (e.g.
  # archived/filtered out) — those sessions render at the top level instead
  # of vanishing. Every other session is grouped under its parent id;
  # `children_by_parent` covers arbitrary depth since a grandchild's parent
  # (the child) is itself just another key in the same map, walked
  # recursively by `tree_node/1` in the template.
  defp build_tree(sessions, sessions_by_id) do
    {roots, children} =
      Enum.split_with(sessions, fn s ->
        is_nil(s.parent_session_id) or not Map.has_key?(sessions_by_id, s.parent_session_id)
      end)

    children_by_parent =
      children
      |> Enum.group_by(& &1.parent_session_id)
      |> Map.new(fn {parent_id, kids} ->
        {parent_id, Enum.sort_by(kids, & &1.updated_at, {:desc, NaiveDateTime})}
      end)

    {Enum.sort_by(roots, & &1.updated_at, {:desc, NaiveDateTime}), children_by_parent}
  end

  # One chip per ordered (sender, recipient) pair, folding repeat edges into
  # a count instead of one chip per row. Resolves the OTHER end's title from
  # `sessions_by_id` when it's in the visible set (`clickable: true`); when
  # it's been filtered out, does a single bulk id->title lookup for every
  # such id across the whole page (never per-chip) and falls back to a short
  # id if even that comes up empty (a session that's been fully deleted, if
  # that's ever possible, or a lookup timing gap).
  defp build_edges(interactions, sessions_by_id) do
    missing_ids =
      interactions
      |> Enum.flat_map(&[&1.sender_session_id, &1.recipient_session_id])
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(sessions_by_id, &1))

    extra_titles =
      case missing_ids do
        [] -> %{}
        ids -> HubRPC.list_sessions_by_ids(ids) |> Map.new(&{&1.id, &1.title})
      end

    interactions
    |> Enum.group_by(fn i -> {i.sender_session_id, i.recipient_session_id} end)
    |> Enum.reduce(%{}, fn {{sender_id, recipient_id}, edges}, acc ->
      count = length(edges)

      acc
      |> maybe_add_chip(sender_id, sessions_by_id, :sent, %{
        target_id: recipient_id,
        title: title_for(recipient_id, sessions_by_id, extra_titles),
        count: count,
        clickable: Map.has_key?(sessions_by_id, recipient_id)
      })
      |> maybe_add_chip(recipient_id, sessions_by_id, :received, %{
        target_id: sender_id,
        title: title_for(sender_id, sessions_by_id, extra_titles),
        count: count,
        clickable: Map.has_key?(sessions_by_id, sender_id)
      })
    end)
  end

  # A chip only renders on a node that's actually in the visible set — the
  # far end of an edge whose OWN node got filtered out contributes titles
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

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: to_string(id)

  def status_badge_class(status) do
    case status do
      "running" -> "badge-warning"
      "compacting" -> "badge-warning"
      "waiting" -> "badge-info"
      "idle" -> "badge-success"
      "ready" -> "badge-ghost"
      "error" -> "badge-error"
      _ -> "badge-ghost"
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
  # goes. Mirrors structured_editor.ex's `node_view/1` recursion pattern.
  # -------------------------------------------------------------------

  attr :session, :map, required: true
  attr :children_by_parent, :map, required: true
  attr :edges_by_session, :map, required: true
  attr :subagents, :map, required: true

  defp tree_node(assigns) do
    children = Map.get(assigns.children_by_parent, assigns.session.id, [])
    edges = Map.get(assigns.edges_by_session, assigns.session.id, %{sent: [], received: []})

    assigns =
      assigns
      |> assign(:children, children)
      |> assign(:edges, edges)
      |> assign(:subagent_list, Map.get(assigns.subagents, assigns.session.id))

    ~H"""
    <div id={"session-node-#{@session.id}"} class="rounded-lg transition-shadow">
      <%= if @children != [] do %>
        <details class="group/node" open>
          <summary class="list-none cursor-pointer flex flex-wrap items-center gap-1.5 rounded-lg px-1.5 py-1 hover:bg-base-200 transition-colors">
            <.icon
              name="hero-chevron-right-micro"
              class="size-4 shrink-0 transition-transform group-open/node:rotate-90"
            />
            <.node_title_and_badges session={@session} />
          </summary>
          <div class="ml-6 mt-0.5">
            <.node_chips_and_subagents
              edges={@edges}
              session={@session}
              subagent_list={@subagent_list}
            />
            <div class="border-l border-base-300 pl-2 ml-2 mt-1 space-y-1">
              <.tree_node
                :for={child <- @children}
                session={child}
                children_by_parent={@children_by_parent}
                edges_by_session={@edges_by_session}
                subagents={@subagents}
              />
            </div>
          </div>
        </details>
      <% else %>
        <div class="flex flex-wrap items-center gap-1.5 rounded-lg px-1.5 py-1">
          <span class="size-4 shrink-0"></span>
          <.node_title_and_badges session={@session} />
        </div>
        <div class="ml-6 mt-0.5">
          <.node_chips_and_subagents edges={@edges} session={@session} subagent_list={@subagent_list} />
        </div>
      <% end %>
    </div>
    """
  end

  attr :session, :map, required: true

  defp node_title_and_badges(assigns) do
    ~H"""
    <.link navigate={~p"/sessions/#{@session.id}"} class="link link-hover font-medium">
      {@session.title || @session.directory}
    </.link>
    <span class={["badge badge-sm", status_badge_class(@session.status)]}>{@session.status}</span>
    <span class="badge badge-sm badge-outline opacity-60">{@session.backend}</span>
    <span
      :if={@session.runner_node not in [nil, ""]}
      class="badge badge-sm badge-ghost opacity-60"
    >
      {OrcaHub.Cluster.node_name(@session.runner_node)}
    </span>
    <span
      :if={@session.progress_phase not in [nil, ""]}
      class="badge badge-sm badge-info badge-outline"
    >
      {@session.progress_phase}
    </span>
    """
  end

  attr :edges, :map, required: true
  attr :session, :map, required: true
  attr :subagent_list, :list, default: nil

  defp node_chips_and_subagents(assigns) do
    ~H"""
    <div :if={@edges.sent != [] or @edges.received != []} class="flex flex-wrap gap-1 mb-1">
      <.edge_chip :for={chip <- @edges.sent} chip={chip} arrow="→" />
      <.edge_chip :for={chip <- @edges.received} chip={chip} arrow="←" />
    </div>

    <details class="group/subagents mb-1">
      <summary
        phx-click="toggle_subagents"
        phx-value-id={@session.id}
        class="list-none cursor-pointer inline-flex items-center gap-1 text-xs opacity-60 hover:opacity-100 transition-opacity"
      >
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 transition-transform group-open/subagents:rotate-90"
        /> Subagents
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

  attr :chip, :map, required: true
  attr :arrow, :string, required: true

  defp edge_chip(assigns) do
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
        "badge badge-sm badge-outline gap-1",
        @chip.clickable && "cursor-pointer hover:badge-primary",
        !@chip.clickable && "opacity-40 cursor-not-allowed"
      ]}
    >
      {@arrow} {@chip.title}<span :if={@chip.count > 1}>×{@chip.count}</span>
    </button>
    """
  end
end
