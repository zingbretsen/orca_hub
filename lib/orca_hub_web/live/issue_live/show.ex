defmodule OrcaHubWeb.IssueLive.Show do
  @moduledoc """
  Single-issue view — see OrcaHubWeb.IssueLive.Index moduledoc. Otherwise
  read-only; the one action is closing/reopening, both plain status
  transitions via `OrcaHub.HubRPC`.
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.HubRPC

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    issue = HubRPC.get_issue!(id)
    {:ok, assign(socket, page_title: issue.title, issue: issue)}
  end

  @impl true
  def handle_event("close", _params, socket) do
    {:ok, issue} = HubRPC.close_issue(socket.assigns.issue)
    {:noreply, assign(socket, issue: issue)}
  end

  @impl true
  def handle_event("reopen", _params, socket) do
    {:ok, issue} = HubRPC.reopen_issue(socket.assigns.issue)
    {:noreply, assign(socket, issue: issue)}
  end
end
