defmodule OrcaHub.MCP.Tools.PhxAgents do
  @moduledoc """
  MCP tools for messaging phx-app's domain agents (todos/projects, chores,
  relationships, learning, content, location) over A2A JSON-RPC
  (`OrcaHub.A2A`), so ANY session — including Bash-less orchestrators, which
  can't shell out to curl the way the `phx-app-agents` skill documents — can
  discover and message them as plain `Tools.*` functions from `run_elixir`.

  Configuration (base URL + bearer token) is resolved from application env
  (`PHX_APP_A2A_URL`/`PHX_APP_A2A_TOKEN`, see `config/runtime.exs`) — the
  same shape `OrcaHub.MCP.Tools.Databases` uses for the pg-provisioner
  token, an env var rather than a DB-backed secret, because the MCP server
  for a session runs on the session's own runner node and agent nodes have
  no `Repo`. Must be set on every node (k3s pods + systemd hosts), not just
  the hub.

  Only text message parts are read/written; file/data parts and
  `message/stream` (SSE) are deliberately out of scope for now — see
  `OrcaHub.A2A`.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.A2A

  @default_wait_timeout_seconds 120

  def list do
    [
      %{
        "name" => "phx_list_agents",
        "description" =>
          "List phx-app's domain agents available to message (todos/projects, chores, " <>
            "relationships, learning, content, location, etc.) — each has an id, name, " <>
            "description, and specialty. Use the id with phx_send_to_agent. Optionally " <>
            "filter client-side by a name/description/specialty substring.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" =>
                "Optional case-insensitive substring to filter agents by name, " <>
                  "description, or specialty."
            }
          }
        }
      },
      %{
        "name" => "phx_send_to_agent",
        "description" =>
          "Send a message to a phx-app agent over A2A, starting a new conversation, or " <>
            "CONTINUING a prior one by passing `context_id` (the `task_id`/`context_id` " <>
            "returned from an earlier phx_send_to_agent or phx_get_task call — phx-app's " <>
            "task id, context id, and underlying chat id are all the same value, so the " <>
            "reply carries the id forward to continue with). By default waits (polling) " <>
            "for the agent's reply up to `timeout` seconds and returns it; pass wait=false " <>
            "to get the task id back immediately and check it later with phx_get_task.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{
              "type" => "string",
              "description" => "Agent id from phx_list_agents."
            },
            "message" => %{"type" => "string", "description" => "Message text to send."},
            "context_id" => %{
              "type" => "string",
              "description" =>
                "A prior task/context id to CONTINUE that same conversation instead of " <>
                  "starting a new one. Omit to start a fresh conversation."
            },
            "wait" => %{
              "type" => "boolean",
              "description" => "Wait for the agent's reply before returning. Default true."
            },
            "timeout" => %{
              "type" => "integer",
              "description" =>
                "Max seconds to wait for a reply when wait=true. Default " <>
                  "#{@default_wait_timeout_seconds}."
            }
          },
          "required" => ["agent_id", "message"]
        }
      },
      %{
        "name" => "phx_get_task",
        "description" =>
          "Check the current state of a phx-app A2A task (e.g. one started with " <>
            "phx_send_to_agent wait=false). Returns the state and, once terminal " <>
            "(completed/failed/canceled/rejected), the agent's reply text. The returned " <>
            "task id doubles as the context_id to pass back into phx_send_to_agent to " <>
            "CONTINUE this same conversation.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{
              "type" => "string",
              "description" => "Agent id the task belongs to."
            },
            "task_id" => %{
              "type" => "string",
              "description" => "Task id (== context id) to check."
            }
          },
          "required" => ["agent_id", "task_id"]
        }
      }
    ]
  end

  def call("phx_list_agents", args, _state) do
    with {:ok, server} <- require_server() do
      do_list_agents(server, args["query"])
    else
      {:error, reason} -> error(reason)
    end
  end

  def call("phx_send_to_agent", args, _state) do
    with {:ok, server} <- require_server(),
         {:ok, agent_id} <- require_string(args, "agent_id"),
         {:ok, message} <- require_string(args, "message") do
      do_send(server, agent_id, message, args)
    else
      {:error, reason} -> error(reason)
    end
  end

  def call("phx_get_task", args, _state) do
    with {:ok, server} <- require_server(),
         {:ok, agent_id} <- require_string(args, "agent_id"),
         {:ok, task_id} <- require_string(args, "task_id") do
      do_get_task(server, agent_id, task_id)
    else
      {:error, reason} -> error(reason)
    end
  end

  # ------------------------------------------------------------------
  # phx_list_agents
  # ------------------------------------------------------------------

  defp do_list_agents(server, query) do
    case A2A.list_agents(server) do
      {:ok, agents} -> text(Jason.encode!(filter_agents(agents, query)))
      {:error, reason} -> error(format_error(reason))
    end
  end

  defp filter_agents(agents, query) when is_binary(query) and query != "" do
    q = String.downcase(query)

    Enum.filter(agents, fn agent ->
      [agent["name"], agent["description"], agent["specialty"]]
      |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), q)))
    end)
  end

  defp filter_agents(agents, _query), do: agents

  # ------------------------------------------------------------------
  # phx_send_to_agent
  # ------------------------------------------------------------------

  defp do_send(server, agent_id, message, args) do
    case A2A.send_message(server, agent_id, message, context_id_opt(args)) do
      {:ok, task} ->
        if wait?(args) do
          await_result(server, agent_id, task, args)
        else
          text(Jason.encode!(task_summary(task)))
        end

      {:error, reason} ->
        error(format_error(reason))
    end
  end

  defp await_result(server, agent_id, task, args) do
    task_id = task["id"]
    timeout_seconds = wait_timeout_seconds(args)

    case A2A.wait_for_result(server, agent_id, task_id, timeout_ms: timeout_seconds * 1000) do
      {:ok, final_task} ->
        text(Jason.encode!(task_summary(final_task)))

      {:error, :timeout} ->
        error(
          "Timed out after #{timeout_seconds}s waiting for a reply. The task may still " <>
            "complete — check it with phx_get_task(agent_id: #{inspect(agent_id)}, " <>
            "task_id: #{inspect(task_id)}), or continue the conversation later with " <>
            "context_id: #{inspect(task_id)}."
        )
    end
  end

  # ------------------------------------------------------------------
  # phx_get_task
  # ------------------------------------------------------------------

  defp do_get_task(server, agent_id, task_id) do
    case A2A.get_task(server, agent_id, task_id) do
      {:ok, task} -> text(Jason.encode!(task_summary(task)))
      {:error, reason} -> error(format_error(reason))
    end
  end

  # ------------------------------------------------------------------
  # Shared helpers
  # ------------------------------------------------------------------

  defp task_summary(task) do
    %{
      task_id: task["id"],
      context_id: task["contextId"],
      state: get_in(task, ["status", "state"]),
      reply_text: A2A.reply_text(task)
    }
  end

  defp context_id_opt(%{"context_id" => context_id})
       when is_binary(context_id) and context_id != "",
       do: [context_id: context_id]

  defp context_id_opt(_args), do: []

  defp wait?(%{"wait" => false}), do: false
  defp wait?(_args), do: true

  defp wait_timeout_seconds(%{"timeout" => timeout}) when is_integer(timeout) and timeout > 0,
    do: timeout

  defp wait_timeout_seconds(_args), do: @default_wait_timeout_seconds

  defp require_string(args, key) do
    case args[key] do
      val when is_binary(val) and val != "" -> {:ok, val}
      _ -> {:error, "#{key} is required and must be a non-empty string"}
    end
  end

  defp require_server do
    case Application.get_env(:orca_hub, :phx_app_a2a_token) do
      token when is_binary(token) and token != "" ->
        {:ok, %A2A.Server{base_url: base_url(), token: token, req_options: req_options()}}

      _ ->
        {:error,
         "PHX_APP_A2A_TOKEN is not configured on this node — phx-app agent tools are unavailable. " <>
           "Ask a human to check the node's env/secrets."}
    end
  end

  defp base_url,
    do:
      Application.get_env(:orca_hub, :phx_app_a2a_url) ||
        "https://llm.lab.ingbretsenhome.com"

  defp req_options, do: Application.get_env(:orca_hub, :phx_app_a2a_req_options, [])

  defp format_error({:http_error, status, body}),
    do: "phx-app returned HTTP #{status}: #{inspect(body)}"

  defp format_error({:rpc_error, %{"code" => code, "message" => msg}}),
    do: "phx-app A2A error #{code}: #{msg}"

  defp format_error({:rpc_error, rpc_error}), do: "phx-app A2A error: #{inspect(rpc_error)}"
  defp format_error({:transport_error, reason}), do: "Failed to reach phx-app: #{inspect(reason)}"

  defp format_error({:unexpected_response, body}),
    do: "Unexpected phx-app response: #{inspect(body)}"

  defp format_error(other), do: inspect(other)
end
