defmodule OrcaHubWeb.ArtifactLive.Show do
  @moduledoc """
  Fullscreen artifact viewer at `/artifacts/:id` — a bare sandboxed iframe
  plus a minimal header, with a viewport-width toggle for eyeballing
  responsiveness. Reachable directly, or via `open_artifact`/`save_artifact`
  with `mode: "full"` pushing here from `SessionLive.Show`.
  """

  use OrcaHubWeb, :live_view

  alias OrcaHub.HubRPC

  @viewports %{"mobile" => 375, "tablet" => 768, "full" => nil}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case HubRPC.get_artifact(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Artifact not found.")
         |> push_navigate(to: ~p"/projects")}

      artifact ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifact:#{artifact.id}")
        end

        {:ok,
         socket
         |> assign(:artifact, artifact)
         |> assign(:project, HubRPC.get_project(artifact.project_id))
         |> assign(:viewport, "full")
         |> assign(:page_title, artifact.name)}
    end
  end

  @impl true
  def handle_event("set_viewport", %{"viewport" => viewport}, socket) do
    {:noreply, assign(socket, :viewport, viewport)}
  end

  @impl true
  def handle_info({:artifact_updated, artifact}, socket) do
    {:noreply, assign(socket, :artifact, artifact)}
  end

  # Live-data push (OrcaHub.Artifacts.update_artifact_data/2) — no version
  # bump, so no iframe reload; forwarded to the ArtifactData hook instead.
  def handle_info({:artifact_data_updated, artifact}, socket) do
    {:noreply,
     socket
     |> assign(:artifact, artifact)
     |> push_event("artifact_data_updated", %{artifact_id: artifact.id, data: artifact.data})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp viewport_width(viewport), do: @viewports[viewport]

  defp raw_src(artifact), do: ~p"/artifacts/#{artifact.id}/raw?v=#{artifact.version}"
end
