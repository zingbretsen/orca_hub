defmodule OrcaHubWeb.ProjectLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Projects

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)
    md_files = Projects.list_markdown_files(project)
    commits = Projects.git_log(project)

    {:ok,
     socket
     |> assign(
       project: project,
       page_title: project.name,
       commits: commits,
       md_files: md_files,
       selected_file: nil,
       file_content: nil,
       file_editing: false,
       new_file_name: nil
     )}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    project = socket.assigns.project

    case Projects.load_markdown_file(project, path) do
      {:ok, content} ->
        {:noreply,
         assign(socket,
           selected_file: path,
           file_content: content,
           file_editing: false,
           new_file_name: nil
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to load #{path}")}
    end
  end

  def handle_event("edit_file", _params, socket) do
    {:noreply, assign(socket, file_editing: true)}
  end

  def handle_event("cancel_edit_file", _params, socket) do
    if socket.assigns.new_file_name do
      {:noreply, assign(socket, file_editing: false, selected_file: nil, new_file_name: nil)}
    else
      {:noreply, assign(socket, file_editing: false)}
    end
  end

  def handle_event("save_file", params, socket) do
    content = params["content"]
    project = socket.assigns.project

    path =
      if socket.assigns.new_file_name != nil do
        filename = params["filename"] || ""
        if String.ends_with?(filename, ".md"), do: filename, else: filename <> ".md"
      else
        socket.assigns.selected_file
      end

    if path == "" or path == ".md" do
      {:noreply, put_flash(socket, :error, "Please enter a filename")}
    else
      case Projects.save_markdown_file(project, path, content) do
      :ok ->
        md_files = Projects.list_markdown_files(project)

        {:noreply,
         assign(socket,
           file_content: content,
           file_editing: false,
           selected_file: path,
           new_file_name: nil,
           md_files: md_files
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("new_file", _params, socket) do
    {:noreply,
     assign(socket,
       selected_file: nil,
       new_file_name: "",
       file_content: "",
       file_editing: true
     )}
  end

  def handle_event("deselect_file", _params, socket) do
    {:noreply,
     assign(socket, selected_file: nil, file_content: nil, file_editing: false, new_file_name: nil)}
  end
end
