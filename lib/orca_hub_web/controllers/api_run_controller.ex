defmodule OrcaHubWeb.ApiRunController do
  @moduledoc """
  Agent Runs API (docs/api.md): POST creates a session + run and returns
  immediately; GET polls the run to completion. `show/2` is deliberately a
  pure poll-driven state machine (no background monitor task) so it survives
  restarts and works regardless of which node handles the poll.
  """

  use OrcaHubWeb, :controller

  require Logger

  alias OrcaHub.{ApiRuns, Cluster, HubRPC}

  @in_progress_session_statuses ~w(running compacting waiting)
  @default_timeout_seconds 3600
  @default_max_validation_attempts 3

  # ---------------------------------------------------------------------
  # POST /api/v1/runs
  # ---------------------------------------------------------------------

  # Continuation: deliver the prompt into an EXISTING session instead of
  # creating a new one (docs/api.md's "Continuing a session" section).
  # `directory`/`project_id`/`backend`/`model`/`no_tools`/`title` are all
  # session-creation concerns and are ignored here — the session already has
  # them.
  def create(conn, %{"session_id" => session_id} = params)
      when is_binary(session_id) and session_id != "" do
    with {:ok, prompt} <- fetch_prompt(params),
         {:ok, session} <- fetch_existing_session(session_id),
         runner_node <- Cluster.runner_node_for(session),
         :ok <- check_node_available(runner_node) do
      create_continuation_run(conn, params, prompt, session, runner_node)
    else
      {:error, status, body} -> conn |> put_status(status) |> json(body)
    end
  end

  def create(conn, params) do
    with {:ok, prompt} <- fetch_prompt(params),
         {:ok, project} <- fetch_project(params),
         {:ok, directory} <- resolve_directory(params, project),
         {:ok, backend} <- resolve_backend(params),
         :ok <- validate_no_tools(params, backend),
         runner_node <- resolve_runner_node(project),
         :ok <- check_node_available(runner_node) do
      create_run(conn, params, prompt, project, directory, backend, runner_node)
    else
      {:error, status, body} -> conn |> put_status(status) |> json(body)
    end
  end

  # Same 404 posture as show/2's Ecto.UUID.cast handling below: a malformed
  # id and a well-formed-but-nonexistent id both just mean "no such session",
  # not a validation error.
  defp fetch_existing_session(session_id) do
    case Ecto.UUID.cast(session_id) do
      :error ->
        {:error, 404, %{error: "session not found"}}

      {:ok, _} ->
        case HubRPC.get_session(session_id) do
          nil -> {:error, 404, %{error: "session not found"}}
          session -> {:ok, session}
        end
    end
  end

  defp fetch_prompt(%{"prompt" => prompt}) when is_binary(prompt) and prompt != "" do
    {:ok, prompt}
  end

  defp fetch_prompt(_), do: {:error, 400, %{error: "prompt is required"}}

  defp fetch_project(%{"project_id" => project_id}) when is_binary(project_id) do
    case HubRPC.get_project(project_id) do
      nil -> {:error, 400, %{error: "project not found"}}
      project -> {:ok, project}
    end
  end

  defp fetch_project(_), do: {:ok, nil}

  defp resolve_directory(%{"directory" => directory}, _project)
       when is_binary(directory) and directory != "" do
    {:ok, directory}
  end

  defp resolve_directory(_params, %{directory: directory}), do: {:ok, directory}

  defp resolve_directory(_params, nil),
    do: {:error, 400, %{error: "directory or project_id is required"}}

  defp resolve_backend(%{"backend" => backend}) when is_binary(backend) and backend != "" do
    {:ok, backend}
  end

  defp resolve_backend(_params), do: {:ok, "claude"}

  defp validate_no_tools(%{"no_tools" => true}, backend) when backend != "claude" do
    {:error, 400, %{error: "no_tools is only supported with backend \"claude\""}}
  end

  defp validate_no_tools(_params, _backend), do: :ok

  defp resolve_runner_node(nil), do: node()
  defp resolve_runner_node(project), do: Cluster.project_node_for(project)

  defp check_node_available(runner_node) do
    if Cluster.node_available?(runner_node) do
      :ok
    else
      {:error, 503, %{error: "node #{inspect(runner_node)} is not currently connected"}}
    end
  end

  defp create_run(conn, params, prompt, project, directory, backend, runner_node) do
    result_schema = params["result_schema"]
    no_tools = params["no_tools"] == true

    session_attrs =
      %{
        directory: directory,
        project_id: project && project.id,
        title: params["title"] || "API run",
        status: "ready",
        triggered: true,
        runner_node: Atom.to_string(runner_node),
        model: params["model"],
        backend: backend,
        tools: if(no_tools, do: "", else: nil)
      }
      |> maybe_disable_code_exec(result_schema)

    with {:ok, session} <- HubRPC.create_session(session_attrs),
         {:ok, run} <-
           HubRPC.create_api_run(%{
             session_id: session.id,
             result_schema: result_schema,
             timeout_seconds: params["timeout_seconds"] || @default_timeout_seconds,
             max_validation_attempts:
               params["max_validation_attempts"] || @default_max_validation_attempts
           }) do
      Cluster.start_session(runner_node, session.id, session)

      case Cluster.send_message(runner_node, session.id, full_prompt(prompt, result_schema)) do
        :ok ->
          :ok

        other ->
          Logger.warning(
            "ApiRunController: send_message for run #{run.id} (session #{session.id}) " <>
              "returned #{inspect(other)}"
          )
      end

      conn
      |> put_status(202)
      |> json(%{run_id: run.id, session_id: session.id, status: "running"})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid parameters", details: changeset_errors(changeset)})
    end
  end

  defp create_continuation_run(conn, params, prompt, session, runner_node) do
    result_schema = params["result_schema"]
    # Snapshot BEFORE delivery — see awaiting_new_turn?/2 and the migration
    # comment on baseline_message_count.
    baseline_message_count = HubRPC.count_messages(session.id)

    with {:ok, run} <-
           HubRPC.create_api_run(%{
             session_id: session.id,
             result_schema: result_schema,
             timeout_seconds: params["timeout_seconds"] || @default_timeout_seconds,
             max_validation_attempts:
               params["max_validation_attempts"] || @default_max_validation_attempts,
             baseline_message_count: baseline_message_count
           }) do
      deliver_continuation(conn, run, session, runner_node, full_prompt(prompt, result_schema))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid parameters", details: changeset_errors(changeset)})
    end
  end

  # Reuses the exact mechanism send_message_to_session uses (Cluster.send_message/3,
  # see OrcaHub.MCP.Tools.Sessions): it starts a torn-down/never-started runner
  # and unarchives an archived session automatically, so a continuation into an
  # idle-teardown'd or archived session revives it the same way a sibling
  # session's send_message_to_session call would.
  defp deliver_continuation(conn, run, session, runner_node, message) do
    case Cluster.send_message(runner_node, session.id, message) do
      :ok ->
        conn
        |> put_status(202)
        |> json(%{run_id: run.id, session_id: session.id, status: "running"})

      {:error, reason} ->
        message =
          Cluster.node_unavailable_message(reason) ||
            "session #{session.id} could not be revived: #{inspect(reason)}"

        {:ok, run} = HubRPC.update_api_run(run, %{status: "failed", error: message})

        conn
        |> put_status(502)
        |> json(%{error: message, run_id: run.id, session_id: session.id, status: "failed"})
    end
  end

  # code_exec is ON by default for new sessions (see Sessions.Session);
  # a schema run's MCP server must expose ONLY submit_result (docs/api.md),
  # so code_exec has to be explicitly turned off — leaving the key out of
  # session_attrs entirely (rather than passing `code_exec: nil`) would
  # otherwise apply the column's `true` default via the changeset.
  defp maybe_disable_code_exec(attrs, nil), do: attrs
  defp maybe_disable_code_exec(attrs, _result_schema), do: Map.put(attrs, :code_exec, false)

  defp full_prompt(prompt, nil), do: prompt

  defp full_prompt(prompt, result_schema) do
    schema_json = Jason.encode!(result_schema, pretty: true)

    prompt <>
      "\n\nWhen you have your final answer, call the submit_result tool with a JSON object " <>
      "conforming to this JSON Schema (shown here for reference; the tool's input schema " <>
      "enforces it):\n```json\n#{schema_json}\n```"
  end

  # ---------------------------------------------------------------------
  # GET /api/v1/runs/:id
  # ---------------------------------------------------------------------

  def show(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      :error -> conn |> put_status(404) |> json(%{error: "not found"})
      {:ok, _} -> do_show(conn, id)
    end
  end

  defp do_show(conn, id) do
    case HubRPC.get_api_run(id) do
      nil -> conn |> put_status(404) |> json(%{error: "not found"})
      run -> advance_and_render(conn, run)
    end
  end

  defp advance_and_render(conn, %{status: status} = run)
       when status in ~w(completed failed timed_out) do
    render_run(conn, run)
  end

  defp advance_and_render(conn, run) do
    if timed_out?(run) do
      {:ok, run} = HubRPC.update_api_run(run, %{status: "timed_out"})
      render_run(conn, run)
    else
      advance_running(conn, run, run.session)
    end
  end

  defp timed_out?(run) do
    inserted_at = DateTime.from_naive!(run.inserted_at, "Etc/UTC")
    DateTime.diff(DateTime.utc_now(), inserted_at) > run.timeout_seconds
  end

  defp advance_running(conn, run, %{status: session_status})
       when session_status in @in_progress_session_statuses do
    render_run(conn, run, session_status: session_status, status_override: "in_progress")
  end

  defp advance_running(conn, run, %{status: "error"} = session) do
    result_text = HubRPC.last_assistant_text(session.id)

    {:ok, run} =
      HubRPC.update_api_run(run, %{
        status: "failed",
        error: "session errored",
        result_text: result_text
      })

    render_run(conn, run)
  end

  defp advance_running(conn, run, %{status: "idle"} = session) do
    if awaiting_new_turn?(run, session.id) do
      # Continuation's stale-reply race: the target session can already be
      # "idle" — from its PREVIOUS turn — the instant send_message returns
      # (see create_continuation_run/5), so `session.status == "idle"` alone
      # can't tell "this run's turn is done" apart from "hasn't started yet".
      # baseline_message_count (snapshotted right before delivery) is the
      # tiebreaker: no new message yet means don't trust last_assistant_text,
      # it would just be the prior turn's reply.
      render_run(conn, run, session_status: session.status, status_override: "in_progress")
    else
      text = HubRPC.last_assistant_text(session.id)
      handle_idle_result(conn, run, session, text)
    end
  end

  # Any other session status (e.g. a freshly created "ready" session whose
  # runner hasn't picked up the turn yet) is still in progress.
  defp advance_running(conn, run, session) do
    render_run(conn, run, session_status: session.status, status_override: "in_progress")
  end

  # One-shot runs start at baseline_message_count: 0 on a brand-new session
  # with no messages, so this is always false for them the moment the first
  # user turn is persisted — the guard only ever actually bites for a
  # continuation's already-idle target session.
  defp awaiting_new_turn?(run, session_id) do
    HubRPC.count_messages(session_id) <= run.baseline_message_count
  end

  defp handle_idle_result(conn, run, _session, text) when is_nil(run.result_schema) do
    result =
      case ApiRuns.extract_json(text) do
        {:ok, value} -> value
        :error -> nil
      end

    {:ok, run} =
      HubRPC.update_api_run(run, %{status: "completed", result_text: text, result: result})

    render_run(conn, run)
  end

  defp handle_idle_result(conn, run, session, text) do
    case ApiRuns.extract_json(text) do
      {:ok, parsed} ->
        validate_and_finish(conn, run, session, text, parsed)

      :error ->
        retry_or_fail(conn, run, session, text, [
          "response was not valid JSON (and no ```json fence found)"
        ])
    end
  end

  defp validate_and_finish(conn, run, session, text, parsed) do
    case ApiRuns.validate_against_schema(parsed, run.result_schema) do
      :ok ->
        {:ok, run} =
          HubRPC.update_api_run(run, %{status: "completed", result_text: text, result: parsed})

        render_run(conn, run)

      {:error, errors} ->
        retry_or_fail(conn, run, session, text, errors)

      {:schema_error, message} ->
        {:ok, run} =
          HubRPC.update_api_run(run, %{status: "failed", error: message, result_text: text})

        render_run(conn, run)
    end
  end

  defp retry_or_fail(conn, run, session, text, errors) do
    if run.validation_attempts < run.max_validation_attempts do
      attempts = run.validation_attempts + 1
      {:ok, run} = HubRPC.update_api_run(run, %{validation_attempts: attempts})

      runner_node = Cluster.runner_node_for(session)
      corrective_prompt = corrective_prompt(errors)

      case Cluster.send_message(runner_node, session.id, corrective_prompt) do
        :ok ->
          :ok

        other ->
          Logger.warning(
            "ApiRunController: corrective send_message for run #{run.id} " <>
              "(session #{session.id}) returned #{inspect(other)}"
          )
      end

      render_run(conn, run,
        session_status: session.status,
        status_override: "in_progress",
        note: "retrying validation"
      )
    else
      {:ok, run} =
        HubRPC.update_api_run(run, %{
          status: "failed",
          error:
            "validation failed after #{run.max_validation_attempts} attempts: " <>
              Enum.join(errors, "; "),
          result_text: text
        })

      render_run(conn, run)
    end
  end

  # This corrective prompt is only reached via the idle-fallback path (a
  # schema-run session went idle without ever calling submit_result — see
  # handle_idle_result/4) — the primary channel is the submit_result tool
  # itself, whose validation errors return within the SAME turn as a tool
  # error (see MCP.Server), never reaching this poll-driven retry at all.
  defp corrective_prompt(errors) do
    "Your previous response did not produce a valid result:\n" <>
      Enum.map_join(errors, "\n", &"- #{&1}") <>
      "\n\nCall the submit_result tool with your final result now — a plain text response is not accepted."
  end

  # ---------------------------------------------------------------------
  # Response shaping
  # ---------------------------------------------------------------------

  defp render_run(conn, run, opts \\ []) do
    body =
      %{
        run_id: run.id,
        session_id: run.session_id,
        status: Keyword.get(opts, :status_override, run.status),
        session_status: Keyword.get(opts, :session_status),
        result: run.result,
        result_text: run.result_text,
        error: run.error,
        validation_attempts: run.validation_attempts
      }
      |> maybe_put(:note, Keyword.get(opts, :note))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    json(conn, body)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
