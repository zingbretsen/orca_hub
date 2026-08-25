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

  def handle_event("pin", %{"id" => id}, socket) do
    case find_issue(socket, id) do
      nil ->
        {:noreply, socket}

      issue ->
        {:ok, _} = HubRPC.pin_issue(issue)
        {:noreply, reload_issues(socket)}
    end
  end

  def handle_event("unpin", %{"id" => id}, socket) do
    case find_issue(socket, id) do
      nil ->
        {:noreply, socket}

      issue ->
        {:ok, _} = HubRPC.unpin_issue(issue)
        {:noreply, reload_issues(socket)}
    end
  end

  defp find_issue(socket, id), do: Enum.find(socket.assigns.issues, &(&1.id == id))

  defp reload_issues(socket) do
    issues =
      HubRPC.list_issues(%{
        status: socket.assigns.status_filter,
        kind: socket.assigns.kind_filter,
        limit: 200
      })

    {pinned, rest} = Enum.split_with(issues, & &1.pinned_at)

    pinned_list = Enum.sort_by(pinned, & &1.pinned_at, {:desc, DateTime})
    groups = group_by_project(rest)

    assign(socket,
      issues: issues,
      pinned: pinned_list,
      groups: groups
    )
  end

  defp group_by_project(issues) do
    {unassigned, assigned} = Enum.split_with(issues, &is_nil(&1.project))

    unassigned_group =
      if unassigned != [] do
        [
          %{
            key: "unassigned",
            label: "Unassigned",
            rows: unassigned,
            icon: "hero-folder-micro",
            count: length(unassigned)
          }
        ]
      else
        []
      end

    assigned
    |> Enum.group_by(& &1.project)
    |> Enum.map(fn {project, rows} ->
      %{
        key: project.id,
        label: project.name,
        rows: rows,
        icon: "hero-folder-micro",
        count: length(rows)
      }
    end)
    |> Enum.sort_by(& &1.label)
    |> Kernel.++(unassigned_group)
  end

  defp kind_filters, do: @kind_filters
  defp status_filters, do: @status_filters

  @doc false
  def issue_key(issue), do: HubRPC.render_issue_key(issue)
end
