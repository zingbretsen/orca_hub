defmodule OrcaHub.Projects do
  import Ecto.Query
  alias OrcaHub.Repo
  alias OrcaHub.Projects.Project

  @instruction_files ~w(CLAUDE.md AGENTS.md)

  def list_projects do
    Repo.all(from p in Project, order_by: [asc: p.name])
  end

  def search(query) do
    like = "%#{query}%"
    Repo.all(from p in Project, where: ilike(p.name, ^like), order_by: [asc: p.name], limit: 5)
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

  @editable_extensions ~w(.md .toml .yaml .yml .json .txt .ex .exs .eex .heex .css .js .ts .tsx .jsx .html .xml .env .cfg .ini .conf .sh .bash .zsh .fish .py .rb .rs .go .lua .sql .graphql .svg)
  @editable_basenames ~w(Dockerfile Makefile Justfile Procfile Gemfile Rakefile)

  @doc """
  Recursively lists editable text files in the project directory.
  Returns sorted list of relative paths.
  """
  def list_editable_files(%Project{directory: dir}) do
    dir
    |> find_editable_files("")
    |> Enum.sort()
  end

  @doc """
  Builds a hierarchical tree from a flat list of relative paths.
  Returns a list of nodes: %{name, path, type: :file} or %{name, type: :dir, children: [...]}.
  Directories sorted first, then files, both alphabetical.
  """
  def build_file_tree(paths) do
    paths
    |> Enum.reduce(%{}, fn path, acc ->
      parts = Path.split(path)
      insert_path(acc, parts, path)
    end)
    |> map_to_tree()
    |> sort_tree()
  end

  defp insert_path(tree, [name], full_path), do: Map.put(tree, name, full_path)

  defp insert_path(tree, [dir | rest], full_path) do
    subtree = Map.get(tree, dir, %{})
    Map.put(tree, dir, insert_path(subtree, rest, full_path))
  end

  defp map_to_tree(map) do
    Enum.map(map, fn
      {name, path} when is_binary(path) ->
        %{name: name, path: path, type: :file}

      {name, children} when is_map(children) ->
        %{name: name, type: :dir, children: map_to_tree(children)}
    end)
  end

  defp sort_tree(nodes) do
    nodes
    |> Enum.sort_by(fn
      %{type: :dir, name: name} -> {0, name}
      %{type: :file, name: name} -> {1, name}
    end)
    |> Enum.map(fn
      %{type: :dir, children: children} = node -> %{node | children: sort_tree(children)}
      node -> node
    end)
  end

  defp find_editable_files(base_dir, rel_dir) do
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
            File.dir?(full_path) -> find_editable_files(base_dir, rel_path)
            editable_file?(entry) -> [rel_path]
            true -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp editable_file?(filename) do
    ext = Path.extname(filename) |> String.downcase()
    ext in @editable_extensions or filename in @editable_basenames
  end

  @doc """
  Loads a file by relative path from the project directory.
  Returns {:ok, content} or {:error, reason}.
  """
  def load_file(%Project{directory: dir}, rel_path) do
    with :ok <- validate_path(rel_path) do
      File.read(Path.join(dir, rel_path))
    end
  end

  @doc """
  Saves a file by relative path in the project directory.
  """
  def save_file(%Project{directory: dir}, rel_path, content) do
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

  @doc "Returns the current git branch name."
  def git_branch(%Project{directory: dir}) do
    case System.cmd("git", ["branch", "--show-current"], cd: dir, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  @doc "Returns list of local branch names."
  def git_branches(%Project{directory: dir}) do
    case System.cmd("git", ["branch", "--format=%(refname:short)"], cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.sort()

      _ ->
        []
    end
  end

  @doc "Returns the main/master branch name for the repo."
  def git_main_branch(%Project{directory: dir}) do
    # Check which of main/master exists
    case System.cmd("git", ["branch", "--list", "main"], cd: dir, stderr_to_stdout: true) do
      {output, 0} when output != "" -> "main"
      _ ->
        case System.cmd("git", ["branch", "--list", "master"], cd: dir, stderr_to_stdout: true) do
          {output, 0} when output != "" -> "master"
          _ -> "main"
        end
    end
  end

  @doc "Runs git pull in the project directory."
  def git_pull(%Project{directory: dir}) do
    case System.cmd("git", ["pull"], cd: dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @doc "Lists git worktrees. Returns list of maps with :path, :branch, :head keys."
  def git_worktree_list(%Project{directory: dir}) do
    case System.cmd("git", ["worktree", "list", "--porcelain"], cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n\n", trim: true)
        |> Enum.map(fn block ->
          lines = String.split(block, "\n", trim: true)

          Enum.reduce(lines, %{}, fn line, acc ->
            cond do
              String.starts_with?(line, "worktree ") -> Map.put(acc, :path, String.trim_leading(line, "worktree "))
              String.starts_with?(line, "HEAD ") -> Map.put(acc, :head, String.trim_leading(line, "HEAD "))
              String.starts_with?(line, "branch ") -> Map.put(acc, :branch, String.trim_leading(line, "branch refs/heads/"))
              line == "bare" -> Map.put(acc, :bare, true)
              true -> acc
            end
          end)
        end)
        # Filter out the main worktree (the project dir itself)
        |> Enum.reject(fn wt -> Path.expand(wt[:path]) == Path.expand(dir) end)

      _ ->
        []
    end
  end

  @doc """
  Creates a new git worktree in .worktrees/<branch_name>.
  If `new_branch: true` is passed, creates a new branch with `-b`.
  Otherwise checks out an existing branch.
  """
  def git_create_worktree(%Project{directory: dir}, branch_name, opts \\ []) do
    ensure_worktrees_gitignored(dir)
    worktree_path = Path.join([dir, ".worktrees", branch_name])

    args =
      if Keyword.get(opts, :new_branch, false) do
        ["worktree", "add", worktree_path, "-b", branch_name]
      else
        ["worktree", "add", worktree_path, branch_name]
      end

    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_output, 0} -> {:ok, worktree_path}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp ensure_worktrees_gitignored(dir) do
    gitignore_path = Path.join(dir, ".gitignore")

    existing =
      case File.read(gitignore_path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end

    unless String.contains?(existing, ".worktrees") do
      addition = if String.ends_with?(existing, "\n") or existing == "", do: ".worktrees/\n", else: "\n.worktrees/\n"
      File.write(gitignore_path, existing <> addition)
    end
  end

  @doc "Rebases the worktree branch onto the main branch."
  def git_rebase_worktree(%Project{directory: dir}, worktree_path) do
    main = git_main_branch(%Project{directory: dir})

    # First fetch to make sure we have latest
    System.cmd("git", ["fetch", "origin"], cd: worktree_path, stderr_to_stdout: true)

    case System.cmd("git", ["rebase", "origin/#{main}"], cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} ->
        # Abort the failed rebase
        System.cmd("git", ["rebase", "--abort"], cd: worktree_path, stderr_to_stdout: true)
        {:error, String.trim(output)}
    end
  end

  @doc "Merges a worktree branch into the main branch."
  def git_merge_worktree(%Project{directory: dir}, branch_name) do
    main = git_main_branch(%Project{directory: dir})

    # Checkout main in the main worktree and merge
    with {_, 0} <- System.cmd("git", ["checkout", main], cd: dir, stderr_to_stdout: true),
         {output, 0} <- System.cmd("git", ["merge", branch_name], cd: dir, stderr_to_stdout: true) do
      {:ok, String.trim(output)}
    else
      {output, _} -> {:error, String.trim(output)}
    end
  end
end
