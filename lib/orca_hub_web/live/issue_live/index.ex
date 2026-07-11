defmodule OrcaHubWeb.IssueLive.Index do
  @moduledoc """
  Read-only listing of the agent-filed (and any human-filed) issue backlog.

  Deliberately minimal per `OrcaHub.Issues`' moduledoc — no create/edit/
  delete UI, just enough to browse what `file_feature_request` has been
  filing. Closed issues render dimmed, sorted after open ones. Closing/
  reopening itself lives on `IssueLive.Show`, the one status-change action
  this UI supports.
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.HubRPC

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Issues", issues: HubRPC.list_issues())}
  end

  # Best-effort `Category: ...` line parsed out of the provenance block
  # file_feature_request appends. `nil` when absent (e.g. a human-filed
  # issue).
  defp category(%{description: description}) when is_binary(description) do
    case Regex.run(~r/^Category:\s*(.+)$/m, description) do
      [_, category] -> String.trim(category)
      nil -> nil
    end
  end

  defp category(_issue), do: nil
end
