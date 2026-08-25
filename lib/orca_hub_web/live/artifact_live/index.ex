defmodule OrcaHubWeb.ArtifactLive.Index do
  @moduledoc """
  Top-level artifacts nav page at `/artifacts` — every artifact across
  every project in one place, optimized for "open my grocery list in one
  click, from anywhere" (see `OrcaHub.Artifacts` moduledoc for the
  underlying user-state persistence this page is meant to surface).

  A **Pinned** section (ordered by `pinned_at`, most recently pinned
  first) sits above the rest, which is grouped by project the same way
  `SessionLive.Index` groups sessions by directory — one `.table` per
  group, source list pre-sorted by `updated_at` descending so group order
  falls out naturally (most-recently-active project's group first).

  Deliberately DB-only (no `Cluster`/`NodeFilter` involvement, unlike
  Sessions/Terminals): artifacts live in the one Postgres DB on the hub
  regardless of which node's project created them, so this is a plain
  `HubRPC` read/write page — same shape as `IssueLive.Index`.
  """

  use OrcaHubWeb, :live_view

  alias OrcaHub.HubRPC

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifacts")
    end

    socket =
      socket
      |> assign(
        page_title: "Artifacts",
        name_filter: "",
        project_filter: "",
        projects: HubRPC.list_projects()
      )
      |> reload_artifacts()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter_name", %{"name" => name}, socket) do
    {:noreply, socket |> assign(:name_filter, name) |> reload_artifacts()}
  end

  def handle_event("filter_project", %{"project_id" => project_id}, socket) do
    {:noreply, socket |> assign(:project_filter, project_id) |> reload_artifacts()}
  end

  def handle_event("pin", %{"id" => id}, socket) do
    case find_artifact(socket, id) do
      nil ->
        {:noreply, socket}

      artifact ->
        {:ok, _} = HubRPC.pin_artifact(artifact)
        {:noreply, reload_artifacts(socket)}
    end
  end

  def handle_event("unpin", %{"id" => id}, socket) do
    case find_artifact(socket, id) do
      nil ->
        {:noreply, socket}

      artifact ->
        {:ok, _} = HubRPC.unpin_artifact(artifact)
        {:noreply, reload_artifacts(socket)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case find_artifact(socket, id) do
      nil ->
        {:noreply, socket}

      artifact ->
        {:ok, _} = HubRPC.delete_artifact(artifact)

        {:noreply,
         socket
         |> reload_artifacts()
         |> put_flash(:info, "Artifact \"#{artifact.name}\" deleted.")}
    end
  end

  @impl true
  def handle_info({:artifact_changed, _artifact_id}, socket) do
    {:noreply, reload_artifacts(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp find_artifact(socket, id), do: Enum.find(socket.assigns.artifacts, &(&1.id == id))

  defp empty_message do
    Phoenix.HTML.raw("""
    <p class="mb-2">No artifacts yet.</p>
    <p class="text-xs max-w-md mx-auto">
      Artifacts are rich HTML/SVG/markdown documents an agent session saves with the
      <code class="font-mono">save_artifact</code>
      MCP tool — dashboards, checklists, reports — that outlive the session that made them.
      Ask an agent to save one, or open a project page to see artifacts already created there.
    </p>
    """)
  end

  defp reload_artifacts(socket) do
    opts = %{name: socket.assigns.name_filter, project_id: socket.assigns.project_filter}
    artifacts = HubRPC.list_all_artifacts(opts)
    {pinned, rest} = Enum.split_with(artifacts, & &1.pinned_at)

    assign(socket,
      artifacts: artifacts,
      pinned_artifacts: Enum.sort_by(pinned, & &1.pinned_at, {:desc, DateTime}),
      grouped_artifacts: group_by_project(rest)
    )
  end

  # `artifacts` is already ordered most-recently-updated-first (see
  # OrcaHub.Artifacts.list_all_artifacts/1), so within each group the first
  # element is that project's most recently updated artifact — sorting
  # groups by that gives "most recently active project first" without a
  # second updated_at lookup. Explicit NaiveDateTime comparator per this
  # repo's timestamp-sorting bug class (CLAUDE.md "Common issues").
  defp group_by_project(artifacts) do
    artifacts
    |> Enum.group_by(& &1.project)
    |> Enum.sort_by(
      fn {_project, [most_recent | _]} -> most_recent.updated_at end,
      {:desc, NaiveDateTime}
    )
    |> Enum.map(fn {project, rows} ->
      %{
        key: "project-#{project.id}",
        label: project.name,
        rows: rows,
        count: length(rows),
        icon: "hero-code-bracket-micro",
        navigate: ~p"/projects/#{project.id}"
      }
    end)
  end
end
