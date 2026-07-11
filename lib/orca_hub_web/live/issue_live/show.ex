defmodule OrcaHubWeb.IssueLive.Show do
  @moduledoc "Read-only single-issue view — see OrcaHubWeb.IssueLive.Index moduledoc."
  use OrcaHubWeb, :live_view

  alias OrcaHub.HubRPC

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    issue = HubRPC.get_issue!(id)
    {:ok, assign(socket, page_title: issue.title, issue: issue)}
  end
end
