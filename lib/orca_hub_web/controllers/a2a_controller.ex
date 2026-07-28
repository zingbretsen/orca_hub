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

  alias OrcaHub.{A2ATasks, Cluster, HubRPC, SessionRunner}

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

  defp handle_message_send(conn, project, %{"message" => message}, rpc_id)
       when is_map(message) do
    with {:ok, text} <- extract_text(message),
         :ok <- reject_task_id(message) do
      case Map.get(message, "contextId") do
        nil -> create_new_session_task(conn, project, text, rpc_id)
        context_id -> continue_session_task(conn, project, context_id, text, rpc_id)
      end
    else
      {:error, reason} -> rpc_error(conn, rpc_id, @invalid_params, reason)
    end
  end

  defp handle_message_send(conn, _project, _rpc_params, rpc_id),
    do: rpc_error(conn, rpc_id, @invalid_params, "params.message is required")

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

  # One OrcaHub A2A task == one turn: a follow-up is expressed via
  # message.contextId (the session id), not message.taskId — there is no
  # "add another message to an existing task" concept here.
  defp reject_task_id(%{"taskId" => task_id}) when is_binary(task_id) and task_id != "" do
    {:error,
     "message.taskId is not supported for follow-ups — use message.contextId (the prior " <>
       "task's contextId, i.e. the session id) instead; one OrcaHub A2A task is one turn"}
  end

  defp reject_task_id(_message), do: :ok

  defp create_new_session_task(conn, project, text, rpc_id) do
    runner_node = Cluster.project_node_for(project)

    if Cluster.node_available?(runner_node) do
      do_create_new_session_task(conn, project, runner_node, text, rpc_id)
    else
      node_unavailable_error(conn, rpc_id, runner_node)
    end
  end

  defp do_create_new_session_task(conn, project, runner_node, text, rpc_id) do
    session_attrs = %{
      directory: project.directory,
      project_id: project.id,
      title: SessionRunner.fallback_title(text),
      status: "ready",
      triggered: true,
      runner_node: Atom.to_string(runner_node)
    }

    with {:ok, session} <- HubRPC.create_session(session_attrs),
         {:ok, task} <- A2ATasks.create_task(%{session_id: session.id}) do
      Cluster.start_session(runner_node, session.id, session)

      case Cluster.send_message(runner_node, session.id, text) do
        :ok ->
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

      {:ok, task} =
        A2ATasks.create_task(%{
          session_id: session.id,
          baseline_message_count: baseline_message_count
        })

      deliver_continuation(conn, task, session, runner_node, text, rpc_id)
    else
      node_unavailable_error(conn, rpc_id, runner_node)
    end
  end

  defp deliver_continuation(conn, task, session, runner_node, text, rpc_id) do
    case Cluster.send_message(runner_node, session.id, text) do
      :ok ->
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

  defp render_task(task) do
    %{
      "id" => task.id,
      "contextId" => task.session_id,
      "kind" => "task",
      "status" => render_status(task)
    }
  end

  defp render_status(task) do
    base = %{
      "state" => task.status,
      "timestamp" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    case reply_message(task) do
      nil -> base
      message -> Map.put(base, "message", message)
    end
  end

  defp reply_message(%{status: "completed", result_text: text}), do: text_message(text)
  defp reply_message(%{status: "failed", error: error}), do: text_message(error)
  defp reply_message(_task), do: nil

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
