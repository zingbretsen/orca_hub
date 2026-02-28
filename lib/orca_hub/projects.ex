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

  @doc """
  Returns recent git commits from the project directory.
  Returns a list of maps with :hash, :subject, :relative_date, and :author keys.
  """
  def git_log(%Project{directory: dir}, count \\ 20) do
    case System.cmd("git", ["log", "--format=%h|%s|%ar|%an", "-n", "#{count}"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        commits =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "|", parts: 4) do
              [hash, subject, relative_date, author] ->
                %{hash: hash, subject: subject, relative_date: relative_date, author: author}

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        commits

      _ ->
        []
    end
  end
end
