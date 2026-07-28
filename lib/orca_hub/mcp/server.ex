defmodule OrcaHub.MCP.Server do
  @moduledoc """
  GenServer managing an MCP session. Handles JSON-RPC message routing
  for the Streamable HTTP transport.
  """
  use GenServer
  require Logger

  alias OrcaHub.MCP.Tools
  alias OrcaHub.MCP.ToolCallHolder

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def via(session_id), do: {:via, Registry, {OrcaHub.MCPRegistry, session_id}}

  def handle_jsonrpc(session_id, message) do
    GenServer.call(via(session_id), {:jsonrpc, message}, :infinity)
  end

  # Start an MCP session (called from the Plug on initialize)
  def start_session(opts \\ []) do
    session_id = generate_session_id()
    orca_session_id = Keyword.get(opts, :orca_session_id)
    orchestrator = Keyword.get(opts, :orchestrator, false)
    code_exec = Keyword.get(opts, :code_exec, false)
    api_run = Keyword.get(opts, :api_run, false)

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OrcaHub.MCPSupervisor,
        {__MODULE__,
         session_id: session_id,
         orca_session_id: orca_session_id,
         orchestrator: orchestrator,
         code_exec: code_exec,
         api_run: api_run}
      )

    {:ok, session_id}
  end

  def stop_session(session_id) do
    case Registry.lookup(OrcaHub.MCPRegistry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(OrcaHub.MCPSupervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  def session_exists?(session_id) do
    Registry.lookup(OrcaHub.MCPRegistry, session_id) != []
  end

  # Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    orca_session_id = Keyword.get(opts, :orca_session_id)
    orchestrator = Keyword.get(opts, :orchestrator, false)
    # The kill switch is honored at resolution time so a stale code_exec=true
    # query param can never re-enable the feature node-wide.
    code_exec = OrcaHub.MCP.CodeExec.enabled?(Keyword.get(opts, :code_exec, false))
    # Agent Runs API (docs/api.md): whether this connection is scoped to the
    # api_run tool surface — a `submit_result` tool synthesized from a run's
    # result_schema, and/or caller-defined client (frontend) tools.
    api_run = Keyword.get(opts, :api_run, false)

    Logger.info(
      "[MCP] session start: mcp_session_id=#{session_id} " <>
        "orca_session_id=#{inspect(orca_session_id)} orchestrator=#{orchestrator} " <>
        "code_exec=#{code_exec} api_run=#{api_run}"
    )

    # `initialize` does NO hub work. The connection role (orchestrator?) is
    # carried by the MCP connection itself (a query param set by
    # SessionRunner) rather than resolved via a hub/DB lookup. This keeps the
    # MCP handshake fast — no erpc, no DB — so tools/list is ready before the
    # model emits its first tool call, and a hub outage can't strip the
    # orchestrator tool set. `tool_holder` (the actual result_schema and/or
    # client_tools, plus which holder module backs this connection — see
    # `OrcaHub.MCP.ToolCallHolder`) is fetched lazily at tools/list (and,
    # defensively, tools/call) time instead — see `ensure_tool_holder/1` —
    # since THAT round-trip can tolerate the latency (nothing to hand-shake
    # against it).
    {:ok,
     %{
       session_id: session_id,
       orca_session_id: orca_session_id,
       orchestrator: orchestrator,
       code_exec: code_exec,
       api_run: api_run,
       tool_holder: nil,
       initialized: false,
       # Client (frontend) tool call currently holding a `tools/call` JSON-RPC
       # response open (docs/api.md) — see the "Client tool call parking"
       # section below. `nil` when nothing is parked.
       parked_tool_call: nil
     }}
  end

  # Client (frontend) tool calls on an api_run connection (every tools/call
  # name except the literal "submit_result") are intercepted here, BEFORE
  # `dispatch/2`, because resolving one may need to defer the JSON-RPC reply
  # (`{:noreply, state}`) rather than answer immediately — see "Client tool
  # call parking" below. submit_result is delegated straight to `dispatch/2`
  # unchanged (it always answers synchronously).
  @impl true
  def handle_call(
        {:jsonrpc, %{"method" => "tools/call", "id" => id, "params" => params} = message},
        from,
        %{api_run: true} = state
      ) do
    case params["name"] do
      "submit_result" ->
        {response, new_state} = dispatch(message, state)
        {:reply, response, new_state}

      tool_name ->
        handle_client_tool_call_dispatch(id, tool_name, params["arguments"] || %{}, from, state)
    end
  end

  @impl true
  def handle_call({:jsonrpc, message}, _from, state) do
    {response, new_state} = dispatch(message, state)
    {:reply, response, new_state}
  end

  # Hold timeout: give up waiting for the caller and hand the model the old
  # v1 placeholder ("forwarded, end your turn") so its turn can finish. The
  # DB `pending_tool_call`/run status are deliberately left untouched (still
  # `awaiting_tool_result`) — only marked `hold_expired` — so `GET`/`POST
  # .../tool_result` keep working exactly as they did pre-rework; see
  # ApiRunController.deliver_tool_result/3's `hold_expired` branch.
  @impl true
  def handle_info(
        {:client_tool_hold_timeout, tool_call_id},
        %{parked_tool_call: %{tool_call_id: tool_call_id} = parked} = state
      ) do
    reply_to_froms(parked.froms, placeholder_result())
    mark_hold_expired(parked.holder_mod, parked.holder_id, tool_call_id)
    cleanup_parked(parked)
    {:noreply, %{state | parked_tool_call: nil}}
  end

  def handle_info({:client_tool_hold_timeout, _stale_id}, state), do: {:noreply, state}

  # Belt-and-braces poll (docs/api.md's cross-node signaling note): the
  # primary resolution path is the PubSub broadcast below, but this covers a
  # missed/undelivered broadcast (e.g. a netsplit between the tool_result POST
  # landing on the hub and this GenServer running on an agent node).
  def handle_info(
        {:client_tool_poll, tool_call_id},
        %{parked_tool_call: %{tool_call_id: tool_call_id}} = state
      ) do
    {:noreply, poll_parked_call(state)}
  end

  def handle_info({:client_tool_poll, _stale_id}, state), do: {:noreply, state}

  # Real-time resolution: ApiRunController persists the caller's answer and
  # broadcasts this after `POST /api/v1/runs/:id/tool_result` — see
  # "Client tool call parking" below.
  def handle_info(
        {:client_tool_result, holder_id, tool_call_id, payload},
        %{parked_tool_call: %{holder_id: holder_id, tool_call_id: tool_call_id} = parked} = state
      ) do
    {:noreply, resolve_parked(parked, payload, state)}
  end

  def handle_info({:client_tool_result, _run_id, _tool_call_id, _payload}, state),
    do: {:noreply, state}

  # JSON-RPC dispatch

  defp dispatch(%{"method" => "initialize", "id" => id}, state) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{
          "tools" => %{}
        },
        "serverInfo" => %{
          "name" => "OrcaHub",
          "version" => "0.1.0"
        }
      }
    }

    {response, %{state | initialized: true}}
  end

  defp dispatch(%{"method" => "notifications/initialized"}, state) do
    {:accepted, state}
  end

  defp dispatch(%{"method" => "ping", "id" => id}, state) do
    {%{"jsonrpc" => "2.0", "id" => id, "result" => %{}}, state}
  end

  # Orchestrator-only tools we explicitly assert are present for orchestrator
  # connections — used as a smoking-gun check in the tools/list log line, not
  # an exhaustive list of every orchestrator-only tool (search_sessions is
  # also orchestrator-only, just not part of this particular sanity check).
  # start_session/archive_session moved OUT of this list: regular sessions can
  # now spawn/peek-at/archive children too (see Tools.@regular_session_tools)
  # — only the heartbeat tools remain orchestrator-only here.
  @orchestrator_only_tools ~w(cancel_heartbeat schedule_heartbeat)

  # Agent Runs API (docs/api.md): an api_run connection's tool surface is
  # built entirely from the run's config — caller-defined client (frontend)
  # tools, plus a synthesized submit_result tool when the run has a
  # result_schema — no other orca tool, no code-exec meta-tools, no upstream
  # tools. `initialize` deliberately did no hub work (see init/1's doc), so
  # the config is fetched here, on first tools/list, and cached in state.
  defp dispatch(%{"method" => "tools/list", "id" => id}, %{api_run: true} = state) do
    # ensure_tool_holder/1 does a HubRPC call, which RAISES on erpc/hub
    # failures — same defensive wrapper as the general tools/call dispatcher
    # (and the api_run tools/call clauses below) so a hub blip degrades
    # to an empty tool list instead of crashing this GenServer.
    state =
      try do
        ensure_tool_holder(state)
      rescue
        e ->
          Logger.error(
            "[MCP] api_run tools/list raised: " <> Exception.format(:error, e, __STACKTRACE__)
          )

          state
      catch
        kind, reason ->
          Logger.error(
            "[MCP] api_run tools/list #{kind}: " <> Exception.format(kind, reason, __STACKTRACE__)
          )

          state
      end

    tools =
      case state.tool_holder do
        nil ->
          Logger.error(
            "[MCP] api_run tools/list: no run found for orca_session_id=" <>
              inspect(state.orca_session_id)
          )

          []

        %{result_schema: schema, client_tools: client_tools} ->
          Enum.map(client_tools, &client_tool_definition/1) ++
            if(is_map(schema), do: [submit_result_tool(schema)], else: [])
      end

    log_tools_list_size("api_run", state, tools)

    response = %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}
    {response, state}
  end

  # Code-exec mode: collapse the surface to just the run_elixir meta-tool.
  # First-party + upstream tools are no longer flattened here — they're
  # reachable only as `Tools.*` functions inside run_elixir. When the flag is
  # OFF this clause never matches and tools/list behaves exactly as before.
  defp dispatch(%{"method" => "tools/list", "id" => id}, %{code_exec: true} = state) do
    all_tools = OrcaHub.MCP.CodeExec.MetaTools.list()

    log_tools_list_size("code_exec", state, all_tools)

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"tools" => all_tools}
    }

    {response, state}
  end

  defp dispatch(%{"method" => "tools/list", "id" => id}, state) do
    upstream_tools = OrcaHub.MCP.UpstreamClient.list_tools()
    orca_tools = Tools.list(state)
    all_tools = (orca_tools ++ upstream_tools) |> Enum.sort_by(& &1["name"])

    orca_tool_names = Enum.map(orca_tools, & &1["name"])
    orchestrator_tools_present? = Enum.all?(@orchestrator_only_tools, &(&1 in orca_tool_names))

    Logger.info(
      "[MCP] tools/list: orca_session_id=#{inspect(state.orca_session_id)} " <>
        "orchestrator=#{state.orchestrator} orca_tool_count=#{length(orca_tools)} " <>
        "orchestrator_tools_present=#{orchestrator_tools_present?} " <>
        "upstream_tool_count=#{length(upstream_tools)}"
    )

    log_tools_list_size("standard", state, all_tools)

    Logger.debug("[MCP] tools/list orca tools: #{inspect(orca_tool_names)}")

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => all_tools
      }
    }

    {response, state}
  end

  # Agent Runs API (docs/api.md): an api_run connection may only call
  # submit_result or one of the run's client (frontend) tools — every other
  # name is rejected outright rather than falling through to the general
  # dispatcher below. submit_result is matched here by literal name (it's
  # never a caller-supplied client tool name — see the validation in
  # ApiRuns.validate_client_tools/1); every other name goes through the
  # client-tool clause below.
  defp dispatch(
         %{
           "method" => "tools/call",
           "id" => id,
           "params" => %{"name" => "submit_result"} = params
         },
         %{api_run: true} = state
       ) do
    arguments = params["arguments"] || %{}

    # Same defensive wrapper the general tools/call dispatcher uses below —
    # this clause bypasses that dispatcher entirely, but handle_submit_result/2
    # does its own HubRPC calls (get_run_by_session_id, update_api_run), which
    # RAISE on erpc/hub failures. Without this, a hub blip mid-submission would
    # crash this GenServer and orphan the MCP session instead of just failing
    # the one tool call.
    result =
      try do
        handle_submit_result(arguments, state)
      rescue
        e ->
          Logger.error(
            "[MCP] api_run submit_result raised: " <> Exception.format(:error, e, __STACKTRACE__)
          )

          OrcaHub.MCP.Tools.Result.error("submit_result raised: #{Exception.message(e)}")
      catch
        kind, reason ->
          Logger.error(
            "[MCP] api_run submit_result #{kind}: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          OrcaHub.MCP.Tools.Result.error("submit_result failed: #{inspect(reason)}")
      end

    {%{"jsonrpc" => "2.0", "id" => id, "result" => result}, state}
  end

  defp dispatch(%{"method" => "tools/call", "id" => id, "params" => params}, state) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}
    upstream? = OrcaHub.MCP.UpstreamClient.upstream_tool?(tool_name)
    # Threaded through to Tools.call (and, for code-exec connections, into
    # run_elixir's CodeExec state) so side-effecting tools like start_session
    # can derive an automatic idempotency key that survives a transport-level
    # replay of this same JSON-RPC request — see issue c7eeef06. The id is
    # connection/turn-scoped (resets across CLI re-handshakes), so it's only
    # ever used ALONGSIDE the call's own arguments, never alone.
    state = Map.put(state, :mcp_request_id, id)

    Logger.info(
      "[MCP] tools/call: name=#{inspect(tool_name)} orchestrator=#{state.orchestrator} " <>
        "orca_session_id=#{inspect(state.orca_session_id)} path=#{if upstream?, do: "upstream", else: "local"}"
    )

    # Defensive wrapper: an exception/exit inside a tool implementation would
    # otherwise crash this GenServer, orphaning the MCP session and producing
    # the suspect "Invalid or missing session" 400s on subsequent requests.
    result =
      try do
        cond do
          # Code-exec mode: only the meta-tools are dispatchable here; every
          # other tool is reachable as Tools.<name> inside run_elixir.
          state.code_exec ->
            OrcaHub.MCP.CodeExec.MetaTools.call(tool_name, arguments, state)

          upstream? ->
            OrcaHub.MCP.UpstreamClient.call_tool(tool_name, arguments,
              orca_session_id: state.orca_session_id
            )

          true ->
            Tools.call(tool_name, arguments, state)
        end
      rescue
        e ->
          Logger.error(
            "[MCP] tools/call raised for name=#{inspect(tool_name)}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          OrcaHub.MCP.Tools.Result.error("Tool #{tool_name} raised: #{Exception.message(e)}")
      catch
        kind, reason ->
          Logger.error(
            "[MCP] tools/call #{kind} for name=#{inspect(tool_name)}: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          OrcaHub.MCP.Tools.Result.error("Tool #{tool_name} failed: #{inspect(reason)}")
      end

    if is_map(result) and result["isError"] == true do
      error_text =
        case result["content"] do
          [%{"text" => text} | _] -> text
          _ -> inspect(result["content"])
        end

      Logger.warning(
        "[MCP] tools/call result: name=#{inspect(tool_name)} isError=true error=#{inspect(error_text)}"
      )
    else
      Logger.info("[MCP] tools/call result: name=#{inspect(tool_name)} isError=false")
    end

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }

    {response, state}
  end

  defp dispatch(%{"method" => method, "id" => id}, state) do
    Logger.warning(
      "[MCP] unknown method=#{inspect(method)} orca_session_id=#{inspect(state.orca_session_id)}"
    )

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32_601,
        "message" => "Method not found: #{method}"
      }
    }

    {response, state}
  end

  # Notification we don't handle — just accept
  defp dispatch(%{"method" => _}, state) do
    {:accepted, state}
  end

  # ── api_run connections (Agent Runs API, docs/api.md, and A2A v2 client-tool/
  # result_schema declarations, docs/a2a.md) ─────────────────────────────────
  #
  # A connection with `api_run: true` exposes ONLY a synthesized submit_result
  # tool and/or caller-defined client (frontend) tools, resolved from whichever
  # `OrcaHub.MCP.ToolCallHolder` (see that module) backs this session — either
  # an Agent Runs API run or an A2A task. A session only ever has ONE holder
  # kind, so `ToolCallHolder.find_by_session_id/1` trying each registered
  # module in turn is enough to find it without threading an extra "which
  # holder kind" flag through the MCP connection/URL.

  defp ensure_tool_holder(%{tool_holder: holder} = state) when not is_nil(holder), do: state

  defp ensure_tool_holder(state) do
    case ToolCallHolder.find_by_session_id(state.orca_session_id) do
      nil ->
        state

      {_mod, holder} ->
        %{
          state
          | tool_holder: %{
              result_schema: holder.result_schema,
              client_tools: holder.client_tools || []
            }
        }
    end
  end

  # The caller's schema is used directly as the tool's inputSchema when it's
  # already a JSON object schema (the common case: `result_schema` describes
  # an object). Anything else (array, string, ...) is wrapped so submit_result
  # still has a valid object-shaped inputSchema — see `unwrap_wrapped_arguments/2`.
  defp submit_result_tool(schema) do
    %{
      "name" => "submit_result",
      "description" =>
        "Submit the final structured result for this run. Input must conform to the schema.",
      "inputSchema" => wrapped_input_schema(schema)
    }
  end

  # This tool is executed by the calling application, not this server — the
  # call is only ever parked as a pending_tool_call (see
  # handle_client_tool_call/3) and answered out-of-band via
  # POST /api/v1/runs/:id/tool_result.
  @client_tool_note "This tool is executed by the calling application. After calling it, " <>
                      "END YOUR TURN — the result will arrive as your next user message."

  defp client_tool_definition(tool) do
    schema = tool["input_schema"]

    %{
      "name" => tool["name"],
      "description" =>
        String.trim_trailing(tool["description"] || "") <> " " <> @client_tool_note,
      "inputSchema" => wrapped_input_schema(schema)
    }
  end

  defp wrapped_input_schema(%{"type" => "object"} = schema), do: schema

  defp wrapped_input_schema(schema) do
    %{"type" => "object", "properties" => %{"result" => schema}, "required" => ["result"]}
  end

  defp wrapped_schema?(%{"type" => "object"}), do: false
  defp wrapped_schema?(_schema), do: true

  defp unwrap_wrapped_arguments(arguments, schema) do
    if wrapped_schema?(schema), do: Map.get(arguments, "result"), else: arguments
  end

  defp handle_submit_result(arguments, state) do
    case ToolCallHolder.find_by_session_id(state.orca_session_id) do
      nil ->
        OrcaHub.MCP.Tools.Result.error(
          "No matching run found for orca_session_id=#{inspect(state.orca_session_id)}."
        )

      {_mod, %{status: "completed"}} ->
        OrcaHub.MCP.Tools.Result.text("Result already submitted.")

      {mod, holder} ->
        validate_and_complete_run(mod, holder, arguments)
    end
  end

  defp validate_and_complete_run(mod, holder, arguments) do
    submission = unwrap_wrapped_arguments(arguments, holder.result_schema)

    case OrcaHub.ApiRuns.validate_against_schema(submission, holder.result_schema) do
      :ok ->
        persist_completed_run(mod, holder, submission)

      {:error, errors} ->
        OrcaHub.MCP.Tools.Result.error(
          "Validation failed:\n" <> Enum.map_join(errors, "\n", &"- #{&1}")
        )

      {:schema_error, message} ->
        OrcaHub.MCP.Tools.Result.error("Invalid result_schema: #{message}")
    end
  end

  defp find_client_tool(%{tool_holder: %{client_tools: client_tools}}, tool_name) do
    Enum.find(client_tools, &(&1["name"] == tool_name))
  end

  defp find_client_tool(_state, _tool_name), do: nil

  defp unknown_tool_message(tool_name, %{
         tool_holder: %{client_tools: client_tools, result_schema: schema}
       }) do
    names =
      Enum.map(client_tools, & &1["name"]) ++ if(is_map(schema), do: ["submit_result"], else: [])

    case names do
      [] -> "Unknown tool: #{tool_name}. This connection exposes no tools."
      _ -> "Unknown tool: #{tool_name}. This connection only exposes #{Enum.join(names, ", ")}."
    end
  end

  defp unknown_tool_message(tool_name, _state) do
    "Unknown tool: #{tool_name}. This connection only exposes submit_result."
  end

  # ── Client tool call parking (docs/api.md, AG-UI-style) ────────────────
  #
  # A client (frontend) tool call is never dispatched locally. Instead of
  # replying right away, the `tools/call` JSON-RPC response is PARKED (its
  # `from` stashed in `state.parked_tool_call`, `{:noreply, state}` returned
  # so this GenServer's loop stays free to serve other requests — in
  # particular a SECOND concurrent tools/call on the same MCP session) until
  # one of three things resolves it:
  #
  #   1. `POST /api/v1/runs/:id/tool_result` lands (possibly on a different
  #      node than this GenServer — see ApiRunController) and broadcasts
  #      `{:client_tool_result, run_id, tool_call_id, payload}` on
  #      `"api_run:<run_id>"` (Phoenix.PubSub auto-distributes across nodes).
  #   2. The belt-and-braces poll timer (`:client_tool_poll`, every
  #      @poll_interval_ms) notices the answer in the DB in case the
  #      broadcast above was missed.
  #   3. The hold timer (`:client_tool_hold_timeout`) fires first: the model
  #      gets the OLD v1 placeholder text and ends its turn: `pending_tool_call`
  #      is marked `hold_expired` (not cleared) so a subsequent
  #      `tool_result` POST falls back to v1 message-delivery — see
  #      ApiRunController.deliver_tool_result/3.
  #
  # A tools/call for the SAME tool name arriving while a DB pending_tool_call
  # already exists (this connection restarted mid-hold and the model/CLI
  # retried after the held HTTP request died — see docs/api.md) is re-parked
  # against that EXISTING call id rather than creating a new one the caller
  # would end up double-executing. A DIFFERENT tool name gets the immediate
  # "one at a time" error, exactly as before.
  defp handle_client_tool_call_dispatch(id, tool_name, arguments, from, state) do
    {outcome, new_state} =
      try do
        resolve_client_tool_call(tool_name, arguments, {from, id}, state)
      rescue
        e ->
          Logger.error(
            "[MCP] api_run client tool call raised: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          {{:reply,
            OrcaHub.MCP.Tools.Result.error("Tool #{tool_name} raised: #{Exception.message(e)}")},
           state}
      catch
        kind, reason ->
          Logger.error(
            "[MCP] api_run client tool call #{kind}: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          {{:reply,
            OrcaHub.MCP.Tools.Result.error("Tool #{tool_name} failed: #{inspect(reason)}")},
           state}
      end

    case outcome do
      :parked ->
        {:noreply, new_state}

      {:reply, result} ->
        {:reply, %{"jsonrpc" => "2.0", "id" => id, "result" => result}, new_state}
    end
  end

  defp resolve_client_tool_call(tool_name, arguments, from_entry, state) do
    state = ensure_tool_holder(state)

    case find_client_tool(state, tool_name) do
      nil ->
        Logger.warning(
          "[MCP] api_run tools/call: rejected name=#{inspect(tool_name)} — not a known " <>
            "client tool/submit_result on this connection"
        )

        {{:reply, OrcaHub.MCP.Tools.Result.error(unknown_tool_message(tool_name, state))}, state}

      tool ->
        park_or_resolve(tool, arguments, from_entry, state)
    end
  end

  # Already parked locally (this connection is holding an earlier call open):
  # same tool name → another from waiting on the SAME call (e.g. parallel
  # tool_use blocks the model itself issued); different name → the classic
  # one-at-a-time error, no DB round-trip needed since we already know what's
  # pending.
  defp park_or_resolve(
         %{"name" => name},
         _arguments,
         from_entry,
         %{parked_tool_call: %{tool_name: name}} = state
       ) do
    {:parked, add_parked_from(state, from_entry)}
  end

  defp park_or_resolve(_tool, _arguments, _from_entry, %{parked_tool_call: %{} = parked} = state) do
    {{:reply, one_at_a_time_message(parked.tool_name, parked.tool_call_id)}, state}
  end

  defp park_or_resolve(
         %{"name" => tool_name} = tool,
         arguments,
         from_entry,
         %{parked_tool_call: nil} = state
       ) do
    case ToolCallHolder.find_by_session_id(state.orca_session_id) do
      nil ->
        {{:reply,
          OrcaHub.MCP.Tools.Result.error(
            "No matching run found for orca_session_id=#{inspect(state.orca_session_id)}."
          )}, state}

      {mod, %{pending_tool_call: nil} = holder} ->
        persist_and_park(mod, holder, tool, arguments, from_entry, state)

      {mod, %{pending_tool_call: %{"name" => ^tool_name} = pending} = holder} ->
        if Map.has_key?(pending, "result") or Map.has_key?(pending, "error") do
          # Already answered while nobody was parked to consume it (e.g. a
          # broadcast/poll raced this restart) — resolve inline, no parking.
          {{:reply, mcp_result_from_pending(pending)},
           clear_pending_and_resume(mod, holder, pending["id"])}
        else
          {:parked, repark_existing(mod, holder, pending, from_entry, state)}
        end

      {_mod, %{pending_tool_call: pending}} ->
        {{:reply, one_at_a_time_message(pending["name"], pending["id"])}, state}
    end
  end

  defp one_at_a_time_message(name, id) do
    OrcaHub.MCP.Tools.Result.error(
      "A frontend tool call (#{name}, id #{id}) is already pending. Call one frontend " <>
        "tool at a time — wait for its result before calling another."
    )
  end

  # The holder's `pending_tool_call` column casts as a plain map — arguments
  # are unwrapped back to the caller's raw shape (see wrapped_input_schema/1)
  # before being stored, so the caller sees exactly the shape matching the
  # `input_schema` they supplied, not an internal `{"result": ...}` wrapper.
  defp persist_and_park(mod, holder, tool, arguments, from_entry, state) do
    tool_call_id = Ecto.UUID.generate()
    real_arguments = unwrap_wrapped_arguments(arguments, tool["input_schema"])

    pending_tool_call = %{
      "id" => tool_call_id,
      "name" => tool["name"],
      "arguments" => real_arguments
    }

    case mod.update(holder, %{
           status: mod.parked_status(),
           pending_tool_call: pending_tool_call
         }) do
      {:ok, updated_holder} ->
        {:parked, begin_park(mod, updated_holder, tool_call_id, tool["name"], from_entry, state)}

      {:error, changeset} ->
        Logger.error(
          "[MCP] api_run client tool call: failed to persist pending_tool_call for holder " <>
            "#{holder.id}: #{inspect(changeset.errors)}"
        )

        {{:reply,
          OrcaHub.MCP.Tools.Result.error(
            "Tool call recorded but could not be stored: " <> inspect(changeset.errors)
          )}, state}
    end
  end

  # Re-parking against an existing, unanswered pending_tool_call (restart
  # mid-hold — see moduledoc above): clear any stale `hold_expired` marker so
  # ApiRunController.deliver_tool_result/3 (or its A2A counterpart) takes the
  # real-time path again now that someone IS parked once more. Best-effort —
  # still park even if this write fails, since the pending call itself is
  # unaffected either way.
  defp repark_existing(mod, holder, pending, from_entry, state) do
    holder =
      case mod.update(holder, %{pending_tool_call: Map.delete(pending, "hold_expired")}) do
        {:ok, updated_holder} -> updated_holder
        {:error, _changeset} -> holder
      end

    begin_park(mod, holder, pending["id"], pending["name"], from_entry, state)
  end

  # `parked.froms` is a list of `{genserver_from, jsonrpc_id}` pairs, not bare
  # `from`s — each concurrently-parked caller issued its OWN `tools/call`
  # request with its own JSON-RPC `id`, and the eventual reply must be
  # wrapped with the MATCHING id (see reply_to_froms/2) or the CLI can't
  # correlate the response back to its request.
  defp begin_park(mod, holder, tool_call_id, tool_name, from_entry, state) do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, mod.topic(holder.id))

    parked = %{
      holder_mod: mod,
      holder_id: holder.id,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      froms: [from_entry],
      hold_ref:
        Process.send_after(
          self(),
          {:client_tool_hold_timeout, tool_call_id},
          hold_timeout_ms(holder)
        ),
      poll_ref: schedule_poll(tool_call_id)
    }

    %{state | parked_tool_call: parked}
  end

  defp add_parked_from(state, from_entry) do
    update_in(state.parked_tool_call.froms, &[from_entry | &1])
  end

  defp reply_to_froms(froms, mcp_result) do
    Enum.each(froms, fn {from, id} ->
      GenServer.reply(from, %{"jsonrpc" => "2.0", "id" => id, "result" => mcp_result})
    end)
  end

  defp schedule_poll(tool_call_id) do
    Process.send_after(self(), {:client_tool_poll, tool_call_id}, poll_interval_ms())
  end

  # Re-fetches the holder and resolves if the caller's answer has landed
  # (belt-and-braces fallback for a missed PubSub broadcast — see moduledoc
  # above); otherwise just reschedules the next poll tick.
  defp poll_parked_call(%{parked_tool_call: parked} = state) do
    case parked.holder_mod.get(parked.holder_id) do
      %{pending_tool_call: %{"id" => tool_call_id} = pending}
      when tool_call_id == parked.tool_call_id ->
        if Map.has_key?(pending, "result") or Map.has_key?(pending, "error") do
          resolve_parked(parked, pending_payload(pending), state)
        else
          %{state | parked_tool_call: %{parked | poll_ref: schedule_poll(parked.tool_call_id)}}
        end

      _other ->
        # pending_tool_call was cleared/changed out from under us — nothing
        # sane to resolve to; give up gracefully rather than hang forever.
        reply_to_froms(parked.froms, unexpected_state_result())
        cleanup_parked(parked)
        %{state | parked_tool_call: nil}
    end
  rescue
    e ->
      Logger.error(
        "[MCP] api_run client tool call poll raised: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      %{state | parked_tool_call: %{parked | poll_ref: schedule_poll(parked.tool_call_id)}}
  end

  defp pending_payload(%{"error" => error}) when is_binary(error) and error != "",
    do: {:error, error}

  defp pending_payload(pending), do: {:ok, Map.get(pending, "result")}

  defp resolve_parked(parked, payload, state) do
    mcp_result = mcp_result_from_payload(payload)
    reply_to_froms(parked.froms, mcp_result)
    clear_pending_and_resume(parked.holder_mod, parked.holder_id, parked.tool_call_id)
    cleanup_parked(parked)
    %{state | parked_tool_call: nil}
  end

  defp mcp_result_from_pending(pending), do: mcp_result_from_payload(pending_payload(pending))

  defp mcp_result_from_payload({:error, error}), do: OrcaHub.MCP.Tools.Result.error(error)

  defp mcp_result_from_payload({:ok, result}),
    do: OrcaHub.MCP.Tools.Result.text(Jason.encode!(result, pretty: true))

  # MCP.Server resolves, replies, THEN clears pending_tool_call and flips
  # status back to the holder's own `resumed_status()` — kept as a distinct
  # last step so a crash between reply and clear just re-triggers the
  # (idempotent) restart/re-park path above instead of losing the answer.
  defp clear_pending_and_resume(mod, holder_id, tool_call_id) when is_binary(holder_id) do
    case mod.get(holder_id) do
      %{pending_tool_call: %{"id" => ^tool_call_id}} = holder ->
        clear_pending_and_resume(mod, holder, tool_call_id)

      _other ->
        :ok
    end
  end

  defp clear_pending_and_resume(
         mod,
         %{pending_tool_call: %{"id" => tool_call_id}} = holder,
         tool_call_id
       ) do
    mod.update(holder, %{status: mod.resumed_status(), pending_tool_call: nil})
    holder
  end

  defp mark_hold_expired(mod, holder_id, tool_call_id) do
    case mod.get(holder_id) do
      %{pending_tool_call: %{"id" => ^tool_call_id} = pending} = holder ->
        mod.update(holder, %{pending_tool_call: Map.put(pending, "hold_expired", true)})

      _other ->
        :ok
    end
  end

  defp cleanup_parked(parked) do
    if parked.hold_ref, do: Process.cancel_timer(parked.hold_ref)
    if parked.poll_ref, do: Process.cancel_timer(parked.poll_ref)
    Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, parked.holder_mod.topic(parked.holder_id))
  end

  # v1 placeholder text (unchanged from the pre-rework behavior) — used only
  # as the hold-timeout fallback now; the happy path replies with the
  # caller's actual result instead.
  defp placeholder_result do
    OrcaHub.MCP.Tools.Result.text(
      "Forwarded to the calling application. END YOUR TURN now and wait — the result " <>
        "will arrive as your next user message."
    )
  end

  defp unexpected_state_result do
    OrcaHub.MCP.Tools.Result.error(
      "This tool call's pending state changed unexpectedly on the server — the calling " <>
        "application may need to retry."
    )
  end

  # Server-side hold budget (docs/api.md): the run's remaining timeout_seconds
  # budget, capped so a session can't hold a port open indefinitely. Claude
  # sessions get a matching/generous client-side MCP_TOOL_TIMEOUT (see
  # OrcaHub.Backend.Claude) so the CLI's own tool-call timeout doesn't fire
  # first and orphan the held connection without us knowing.
  @default_hold_cap_ms 600_000

  @doc """
  The cap on how long a parked client tool call is held open server-side —
  shared with `OrcaHub.Backend.Claude`, which sizes a generous client-side
  `MCP_TOOL_TIMEOUT` around this same number so the CLI's own tool-call
  timeout can never fire first (see `hold_timeout_ms/1` below).
  """
  @spec client_tool_hold_cap_ms() :: pos_integer()
  def client_tool_hold_cap_ms,
    do: Application.get_env(:orca_hub, :api_run_tool_hold_cap_ms, @default_hold_cap_ms)

  defp hold_timeout_ms(holder) do
    inserted_at = DateTime.from_naive!(holder.inserted_at, "Etc/UTC")
    elapsed_ms = DateTime.diff(DateTime.utc_now(), inserted_at, :millisecond)
    remaining_ms = holder.timeout_seconds * 1000 - elapsed_ms

    remaining_ms |> min(client_tool_hold_cap_ms()) |> max(0)
  end

  @default_poll_interval_ms 12_000

  defp poll_interval_ms,
    do: Application.get_env(:orca_hub, :api_run_tool_poll_interval_ms, @default_poll_interval_ms)

  # The holder's `result` column casts as a plain map (see ApiRun/A2ATask
  # schemas) — a schema-valid but non-object top-level submission (e.g. a
  # wrapped array schema) fails THIS cast even though it passed JSON Schema
  # validation. Handled as an ordinary tool error rather than crashing the
  # GenServer (the general tools/call dispatcher's try/rescue doesn't cover
  # this clause).
  defp persist_completed_run(mod, holder, submission) do
    case mod.update(holder, %{status: "completed", result: submission, result_text: nil}) do
      {:ok, _holder} ->
        OrcaHub.MCP.Tools.Result.text("Result accepted.")

      {:error, changeset} ->
        Logger.error(
          "[MCP] api_run submit_result: failed to persist holder #{holder.id}: " <>
            inspect(changeset.errors)
        )

        OrcaHub.MCP.Tools.Result.error(
          "Result passed schema validation but could not be stored: " <>
            inspect(changeset.errors)
        )
    end
  end

  # Token instrumentation: log the serialized payload size + tool count so the
  # before/after savings of code-exec mode can be measured.
  defp log_tools_list_size(mode, state, tools) do
    bytes = tools |> Jason.encode!() |> byte_size()

    Logger.info(
      "[MCP] tools/list payload: mode=#{mode} orca_session_id=#{inspect(state.orca_session_id)} " <>
        "tool_count=#{length(tools)} payload_bytes=#{bytes}"
    )
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
