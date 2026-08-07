defmodule OrcaHubWeb.IssueLive.Index do
  @moduledoc """
  Listing of durable work items (issues_spec.md) — both `kind`s (`task` and
  `feature_request`) in one table, filterable by `kind` and `status`. The
  feature-request board is now just this list with `kind: "feature_request"`
  selected (§8), not a separate view.

  Deliberately minimal beyond that — no create/edit/delete UI here; filing
  is agent-driven (`create_issue`). Closing/reopening lives on
  `IssueLive.Show`, the one status-change action this UI supports. No
  `attempts`/`commits` fan-out is loaded here — that's a show-page-only
  concern (issues_spec.md §3.5), since it's a live git-log walk per open
  issue's attempts and would be far too expensive to run for an entire
  index page of issues.
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.HubRPC

  @kind_filters [{"All kinds", "all"}, {"Task", "task"}, {"Feature request", "feature_request"}]
  @status_filters [
    {"Open", "open"},
    {"In progress", "in_progress"},
    {"Closed", "closed"},
    {"Abandoned", "abandoned"},
    {"All", "all"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Issues", kind_filter: "all", status_filter: "all")
      |> reload_issues()

    {:ok, socket}
  end

  @impl true
  def handle_event("set_kind_filter", %{"kind" => kind}, socket) do
    {:noreply, socket |> assign(:kind_filter, kind) |> reload_issues()}
  end

  def handle_event("set_status_filter", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> reload_issues()}
  end

  defp reload_issues(socket) do
    issues =
      HubRPC.list_issues(%{
        status: socket.assigns.status_filter,
        kind: socket.assigns.kind_filter,
        limit: 200
      })

    assign(socket, :issues, issues)
  end

  defp kind_filters, do: @kind_filters
  defp status_filters, do: @status_filters

  @doc false
  def issue_key(issue), do: HubRPC.render_issue_key(issue)
end
