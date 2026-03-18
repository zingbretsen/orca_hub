defmodule OrcaHub.Terminals do
  import Ecto.Query
  alias OrcaHub.{Repo, Terminals.Terminal}

  def list_terminals do
    Repo.all(from t in Terminal, preload: [:project], order_by: [desc: t.updated_at])
  end

  def list_terminals_for_project(project_id) do
    Repo.all(
      from t in Terminal,
        where: t.project_id == ^project_id,
        preload: [:project],
        order_by: [desc: t.updated_at]
    )
  end

  def get_terminal!(id), do: Repo.get!(Terminal, id) |> Repo.preload(:project)

  def get_terminal(id) do
    case Repo.get(Terminal, id) do
      nil -> nil
      terminal -> Repo.preload(terminal, :project)
    end
  end

  def create_terminal(attrs) do
    %Terminal{}
    |> Terminal.changeset(attrs)
    |> Repo.insert()
  end

  def update_terminal(%Terminal{} = terminal, attrs) do
    terminal
    |> Terminal.changeset(attrs)
    |> Repo.update()
  end

  def delete_terminal(%Terminal{} = terminal), do: Repo.delete(terminal)

  def change_terminal(%Terminal{} = terminal, attrs \\ %{}) do
    Terminal.changeset(terminal, attrs)
  end
end
