defmodule OrcaHub.Projects do
  import Ecto.Query
  alias OrcaHub.Repo
  alias OrcaHub.Projects.Project

  @instruction_files ~w(CLAUDE.md AGENTS.md)

  def list_projects do
    Repo.all(from p in Project, order_by: [asc: p.name])
  end

  def get_project!(id), do: Repo.get!(Project, id) |> Repo.preload(:issues)

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def delete_project(%Project{} = project), do: Repo.delete(project)

  @doc """
  Loads the first found instructions file (CLAUDE.md, AGENTS.md) from the project directory.
  Returns {filename, content} or nil.
  """
  def load_instructions_file(%Project{directory: dir}) do
    Enum.find_value(@instruction_files, fn filename ->
      path = Path.join(dir, filename)

      case File.read(path) do
        {:ok, content} -> {filename, content}
        {:error, _} -> nil
      end
    end)
  end

  @doc """
  Saves instructions content to the given filename in the project directory.
  """
  def save_instructions_file(%Project{directory: dir}, filename, content) do
    path = Path.join(dir, filename)
    File.write(path, content)
  end
end
