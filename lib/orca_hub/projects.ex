defmodule OrcaHub.Projects do
  import Ecto.Query
  alias OrcaHub.Repo
  alias OrcaHub.Projects.Project

  @instruction_files ~w(CLAUDE.md AGENTS.md)

  def list_projects do
    Repo.all(from p in Project, order_by: [asc: p.name])
  end

  def get_project!(id) do
    Repo.get!(Project, id)
    |> Repo.preload([:issues, sessions: from(s in OrcaHub.Sessions.Session, order_by: [desc: s.updated_at])])
  end

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

  @skip_dirs ~w(.git .claude node_modules deps _build .elixir_ls .hex .mix _deps vendor)

  @doc """
  Recursively lists all .md files in the project directory.
  Returns sorted list of relative paths.
  """
  def list_markdown_files(%Project{directory: dir}) do
    dir
    |> find_md_files("")
    |> Enum.sort()
  end

  defp find_md_files(base_dir, rel_dir) do
    full_dir = Path.join(base_dir, rel_dir)

    case File.ls(full_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.reject(&(&1 in @skip_dirs))
        |> Enum.flat_map(fn entry ->
          rel_path = if(rel_dir == "", do: entry, else: Path.join(rel_dir, entry))
          full_path = Path.join(base_dir, rel_path)

          cond do
            File.dir?(full_path) -> find_md_files(base_dir, rel_path)
            String.ends_with?(entry, ".md") -> [rel_path]
            true -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Loads a markdown file by relative path from the project directory.
  Returns {:ok, content} or {:error, reason}.
  """
  def load_markdown_file(%Project{directory: dir}, rel_path) do
    with :ok <- validate_path(rel_path) do
      File.read(Path.join(dir, rel_path))
    end
  end

  @doc """
  Saves a markdown file by relative path in the project directory.
  """
  def save_markdown_file(%Project{directory: dir}, rel_path, content) do
    with :ok <- validate_path(rel_path) do
      full_path = Path.join(dir, rel_path)
      full_path |> Path.dirname() |> File.mkdir_p!()
      File.write(full_path, content)
    end
  end

  defp validate_path(rel_path) do
    normalized = Path.expand(rel_path, "/")

    if String.starts_with?(normalized, "/") and not String.contains?(normalized, "..") do
      :ok
    else
      {:error, :invalid_path}
    end
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
