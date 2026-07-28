defmodule OrcaHub.A2ATasks do
  @moduledoc """
  Context for inbound A2A tasks (docs/a2a.md): CRUD plus the poll-driven
  `advance/1` logic `OrcaHubWeb.A2AController`'s `tasks/get` uses to move a
  task from `submitted`/`working`/`input-required` to a terminal state.
  Mirrors `OrcaHub.ApiRuns`/`ApiRunController`'s `advance_running/3`
  philosophy — pure poll, no background process — including v2's
  schema-validation idle-fallback retry loop (`docs/a2a.md` "Structured
  results"), which reuses `OrcaHub.ApiRuns.extract_json/1` and
  `validate_against_schema/2` directly rather than duplicating them.

  Hub-only, like the rest of the A2A server (`docs/a2a.md`) — plain `Repo`
  access, no `HubRPC` indirection needed for this module's own CRUD, though
  `advance/1` reads session state via `HubRPC` since a session may be
  running on an agent node.
  """

  import Ecto.Query, only: [from: 2]

  alias OrcaHub.A2ATasks.A2ATask
  alias OrcaHub.{ApiRuns, Cluster, HubRPC}
  alias OrcaHub.Repo

  @in_progress_session_statuses ~w(running compacting waiting)
  @terminal_statuses ~w(completed failed canceled)

  def get_task(id) do
    case Repo.get(A2ATask, id) do
      nil -> nil
      task -> Repo.preload(task, :session)
    end
  end

  @doc """
  The most recently created task for a session, or `nil` — mirrors
  `OrcaHub.ApiRuns.get_run_by_session_id/1`. Used by `MCP.Server`'s
  `OrcaHub.MCP.ToolCallHolder.A2ATaskHolder` (v2 client-tool/result_schema
  connections) and by `A2AController`'s continuation-task creation (v2
  declaration inheritance, docs/a2a.md) to find the conversation's prior
  task to copy `client_tools`/`result_schema`/`max_validation_attempts`
  forward from.
  """
  def get_task_by_session_id(session_id) do
    from(t in A2ATask,
      where: t.session_id == ^session_id,
      order_by: [desc: t.inserted_at],
      limit: 1
    )
    |> Repo.one()
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

  # v2 (docs/a2a.md "Tool-call loop"): a parked client-tool call parks the
  # task here until the caller answers via `message/send` WITH `taskId` — the
  # task's OWN status, not the session's, is authoritative while this is set,
  # so this MUST be checked before falling into advance_running/2's
  # session-status-driven idle-completion logic below (which would otherwise
  # be free to flip "input-required" back to "working"/"completed" off
  # whatever the session's own status happens to be — the underlying
  # session is typically still "running", blocked mid-turn on the held MCP
  # call). Timeout still wins over an unanswered tool call, same as any
  # other in-progress task — mirrors ApiRunController.advance_and_render/2's
  # identical `awaiting_tool_result` clause.
  def advance(%A2ATask{status: "input-required"} = task) do
    if timed_out?(task) do
      update_task(task, %{status: "failed", error: "timed out after #{task.timeout_seconds}s"})
    else
      {:ok, task}
    end
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
      handle_idle_result(task, session, text)
    end
  end

  # Any other session status (e.g. a freshly created "ready" session whose
  # runner hasn't picked up the turn yet) — leave the task's current state
  # alone (stays "submitted" until first observed running, never regresses
  # an already-"working" task).
  defp advance_running(task, _session), do: {:ok, task}

  defp set_working(%A2ATask{status: "working"} = task), do: {:ok, task}
  defp set_working(task), do: update_task(task, %{status: "working"})

  # v2 (docs/a2a.md "Structured results") — mirrors
  # ApiRunController.handle_idle_result/4 and validate_and_finish/4 exactly.
  # This idle-text fallback only fires when the model never called
  # submit_result — the PRIMARY completion channel is that tool itself
  # (see OrcaHub.MCP.Server.persist_completed_run/3), which sets the task to
  # "completed" directly and short-circuits the terminal-status advance/1
  # clause above before this code is ever reached.
  defp handle_idle_result(task, _session, text) when is_nil(task.result_schema) do
    update_task(task, %{status: "completed", result_text: text})
  end

  defp handle_idle_result(task, session, text) do
    case ApiRuns.extract_json(text) do
      {:ok, parsed} ->
        validate_and_finish(task, session, text, parsed)

      :error ->
        retry_or_fail(task, session, text, [
          "response was not valid JSON (and no ```json fence found)"
        ])
    end
  end

  defp validate_and_finish(task, session, text, parsed) do
    case ApiRuns.validate_against_schema(parsed, task.result_schema) do
      :ok ->
        update_task(task, %{status: "completed", result_text: text, result: parsed})

      {:error, errors} ->
        retry_or_fail(task, session, text, errors)

      {:schema_error, message} ->
        update_task(task, %{status: "failed", error: message, result_text: text})
    end
  end

  # Corrective retries must NEVER be observable as a distinct task state
  # (docs/a2a.md) — the task stays "working" to a poller across every retry
  # attempt, all the way up to the final terminal completed/failed
  # transition. Mirrors ApiRunController.retry_or_fail/4.
  defp retry_or_fail(task, session, text, errors) do
    if task.validation_attempts < task.max_validation_attempts do
      {:ok, task} = update_task(task, %{validation_attempts: task.validation_attempts + 1})

      runner_node = Cluster.runner_node_for(session)
      Cluster.send_message(runner_node, session.id, corrective_prompt(errors))

      set_working(task)
    else
      update_task(task, %{
        status: "failed",
        error:
          "validation failed after #{task.max_validation_attempts} attempts: " <>
            Enum.join(errors, "; "),
        result_text: text
      })
    end
  end

  defp corrective_prompt(errors) do
    "Your previous response did not produce a valid result:\n" <>
      Enum.map_join(errors, "\n", &"- #{&1}") <>
      "\n\nCall the submit_result tool with your final result now — a plain text response is not accepted."
  end

  # One-shot tasks start at baseline_message_count: 0 on a brand-new session
  # with no messages, so this is always false for them the moment the first
  # user turn is persisted — the guard only ever actually bites for a
  # continuation's already-idle target session.
  defp awaiting_new_turn?(task, session_id) do
    HubRPC.count_messages(session_id) <= task.baseline_message_count
  end
end
