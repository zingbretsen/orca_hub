defmodule OrcaHub.A2A do
  @moduledoc """
  Generic A2A (Agent2Agent) v0.3.0 JSON-RPC client, built on Req.

  This module knows nothing about any specific A2A server — every function
  takes a `%OrcaHub.A2A.Server{}` (base URL + bearer token + optional Req
  overrides for testing) as its first argument. phx-app
  (`OrcaHub.MCP.Tools.PhxAgents`) is the first caller; wiring up a second
  A2A-speaking service later is just another `%Server{}` value passed to
  these same functions, no changes needed here.

  Covers the subset of the A2A v0.3.0 surface phx-app implements today:
  `message/send`, `tasks/get`, `tasks/cancel`, plus the plain-HTTP agent
  discovery endpoints (`GET /a2a/agents`, agent cards). `message/stream`
  (SSE) is deliberately out of scope for now.

  Additive v2 support (docs/a2a.md "v2: client tools + structured results"):
  `send_message/4`'s `:metadata` option carries a session-creating send's
  `client_tools`/`result_schema`/`max_validation_attempts` declaration (or
  `no_tools`); `answer_tool_call/6` answers a parked client-tool call via a
  `taskId`-bearing send; `data_parts/1`, `result_data/1`, and
  `pending_tool_call/1` read the `DataPart` shapes v2 introduces, keyed off
  the `metadata.orcahub_part` discriminator. `reply_text/1`'s `TextPart`-only
  behavior is unchanged — a v1-only caller doesn't need to touch any of this.
  """

  defmodule Server do
    @moduledoc "Connection info for one A2A server: base URL + bearer token."
    @enforce_keys [:base_url]
    defstruct base_url: nil, token: nil, req_options: []
  end

  @terminal_states ~w(completed failed canceled rejected)

  @doc "GET /a2a/agents — every agent the token's user owns."
  def list_agents(%Server{} = server) do
    case get(server, "/a2a/agents") do
      {:ok, %{"agents" => agents}} when is_list(agents) -> {:ok, agents}
      {:ok, agents} when is_list(agents) -> {:ok, agents}
      {:ok, _other} -> {:ok, []}
      error -> error
    end
  end

  @doc "GET /a2a/agents/:id/.well-known/agent-card.json"
  def get_agent_card(%Server{} = server, agent_id) do
    get(server, "/a2a/agents/#{agent_id}/.well-known/agent-card.json")
  end

  @doc """
  `message/send` — start or continue a conversation with `agent_id`.

  Options:
    * `:context_id` — a prior task's `id` (== `contextId`), to continue
      that same conversation instead of starting a new one.
    * `:message_id` — override the generated message UUID (rarely needed).
    * `:metadata` — a map merged onto `message.metadata` (e.g. `no_tools`,
      or the v2 declaration keys `client_tools`/`result_schema`/
      `max_validation_attempts` on a session-creating send — docs/a2a.md
      "v2: client tools + structured results").

  Returns `{:ok, task}` — the JSON-RPC `result`, a task map with `"id"`
  (== `"contextId"` == the underlying phx-app chat id), `"status"`, `"kind"`.
  """
  def send_message(%Server{} = server, agent_id, text, opts \\ []) when is_binary(text) do
    message =
      %{
        "messageId" => Keyword.get(opts, :message_id, Ecto.UUID.generate()),
        "role" => "user",
        "parts" => [%{"kind" => "text", "text" => text}]
      }
      |> put_context_id(Keyword.get(opts, :context_id))
      |> put_metadata(Keyword.get(opts, :metadata))

    rpc(server, agent_id, "message/send", %{"message" => message})
  end

  @doc """
  v2 (docs/a2a.md "Tool-call loop"): answers a client-tool call parked by
  `agent_id` against `task_id` — a `message/send` WITH `taskId` set, carrying
  a `DataPart` instead of a `TextPart`. `answer` is `{:result, value}` (any
  JSON-encodable value) or `{:error, reason}` (a string, for a failed
  client-side tool execution).

  Options:
    * `:context_id` — optional; if given it's checked server-side against
      the task's own `contextId` (mismatch is rejected). `task_id` alone is
      sufficient to identify the task.
    * `:message_id` — override the generated message UUID.

  Returns `{:ok, task}` exactly like `send_message/4` — per the idempotent-
  ack precedence rule (docs/a2a.md), answering the SAME `tool_call_id` again
  later (even after the task has moved on) is always safe to retry.
  """
  def answer_tool_call(%Server{} = server, agent_id, task_id, tool_call_id, answer, opts \\ [])
      when is_binary(task_id) and is_binary(tool_call_id) do
    message =
      %{
        "messageId" => Keyword.get(opts, :message_id, Ecto.UUID.generate()),
        "role" => "user",
        "taskId" => task_id,
        "parts" => [%{"kind" => "data", "data" => tool_call_answer_data(tool_call_id, answer)}]
      }
      |> put_context_id(Keyword.get(opts, :context_id))

    rpc(server, agent_id, "message/send", %{"message" => message})
  end

  defp tool_call_answer_data(tool_call_id, {:result, value}),
    do: %{"tool_call_id" => tool_call_id, "result" => value}

  defp tool_call_answer_data(tool_call_id, {:error, reason}) when is_binary(reason),
    do: %{"tool_call_id" => tool_call_id, "error" => reason}

  @doc "`tasks/get` — current state of a task."
  def get_task(%Server{} = server, agent_id, task_id) do
    rpc(server, agent_id, "tasks/get", %{"id" => task_id})
  end

  @doc "`tasks/cancel` — cancel an in-flight task."
  def cancel_task(%Server{} = server, agent_id, task_id) do
    rpc(server, agent_id, "tasks/cancel", %{"id" => task_id})
  end

  @doc """
  Poll `get_task/3` with exponential backoff (starting at `:poll_interval_ms`,
  default 500ms, capped at 5s) until the task reaches a terminal state
  (`completed`/`failed`/`canceled`/`rejected`) or `:timeout_ms` (default
  120_000) elapses. Returns `{:ok, task}` on reaching ANY terminal state —
  callers inspect `task["status"]["state"]` themselves to distinguish
  success from failure — or `{:error, :timeout}`.
  """
  def wait_for_result(%Server{} = server, agent_id, task_id, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 500)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(server, agent_id, task_id, deadline, poll_interval_ms)
  end

  @doc "Extract the agent's reply text from a terminal task's status.message.parts, if any."
  def reply_text(%{"status" => %{"message" => %{"parts" => parts}}}) when is_list(parts) do
    text =
      parts
      |> Enum.filter(&(&1["kind"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    if text == "", do: nil, else: text
  end

  def reply_text(_task), do: nil

  @doc """
  v2 (docs/a2a.md "v2: client tools + structured results"): every
  `"kind": "data"` part on a task's `status.message`, if any — `[]` for a
  text-only (v1) task or one with no message at all.
  """
  def data_parts(%{"status" => %{"message" => %{"parts" => parts}}}) when is_list(parts) do
    Enum.filter(parts, &(&1["kind"] == "data"))
  end

  def data_parts(_task), do: []

  @doc """
  v2: the validated structured result (`metadata.orcahub_part: "result"`) on
  a `"completed"` task, or `nil` if the task has no result data part yet
  (still in progress, failed before validating, or a plain text-only v1
  reply).
  """
  def result_data(task), do: data_part(task, "result")

  @doc """
  v2: the pending client-tool call (`metadata.orcahub_part: "tool_call"`) on
  an `"input-required"` task — `%{"tool_call_id", "name", "arguments"}` — or
  `nil` if none is pending.
  """
  def pending_tool_call(task), do: data_part(task, "tool_call")

  defp data_part(task, orcahub_part) do
    case Enum.find(data_parts(task), &(get_in(&1, ["metadata", "orcahub_part"]) == orcahub_part)) do
      %{"data" => data} -> data
      nil -> nil
    end
  end

  @doc "Whether `state` is one of the terminal A2A task states."
  def terminal_state?(state), do: state in @terminal_states

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp poll(server, agent_id, task_id, deadline, interval_ms) do
    with {:ok, task} <- get_task(server, agent_id, task_id) do
      state = get_in(task, ["status", "state"])

      if terminal_state?(state) do
        {:ok, task}
      else
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :timeout}
        else
          Process.sleep(min(interval_ms, remaining_ms))
          poll(server, agent_id, task_id, deadline, min(interval_ms * 2, 5_000))
        end
      end
    end
  end

  defp rpc(server, agent_id, method, params) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => Ecto.UUID.generate(),
      "method" => method,
      "params" => params
    }

    case post(server, "/a2a/agents/#{agent_id}", body) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => rpc_error}} -> {:error, {:rpc_error, rpc_error}}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end

  defp get(server, path) do
    ([method: :get, url: server.base_url <> path, headers: auth_headers(server)] ++
       server.req_options)
    |> Req.request()
    |> handle_response()
  end

  defp post(server, path, json_body) do
    ([method: :post, url: server.base_url <> path, headers: auth_headers(server), json: json_body] ++
       server.req_options)
    |> Req.request()
    |> handle_response()
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp auth_headers(%Server{token: nil}), do: []
  defp auth_headers(%Server{token: token}), do: [{"authorization", "Bearer #{token}"}]

  defp put_context_id(message, nil), do: message
  defp put_context_id(message, context_id), do: Map.put(message, "contextId", context_id)

  defp put_metadata(message, nil), do: message

  defp put_metadata(message, metadata) when is_map(metadata),
    do: Map.put(message, "metadata", metadata)
end
