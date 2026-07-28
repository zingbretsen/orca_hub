defmodule OrcaHub.A2ATasks do
  @moduledoc """
  Context for inbound A2A tasks (docs/a2a.md): CRUD plus the poll-driven
  `advance/1` logic `OrcaHubWeb.A2AController`'s `tasks/get` uses to move a
  task from `submitted`/`working` to a terminal state. Mirrors
  `OrcaHub.ApiRuns`/`ApiRunController`'s `advance_running/3` philosophy —
  pure poll, no background process — trimmed to A2A's plain task states (no
  schema validation, no client tools; see `OrcaHub.ApiRuns` for that surface).

  Hub-only, like the rest of the A2A server (`docs/a2a.md`) — plain `Repo`
  access, no `HubRPC` indirection needed for this module's own CRUD, though
  `advance/1` reads session state via `HubRPC` since a session may be
  running on an agent node.
  """

  alias OrcaHub.A2ATasks.A2ATask
  alias OrcaHub.HubRPC
  alias OrcaHub.Repo

  @in_progress_session_statuses ~w(running compacting waiting)
  @terminal_statuses ~w(completed failed canceled)

  def get_task(id) do
    case Repo.get(A2ATask, id) do
      nil -> nil
      task -> Repo.preload(task, :session)
    end
  end

  def create_task(attrs) do
    %A2ATask{}
    |> A2ATask.changeset(attrs)
    |> Repo.insert()
  end

  def update_task(%A2ATask{} = task, attrs) do
    task
    |> A2ATask.changeset(attrs)
    |> Repo.update()
  end

  @doc "Whether `status` is one of the terminal A2A task states."
  def terminal_status?(status), do: status in @terminal_statuses

  @doc """
  Advances `task` (with its `:session` preloaded) based on the session's
  current status, the task's timeout, and the stale-reply baseline guard —
  same tiebreaker `ApiRunController.awaiting_new_turn?/2` uses for
  continuations. Returns `{:ok, task}`, possibly updated in the DB. Already-
  terminal tasks are returned unchanged — `tasks/get` never resurrects a
  finished task.
  """
  def advance(%A2ATask{status: status} = task) when status in @terminal_statuses do
    {:ok, task}
  end

  def advance(%A2ATask{} = task) do
    if timed_out?(task) do
      update_task(task, %{status: "failed", error: "timed out after #{task.timeout_seconds}s"})
    else
      advance_running(task, task.session)
    end
  end

  defp timed_out?(task) do
    inserted_at = DateTime.from_naive!(task.inserted_at, "Etc/UTC")
    DateTime.diff(DateTime.utc_now(), inserted_at) > task.timeout_seconds
  end

  defp advance_running(task, %{status: session_status})
       when session_status in @in_progress_session_statuses do
    set_working(task)
  end

  defp advance_running(task, %{status: "error"} = session) do
    result_text = HubRPC.last_assistant_text(session.id)
    update_task(task, %{status: "failed", error: "session errored", result_text: result_text})
  end

  defp advance_running(task, %{status: "idle"} = session) do
    if awaiting_new_turn?(task, session.id) do
      # Stale-reply race, same as ApiRunController.awaiting_new_turn?/2: the
      # target session can already be "idle" — from its PREVIOUS turn — the
      # instant send_message returns, so session.status == "idle" alone
      # can't tell "this task's turn is done" apart from "hasn't started
      # yet". baseline_message_count (snapshotted right before delivery) is
      # the tiebreaker.
      set_working(task)
    else
      text = HubRPC.last_assistant_text(session.id)
      update_task(task, %{status: "completed", result_text: text})
    end
  end

  # Any other session status (e.g. a freshly created "ready" session whose
  # runner hasn't picked up the turn yet) — leave the task's current state
  # alone (stays "submitted" until first observed running, never regresses
  # an already-"working" task).
  defp advance_running(task, _session), do: {:ok, task}

  defp set_working(%A2ATask{status: "working"} = task), do: {:ok, task}
  defp set_working(task), do: update_task(task, %{status: "working"})

  # One-shot tasks start at baseline_message_count: 0 on a brand-new session
  # with no messages, so this is always false for them the moment the first
  # user turn is persisted — the guard only ever actually bites for a
  # continuation's already-idle target session.
  defp awaiting_new_turn?(task, session_id) do
    HubRPC.count_messages(session_id) <= task.baseline_message_count
  end
end
