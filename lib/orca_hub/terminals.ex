defmodule OrcaHub.Terminals do
  @moduledoc """
  Context for managing embedded web terminals.
  """

  import Ecto.Query
  alias OrcaHub.{Repo, Terminals.Terminal}

  def list_terminals do
    Repo.all(from t in Terminal, preload: [:project], order_by: [desc: t.updated_at])
  end

  # A session with no project opens its terminal panel with a nil id; a bare
  # `== ^nil` comparison raises in Ecto and crashed the session page.
  def list_terminals_for_project(nil) do
    Repo.all(
      from t in Terminal,
        where: is_nil(t.project_id),
        preload: [:project],
        order_by: [desc: t.updated_at]
    )
  end

  def list_terminals_for_project(project_id) do
    Repo.all(
      from t in Terminal,
        where: t.project_id == ^project_id,
        preload: [:project],
        order_by: [desc: t.updated_at]
    )
  end

  @doc "Rows reading `\"running\"` whose `runner_node` is `node_name` (the boot sweep)."
  def list_running_terminals_for_node(node_name) when is_binary(node_name) do
    Repo.all(from t in Terminal, where: t.status == "running" and t.runner_node == ^node_name)
  end

  @doc """
  Sets `status` on the row only if it still reads `from`; returns the number
  of rows updated (0 or 1). A conditional write, so a reconcile never
  clobbers a status a live runner wrote in the meantime.
  """
  def reconcile_terminal_status(id, from, status)
      when is_binary(from) and status in ~w(stopped running dead) do
    {count, _} =
      Repo.update_all(
        from(t in Terminal, where: t.id == ^id and t.status == ^from),
        set: [status: status, updated_at: NaiveDateTime.utc_now(:second)]
      )

    count
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

  @doc """
  Deletes the row, then tells a runner still alive for it (on whatever node)
  to stop and kill its shell — see `OrcaHub.TerminalRunner`'s teardown. The
  runner's periodic row check is the fallback if this broadcast is missed.
  Deleting a row that is already gone (another tab got there first) is not
  an error.
  """
  def delete_terminal(%Terminal{} = terminal) do
    with {:ok, deleted} <- Repo.delete(terminal, allow_stale: true) do
      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        OrcaHub.TerminalRunner.control_topic(deleted.id),
        {:terminal_deleted, deleted.id}
      )

      {:ok, deleted}
    end
  end

  def change_terminal(%Terminal{} = terminal, attrs \\ %{}) do
    Terminal.changeset(terminal, attrs)
  end
end
