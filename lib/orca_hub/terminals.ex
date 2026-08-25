defmodule OrcaHub.Terminals do
  @moduledoc """
  Context for managing embedded web terminals.
  """

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

  @doc """
  Pins a terminal by stamping `pinned_at` — a nullable timestamp (not a
  boolean) so `TerminalLive.Index`'s Pinned section can order by when each
  terminal was pinned, the same rationale as `Session.archived_at`. Two
  explicit functions (`pin_terminal/1`/`unpin_terminal/1`) rather than one
  generic toggle, mirroring `archive_session/1`/`unarchive_session/1`.
  """
  def pin_terminal(%Terminal{} = terminal) do
    terminal
    |> Terminal.changeset(%{pinned_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  @doc "Unpins a terminal — clears `pinned_at`. See `pin_terminal/1`."
  def unpin_terminal(%Terminal{} = terminal) do
    terminal
    |> Terminal.changeset(%{pinned_at: nil})
    |> Repo.update()
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
