defmodule OrcaHubWeb.IdleBadgeLive do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Cluster

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    {:ok, assign(socket, idle_count: Cluster.count_idle_sessions()), layout: false}
  end

  def render(assigns) do
    ~H"""
    <span :if={@idle_count > 0} class="badge badge-sm badge-primary">{@idle_count}</span>
    """
  end

  def handle_info({_session_id, {:status, _status}}, socket) do
    {:noreply, assign(socket, idle_count: Cluster.count_idle_sessions())}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
