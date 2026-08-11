defmodule OrcaHubWeb.A2AController do
  @moduledoc """
  Inbound A2A (Agent2Agent) v0.3.0 server surface (docs/a2a.md) — lets an
  external service dispatch work to an OrcaHub project over the A2A JSON-RPC
  protocol. `OrcaHub.A2A` (the OUTBOUND client) is proven to drive this
  controller end-to-end by `test/orca_hub_web/controllers/a2a_controller_test.exs`'s
  symmetry test — keep the wire shapes in sync with what that module expects.

  An A2A "agent" is an OrcaHub project (agent id == project id). `tasks/get`
  is a pure poll-driven state machine, same philosophy as
  `OrcaHubWeb.ApiRunController.show/2` (see `OrcaHub.A2ATasks.advance/1`) —
  no background monitor process.

  Hub-only by design: not on the agent-mode HTTP allow-list
  (`OrcaHubWeb.Endpoint.agent_mode_allowed?/1`) since this needs the `Repo`
  directly.
  """

  use OrcaHubWeb, :controller

  require Logger

  alias OrcaHub.{A2ATasks, ApiRuns, Cluster, HubRPC, SessionRunner}
  alias OrcaHub.MCP.ToolCallHolder.A2ATaskHolder

  # JSON-RPC 2.0 error codes. The A2A-specific codes (-3200x) follow the A2A
  # v0.3.0 spec's reserved server-error range; -32600/-32601/-32602 are
  # plain JSON-RPC 2.0.
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @task_not_found -32001
  @task_not_cancelable -32002
  @push_notification_not_supported -32003
  @unsupported_operation -32004
  @server_error -32000

  @unsupported_methods ~w(message/stream tasks/resubscribe tasks/list)

  # ---------------------------------------------------------------------
  # GET /a2a/agents
  # ---------------------------------------------------------------------

  def agents(conn, _params) do
    agents =
      Enum.map(HubRPC.list_projects(), fn project ->
        %{"id" => project.id, "name" => project.name, "description" => project.directory}
      end)

    json(conn, %{"agents" => agents})
  end

  # ---------------------------------------------------------------------
  # GET /a2a/agents/:id/.well-known/agent-card.json
  # ---------------------------------------------------------------------

  def agent_card(conn, %{"id" => id}) do
    case fetch_project(id) do
      {:ok, project} -> json(conn, agent_card_body(project))
      :error -> agent_not_found(conn)
    end
  end

  defp agent_card_body(project) do
    %{
      "name" => project.name,
      "description" => project.directory,
      "url" => OrcaHubWeb.Endpoint.url() <> "/a2a/agents/#{project.id}",
      "protocolVersion" => "0.3.0",
      "capabilities" => %{"streaming" => false, "pushNotifications" => false},
      "defaultInputModes" => ["text/plain"],
      "defaultOutputModes" => ["text/plain"],
      "skills" => [
        %{
          "id" => "run-session",
          "name" => "Run an agent session",
          "description" =>
            "Runs an OrcaHub agent session in the #{project.name} project " <>
              "(#{project.directory}), driven by the sent message text.",
          "tags" => ["agent", "coding"]
        }
      ]
    }
  end

  defp agent_not_found(conn), do: conn |> put_status(404) |> json(%{"error" => "agent not found"})

  # ---------------------------------------------------------------------
  # POST /a2a/agents/:agent_id — JSON-RPC 2.0 endpoint
  # ---------------------------------------------------------------------

  def rpc(conn, %{"agent_id" => agent_id} = params) do
    case fetch_project(agent_id) do
      {:ok, project} -> dispatch(conn, project, params)
      :error -> agent_not_found(conn)
    end
  end

  defp dispatch(conn, project, %{"jsonrpc" => "2.0"} = params) do
    handle_method(conn, project, params["method"], params["params"] || %{}, params["id"])
  end

  defp dispatch(conn, _project, params) do
    rpc_error(conn, params["id"], @invalid_request, "jsonrpc must be \"2.0\"")
  end

  defp handle_method(conn, project, "message/send", rpc_params, rpc_id),
    do: handle_message_send(conn, project, rpc_params, rpc_id)

  defp handle_method(conn, _project, "tasks/get", rpc_params, rpc_id),
    do: handle_tasks_get(conn, rpc_params, rpc_id)

  defp handle_method(conn, _project, "tasks/cancel", rpc_params, rpc_id),
    do: handle_tasks_cancel(conn, rpc_params, rpc_id)

  defp handle_method(conn, _project, method, _rpc_params, rpc_id)
       when method in @unsupported_methods do
    rpc_error(
      conn,
      rpc_id,
      @unsupported_operation,
      "#{method} is not supported by this A2A server (no streaming/subscriptions yet)"
    )
  end

  defp handle_method(conn, _project, "tasks/pushNotificationConfig/" <> _, _rpc_params, rpc_id) do
    rpc_error(
      conn,
      rpc_id,
      @push_notification_not_supported,
      "push notifications are not supported by this A2A server"
    )
  end

  defp handle_method(conn, _project, method, _rpc_params, rpc_id) do
    rpc_error(conn, rpc_id, @method_not_found, "unknown method #{inspect(method)}")
  end

  # ---------------------------------------------------------------------
  # message/send
  # ---------------------------------------------------------------------

  # v2 (docs/a2a.md "Tool-call loop"): `message.taskId` now narrows v1's
  # blanket -32602 — it's how the caller answers a parked client-tool call
  # (`handle_tool_answer/4`). A plain text/contextId send (new session or
  # follow-up turn) never carries `taskId`.
  defp handle_message_send(
         conn,
         _project,
         %{"message" => %{"taskId" => task_id} = message},
         rpc_id
       )
       when is_binary(task_id) and task_id != "" do
    handle_tool_answer(conn, task_id, message, rpc_id)
  end

  defp handle_message_send(conn, project, %{"message" => message}, rpc_id)
       when is_map(message) do
    case Map.get(message, "contextId") do
      nil -> handle_new_session_send(conn, project, message, rpc_id)
      context_id -> handle_continuation_send(conn, project, context_id, message, rpc_id)
    end
  end

  defp handle_message_send(conn, _project, _rpc_params, rpc_id),
    do: rpc_error(conn, rpc_id, @invalid_params, "params.message is required")

  defp handle_new_session_send(conn, project, message, rpc_id) do
    with {:ok, text} <- extract_text(message),
         {:ok, declarations} <- extract_declarations(message) do
      create_new_session_task(conn, project, text, no_tools?(message), declarations, rpc_id)
    else
      {:error, reason} -> rpc_error(conn, rpc_id, @invalid_params, reason)
    end
  end

  defp handle_continuation_send(conn, project, context_id, message, rpc_id) do
    with :ok <- reject_declarations_on_continuation(message),
         {:ok, text} <- extract_text(message) do
      continue_session_task(conn, project, context_id, text, rpc_id)
    else
      {:error, reason} -> rpc_error(conn, rpc_id, @invalid_params, reason)
    end
  end

  defp extract_text(%{"parts" => parts}) when is_list(parts) do
    text =
      parts
      |> Enum.filter(&(&1["kind"] == "text"))
      |> Enum.map_join("", & &1["text"])
      |> String.trim()

    if text == "" do
      {:error, "message.parts must include at least one non-empty \"kind\": \"text\" part"}
    else
      {:ok, text}
    end
  end

  defp extract_text(_message), do: {:error, "message.parts is required"}

  # message.metadata (A2A's standard per-message extension point, docs/a2a.md
  # "Metadata extensions"): "no_tools" mirrors the Agent Runs API's `no_tools`
  # (ApiRunController.validate_no_tools/2) — anything other than exactly
  # `true` is treated as "not requested", no error. `no_tools` is fully
  # independent of `client_tools`/`result_schema` below — it only ever empties
  # the session's BUILT-IN tool allow-list (`tools: ""`); the synthesized
  # submit_result/client-tools MCP surface (docs/a2a.md "v2") is wired up (or
  # not) purely based on whether client_tools/result_schema were declared,
  # regardless of no_tools. The two compose freely, exactly like the Agent
  # Runs API's identical `no_tools` + `client_tools`/`result_schema` combo
  # (docs/api.md).
  defp no_tools?(%{"metadata" => %{"no_tools" => true}}), do: true
  defp no_tools?(_message), do: false

  # v2 declaration (docs/a2a.md "Declaration", session-creating sends only):
  # reuses OrcaHub.ApiRuns.validate_client_tools/1 verbatim — same shape,
  # same reserved-name/uniqueness rules as the Agent Runs API's client_tools.
  @default_max_validation_attempts 3

  defp extract_declarations(%{"metadata" => metadata}) when is_map(metadata) do
    with {:ok, client_tools} <- ApiRuns.validate_client_tools(metadata["client_tools"]),
         {:ok, result_schema} <- validate_result_schema(metadata["result_schema"]),
         {:ok, max_validation_attempts} <-
           validate_max_validation_attempts(metadata["max_validation_attempts"]) do
      {:ok,
       %{
         client_tools: client_tools,
         result_schema: result_schema,
         max_validation_attempts: max_validation_attempts || @default_max_validation_attempts
       }}
    end
  end

  defp extract_declarations(_message) do
    {:ok,
     %{
       client_tools: nil,
       result_schema: nil,
       max_validation_attempts: @default_max_validation_attempts
     }}
  end

  defp validate_result_schema(nil), do: {:ok, nil}
  defp validate_result_schema(schema) when is_map(schema), do: {:ok, schema}

  defp validate_result_schema(_other),
    do: {:error, "result_schema must be an object (a JSON Schema)"}

  defp validate_max_validation_attempts(nil), do: {:ok, nil}

  defp validate_max_validation_attempts(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp validate_max_validation_attempts(_other),
    do: {:error, "max_validation_attempts must be a positive integer"}

  # Declaring ANY of client_tools/result_schema/max_validation_attempts on a
  # continuation is rejected -32602 BEFORE any state change (docs/a2a.md
  # "Declaration") — a deliberate asymmetry with no_tools (silently ignored
  # on continuations, see no_tools?/1 above): a silently-dropped
  # client_tools/result_schema would be a correctness trap, since the caller
  # would believe structured output/tool routing is active when it isn't.
  # Fires on presence alone, regardless of whether the value would otherwise
  # be valid — even max_validation_attempts given alone, with neither of the
  # other two present, is rejected.
  @declaration_keys ~w(client_tools result_schema max_validation_attempts)

  defp reject_declarations_on_continuation(%{"metadata" => metadata}) when is_map(metadata) do
    case Enum.filter(@declaration_keys, &Map.has_key?(metadata, &1)) do
      [] ->
        :ok

      keys ->
        {:error,
         "#{Enum.join(keys, ", ")} cannot be declared on a continuation (contextId) — " <>
           "client_tools/result_schema/max_validation_attempts are fixed at session creation " <>
           "and inherited automatically across the conversation; see docs/a2a.md"}
    end
  end

  defp reject_declarations_on_continuation(_message), do: :ok

  defp create_new_session_task(conn, project, text, no_tools, declarations, rpc_id) do
    runner_node = Cluster.project_node_for(project)

    cond do
      not Cluster.node_available?(runner_node) ->
        node_unavailable_error(conn, rpc_id, runner_node)

      no_tools and not claude_backend?(runner_node) ->
        rpc_error(
          conn,
          rpc_id,
          @invalid_params,
          "no_tools is only supported with backend \"claude\" — this project's node " <>
            "defaults to a different backend"
        )

      true ->
        do_create_new_session_task(
          conn,
          project,
          runner_node,
          text,
          no_tools,
          declarations,
          rpc_id
        )
    end
  end

  # Mirrors OrcaHub.Sessions.apply_node_defaults/merge_node_defaults: with no
  # explicit `backend` in session_attrs, the effective backend is the node's
  # configured default_backend, falling back to "claude" (the Session
  # schema's own column default) when the node has none set. Resolving this
  # BEFORE creating the session (rather than checking the changeset result
  # after the fact) avoids leaving behind an orphaned session row when the
  # request is rejected.
  defp claude_backend?(runner_node) do
    case HubRPC.get_node_by_name(Atom.to_string(runner_node)) do
      nil -> true
      node -> (node.default_backend || "claude") == "claude"
    end
  end

  defp do_create_new_session_task(
         conn,
         project,
         runner_node,
         text,
         no_tools,
         declarations,
         rpc_id
       ) do
    session_attrs =
      %{
        directory: project.directory,
        project_id: project.id,
        title: SessionRunner.fallback_title(text),
        status: "ready",
        triggered: true,
        runner_node: Atom.to_string(runner_node),
        tools: if(no_tools, do: "", else: nil)
      }
      |> maybe_disable_code_exec(declarations)

    with {:ok, session} <- HubRPC.create_session(session_attrs),
         task_attrs <- Map.put(declaration_task_attrs(declarations), :session_id, session.id),
         {:ok, task} <- A2ATasks.create_task(task_attrs) do
      Cluster.start_session(runner_node, session.id, session)

      # :queue (ORCAHUB3-29): session was just created (status "ready") so this
      # always delivers immediately either way — :queue for consistency.
      case Cluster.send_message(runner_node, session.id, full_prompt(text, declarations), :queue) do
        :ok ->
          :ok

        {:queued, _status} ->
          :ok

        other ->
          Logger.warning(
            "A2AController: send_message for task #{task.id} (session #{session.id}) " <>
              "returned #{inspect(other)}"
          )
      end

      rpc_result(conn, rpc_id, render_task(task))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        rpc_error(
          conn,
          rpc_id,
          @invalid_params,
          "invalid session parameters: #{inspect(changeset_errors(changeset))}"
        )
    end
  end

  # v2 (docs/a2a.md "v2 Declaration"): code_exec is ON by default for new
  # sessions (see Sessions.Session); a schema/client-tools task's MCP server
  # must expose ONLY the synthesized submit_result/client-tools surface —
  # mirrors ApiRunController.maybe_disable_code_exec/3 exactly.
  defp maybe_disable_code_exec(attrs, %{client_tools: nil, result_schema: nil}), do: attrs
  defp maybe_disable_code_exec(attrs, _declarations), do: Map.put(attrs, :code_exec, false)

  defp declaration_task_attrs(declarations) do
    %{
      client_tools: declarations.client_tools,
      result_schema: declarations.result_schema,
      max_validation_attempts: declarations.max_validation_attempts
    }
  end

  # Mirrors ApiRunController.append_schema_instructions/1 +
  # append_client_tools_instructions/2 verbatim — re-appended on EVERY task
  # in the conversation (not just the first), since v2 declarations are
  # inherited silently (the caller doesn't repeat them), so the model needs
  # the reminder every turn.
  defp full_prompt(text, declarations) do
    text
    |> append_schema_instructions(declarations.result_schema)
    |> append_client_tools_instructions(declarations.client_tools)
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

  defp continue_session_task(conn, project, context_id, text, rpc_id) do
    case fetch_session_in_project(context_id, project) do
      {:ok, session} -> do_continue_session_task(conn, session, text, rpc_id)
      :error -> unknown_context_error(conn, rpc_id, context_id)
    end
  end

  defp do_continue_session_task(conn, session, text, rpc_id) do
    runner_node = Cluster.runner_node_for(session)

    if Cluster.node_available?(runner_node) do
      # Snapshot BEFORE delivery — see OrcaHub.A2ATasks.advance/1's
      # awaiting_new_turn?/2 and ApiRunController's identical
      # baseline_message_count comment: the target session can already be
      # idle from a PREVIOUS turn the instant send_message returns.
      baseline_message_count = HubRPC.count_messages(session.id)
      # v2 inheritance (docs/a2a.md "Declaration"): declared once at session
      # creation, copy-forward from the conversation's most recent task —
      # the same "latest task for this session" lookup the MCP.Server holder
      # itself uses (OrcaHub.A2ATasks.get_task_by_session_id/1).
      declarations = inherited_declarations(session.id)

      task_attrs =
        declaration_task_attrs(declarations)
        |> Map.merge(%{session_id: session.id, baseline_message_count: baseline_message_count})

      {:ok, task} = A2ATasks.create_task(task_attrs)

      deliver_continuation(
        conn,
        task,
        session,
        runner_node,
        full_prompt(text, declarations),
        rpc_id
      )
    else
      node_unavailable_error(conn, rpc_id, runner_node)
    end
  end

  defp inherited_declarations(session_id) do
    case A2ATasks.get_task_by_session_id(session_id) do
      nil ->
        %{
          client_tools: nil,
          result_schema: nil,
          max_validation_attempts: @default_max_validation_attempts
        }

      task ->
        %{
          client_tools: task.client_tools,
          result_schema: task.result_schema,
          max_validation_attempts: task.max_validation_attempts
        }
    end
  end

  # :queue (ORCAHUB3-29): a fast/duplicate continuation call must not cancel a
  # still-running prior turn on the same session.
  defp deliver_continuation(conn, task, session, runner_node, text, rpc_id) do
    case Cluster.send_message(runner_node, session.id, text, :queue) do
      :ok ->
        rpc_result(conn, rpc_id, render_task(task))

      {:queued, _status} ->
        rpc_result(conn, rpc_id, render_task(task))

      {:error, reason} ->
        message =
          Cluster.node_unavailable_message(reason) ||
            "session #{session.id} could not be revived: #{inspect(reason)}"

        {:ok, task} = A2ATasks.update_task(task, %{status: "failed", error: message})
        rpc_result(conn, rpc_id, render_task(task))
    end
  end

  defp fetch_session_in_project(session_id, project) when is_binary(session_id) do
    case Ecto.UUID.cast(session_id) do
      :error ->
        :error

      {:ok, _} ->
        case HubRPC.get_session(session_id) do
          %{project_id: project_id} = session when project_id == project.id -> {:ok, session}
          _no_match -> :error
        end
    end
  end

  defp fetch_session_in_project(_session_id, _project), do: :error

  defp node_unavailable_error(conn, rpc_id, runner_node) do
    rpc_error(
      conn,
      rpc_id,
      @server_error,
      "node #{inspect(runner_node)} is not currently connected"
    )
  end

  defp unknown_context_error(conn, rpc_id, context_id) do
    rpc_error(
      conn,
      rpc_id,
      @task_not_found,
      "no session #{inspect(context_id)} in this agent (project)"
    )
  end

  # ---------------------------------------------------------------------
  # v2 tool-call answers — message/send WITH taskId (docs/a2a.md "Tool-call
  # loop"): answers a client-tool call parked by OrcaHub.MCP.Server against
  # this task (OrcaHub.MCP.ToolCallHolder.A2ATaskHolder). Mirrors
  # ApiRunController's tool_result/2 + deliver_tool_result/3 chain, with the
  # idempotent-ack precedence rule layered on top (docs/a2a.md, negotiated
  # carefully — see A2ATaskHolder.update/2's issued_tool_call_ids bookkeeping).
  # ---------------------------------------------------------------------

  defp handle_tool_answer(conn, task_id, message, rpc_id) do
    case fetch_task(task_id) do
      :error ->
        task_not_found_error(conn, rpc_id, task_id)

      {:ok, task} ->
        with :ok <- validate_answer_context_id(task, message),
             {:ok, tool_call_id, answer} <- extract_tool_answer(message) do
          resolve_tool_answer(conn, task, tool_call_id, answer, rpc_id)
        else
          {:error, reason} -> rpc_error(conn, rpc_id, @invalid_params, reason)
        end
    end
  end

  # contextId is optional alongside taskId; if present it must match the
  # task's own contextId (its session_id) — taskId alone is sufficient to
  # identify the task.
  defp validate_answer_context_id(%{session_id: session_id}, %{"contextId" => context_id})
       when is_binary(context_id) and context_id != "" and context_id != session_id do
    {:error,
     "message.contextId #{inspect(context_id)} does not match this task's contextId " <>
       inspect(session_id)}
  end

  defp validate_answer_context_id(_task, _message), do: :ok

  defp extract_tool_answer(%{"parts" => parts}) when is_list(parts) do
    case Enum.find(parts, &(&1["kind"] == "data")) do
      %{"data" => %{"tool_call_id" => tool_call_id} = data}
      when is_binary(tool_call_id) and tool_call_id != "" ->
        {:ok, tool_call_id, tool_answer_fields(data)}

      _other ->
        {:error,
         "message.parts must include a \"kind\": \"data\" part with a \"tool_call_id\" and " <>
           "either \"result\" or \"error\""}
    end
  end

  defp extract_tool_answer(_message), do: {:error, "message.parts is required"}

  defp tool_answer_fields(%{"error" => error}) when is_binary(error) and error != "",
    do: %{"error" => error}

  defp tool_answer_fields(data), do: %{"result" => Map.get(data, "result")}

  # Precedence: idempotent ack beats the state gate (docs/a2a.md, spelled out
  # precisely — negotiated carefully). Order matters:
  #   1. Matches the CURRENTLY parked call, unanswered yet — the normal,
  #      first-time resolution path (real-time if still held, hold_expired
  #      fallback otherwise).
  #   2. Matches the CURRENTLY parked call, ALREADY answered (a race: two
  #      answers for the same live call landed before MCP.Server consumed
  #      the first) — no-op ack, re-broadcast in case the first broadcast
  #      was missed (mirrors ApiRunController.ack_duplicate_tool_result/2).
  #   3. Was issued for this task at SOME point (not the current pending
  #      call — already superseded/cleared) — idempotent no-op ack, task
  #      object returned UNCHANGED, in ANY state including terminal. No
  #      client-side dedup required.
  #   4. Never issued for this task at all, in ANY state — -32602. This is
  #      the ONLY case that's rejected; a never-issued id is state-independent.
  defp resolve_tool_answer(conn, task, tool_call_id, answer, rpc_id) do
    cond do
      matches_current_pending?(task, tool_call_id) and
          not tool_call_answered?(task.pending_tool_call) ->
        deliver_tool_answer(conn, task, answer, rpc_id)

      matches_current_pending?(task, tool_call_id) ->
        ack_duplicate(conn, task, rpc_id)

      tool_call_id in (task.issued_tool_call_ids || []) ->
        rpc_result(conn, rpc_id, render_task(task))

      true ->
        rpc_error(
          conn,
          rpc_id,
          @invalid_params,
          "tool_call_id #{inspect(tool_call_id)} was never issued for task #{task.id}"
        )
    end
  end

  defp matches_current_pending?(%{pending_tool_call: %{"id" => id}}, tool_call_id),
    do: id == tool_call_id

  defp matches_current_pending?(_task, _tool_call_id), do: false

  defp tool_call_answered?(pending),
    do: Map.has_key?(pending, "result") or Map.has_key?(pending, "error")

  # A duplicate answer for the SAME live pending call, arriving after an
  # earlier answer already merged but before MCP.Server consumed it —
  # re-broadcast (harmless, ignored once no longer parked) rather than
  # re-merge; mirrors ApiRunController.ack_duplicate_tool_result/2.
  defp ack_duplicate(conn, task, rpc_id) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      A2ATaskHolder.topic(task.id),
      {:client_tool_result, task.id, task.pending_tool_call["id"],
       answer_payload(task.pending_tool_call)}
    )

    rpc_result(conn, rpc_id, render_task(task))
  end

  # The call is normally still parked open on a live MCP.Server (docs/a2a.md
  # "Tool-call loop"): merge the answer and broadcast it — MCP.Server
  # resolves the still-open tools/call, replies with the real result, THEN
  # clears pending_tool_call and flips status back to "working" itself (see
  # OrcaHub.MCP.Server's "Client tool call parking" section). If the hold
  # already timed out (A2ATaskHolder.parked_status/0-tracked hold expired —
  # the model already got the placeholder and ended its turn), fall back:
  # deliver the answer as a brand-new session message instead. Mirrors
  # ApiRunController.deliver_tool_result/3 exactly.
  defp deliver_tool_answer(conn, task, answer, rpc_id) do
    if task.pending_tool_call["hold_expired"] do
      deliver_tool_answer_via_message(conn, task, answer, rpc_id)
    else
      deliver_tool_answer_realtime(conn, task, answer, rpc_id)
    end
  end

  defp deliver_tool_answer_realtime(conn, task, answer, rpc_id) do
    tool_call = task.pending_tool_call
    merged_pending_tool_call = Map.merge(tool_call, answer)

    case A2ATasks.update_task(task, %{pending_tool_call: merged_pending_tool_call}) do
      {:ok, task} ->
        Phoenix.PubSub.broadcast(
          OrcaHub.PubSub,
          A2ATaskHolder.topic(task.id),
          {:client_tool_result, task.id, tool_call["id"], answer_payload(answer)}
        )

        # Response result is the task object; state moves to "working"
        # (docs/a2a.md) — an optimistic override, same as
        # ApiRunController.deliver_tool_result_realtime/3's immediate
        # `status: "running"`: MCP.Server hasn't actually consumed/cleared
        # the call yet, but the answer HAS been accepted and delivery is
        # underway, so the caller shouldn't see the stale "input-required".
        rpc_result(conn, rpc_id, render_task(task, status_override: "working"))

      {:error, changeset} ->
        rpc_error(
          conn,
          rpc_id,
          @invalid_params,
          "invalid tool answer: #{inspect(changeset_errors(changeset))}"
        )
    end
  end

  defp deliver_tool_answer_via_message(conn, task, answer, rpc_id) do
    tool_call = task.pending_tool_call
    session = task.session
    runner_node = Cluster.runner_node_for(session)
    # Re-snapshot BEFORE delivery — same baseline_message_count race guard
    # as every other continuation delivery in this controller.
    baseline_message_count = HubRPC.count_messages(session.id)

    {:ok, task} =
      A2ATasks.update_task(task, %{
        status: "working",
        pending_tool_call: nil,
        baseline_message_count: baseline_message_count
      })

    deliver_continuation(
      conn,
      task,
      session,
      runner_node,
      tool_answer_message(tool_call, answer),
      rpc_id
    )
  end

  defp tool_answer_message(tool_call, %{"error" => error})
       when is_binary(error) and error != "" do
    "Your #{tool_call["name"]} tool call (id #{tool_call["id"]}) failed:\n#{error}\n\n" <>
      "Continue the task."
  end

  defp tool_answer_message(tool_call, answer) do
    result_json = Jason.encode!(Map.get(answer, "result"), pretty: true)

    "Result of your #{tool_call["name"]} tool call (id #{tool_call["id"]}):\n" <>
      "```json\n#{result_json}\n```\n\nContinue the task."
  end

  defp answer_payload(%{"error" => error}) when is_binary(error) and error != "",
    do: {:error, error}

  defp answer_payload(answer), do: {:ok, Map.get(answer, "result")}

  # ---------------------------------------------------------------------
  # tasks/get
  # ---------------------------------------------------------------------

  defp handle_tasks_get(conn, %{"id" => task_id}, rpc_id) when is_binary(task_id) do
    case fetch_task(task_id) do
      {:ok, task} ->
        {:ok, task} = A2ATasks.advance(task)
        rpc_result(conn, rpc_id, render_task(task))

      :error ->
        task_not_found_error(conn, rpc_id, task_id)
    end
  end

  defp handle_tasks_get(conn, _rpc_params, rpc_id),
    do: task_not_found_error(conn, rpc_id, nil)

  # ---------------------------------------------------------------------
  # tasks/cancel
  # ---------------------------------------------------------------------

  defp handle_tasks_cancel(conn, %{"id" => task_id}, rpc_id) when is_binary(task_id) do
    case fetch_task(task_id) do
      {:ok, task} -> cancel_task(conn, task, rpc_id)
      :error -> task_not_found_error(conn, rpc_id, task_id)
    end
  end

  defp handle_tasks_cancel(conn, _rpc_params, rpc_id),
    do: task_not_found_error(conn, rpc_id, nil)

  defp cancel_task(conn, task, rpc_id) do
    if A2ATasks.terminal_status?(task.status) do
      rpc_error(
        conn,
        rpc_id,
        @task_not_cancelable,
        "task #{task.id} is already #{task.status} and cannot be canceled"
      )
    else
      best_effort_interrupt(task.session)
      {:ok, task} = A2ATasks.update_task(task, %{status: "canceled"})
      rpc_result(conn, rpc_id, render_task(task))
    end
  end

  defp best_effort_interrupt(session) do
    Cluster.interrupt(Cluster.runner_node_for(session), session.id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp fetch_task(id) do
    case Ecto.UUID.cast(id) do
      :error ->
        :error

      {:ok, _} ->
        case A2ATasks.get_task(id) do
          nil -> :error
          task -> {:ok, task}
        end
    end
  end

  defp task_not_found_error(conn, rpc_id, task_id) do
    rpc_error(conn, rpc_id, @task_not_found, "no task #{inspect(task_id)}")
  end

  # ---------------------------------------------------------------------
  # Task rendering (docs/a2a.md task object shape)
  # ---------------------------------------------------------------------

  defp render_task(task, opts \\ []) do
    %{
      "id" => task.id,
      "contextId" => task.session_id,
      "kind" => "task",
      "status" => render_status(task, opts)
    }
  end

  defp render_status(task, opts) do
    base = %{
      "state" => Keyword.get(opts, :status_override, task.status),
      "timestamp" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    case reply_message(task) do
      nil -> base
      message -> Map.put(base, "message", message)
    end
  end

  # v2 (docs/a2a.md "Tool-call loop"): the pending call as a DataPart,
  # discriminated by `metadata.orcahub_part: "tool_call"`. Rendered straight
  # off `task.pending_tool_call` regardless of whether it's already been
  # answered — "stale re-advertisement" is explicitly allowed by the spec
  # (harmless combined with the idempotent-ack precedence rule above), unlike
  # the Agent Runs API's v1 GET, which hides an answered-but-not-yet-consumed
  # tool_call to avoid a re-dispatch race.
  defp reply_message(%{status: "input-required", pending_tool_call: %{"id" => id} = pending}) do
    data_message(
      %{
        "tool_call_id" => id,
        "name" => pending["name"],
        "arguments" => pending["arguments"]
      },
      "tool_call"
    )
  end

  defp reply_message(%{status: "completed"} = task), do: completed_message(task)

  # v2 (docs/a2a.md "Structured results"): the specific failure shape for an
  # exhausted schema-validation retry loop — TextPart with the last RAW
  # (invalid) response, not the error text, no result DataPart (nothing ever
  # validated). Distinguished from every OTHER failure reason (session
  # errored, timeout, ...) by A2ATasks.retry_or_fail/4's exact error-text
  # prefix, since that's the only place this failure shape is produced.
  defp reply_message(%{
         status: "failed",
         error: "validation failed after" <> _,
         result_text: text
       })
       when is_binary(text) and text != "" do
    text_message(text)
  end

  defp reply_message(%{status: "failed", error: error}), do: text_message(error)
  defp reply_message(_task), do: nil

  # v2 (docs/a2a.md "Structured results"): validated result as a DataPart
  # (`metadata.orcahub_part: "result"`), alongside an optional TextPart
  # carrying the raw prose reply. A plain (no result_schema) completed task
  # has `result: nil` and renders exactly like v1 — TextPart only.
  defp completed_message(%{result_text: text, result: result}) do
    parts =
      text_parts(text) ++ if(is_map(result), do: [data_part(result, "result")], else: [])

    case parts do
      [] ->
        nil

      _ ->
        %{
          "role" => "agent",
          "messageId" => Ecto.UUID.generate(),
          "parts" => parts,
          "kind" => "message"
        }
    end
  end

  defp text_parts(text) when is_binary(text) and text != "",
    do: [%{"kind" => "text", "text" => text}]

  defp text_parts(_text), do: []

  defp data_message(data, orcahub_part) do
    %{
      "role" => "agent",
      "messageId" => Ecto.UUID.generate(),
      "parts" => [data_part(data, orcahub_part)],
      "kind" => "message"
    }
  end

  defp data_part(data, orcahub_part),
    do: %{"kind" => "data", "data" => data, "metadata" => %{"orcahub_part" => orcahub_part}}

  defp text_message(text) when is_binary(text) and text != "" do
    %{
      "role" => "agent",
      "messageId" => Ecto.UUID.generate(),
      "parts" => [%{"kind" => "text", "text" => text}],
      "kind" => "message"
    }
  end

  defp text_message(_text), do: nil

  # ---------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------

  defp fetch_project(id) do
    case Ecto.UUID.cast(id) do
      :error ->
        :error

      {:ok, _} ->
        case HubRPC.get_project(id) do
          %{deleted_at: nil} = project -> {:ok, project}
          _not_found_or_deleted -> :error
        end
    end
  end

  defp rpc_result(conn, rpc_id, result) do
    json(conn, %{"jsonrpc" => "2.0", "id" => rpc_id, "result" => result})
  end

  defp rpc_error(conn, rpc_id, code, message) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => rpc_id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
