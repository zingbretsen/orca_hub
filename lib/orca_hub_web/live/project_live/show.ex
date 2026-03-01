defmodule OrcaHubWeb.ProjectLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Projects

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)
    instructions = Projects.load_instructions_file(project)

    commits = Projects.git_log(project)

    {:ok,
     socket
     |> assign(project: project, page_title: project.name, commits: commits)
     |> assign_instructions(instructions)}
  end

  defp assign_instructions(socket, nil) do
    assign(socket,
      instructions_file: nil,
      instructions_content: nil,
      editing: false
    )
  end

  defp assign_instructions(socket, {filename, content}) do
    assign(socket,
      instructions_file: filename,
      instructions_content: content,
      editing: false
    )
  end

  @impl true
  def handle_event("edit", _params, socket) do
    {:noreply, assign(socket, editing: true)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: false)}
  end

  def handle_event("save_instructions", %{"content" => content}, socket) do
    project = socket.assigns.project
    filename = socket.assigns.instructions_file || "CLAUDE.md"

    case Projects.save_instructions_file(project, filename, content) do
      :ok ->
        {:noreply,
         socket
         |> assign(instructions_content: content, instructions_file: filename, editing: false)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{reason}")}
    end
  end

  def handle_event("create_instructions", _params, socket) do
    {:noreply,
     assign(socket,
       instructions_file: "CLAUDE.md",
       instructions_content: "",
       editing: true
     )}
  end
end
