defmodule OrcaHubWeb.IdleBadgeLive do
  @moduledoc """
  The idle-session count next to the Queue nav link. `OrcaHubWeb.Layouts`
  renders it twice, once in the desktop nav and once in the mobile menu,
  since a LiveView can only occupy one place in the DOM.

  Only ONE of the two does any work. The `"primary"` instance (desktop)
  subscribes to `"sessions"`, re-counts on each status change, and hands the
  number to its `"mirror"` (mobile) over a topic private to this browser
  tab's socket. The mirror never queries or subscribes to `"sessions"`; it
  asks the primary for the current count when it connects. Before that, on
  the dead render, it renders nothing: it lives in the closed mobile menu,
  and both badges show the same count once the socket is up.

  Before this split each instance counted on every status broadcast, so
  every open tab ran two identical count queries per session status change,
  and four per page load.
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.Cluster

  def mount(_params, session, socket) do
    role = Map.get(session, "role", "primary")
    socket = assign(socket, role: role, idle_count: 0)

    socket =
      cond do
        role == "primary" ->
          if connected?(socket) do
            Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
            Phoenix.PubSub.subscribe(OrcaHub.PubSub, pair_topic(socket))
          end

          socket |> assign(idle_count: Cluster.count_idle_sessions()) |> share_count()

        connected?(socket) ->
          Phoenix.PubSub.subscribe(OrcaHub.PubSub, pair_topic(socket))
          broadcast_pair(socket, :idle_badge_hello)
          socket

        true ->
          socket
      end

    {:ok, socket, layout: false}
  end

  def render(assigns) do
    ~H"""
    <span :if={@idle_count > 0} class="badge badge-sm badge-primary">{@idle_count}</span>
    """
  end

  def handle_info({_session_id, {:status, _status}}, %{assigns: %{role: "primary"}} = socket) do
    {:noreply, socket |> assign(idle_count: Cluster.count_idle_sessions()) |> share_count()}
  end

  def handle_info(:idle_badge_hello, %{assigns: %{role: "primary"}} = socket) do
    {:noreply, share_count(socket)}
  end

  def handle_info({:idle_badge_count, count}, %{assigns: %{role: "mirror"}} = socket) do
    {:noreply, assign(socket, idle_count: count)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp share_count(socket) do
    if connected?(socket),
      do: broadcast_pair(socket, {:idle_badge_count, socket.assigns.idle_count})

    socket
  end

  # Both instances are sticky children of the same page, so they share the
  # socket's transport process. Another tab has its own, and so does this tab
  # after a reconnect (which re-mounts both).
  defp pair_topic(socket), do: "idle_badge:" <> inspect(socket.transport_pid)

  defp broadcast_pair(socket, message),
    do: Phoenix.PubSub.broadcast_from(OrcaHub.PubSub, self(), pair_topic(socket), message)
end
