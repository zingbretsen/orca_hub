defmodule OrcaHub.Backend.Codex do
  @moduledoc """
  `OrcaHub.Backend` implementation for the OpenAI Codex CLI, over
  `codex app-server` (long-lived JSON-RPC 2.0 over newline-delimited stdio).
  `codex exec --json` is the `:one_shot`-engine fallback (spec §6, Phase 2).

  ## Protocol FSM (`backend_state`)

  `backend_state.phase` moves `:handshaking -> :ready -> :thread_started`:

    * `:handshaking` — `on_open/1` just wrote the `initialize` request
      (id `0`). Nothing else may be sent until its response arrives.
    * `:ready` — `initialize`'s response arrived; `normalize/2` reacted by
      queuing (via `pending_writes`) the `initialized` notification and a
      `thread/start`/`thread/resume` request.
    * `:thread_started` — that request's response arrived with a thread id;
      the synthesized `system`/`init` event has been emitted, and any
      `encode_user_turn/2` prompt stashed while cold (`pending_prompt`) has
      been flushed as a `turn/start` request.

  `backend_state` also carries: `thread_id`, `current_turn_id`,
  `latest_token_usage` (from the most recent `thread/tokenUsage/updated`,
  attached to the synthesized `result` event at `turn/completed`),
  `pending_prompt`, `system_prompt_sent` (leading-message system prompt is
  prepended once per thread — spec §6.3(1)), a `next_id` counter, and
  `pending_requests` (`%{request_id => kind}` for response correlation, since
  `thread/start`'s result arrives as a JSON-RPC response, not a notification).

  `backend_state` is reset to `%{}` by `SessionRunner` on every port
  teardown/crash (see `teardown_port/1`, `handle_streaming_exit/3`) — a fresh
  cold spawn always starts this FSM from `on_open/1` again.
  """

  @behaviour OrcaHub.Backend

  require Logger

  alias OrcaHub.Backend.{McpUrl, SharedPrompts}

  # Suppress delta notifications at the source (v1 renders on item/completed
  # only — spec §6.2/Q7).
  @delta_notification_methods [
    "item/agentMessage/delta",
    "item/reasoning/textDelta",
    "item/commandExecution/outputDelta"
  ]

  # ── Capabilities ─────────────────────────────────────────────────────

  @impl true
  def capabilities do
    %OrcaHub.Backend.Capabilities{
      streaming: true,
      interrupt: :protocol,
      mcp: true,
      resume: true,
      usage: false,
      system_prompt: :leading_message,
      warmup_turn: false,
      # No `~/.claude/plans` / `EnterPlanMode`/`ExitPlanMode` tool pair, and
      # no built-in `AskUserQuestion` tool (spec §6.3(4)/(5)) — both fall
      # back to plain assistant text with no status tracking.
      plan_mode: false,
      ask_user_question: false
    }
  end

  # ── Models ───────────────────────────────────────────────────────────
  # Codex model ids are passthrough strings — codex-cli 0.142.5 has no
  # queryable model enum (spec §7). This is a small default list, not a
  # hardcoded enum: the UI also offers free-text entry for any other id.
  # `gpt-5.5` / `gpt-5.3-Codex-Spark` are spec §7's own example passthrough
  # strings; `gpt-5-codex` is the well-known baseline Codex model id.

  @impl true
  def models do
    [
      {"gpt-5-codex", "GPT-5 Codex"},
      {"gpt-5.3-Codex-Spark", "GPT-5.3 Codex Spark"},
      {"gpt-5.5", "GPT-5.5"}
    ]
  end

  # ── Spawn ────────────────────────────────────────────────────────────

  @impl true
  def spawn_spec(:streaming, ctx) do
    %{
      executable: codex_executable!(),
      args: ["app-server"],
      env: codex_env(ctx),
      port_opts: [cd: String.to_charlist(ctx.directory)],
      framing: :jsonrpc
    }
  end

  def spawn_spec(:one_shot, ctx) do
    prompt = Map.get(ctx, :prompt, "")

    args =
      ["exec", "--json", "--cd", ctx.directory, "--dangerously-bypass-approvals-and-sandbox"]
      |> maybe_add_model_arg(ctx[:model])
      |> Kernel.++([prompt])

    %{
      executable: codex_executable!(),
      args: args,
      env: codex_env(ctx),
      port_opts: [cd: String.to_charlist(ctx.directory)],
      framing: :ndjson
    }
  end

  # `:orca_hub, :codex_executable` is a test-only seam (drives a real
  # SessionRunner against `test/support/fixtures/codex_stub_app_server.py`
  # instead of a real `codex` install — see
  # OrcaHub.Backend.Codex.CodexStubIntegrationTest) — unset in dev/prod, so
  # this falls through to the normal PATH lookup.
  @impl true
  def installed? do
    (Application.get_env(:orca_hub, :codex_executable) || System.find_executable("codex")) != nil
  end

  defp codex_executable! do
    Application.get_env(:orca_hub, :codex_executable) ||
      System.find_executable("codex") ||
      raise "codex executable not found in PATH (install: npm install -g @openai/codex)"
  end

  defp maybe_add_model_arg(args, model) do
    case codex_model(model) do
      nil -> args
      m -> args ++ ["-m", m]
    end
  end

  # `CODEX_HOME` is the per-session isolation lever (spec §6.1/§6.3(2)) — points
  # the CLI at a directory this backend controls (config.toml with the orca MCP
  # stanza), computed the SAME way in spawn_spec/2 (env) and prepare_session/1
  # (the side effect that materializes it), so no extra_env plumbing through
  # the runner is needed (prepare_session/1 returns plain `:ok`).
  defp codex_env(ctx) do
    extra = [{~c"CODEX_HOME", String.to_charlist(codex_home_dir(ctx))}]

    extra =
      case System.get_env("OPENAI_API_KEY") do
        nil -> extra
        "" -> extra
        key -> extra ++ [{~c"OPENAI_API_KEY", String.to_charlist(key)}]
      end

    OrcaHub.Env.sanitized_env(extra)
  end

  defp codex_home_dir(ctx) do
    Path.join([ctx.directory, ".codex_home", to_string(ctx.session_id)])
  end

  # Codex model handling (spec step 3): passthrough string; omit when the
  # session's model is empty or a Claude model id, letting codex use its
  # default.
  defp codex_model(nil), do: nil
  defp codex_model(""), do: nil

  defp codex_model(model) do
    if String.starts_with?(model, "claude"), do: nil, else: model
  end

  # ── Open-time handshake ──────────────────────────────────────────────

  @impl true
  def on_open(ctx) do
    bs = ctx.backend_state

    req = %{
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "clientInfo" => %{"name" => "orca_hub", "version" => orca_hub_version()},
        "capabilities" => %{
          "experimentalApi" => true,
          "optOutNotificationMethods" => @delta_notification_methods
        }
      }
    }

    bs =
      bs
      |> Map.put(:phase, :handshaking)
      |> Map.put(:next_id, 1)
      |> put_pending_request(0, :initialize)

    {Jason.encode!(req) <> "\n", %{ctx | backend_state: bs}}
  end

  defp orca_hub_version, do: to_string(Application.spec(:orca_hub, :vsn) || "dev")

  # ── stdin framing (user turns) ───────────────────────────────────────

  @impl true
  def encode_user_turn(prompt, ctx) do
    bs = ctx.backend_state

    case bs[:thread_id] do
      thread_id when is_binary(thread_id) ->
        {bs2, iodata} = build_turn_start(ctx, bs, thread_id, prompt)
        {iodata, %{ctx | backend_state: bs2}}

      _ ->
        # Thread hasn't started yet (still handshaking) — stash; the FSM
        # sends turn/start once thread/start's response arrives with a
        # thread id (see after_thread_started/2).
        {"", %{ctx | backend_state: Map.put(bs, :pending_prompt, prompt)}}
    end
  end

  @impl true
  def encode_interrupt(_req_id, %{engine: :one_shot}), do: :signal

  def encode_interrupt(req_id, ctx) do
    bs = ctx.backend_state

    case {bs[:thread_id], bs[:current_turn_id]} do
      {thread_id, turn_id} when is_binary(thread_id) and is_binary(turn_id) ->
        Jason.encode!(%{
          "id" => req_id,
          "method" => "turn/interrupt",
          "params" => %{"threadId" => thread_id, "turnId" => turn_id}
        }) <> "\n"

      _ ->
        # No active turn yet (still handshaking, or between turns) —
        # nothing to interrupt; NEVER fall back to :signal here (that would
        # SIGKILL-adjacent the whole long-lived app-server process).
        ""
    end
  end

  # ── Normalization (native app-server frame -> Claude-shaped events) ──

  @impl true
  def normalize(%{"id" => id, "result" => result}, ctx),
    do: handle_response(id, {:ok, result}, ctx)

  def normalize(%{"id" => id, "error" => error}, ctx),
    do: handle_response(id, {:error, error}, ctx)

  def normalize(%{"method" => "item/started"}, ctx), do: {[], ctx}

  def normalize(%{"method" => "item/completed", "params" => %{"item" => item}}, ctx)
      when is_map(item) do
    {item_events(item), ctx}
  end

  def normalize(%{"method" => "thread/tokenUsage/updated", "params" => params}, ctx) do
    bs = Map.put(ctx.backend_state, :latest_token_usage, params["tokenUsage"])
    {[], %{ctx | backend_state: bs}}
  end

  def normalize(%{"method" => "turn/started", "params" => params}, ctx) do
    {[], stash_turn_id(ctx, get_in(params, ["turn", "id"]))}
  end

  def normalize(%{"method" => "turn/plan/updated", "params" => params}, ctx) do
    {[plan_event(params)], ctx}
  end

  def normalize(%{"method" => "turn/completed", "params" => params}, ctx) do
    turn_completed(params, ctx)
  end

  # Unknown/unsolicited notification or frame (configWarning,
  # remoteControl/status/changed, mcpServer/startupStatus/updated,
  # thread/started, item/*/requestUserInput, etc.) — drop rather than emit a
  # foreign shape (spec §3.3 invariant).
  def normalize(_frame, ctx), do: {[], ctx}

  defp handle_response(id, {:ok, result}, ctx) do
    {kind, ctx} = pop_pending_request(ctx, id)

    case kind do
      :initialize -> after_initialize(ctx)
      :thread_start -> after_thread_started(result, ctx)
      :thread_resume -> after_thread_started(result, ctx)
      :turn_start -> after_turn_started(result, ctx)
      :turn_interrupt -> {[], ctx}
      nil -> {[], ctx}
    end
  end

  defp handle_response(id, {:error, error}, ctx) do
    {kind, ctx} = pop_pending_request(ctx, id)
    message = (is_map(error) && error["message"]) || inspect(error)

    case kind do
      nil -> {[], ctx}
      :turn_interrupt -> {[], ctx}
      _ -> {[error_result_event(message)], reset_turn_state(ctx)}
    end
  end

  defp after_initialize(ctx) do
    bs = ctx.backend_state
    {id, bs} = next_id(bs)
    {method, params, kind} = thread_start_or_resume(ctx)

    bs =
      bs
      |> Map.put(:phase, :ready)
      |> put_pending_request(id, kind)
      |> queue_write(Jason.encode!(%{"method" => "initialized"}) <> "\n")
      |> queue_write(Jason.encode!(%{"id" => id, "method" => method, "params" => params}) <> "\n")

    {[], %{ctx | backend_state: bs}}
  end

  defp thread_start_or_resume(ctx) do
    case ctx[:claude_session_id] do
      sid when is_binary(sid) and sid != "" ->
        {"thread/resume", %{"threadId" => sid}, :thread_resume}

      _ ->
        params =
          %{
            "cwd" => ctx.directory,
            "approvalPolicy" => "never",
            "sandbox" => "danger-full-access"
          }
          |> maybe_put_model_param(ctx[:model])

        {"thread/start", params, :thread_start}
    end
  end

  defp maybe_put_model_param(params, model) do
    case codex_model(model) do
      nil -> params
      m -> Map.put(params, "model", m)
    end
  end

  defp after_thread_started(result, ctx) do
    thread_id = get_in(result, ["thread", "id"])

    bs =
      ctx.backend_state
      |> Map.put(:phase, :thread_started)
      |> Map.put(:thread_id, thread_id)

    bs =
      case Map.pop(bs, :pending_prompt) do
        {nil, bs} ->
          bs

        {prompt, bs} ->
          {bs, iodata} = build_turn_start(ctx, bs, thread_id, prompt)
          queue_write(bs, iodata)
      end

    event =
      if is_binary(thread_id) do
        [%{"type" => "system", "session_id" => thread_id, "subtype" => "init"}]
      else
        []
      end

    {event, %{ctx | backend_state: bs}}
  end

  defp after_turn_started(result, ctx) do
    {[], stash_turn_id(ctx, get_in(result, ["turn", "id"]))}
  end

  defp stash_turn_id(ctx, nil), do: ctx

  defp stash_turn_id(ctx, turn_id),
    do: %{ctx | backend_state: Map.put(ctx.backend_state, :current_turn_id, turn_id)}

  defp reset_turn_state(ctx),
    do: %{ctx | backend_state: Map.put(ctx.backend_state, :current_turn_id, nil)}

  # Builds a `turn/start` request (prepending the leading-message system
  # prompt on the first turn of the thread — spec §6.3(1)) and registers it
  # for response correlation. Returns `{new_backend_state, iodata}`.
  defp build_turn_start(ctx, bs, thread_id, prompt) do
    {id, bs} = next_id(bs)
    {text, bs} = with_system_prefix(ctx, bs, prompt)

    req = %{
      "id" => id,
      "method" => "turn/start",
      "params" => %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => text}]
      }
    }

    bs = put_pending_request(bs, id, :turn_start)
    {bs, Jason.encode!(req) <> "\n"}
  end

  defp with_system_prefix(ctx, bs, prompt) do
    if bs[:system_prompt_sent] do
      {prompt, bs}
    else
      {system_prompt(ctx) <> "\n\n" <> prompt, Map.put(bs, :system_prompt_sent, true)}
    end
  end

  defp next_id(bs) do
    id = Map.get(bs, :next_id, 1)
    {id, Map.put(bs, :next_id, id + 1)}
  end

  defp put_pending_request(bs, id, kind),
    do: Map.update(bs, :pending_requests, %{id => kind}, &Map.put(&1, id, kind))

  defp pop_pending_request(ctx, id) do
    {kind, pending} = Map.pop(ctx.backend_state[:pending_requests] || %{}, id)
    {kind, %{ctx | backend_state: Map.put(ctx.backend_state, :pending_requests, pending)}}
  end

  defp queue_write(bs, iodata),
    do: Map.update(bs, :pending_writes, [iodata], &(&1 ++ [iodata]))

  # ── item/completed -> Claude-shaped tool_use/tool_result (spec §6.2) ──

  defp item_events(%{"type" => "agentMessage", "text" => text}) when is_binary(text) do
    [assistant_text_event(text)]
  end

  defp item_events(%{"type" => "reasoning"} = item) do
    text =
      case non_empty_list(item["content"]) || non_empty_list(item["summary"]) do
        nil -> ""
        lines -> Enum.join(lines, "\n")
      end

    if text == "", do: [], else: [assistant_thinking_event(text)]
  end

  defp item_events(%{"type" => "commandExecution", "id" => id} = item) do
    [
      tool_use_event(id, "Bash", %{"command" => item["command"] || ""}),
      tool_result_event(id, item["aggregatedOutput"] || "", item["status"] == "failed")
    ]
  end

  defp item_events(%{"type" => "fileChange", "id" => id, "changes" => changes})
       when is_list(changes) do
    kind =
      if Enum.any?(changes, &(get_in(&1, ["kind", "type"]) == "add")), do: "Write", else: "Edit"

    paths = Enum.map(changes, & &1["path"])
    diff = Enum.map_join(changes, "\n\n", &(&1["diff"] || ""))

    [
      tool_use_event(id, kind, %{"file_path" => List.first(paths) || "", "paths" => paths}),
      tool_result_event(id, diff, false)
    ]
  end

  defp item_events(%{"type" => "mcpToolCall", "id" => id} = item) do
    name = "mcp__#{item["server"]}__#{item["tool"]}"
    failed? = item["status"] == "failed" or not is_nil(item["error"])

    content =
      cond do
        is_map(item["error"]) -> item["error"]["message"] || "error"
        is_map(item["result"]) -> mcp_result_content(item["result"])
        true -> ""
      end

    [
      tool_use_event(id, name, item["arguments"] || %{}),
      tool_result_event(id, content, failed?)
    ]
  end

  defp item_events(%{"type" => "webSearch", "id" => id} = item) do
    [
      tool_use_event(id, "WebSearch", %{"query" => item["query"]}),
      tool_result_event(id, "", false)
    ]
  end

  # Unmapped item types (plan/dynamicToolCall/collabAgentToolCall/
  # subAgentActivity/imageView/sleep/imageGeneration/reviewMode/
  # contextCompaction/userMessage/hookPrompt/…) — drop for v1 rather than
  # emit a foreign shape (spec §3.3 invariant).
  defp item_events(_item), do: []

  defp non_empty_list(list) when is_list(list) and list != [], do: list
  defp non_empty_list(_), do: nil

  defp mcp_result_content(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp mcp_result_content(_), do: ""

  defp assistant_text_event(text) do
    %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  defp assistant_thinking_event(text) do
    %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "thinking", "thinking" => text}]}
    }
  end

  defp tool_use_event(id, name, input) do
    %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
      }
    }
  end

  defp tool_result_event(id, content, is_error) do
    %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => id,
            "content" => content,
            "is_error" => is_error
          }
        ]
      }
    }
  end

  # ── turn/plan/updated -> TodoWrite (spec §6.2) ────────────────────────

  defp plan_event(params) do
    todos =
      (params["plan"] || [])
      |> Enum.map(fn step ->
        %{"content" => step["step"], "status" => todo_status(step["status"])}
      end)

    id = "plan-#{params["turnId"]}-#{System.unique_integer([:positive, :monotonic])}"
    tool_use_event(id, "TodoWrite", %{"todos" => todos})
  end

  defp todo_status("inProgress"), do: "in_progress"
  defp todo_status(status) when is_binary(status), do: status
  defp todo_status(_), do: "pending"

  # ── turn/completed -> synthesized `result` (spec §6.2) ────────────────

  defp turn_completed(params, ctx) do
    turn = params["turn"] || %{}

    event =
      %{"type" => "result", "is_error" => turn["status"] == "failed"}
      |> put_if_present("duration_ms", turn["durationMs"])
      |> put_error_message(turn["error"])
      |> put_usage(ctx.backend_state[:latest_token_usage])

    {[event], reset_turn_state(ctx)}
  end

  defp error_result_event(message),
    do: %{"type" => "result", "is_error" => true, "result" => message}

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_error_message(map, %{"message" => message}) when is_binary(message),
    do: Map.put(map, "result", message)

  defp put_error_message(map, _), do: map

  defp put_usage(map, nil), do: map
  defp put_usage(map, usage), do: Map.put(map, "usage", usage_shape(usage))

  # Codex's tokenUsage.total shape -> the subset of Claude's `usage` keys the
  # result card reads (spec §3.3 missing-field tolerance: total_cost_usd has
  # no Codex equivalent and is simply omitted).
  defp usage_shape(%{"total" => %{} = total}) do
    %{
      "input_tokens" => total["inputTokens"],
      "output_tokens" => total["outputTokens"],
      "cache_read_input_tokens" => total["cachedInputTokens"]
    }
  end

  defp usage_shape(_), do: %{}

  # ── Peer requests (approvals) ─────────────────────────────────────────
  # v1: unconditionally accept, no feed events (spec §6.1/§6.3(2) — hands-off
  # operation via approvalPolicy:"never" + a permissive sandbox means this is
  # a backstop that should rarely fire).

  @impl true
  def handle_peer_request(%{"id" => id, "method" => method}, ctx) do
    Logger.info("[Backend.Codex] peer request #{method} (id=#{inspect(id)}) -> auto-accept")
    reply = Jason.encode!(%{"id" => id, "result" => approval_result(method)}) <> "\n"
    {reply, [], ctx}
  end

  defp approval_result("item/commandExecution/requestApproval"),
    do: %{"decision" => "acceptForSession"}

  defp approval_result("item/fileChange/requestApproval"), do: %{"decision" => "acceptForSession"}
  # Only reachable under a granular approval policy we don't request; empty
  # profile grants nothing extra. All fields are optional (schema-verified).
  defp approval_result("item/permissions/requestApproval"), do: %{"permissions" => %{}}
  defp approval_result(_other), do: %{}

  # ── Session id extraction ─────────────────────────────────────────────

  @impl true
  def session_id(%{"type" => "system", "session_id" => sid}) when is_binary(sid), do: sid
  def session_id(_event), do: nil

  # ── Session lifecycle (CODEX_HOME + config.toml) ──────────────────────
  # Per-session CODEX_HOME lives under the session's working directory
  # (`<directory>/.codex_home/<session_id>`) — deterministic, not `/tmp`
  # (codex warns/refuses PATH-alias helpers under `/tmp`), keyed by session id
  # so concurrent sessions in the same directory don't collide. Rewritten on
  # EVERY spawn (mirrors Claude's per-spawn /mcp URL bake — see
  # `call_prepare_session/1` in SessionRunner) so a flag change
  # (orchestrator/code_exec) is picked up on the next cold reopen. Removed by
  # `cleanup_session/1`, called from `SessionRunner.terminate/3` — i.e. on
  # runner-process death, NOT on every idle-timeout port teardown, so a warm
  # process cycling cold/warm within one runner's life doesn't churn the
  # directory (spec §10 Q3/Q5).

  @impl true
  def prepare_session(ctx) do
    dir = codex_home_dir(ctx)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.toml"), config_toml(ctx))
    copy_auth(dir)
    :ok
  rescue
    e ->
      Logger.error("[Backend.Codex] prepare_session failed: #{Exception.message(e)}")
      :ok
  end

  # The per-session CODEX_HOME hides the user's real one, which is where
  # `codex login` (ChatGPT or --with-api-key) stores credentials — without
  # this copy every turn fails with 401 unless OPENAI_API_KEY happens to be
  # in the BEAM's env. Re-copied on every spawn so a re-login or token
  # refresh in the real home is picked up on the next cold reopen. Caveat:
  # if codex refreshes the ChatGPT token mid-session it writes to the
  # session copy, and the source stays stale until the user's next
  # interactive codex run refreshes it there.
  defp copy_auth(session_home) do
    source_home = System.get_env("CODEX_HOME") || Path.expand("~/.codex")
    source = Path.join(source_home, "auth.json")
    dest = Path.join(session_home, "auth.json")

    if File.exists?(source) do
      File.cp!(source, dest)
      File.chmod!(dest, 0o600)
    end
  end

  @impl true
  def cleanup_session(ctx) do
    File.rm_rf(codex_home_dir(ctx))
    :ok
  rescue
    _ -> :ok
  end

  # CRITICAL: the orca MCP URL is built by the SAME helper Backend.Claude uses
  # (OrcaHub.Backend.McpUrl.orca_url/1) so the query params (orca_session_id,
  # orchestrator, code_exec) can never drift between backends (spec §6.3(2)).
  defp config_toml(ctx) do
    url = McpUrl.orca_url(ctx)

    """
    [mcp_servers.orca]
    url = #{inspect(url)}
    default_tools_approval_mode = "auto"
    """
  end

  # ── System prompt (leading-message — spec §6.3(1)) ────────────────────
  # Reuses the non-Claude-specific fragments from SharedPrompts; the
  # AskUserQuestion fallback and the `mcp__server__tool` naming caveat are
  # genuinely Claude-CLI-specific and dropped here (spec §6.3(5) — no
  # AskUserQuestion tool for Codex in v1).

  @impl true
  def system_prompt(ctx) do
    code_exec = OrcaHub.MCP.CodeExec.enabled?(Map.get(ctx, :code_exec, false))

    [
      "Your OrcaHub session ID is #{ctx.session_id}.",
      orchestrator_system_prompt(ctx.orchestrator, ctx.session_id, code_exec),
      SharedPrompts.code_exec_prompt(code_exec),
      if(!ctx.orchestrator, do: SharedPrompts.commit_trailer_prompt(ctx.session_id)),
      sibling_sessions_prompt(ctx.orchestrator, code_exec),
      SharedPrompts.context_files_prompt(ctx.directory)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp orchestrator_system_prompt(false, _session_id, _code_exec), do: nil
  defp orchestrator_system_prompt(nil, _session_id, _code_exec), do: nil

  # Code-exec collapses a session's MCP surface to run_elixir/search_tools
  # regardless of the orchestrator flag (see
  # lib/orca_hub/mcp/server.ex:130) — none of the coordination tools below
  # exist as standalone orca MCP tools there, so this branch rewrites every
  # reference (including the callback instruction workers get told to paste)
  # to the Tools.<name>(...) inside run_elixir shape.
  defp orchestrator_system_prompt(true, session_id, true) do
    """
    # Orchestrator Session

    You are an **orchestrator session**. Your role is to coordinate work across multiple worker sessions, NOT to do the work yourself.

    ## Your Capabilities

    You have read-only access to the codebase and web access for research. You have file write access, but you must use it **only** to maintain your own file-based memory (e.g. a project-local notes directory). Do NOT edit project source files, run shell commands, or make any other changes directly — delegate all implementation work to worker sessions.

    ## How to Work

    Your MCP tool list is collapsed to `run_elixir` and `search_tools` (code execution mode) — none of the coordination tools (`start_session`, `send_message_to_session`, `schedule_heartbeat`, `search_sessions`, `archive_session`, `cancel_heartbeat`, etc.) are standalone MCP tools here. Call them as `Tools.<name>(args)` from inside `run_elixir`, e.g. `Tools.start_session(%{...})`.

    1. **Delegate all implementation work** to other sessions using `Tools.start_session(...)` (spawn a new worker with a detailed prompt) or `Tools.send_message_to_session(...)` (direct an existing session), both inside `run_elixir`.
    2. **Request callbacks** — when delegating work, explicitly ask the worker session to message you back when done via `Tools.send_message_to_session` inside `run_elixir`, referencing this session id: #{session_id}.
    3. **Set up monitoring** — after spawning workers, use `Tools.schedule_heartbeat(...)` inside `run_elixir` to wake yourself up periodically (e.g. every 2-5 minutes) to check on progress via `Tools.search_sessions(...)`.
    4. **Check in proactively** — if you don't hear back from a worker within a reasonable time, message it for a status update.
    5. **Archive completed children** — use `Tools.archive_session(...)` inside `run_elixir` once a worker has finished, to keep the session list tidy.
    6. **Cancel monitoring** — use `Tools.cancel_heartbeat(...)` inside `run_elixir` once all delegated work is complete.

    Remember: you orchestrate, you don't implement. If you find yourself wanting to edit a file or run a command, spawn a worker session instead.
    """
    |> String.trim()
  end

  defp orchestrator_system_prompt(true, session_id, _code_exec) do
    """
    # Orchestrator Session

    You are an **orchestrator session**. Your role is to coordinate work across multiple worker sessions, NOT to do the work yourself.

    ## Your Capabilities

    You have read-only access to the codebase and web access for research. You have file write access, but you must use it **only** to maintain your own file-based memory (e.g. a project-local notes directory). Do NOT edit project source files, run shell commands, or make any other changes directly — delegate all implementation work to worker sessions.

    ## How to Work

    You have orca MCP tools available (`start_session`, `send_message_to_session`, `schedule_heartbeat`, `search_sessions`, `archive_session`, `cancel_heartbeat`, etc.) for coordinating worker sessions.

    1. **Delegate all implementation work** to other sessions using `start_session` (spawn a new worker with a detailed prompt) or `send_message_to_session` (direct an existing session).
    2. **Request callbacks** — when delegating work, explicitly ask the worker session to message you back when done, referencing this session id: #{session_id}.
    3. **Set up monitoring** — after spawning workers, use `schedule_heartbeat` to wake yourself up periodically (e.g. every 2-5 minutes) to check on progress via `search_sessions`.
    4. **Check in proactively** — if you don't hear back from a worker within a reasonable time, message it for a status update.
    5. **Archive completed children** — use `archive_session` once a worker has finished, to keep the session list tidy.
    6. **Cancel monitoring** — use `cancel_heartbeat` once all delegated work is complete.

    Remember: you orchestrate, you don't implement. If you find yourself wanting to edit a file or run a command, spawn a worker session instead.
    """
    |> String.trim()
  end

  # In code-exec mode, `search_sessions`/`send_message_to_session` only exist
  # as `Tools.*` functions callable from inside `run_elixir` — they are NOT
  # standalone orca MCP tools, so the flat-tool-name guidance below is wrong
  # and must be swapped out.
  defp sibling_sessions_prompt(true, true) do
    "Other agent sessions may be active in this directory. Use `Tools.search_sessions(%{\"status\" => ...})` inside the `run_elixir` MCP tool to discover sibling sessions you may want to coordinate with — it is NOT a standalone MCP tool in this session."
  end

  defp sibling_sessions_prompt(true, _code_exec) do
    "Other agent sessions may be active in this directory. Use the `search_sessions` orca MCP tool to discover sibling sessions you may want to coordinate with."
  end

  defp sibling_sessions_prompt(_orchestrator, true) do
    "Other agent sessions may be active in this directory. Check the `.agents/` directory to discover active sessions and their IDs, then send messages with `Tools.send_message_to_session(%{\"session_id\" => ..., \"message\" => ...})` inside the `run_elixir` MCP tool — it is NOT a standalone MCP tool in this session."
  end

  defp sibling_sessions_prompt(_orchestrator, _code_exec) do
    "Other agent sessions may be active in this directory. Check the `.agents/` directory to discover active sessions and their IDs, then use the `send_message_to_session` orca MCP tool to coordinate with them."
  end
end
