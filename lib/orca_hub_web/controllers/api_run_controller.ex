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
    with :ok <- validate_no_client_tools_on_continuation(params),
         {:ok, prompt} <- fetch_prompt(params),
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
         {:ok, client_tools} <- ApiRuns.validate_client_tools(params["client_tools"]),
         runner_node <- resolve_runner_node(project),
         :ok <- check_node_available(runner_node) do
      create_run(conn, params, prompt, project, directory, backend, client_tools, runner_node)
    else
      {:error, status, body} ->
        conn |> put_status(status) |> json(body)

      {:error, message} when is_binary(message) ->
        conn |> put_status(400) |> json(%{error: message})
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

  # v1 restriction (docs/api.md): a continuation's MCP connection flag and
  # cached tool list are baked in at session creation (see
  # SessionRunner.init/1's api_run_flags), so client_tools can't be wired up
  # onto an already-existing session's connection.
  defp validate_no_client_tools_on_continuation(%{"client_tools" => client_tools})
       when not is_nil(client_tools) do
    {:error, 400,
     %{
       error:
         "client_tools is not yet supported on continuations (session_id) — the MCP " <>
           "connection's tool surface is baked in at session creation. Start a new run " <>
           "without session_id to use client_tools."
     }}
  end

  defp validate_no_client_tools_on_continuation(_params), do: :ok

  defp resolve_runner_node(nil), do: node()
  defp resolve_runner_node(project), do: Cluster.project_node_for(project)

  defp check_node_available(runner_node) do
    if Cluster.node_available?(runner_node) do
      :ok
    else
      {:error, 503, %{error: "node #{inspect(runner_node)} is not currently connected"}}
    end
  end

  defp create_run(conn, params, prompt, project, directory, backend, client_tools, runner_node) do
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
      |> maybe_disable_code_exec(result_schema, client_tools)

    with {:ok, session} <- HubRPC.create_session(session_attrs),
         {:ok, run} <-
           HubRPC.create_api_run(%{
             session_id: session.id,
             result_schema: result_schema,
             client_tools: client_tools,
             timeout_seconds: params["timeout_seconds"] || @default_timeout_seconds,
             max_validation_attempts:
               params["max_validation_attempts"] || @default_max_validation_attempts
           }) do
      Cluster.start_session(runner_node, session.id, session)

      message = full_prompt(prompt, result_schema, client_tools)

      case Cluster.send_message(runner_node, session.id, message) do
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
  # a schema/client-tools run's MCP server must expose ONLY the api_run
  # surface (docs/api.md), so code_exec has to be explicitly turned off —
  # leaving the key out of session_attrs entirely (rather than passing
  # `code_exec: nil`) would otherwise apply the column's `true` default via
  # the changeset.
  defp maybe_disable_code_exec(attrs, nil, nil), do: attrs

  defp maybe_disable_code_exec(attrs, _result_schema, _client_tools),
    do: Map.put(attrs, :code_exec, false)

  defp full_prompt(prompt, result_schema, client_tools \\ nil) do
    prompt
    |> append_schema_instructions(result_schema)
    |> append_client_tools_instructions(client_tools)
  end

  defp append_schema_instructions(prompt, nil), do: prompt

  defp append_schema_instructions(prompt, result_schema) do
    schema_json = Jason.encode!(result_schema, pretty: true)

    prompt <>
      "\n\nWhen you have your final answer, call the submit_result tool with a JSON object " <>
      "conforming to this JSON Schema (shown here for reference; the tool's input schema " <>
      "enforces it):\n```json\n#{schema_json}\n```"
  end

  defp append_client_tools_instructions(prompt, tools) when tools in [nil, []], do: prompt

  defp append_client_tools_instructions(prompt, client_tools) do
    names = Enum.map_join(client_tools, ", ", & &1["name"])

    prompt <>
      "\n\nSome of your tools (#{names}) are executed by the calling application, not by " <>
      "you directly — calling one forwards the call to the caller instead of running it " <>
      "yourself. After calling one of them, END YOUR TURN immediately (don't keep working " <>
      "or call another tool); the result will arrive as your next user message and you can " <>
      "continue from there. Only one such tool call may be in flight at a time."
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

  # A pending client (frontend) tool call (docs/api.md) parks the run here
  # until the caller POSTs /tool_result — the run's own status, not the
  # session's, is authoritative while this is set, so this MUST be checked
  # before falling into advance_running/3's session-status-driven
  # idle-completion logic below (which would otherwise be free to complete
  # the run off whatever the session's final assistant text happens to be).
  # Timeout still wins over an unanswered tool call, same as any other
  # in-progress run.
  defp advance_and_render(conn, %{status: "awaiting_tool_result"} = run) do
    cond do
      timed_out?(run) ->
        {:ok, run} = HubRPC.update_api_run(run, %{status: "timed_out"})
        render_run(conn, run)

      tool_call_answered?(run.pending_tool_call) ->
        # The caller's answer already landed in `pending_tool_call` (POST
        # /tool_result merged it — see deliver_tool_result_realtime/3) but
        # the parked MCP.Server hasn't consumed it yet (PubSub broadcast in
        # flight, or just slow). Rendering the tool_call here would let an
        # overlapping poll/handler loop see it as still-unanswered and
        # re-dispatch/double-POST the same answer, which then 409s once
        # consumption does land a moment later. Render as in_progress with
        # no tool_call instead — closes that window entirely.
        render_run(conn, run, session_status: run.session.status, status_override: "in_progress")

      true ->
        render_run(conn, run, tool_call: caller_tool_call(run.pending_tool_call))
    end
  end

  defp advance_and_render(conn, run) do
    if timed_out?(run) do
      {:ok, run} = HubRPC.update_api_run(run, %{status: "timed_out"})
      render_run(conn, run)
    else
      advance_running(conn, run, run.session)
    end
  end

  # Shared with POST /tool_result's duplicate-answer idempotency check below
  # — both sides key off the same "has this pending call already been
  # answered" question (docs/api.md's "Duplicate answers / 409" note).
  defp tool_call_answered?(pending),
    do: Map.has_key?(pending, "result") or Map.has_key?(pending, "error")

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
  # POST /api/v1/runs/:id/tool_result
  # ---------------------------------------------------------------------

  # Answers a pending client (frontend) tool call (docs/api.md): body is
  # `{"tool_call_id": "...", "result": <any JSON>}`, or
  # `{"tool_call_id": "...", "error": "..."}` for a failed tool execution.
  def tool_result(conn, %{"id" => id} = params) do
    case Ecto.UUID.cast(id) do
      :error -> conn |> put_status(404) |> json(%{error: "not found"})
      {:ok, _} -> do_tool_result(conn, id, params)
    end
  end

  defp do_tool_result(conn, id, params) do
    case HubRPC.get_api_run(id) do
      nil -> conn |> put_status(404) |> json(%{error: "not found"})
      run -> validate_and_deliver_tool_result(conn, run, params)
    end
  end

  defp validate_and_deliver_tool_result(conn, %{status: "awaiting_tool_result"} = run, params) do
    with {:ok, tool_call_id} <- fetch_tool_call_id(params),
         :ok <- validate_tool_call_id_match(run, tool_call_id) do
      deliver_tool_result(conn, run, params)
    else
      {:error, status, body} -> conn |> put_status(status) |> json(body)
    end
  end

  defp validate_and_deliver_tool_result(conn, run, _params) do
    conn
    |> put_status(409)
    |> json(%{
      error: "run #{run.id} is not awaiting a tool result (status: #{run.status})",
      run_id: run.id,
      status: run.status
    })
  end

  defp fetch_tool_call_id(%{"tool_call_id" => tool_call_id})
       when is_binary(tool_call_id) and tool_call_id != "" do
    {:ok, tool_call_id}
  end

  defp fetch_tool_call_id(_params), do: {:error, 400, %{error: "tool_call_id is required"}}

  defp validate_tool_call_id_match(%{pending_tool_call: %{"id" => tool_call_id}}, tool_call_id),
    do: :ok

  defp validate_tool_call_id_match(run, tool_call_id) do
    {:error, 409,
     %{
       error:
         "tool_call_id #{inspect(tool_call_id)} does not match the pending tool call " <>
           "#{inspect(run.pending_tool_call["id"])}",
       run_id: run.id
     }}
  end

  # The call is normally still parked open on a live MCP.Server (docs/api.md
  # "Client (frontend) tools"): merge the answer into `pending_tool_call` and
  # broadcast it — MCP.Server resolves the still-open tools/call, replies
  # with the real result, THEN clears pending_tool_call and flips status
  # back to "running" itself (see OrcaHub.MCP.Server's "Client tool call
  # parking" section). If the hold already timed out (MCP.Server marked
  # `hold_expired` — the model already got the v1 placeholder and ended its
  # turn, so there's nothing left parked to reply to), fall back to the v1
  # path: deliver the answer as a brand-new session message instead.
  defp deliver_tool_result(conn, run, params) do
    cond do
      tool_call_answered?(run.pending_tool_call) ->
        ack_duplicate_tool_result(conn, run)

      run.pending_tool_call["hold_expired"] ->
        deliver_tool_result_via_message(conn, run, params)

      true ->
        deliver_tool_result_realtime(conn, run, params)
    end
  end

  # A duplicate POST for the same tool_call_id, arriving after an earlier
  # POST already merged an answer into `pending_tool_call` but before the
  # parked MCP.Server consumed it (see deliver_tool_result_realtime/3 and
  # tool_call_answered?/1's GET-side counterpart above) — e.g. the caller's
  # own request timed out and it retried, landing a second copy of the same
  # answer. The FIRST POST already did the real work; treat this one as a
  # no-op ack rather than re-merging (which would be harmless but pointless)
  # or 409ing (which is what used to happen once consumption raced ahead —
  # docs/api.md's "Duplicate answers / 409" note). Re-broadcasting is
  # harmless — MCP.Server ignores it once the call is no longer parked — and
  # rescues a missed FIRST broadcast faster than the belt-and-braces poll.
  defp ack_duplicate_tool_result(conn, run) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      api_run_topic(run.id),
      {:client_tool_result, run.id, run.pending_tool_call["id"],
       answer_payload(run.pending_tool_call)}
    )

    conn
    |> put_status(202)
    |> json(%{run_id: run.id, session_id: run.session_id, status: "running"})
  end

  defp deliver_tool_result_realtime(conn, run, params) do
    tool_call = run.pending_tool_call
    merged_pending_tool_call = Map.merge(tool_call, answer_fields(params))

    case HubRPC.update_api_run(run, %{pending_tool_call: merged_pending_tool_call}) do
      {:ok, run} ->
        Phoenix.PubSub.broadcast(
          OrcaHub.PubSub,
          api_run_topic(run.id),
          {:client_tool_result, run.id, tool_call["id"], answer_payload(params)}
        )

        conn
        |> put_status(202)
        |> json(%{run_id: run.id, session_id: run.session_id, status: "running"})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid parameters", details: changeset_errors(changeset)})
    end
  end

  # Reuses deliver_continuation/5's exact revive/error handling — resuming a
  # run after an answered tool call is the same "wake up and deliver a
  # message" operation a continuation's initial delivery is.
  defp deliver_tool_result_via_message(conn, run, params) do
    tool_call = run.pending_tool_call
    session = run.session
    runner_node = Cluster.runner_node_for(session)
    # Re-snapshot BEFORE delivery — see awaiting_new_turn?/2 and the
    # migration comment on baseline_message_count; the session may have
    # gone further idle while this run sat awaiting_tool_result.
    baseline_message_count = HubRPC.count_messages(session.id)

    {:ok, run} =
      HubRPC.update_api_run(run, %{
        status: "running",
        pending_tool_call: nil,
        baseline_message_count: baseline_message_count
      })

    deliver_continuation(conn, run, session, runner_node, tool_result_message(tool_call, params))
  end

  defp tool_result_message(tool_call, %{"error" => error})
       when is_binary(error) and error != "" do
    "Your #{tool_call["name"]} tool call (id #{tool_call["id"]}) failed:\n#{error}\n\n" <>
      "Continue the task."
  end

  defp tool_result_message(tool_call, params) do
    result_json = Jason.encode!(Map.get(params, "result"), pretty: true)

    "Result of your #{tool_call["name"]} tool call (id #{tool_call["id"]}):\n" <>
      "```json\n#{result_json}\n```\n\nContinue the task."
  end

  defp answer_fields(%{"error" => error}) when is_binary(error) and error != "" do
    %{"error" => error}
  end

  defp answer_fields(params), do: %{"result" => Map.get(params, "result")}

  defp answer_payload(%{"error" => error}) when is_binary(error) and error != "" do
    {:error, error}
  end

  defp answer_payload(params), do: {:ok, Map.get(params, "result")}

  # Must match OrcaHub.MCP.Server's api_run_topic/1 exactly — Phoenix.PubSub
  # auto-distributes across nodes, so the caller-facing hub and the
  # session's (possibly agent-node) MCP.Server never need direct rpc to
  # signal each other.
  defp api_run_topic(run_id), do: "api_run:#{run_id}"

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
      |> maybe_put(:tool_call, Keyword.get(opts, :tool_call))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    json(conn, body)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # `pending_tool_call` grows internal bookkeeping fields once an answer is
  # in flight (`result`/`error`) or the hold has timed out (`hold_expired`,
  # see MCP.Server) — none of that is part of the documented `tool_call`
  # shape (docs/api.md: `{"id", "name", "arguments"}`), so it's stripped
  # here rather than leaking implementation detail into the poll response.
  defp caller_tool_call(nil), do: nil
  defp caller_tool_call(pending), do: Map.take(pending, ["id", "name", "arguments"])

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
