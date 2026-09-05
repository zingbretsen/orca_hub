defmodule OrcaHubWeb.ArtifactLive.Show do
  @moduledoc """
  Fullscreen artifact viewer at `/artifacts/:id` — a bare sandboxed iframe
  plus a minimal header, with a viewport-width toggle for eyeballing
  responsiveness. Reachable directly, or via `open_artifact`/`save_artifact`
  with `mode: "full"` pushing here from `SessionLive.Show`.
  """

  use OrcaHubWeb, :live_view

  require Logger

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

        project = HubRPC.get_project(artifact.project_id)

        {:ok,
         socket
         |> assign(:artifact, artifact)
         |> assign(:project, project)
         |> assign(:project_node, project && Cluster.project_node_for(project))
         |> assign(:viewport, "full")
         |> assign(:page_title, artifact.name)
         |> assign(:artifact_send_throttle, %{})
         |> assign(:show_edit_session, false)}
    end
  end

  @impl true
  def handle_event("set_viewport", %{"viewport" => viewport}, socket) do
    {:noreply, assign(socket, :viewport, viewport)}
  end

  def handle_event("open_edit_session", _params, socket) do
    {:noreply, assign(socket, :show_edit_session, true)}
  end

  def handle_event("close_edit_session", _params, socket) do
    {:noreply, assign(socket, :show_edit_session, false)}
  end

  def handle_event("start_edit_session", %{"instruction" => instruction}, socket) do
    instruction = String.trim(instruction)

    cond do
      instruction == "" ->
        {:noreply, put_flash(socket, :error, "Describe what you want changed.")}

      is_nil(socket.assigns.project) ->
        {:noreply,
         socket
         |> assign(:show_edit_session, false)
         |> put_flash(:error, "This artifact's project no longer exists.")}

      not Cluster.node_available?(socket.assigns.project_node) ->
        message =
          Cluster.node_unavailable_message({:node_unavailable, socket.assigns.project_node}) ||
            "Project's node is unavailable."

        {:noreply,
         socket
         |> assign(:show_edit_session, false)
         |> put_flash(:error, message)}

      true ->
        start_edit_session(socket, instruction)
    end
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

  # orca.setState/getState write-through user-state channel (see
  # OrcaHub.Artifacts.merge_user_state/2) — mirrors artifact_send's
  # single-artifact guard above (there's only ever the one viewed artifact
  # here, unlike SessionLive.Show's several-open-tabs split panel). Never
  # touches Cluster.send_message and is NOT throttled — see the
  # SessionLive.Show handler's moduledoc note for why.
  def handle_event("artifact_state", %{"artifact_id" => artifact_id, "patch" => patch}, socket) do
    cond do
      artifact_id != socket.assigns.artifact.id ->
        {:noreply, socket}

      not is_map(patch) ->
        {:noreply, socket}

      ArtifactSend.too_large?(patch) ->
        {:noreply,
         put_flash(socket, :error, "Artifact state payload too large (max 16KB) — dropped.")}

      true ->
        HubRPC.merge_user_state(artifact_id, patch)
        {:noreply, socket}
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

  defp start_edit_session(socket, instruction) do
    project = socket.assigns.project
    node = socket.assigns.project_node
    artifact = socket.assigns.artifact

    params = %{
      "project_id" => project.id,
      "directory" => project.directory,
      "runner_node" => Atom.to_string(node)
    }

    case HubRPC.create_session(params) do
      {:ok, session} ->
        case Cluster.start_session(node, session.id, session) do
          {:ok, _} ->
            prompt = edit_prompt(artifact, instruction)

            case Cluster.send_message(node, session.id, prompt, :queue) do
              :ok ->
                {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

              {:queued, _status} ->
                {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

              {:error, reason} ->
                error_message =
                  Cluster.node_unavailable_message(reason) ||
                    "Session created but failed to send instruction: #{inspect(reason)}"

                {:noreply,
                 socket
                 |> assign(:show_edit_session, false)
                 |> put_flash(:error, error_message)}
            end

          {:error, reason} ->
            Logger.error("Failed to start session runner: #{inspect(reason)}")

            {:noreply,
             socket
             |> assign(:show_edit_session, false)
             |> put_flash(:error, "Session created but failed to start runner")}
        end

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:show_edit_session, false)
         |> put_flash(:error, "Failed to create session")}
    end
  end

  defp edit_prompt(artifact, instruction) do
    """
    Edit the artifact "#{artifact.name}" (artifact_id: #{artifact.id}) in this project.

    Load its current content with the `get_artifact` artifact tool using that
    artifact_id, make the change below, then save it back with `save_artifact`
    using the SAME name ("#{artifact.name}") so it updates in place rather than
    creating a new artifact.

    Requested change:
    #{instruction}
    """
  end

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

          case Cluster.send_message(node, session.id, message, :queue) do
            :ok ->
              {:noreply, put_flash(socket, :info, "Sent to session.")}

            {:queued, _status} ->
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
