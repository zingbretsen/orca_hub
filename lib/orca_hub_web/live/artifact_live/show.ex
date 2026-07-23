defmodule OrcaHubWeb.ArtifactLive.Show do
  @moduledoc """
  Fullscreen artifact viewer at `/artifacts/:id` — a bare sandboxed iframe
  plus a minimal header, with a viewport-width toggle for eyeballing
  responsiveness. Reachable directly, or via `open_artifact`/`save_artifact`
  with `mode: "full"` pushing here from `SessionLive.Show`.
  """

  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC, NodePolicy}
  alias OrcaHubWeb.ArtifactSend

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
         |> assign(:page_title, artifact.name)
         |> assign(:artifact_send_throttle, %{})}
    end
  end

  @impl true
  def handle_event("set_viewport", %{"viewport" => viewport}, socket) do
    {:noreply, assign(socket, :viewport, viewport)}
  end

  # orca.send bidirectional bridge (Artifacts Phase 3): there's no "session
  # being viewed" here (unlike SessionLive.Show's split panel), so deliver
  # to the artifact's CREATOR session instead — reusing the exact
  # find-node/allow/start-if-not-alive/send seam
  # `OrcaHub.MCP.Tools.Sessions.call("send_message_to_session", ...)` uses,
  # including the automatic unarchive `Cluster.send_message/3` gives every
  # caller.
  def handle_event("artifact_send", %{"artifact_id" => artifact_id, "payload" => payload}, socket) do
    if artifact_id != socket.assigns.artifact.id do
      {:noreply, socket}
    else
      if ArtifactSend.too_large?(payload) do
        {:noreply,
         put_flash(socket, :error, "Artifact interaction payload too large (max 16KB) — dropped.")}
      else
        case ArtifactSend.check_throttle(socket.assigns.artifact_send_throttle, artifact_id) do
          :throttled ->
            {:noreply,
             put_flash(socket, :error, "Artifact is sending too fast — interaction dropped.")}

          {:ok, throttle} ->
            socket
            |> assign(:artifact_send_throttle, throttle)
            |> deliver_to_creator_session(payload)
        end
      end
    end
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

  defp deliver_to_creator_session(socket, payload) do
    artifact = socket.assigns.artifact

    case artifact.session_id && Cluster.find_session(artifact.session_id) do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This artifact's creator session no longer exists — there's nothing to receive the interaction."
         )}

      {node, session} ->
        if NodePolicy.cross_node_allowed?(node) do
          unless Cluster.session_alive?(node, session.id) do
            Cluster.start_session(node, session.id, session)
          end

          message = ArtifactSend.format_message(artifact.name, payload)

          case Cluster.send_message(node, session.id, message) do
            :ok ->
              {:noreply, put_flash(socket, :info, "Sent to session.")}

            {:error, reason} ->
              error_message =
                Cluster.node_unavailable_message(reason) ||
                  "Failed to send artifact interaction: #{inspect(reason)}"

              {:noreply, put_flash(socket, :error, error_message)}
          end
        else
          {:noreply, put_flash(socket, :error, NodePolicy.denial_message(node))}
        end
    end
  end
end
