defmodule OrcaHub.SessionRunner do
  @moduledoc """
  GenStatem that manages a Claude CLI session via a port.

  Sends prompts, parses streaming JSON output, persists messages, and
  broadcasts session events via PubSub.
  """

  use GenStatem
  require Logger

  alias OrcaHub.{AgentPresence, AskUserQuestion, HubRPC, Streaming}
  alias OrcaHub.Claude.{Config, StreamParser}

  # Route a HubRPC call through the node that owns the session's DB record.
  # In multi-hub mode, the runner may be on a different node than the DB.
  defp db_call(%{db_node: db_node}, fun, args) when not is_nil(db_node) and db_node != node() do
    :erpc.call(db_node, HubRPC, fun, args, 10_000)
  end

  defp db_call(_data, fun, args) do
    apply(HubRPC, fun, args)
  end

  # Fetch the session and update it in one logical step, avoiding nested db_call.
  defp update_session_status(data, attrs) do
    session = db_call(data, :get_session!, [data.session_id])
    db_call(data, :update_session, [session, attrs])
  end

  # API

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenStatem.start_link(__MODULE__, opts, name: via(session_id))
  end

  def via(session_id), do: {:via, Registry, {OrcaHub.SessionRegistry, session_id}}

  def send_message(session_id, prompt) do
    GenStatem.call(via(session_id), {:send_message, prompt})
  end

  def get_state(session_id) do
    GenStatem.call(via(session_id), :get_state)
  end

  def interrupt(session_id) do
    GenStatem.call(via(session_id), :interrupt)
  end

  def update_model(session_id, model) do
    GenStatem.cast(via(session_id), {:update_model, model})
  end

  def update_orchestrator(session_id, orchestrator) do
    GenStatem.cast(via(session_id), {:update_orchestrator, orchestrator})
  end

  def update_code_exec(session_id, code_exec) do
    GenStatem.cast(via(session_id), {:update_code_exec, code_exec})
  end

  # Callbacks

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    db_node = Keyword.get(opts, :db_node)
    session = Keyword.get(opts, :session_data) || HubRPC.get_session!(session_id)

    # Placeholder data map so db_call works during init
    init_data = %{db_node: db_node}

    saved_messages =
      db_call(init_data, :list_messages, [session_id])
      |> Enum.map(fn msg -> Map.put(msg.data, "timestamp", msg.inserted_at) end)

    initial_state = if saved_messages == [], do: :ready, else: :idle

    # If the session was persisted as "waiting" (an unanswered AskUserQuestion),
    # rebuild the pending questions from history so the UI can render them after
    # a runner restart. DB status — not message history — is the source of truth:
    # the synthetic is_error tool_result means history ALWAYS looks "unanswered".
    pending_questions =
      if session.status == "waiting",
        do: AskUserQuestion.pending_questions(saved_messages),
        else: nil

    # Record which node is running this session
    # Set original_node only if not already set (preserves the first node that ran the session)
    current_node = Atom.to_string(node())
    node_updates = %{runner_node: current_node}

    node_updates =
      if session.original_node,
        do: node_updates,
        else: Map.put(node_updates, :original_node, current_node)

    db_call(init_data, :update_session, [session, node_updates])

    AgentPresence.write(session.directory, session_id, %{
      title: session.title,
      status: to_string(initial_state)
    })

    data = %{
      session_id: session_id,
      project_id: session.project_id,
      claude_session_id: session.claude_session_id,
      directory: session.directory,
      model: session.model,
      orchestrator: session.orchestrator || false,
      code_exec: session.code_exec || false,
      db_node: db_node,
      port: nil,
      buffer: "",
      error_output: "",
      messages: saved_messages,
      first_prompt: nil,
      pending_prompts: [],
      pending_questions: pending_questions,
      # Streaming engine fields (inert when engine == :one_shot)
      engine: resolve_engine(session),
      # cached per-session override so :reresolve_engine can re-decide w/o a DB hit
      streaming_override: Map.get(session, :streaming),
      warming_up: false,
      interrupting: false,
      # set when a runtime kill-switch downgrade is requested mid-turn; consumed
      # when the current turn's result arrives (see finalize_downgrade/1)
      downgrade_pending: false,
      # set when a per-session /mcp flag (orchestrator/code_exec) changes mid-turn;
      # consumed at the running→idle/error transition to evict the now-stale warm
      # port so the NEXT turn cold-reopens with the re-baked /mcp URL
      pending_rebake: false,
      req_counter: 0,
      turn_result: nil
    }

    {:ok, initial_state, data}
  end

  # Resolve which runner engine to use. Streaming is the DEFAULT.
  #
  # Precedence (ABSOLUTE runtime kill switch wins over everything):
  #   1. runtime kill switch (OrcaHub.Streaming, per-node, :persistent_term)
  #      -> :one_shot, overriding even a per-session `streaming: true`.
  #   2. per-session column: true -> :streaming, false -> :one_shot
  #   3. env default ORCA_DISABLE_STREAMING (:disable_streaming) -> :one_shot
  #   4. otherwise -> :streaming
  #
  # The runtime kill switch is the emergency stop: it forces one-shot for ALL
  # sessions on this node regardless of their column (see OrcaHub.Streaming).
  @doc false
  def resolve_engine(session), do: engine_for(Map.get(session, :streaming))

  # Core precedence, keyed on the per-session override (true/false/nil). Shared by
  # resolve_engine/1 (init) and the :reresolve_engine cast (runtime re-enable).
  defp engine_for(override) do
    cond do
      Streaming.kill_engaged?() -> :one_shot
      override == true -> :streaming
      override == false -> :one_shot
      streaming_disabled?() -> :one_shot
      true -> :streaming
    end
  end

  defp streaming_disabled?, do: Application.get_env(:orca_hub, :disable_streaming, false)

  # How long a warm (process-alive, awaiting input) streaming session may sit
  # idle before its claude process is torn down to reclaim memory. The session
  # goes "cold" (port: nil) and re-opens with --resume on the next message.
  @idle_timeout_ms 15 * 60 * 1000

  # Throwaway first turn that forces the async MCP handshake to complete before
  # the user's real first turn runs. The orca server shows `orca:pending` (0
  # tools) on turn 1; completing one no-tool turn lets it reach `orca:connected`
  # so the real first turn sees all tools. This is the fix for the intermittent
  # "No such tool available" client-side registration race.
  #
  # FUTURE (documented follow-up, intentionally NOT in this change): replace this
  # warm-up turn with a zero-token, in-BEAM "MCP ready" gate — have the per-session
  # orca MCP server PubSub-signal the runner once the CLI completes tools/list, and
  # gate the first real turn on that signal. See streaming_runner_design.md §5.
  @warmup_prompt "Respond with the single word: ready"

  # ── :ready state ─────────────────────────────────────────────────────
  # Session has been created but no messages have been sent yet.

  def ready({:call, from}, {:send_message, prompt}, %{engine: :streaming} = data) do
    start_streaming(from, prompt, data)
  end

  def ready({:call, from}, {:send_message, prompt}, data) do
    start_running(from, prompt, data)
  end

  def ready({:call, from}, :interrupt, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def ready({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:ready, data)}]}
  end

  def ready({:call, from}, {:downgrade, _mode}, data), do: downgrade_no_turn(from, data)
  def ready({:call, from}, :evict_warm, _data), do: {:keep_state_and_data, [{:reply, from, :ok}]}
  def ready(:cast, :reresolve_engine, data), do: reresolve_no_turn(data)

  def ready(:cast, {:update_model, model}, data), do: {:keep_state, %{data | model: model}}

  def ready(:cast, {:update_orchestrator, orchestrator}, data),
    do: apply_flag_change_no_turn(data, :orchestrator, orchestrator)

  def ready(:cast, {:update_code_exec, code_exec}, data),
    do: apply_flag_change_no_turn(data, :code_exec, code_exec)

  def ready(:cast, _msg, _data), do: :keep_state_and_data
  def ready(:info, _msg, _data), do: :keep_state_and_data

  # ── :idle state ──────────────────────────────────────────────────────
  # Session has completed at least one run and is waiting for the next message.

  def idle({:call, from}, {:send_message, prompt}, %{engine: :streaming} = data) do
    start_streaming(from, prompt, data)
  end

  def idle({:call, from}, {:send_message, prompt}, data) do
    start_running(from, prompt, data)
  end

  def idle({:call, from}, :interrupt, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def idle({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:idle, data)}]}
  end

  # Streaming: warm process timed out → tear it down (go cold). Crash detection
  # below.
  def idle(:state_timeout, :idle_teardown, %{engine: :streaming, port: port} = data)
      when not is_nil(port) do
    Logger.info(
      "[streaming] idle timeout — tearing down warm process for session #{data.session_id}"
    )

    {:keep_state, teardown_port(data)}
  end

  def idle(:state_timeout, :idle_teardown, data), do: {:keep_state, data}

  def idle({:call, from}, {:downgrade, _mode}, data), do: downgrade_no_turn(from, data)
  def idle({:call, from}, :evict_warm, data), do: evict_warm_idle(from, data)
  def idle(:cast, :reresolve_engine, data), do: reresolve_no_turn(data)

  def idle(:info, {port, {:exit_status, code}}, %{engine: :streaming, port: port} = data) do
    handle_streaming_exit(code, :idle, data)
  end

  def idle(:cast, {:update_model, model}, data), do: {:keep_state, %{data | model: model}}

  def idle(:cast, {:update_orchestrator, orchestrator}, data),
    do: apply_flag_change_no_turn(data, :orchestrator, orchestrator)

  def idle(:cast, {:update_code_exec, code_exec}, data),
    do: apply_flag_change_no_turn(data, :code_exec, code_exec)

  def idle(:cast, _msg, _data), do: :keep_state_and_data
  def idle(:info, _msg, _data), do: :keep_state_and_data

  # ── :running state ──────────────────────────────────────────────────

  # Streaming: a new message while a turn is in flight queues the prompt and
  # interrupts the current turn via a control_request (NOT SIGINT — that would
  # kill the long-lived process). The queued prompt is flushed to the same stdin
  # when the interrupt's `result` arrives. During warm-up we don't interrupt;
  # the warm-up turn finishes and the queue (incl. this prompt) is flushed then.
  def running({:call, from}, {:send_message, prompt}, %{engine: :streaming, port: port} = data)
      when not is_nil(port) do
    user_event = make_user_event(prompt)
    persist_message(data, user_event)
    broadcast(data.session_id, {:event, user_event})

    data = %{
      data
      | pending_prompts: data.pending_prompts ++ [prompt],
        messages: data.messages ++ [user_event]
    }

    data = if data.warming_up, do: data, else: send_control_interrupt(data)

    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def running({:call, from}, {:send_message, prompt}, %{port: port} = data)
      when not is_nil(port) do
    user_event = make_user_event(prompt)
    persist_message(data, user_event)
    broadcast(data.session_id, {:event, user_event})

    # Interrupt the running CLI — SIGINT lets it finish in-progress tool calls gracefully
    send_sigint(port)

    {:keep_state,
     %{
       data
       | pending_prompts: data.pending_prompts ++ [prompt],
         messages: data.messages ++ [user_event]
     }, [{:reply, from, :ok}]}
  end

  # Streaming: explicit stop button — control_request interrupt, process survives.
  def running({:call, from}, :interrupt, %{engine: :streaming, port: port} = data)
      when not is_nil(port) do
    {:keep_state, send_control_interrupt(data), [{:reply, from, :ok}]}
  end

  def running({:call, from}, :interrupt, %{port: port}) when not is_nil(port) do
    send_sigint(port)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def running({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:running, data)}]}
  end

  # Runtime kill-switch downgrade while a turn is in flight. We can't drop to
  # one-shot mid-turn without losing the turn, so we mark it pending and convert
  # when the turn's `result` arrives (finalize_downgrade/1). :interrupt ends the
  # current turn promptly via control_request; :graceful lets it finish.
  def running({:call, from}, {:downgrade, _mode}, %{engine: :one_shot}) do
    {:keep_state_and_data, [{:reply, from, :already_one_shot}]}
  end

  def running({:call, from}, {:downgrade, mode}, data) do
    data =
      if mode == :interrupt and not is_nil(data.port) and not data.warming_up,
        do: send_control_interrupt(data),
        else: data

    {:keep_state, %{data | downgrade_pending: true}, [{:reply, from, :pending_after_turn}]}
  end

  # Never evict a runner that's mid-turn — the WarmPool tries the next LRU victim.
  def running({:call, from}, :evict_warm, _data) do
    {:keep_state_and_data, [{:reply, from, :busy}]}
  end

  def running(:info, {port, {:data, raw}}, %{port: port} = data) do
    {events, new_buffer} = StreamParser.parse(raw, data.buffer)

    error_lines = extract_non_json_lines(raw, data.buffer)

    error_output =
      if error_lines != "" do
        data.error_output <> error_lines
      else
        data.error_output
      end

    new_data =
      Enum.reduce(events, %{data | buffer: new_buffer, error_output: error_output}, fn event,
                                                                                       acc ->
        handle_stream_event(event, acc)
      end)

    case new_data.engine do
      :streaming -> handle_streaming_progress(new_data)
      _ -> {:keep_state, new_data}
    end
  end

  # Streaming: the long-lived process does NOT exit between turns. An exit here
  # means a crash (or an exit we didn't initiate — teardown sets port: nil first,
  # so a matching port means it was unexpected).
  def running(:info, {port, {:exit_status, code}}, %{engine: :streaming, port: port} = data) do
    handle_streaming_exit(code, :running, data)
  end

  def running(:info, {port, {:exit_status, code}}, %{port: port} = data) do
    Logger.info("Claude CLI exited (code #{code}) for session #{data.session_id}")

    case data.pending_prompts do
      [_ | _] = prompts ->
        # Auto-resume with queued prompts bundled into a single message
        combined_prompt = Enum.join(prompts, "\n\n\n")

        Logger.info(
          "Auto-resuming session #{data.session_id} with #{length(prompts)} pending prompt(s)"
        )

        # A queued answer/prompt resumes the run; we're no longer waiting on the user.
        data = resume_clears_waiting(data)

        new_port = open_port(combined_prompt, data)

        {:keep_state,
         %{
           data
           | port: new_port,
             buffer: "",
             error_output: "",
             pending_prompts: [],
             pending_questions: nil
         }}

      [] ->
        data = handle_cli_error(code, data)
        session = db_call(data, :get_session!, [data.session_id])

        # On a clean exit with an unanswered AskUserQuestion, persist/broadcast
        # "waiting" instead of "idle". The state machine still moves to :idle so
        # the next message (the user's answer) resumes normally.
        {db_status, broadcast_status} =
          cond do
            code == 0 and data.pending_questions != nil -> {"waiting", :waiting}
            code == 0 -> {"idle", :idle}
            true -> {"error", :error}
          end

        db_call(data, :update_session, [session, %{status: db_status}])
        broadcast(data.session_id, {:status, broadcast_status})
        AgentPresence.update_status(data.directory, data.session_id, db_status)

        if code == 0 && (session.title == nil || session.title == "") do
          Logger.info(
            "Attempting title generation for session #{data.session_id}, first_prompt: #{inspect(data.first_prompt)}"
          )

          maybe_generate_title(data, data.first_prompt)
        end

        next_state = if code == 0, do: :idle, else: :error
        {:next_state, next_state, %{data | port: nil}}
    end
  end

  def running(:cast, {:update_model, model}, data), do: {:keep_state, %{data | model: model}}

  def running(:cast, {:update_orchestrator, orchestrator}, data),
    do: apply_flag_change_running(data, :orchestrator, orchestrator)

  def running(:cast, {:update_code_exec, code_exec}, data),
    do: apply_flag_change_running(data, :code_exec, code_exec)

  def running(:cast, _msg, _data), do: :keep_state_and_data
  def running(:info, _msg, _data), do: :keep_state_and_data

  # ── :error state ─────────────────────────────────────────────────────
  # Same as idle — accepts new messages to retry, rejects interrupts.

  def error({:call, from}, {:send_message, prompt}, %{engine: :streaming} = data) do
    start_streaming(from, prompt, data)
  end

  def error({:call, from}, {:send_message, prompt}, data) do
    start_running(from, prompt, data)
  end

  def error({:call, from}, :interrupt, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def error({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:error, data)}]}
  end

  # Streaming: a genuine turn error leaves the process ALIVE, so :error can hold a
  # warm port that the idle timeout should still reap, and a crash can still occur.
  def error(:state_timeout, :idle_teardown, %{engine: :streaming, port: port} = data)
      when not is_nil(port) do
    Logger.info(
      "[streaming] idle timeout — tearing down warm process for session #{data.session_id}"
    )

    {:keep_state, teardown_port(data)}
  end

  def error(:state_timeout, :idle_teardown, data), do: {:keep_state, data}

  def error({:call, from}, {:downgrade, _mode}, data), do: downgrade_no_turn(from, data)
  def error({:call, from}, :evict_warm, data), do: evict_warm_idle(from, data)
  def error(:cast, :reresolve_engine, data), do: reresolve_no_turn(data)

  def error(:info, {port, {:exit_status, code}}, %{engine: :streaming, port: port} = data) do
    handle_streaming_exit(code, :error, data)
  end

  def error(:cast, {:update_model, model}, data), do: {:keep_state, %{data | model: model}}

  def error(:cast, {:update_orchestrator, orchestrator}, data),
    do: apply_flag_change_no_turn(data, :orchestrator, orchestrator)

  def error(:cast, {:update_code_exec, code_exec}, data),
    do: apply_flag_change_no_turn(data, :code_exec, code_exec)

  def error(:cast, _msg, _data), do: :keep_state_and_data
  def error(:info, _msg, _data), do: :keep_state_and_data

  # ── Terminate ────────────────────────────────────────────────────────

  @impl true
  def terminate(_reason, _state, data) do
    # Close a warm streaming process if one is open (linked ports auto-close, but
    # be explicit so the child claude process is reaped promptly).
    if data[:port] do
      try do
        Port.close(data.port)
      catch
        _, _ -> :ok
      end
    end

    Streaming.WarmPool.release(data.session_id)
    AgentPresence.remove(data.directory, data.session_id)
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp handle_cli_error(code, data) when code != 0 do
    error_text = String.trim(data.error_output <> data.buffer)

    if error_text != "" do
      error_event =
        stamp(%{
          "type" => "cli_error",
          "exit_code" => code,
          "message" => error_text
        })

      persist_message(data, error_event)
      broadcast(data.session_id, {:event, error_event})
      %{data | messages: data.messages ++ [error_event]}
    else
      data
    end
  end

  defp handle_cli_error(_code, data), do: data

  defp start_running(from, prompt, data) do
    user_event = make_user_event(prompt)
    persist_message(data, user_event)
    broadcast(data.session_id, {:event, user_event})

    port = open_port(prompt, data)
    session = db_call(data, :get_session!, [data.session_id])
    if session.archived_at, do: db_call(data, :unarchive_session, [session])
    db_call(data, :update_session, [session, %{status: "running"}])
    broadcast(data.session_id, {:status, :running})
    AgentPresence.update_status(data.directory, data.session_id, "running")

    first_prompt = data.first_prompt || prompt

    {:next_state, :running,
     %{
       data
       | port: port,
         buffer: "",
         error_output: "",
         messages: data.messages ++ [user_event],
         first_prompt: first_prompt,
         pending_questions: nil
     }, [{:reply, from, :ok}]}
  end

  # When a hung run is resumed by a queued answer, leave "waiting" behind and
  # reflect that the session is running again.
  defp resume_clears_waiting(%{pending_questions: nil} = data), do: data

  defp resume_clears_waiting(data) do
    update_session_status(data, %{status: "running"})
    broadcast(data.session_id, {:status, :running})
    AgentPresence.update_status(data.directory, data.session_id, "running")
    data
  end

  # ── Runtime kill-switch downgrade (no turn in flight) ────────────────
  # Shared by :ready / :idle / :error. Converts a streaming runner to one-shot.

  defp downgrade_no_turn(from, %{engine: :one_shot}) do
    {:keep_state_and_data, [{:reply, from, :already_one_shot}]}
  end

  defp downgrade_no_turn(from, %{port: nil} = data) do
    # Cold (no warm process) — just flip the engine.
    {:keep_state, %{data | engine: :one_shot}, [{:reply, from, :torn_down_now}]}
  end

  defp downgrade_no_turn(from, data) do
    # Warm idle/error process — tear the port down now and cancel the idle timer.
    data = %{teardown_port(data) | engine: :one_shot}

    {:keep_state, data,
     [{:reply, from, :torn_down_now}, {:state_timeout, :infinity, :idle_teardown}]}
  end

  # Runtime re-enable: re-decide the engine from the cached override. Lazy — no
  # port is opened; a re-upgraded session cold-opens streaming on its next turn.
  defp reresolve_no_turn(data) do
    {:keep_state, %{data | engine: engine_for(data.streaming_override)}}
  end

  # LRU warm-cap eviction of an idle/error runner: tear the port down (releasing
  # the slot), cancel the idle timer, and ack. Cold runners ack immediately.
  defp evict_warm_idle(from, %{port: nil}) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  defp evict_warm_idle(from, data) do
    {new_data, actions} = evict_warm_now(data)
    {:keep_state, new_data, [{:reply, from, :ok} | actions]}
  end

  # Core warm-port eviction shared by the LRU :evict_warm handlers and the
  # self-applying /mcp flag-change casts: close the port (releasing the WarmPool
  # slot), set port: nil, and cancel the idle-teardown timer. The runner stays
  # alive but cold; its next turn re-opens the port (re-baking the /mcp URL).
  # Returns {new_data, actions} so callers can prepend their own reply.
  defp evict_warm_now(data) do
    {teardown_port(data), [{:state_timeout, :infinity, :idle_teardown}]}
  end

  # Self-applying per-session /mcp flag change (orchestrator/code_exec) while NOT
  # mid-turn (ready/idle/error). The flag is baked into the /mcp URL only at
  # port-open, so when the value actually CHANGES we evict the warm port now to
  # force a cold re-open (and URL re-bake) on the next turn. A no-op (same value)
  # must NOT tear the port down. Cold runners (port: nil) just store the value.
  defp apply_flag_change_no_turn(data, key, value) do
    changed? = Map.get(data, key) != value
    new_data = Map.put(data, key, value)

    if changed? and not is_nil(data.port) do
      {td, actions} = evict_warm_now(new_data)
      {:keep_state, td, actions}
    else
      {:keep_state, new_data}
    end
  end

  # Self-applying /mcp flag change while a turn is in flight (:running). We must
  # NOT disrupt the active port, so we store the new value and (if it changed)
  # mark a pending rebake; the warm port is evicted at the running→idle/error
  # transition (see consume_pending_rebake/1), so the SUBSEQUENT turn re-bakes the
  # URL. An already-set marker is preserved across a no-op change.
  defp apply_flag_change_running(data, key, value) do
    changed? = Map.get(data, key) != value
    new_data = Map.put(data, key, value)
    {:keep_state, %{new_data | pending_rebake: new_data.pending_rebake or changed?}}
  end

  # At the running→idle/error transition, honor a /mcp flag rebake requested
  # mid-turn: evict the now-stale warm port so the next turn cold-reopens with the
  # new URL. Returns {data, actions}; with no pending rebake, arms the normal idle
  # timer instead. Public (@doc false) as a test seam.
  @doc false
  def consume_pending_rebake(%{pending_rebake: true} = data) do
    evict_warm_now(%{data | pending_rebake: false})
  end

  def consume_pending_rebake(data), do: {data, idle_actions(data)}

  # ── Streaming engine ─────────────────────────────────────────────────
  # Long-lived `claude -p --input-format stream-json --output-format stream-json`
  # process per session. MCP initializes ONCE per process instead of per turn.

  defp start_streaming(from, prompt, data) do
    user_event = make_user_event(prompt)
    persist_message(data, user_event)
    broadcast(data.session_id, {:event, user_event})

    session = db_call(data, :get_session!, [data.session_id])
    if session.archived_at, do: db_call(data, :unarchive_session, [session])
    db_call(data, :update_session, [session, %{status: "running"}])
    broadcast(data.session_id, {:status, :running})
    AgentPresence.update_status(data.directory, data.session_id, "running")

    first_prompt = data.first_prompt || prompt

    base = %{
      data
      | buffer: "",
        error_output: "",
        messages: data.messages ++ [user_event],
        first_prompt: first_prompt,
        pending_questions: nil,
        interrupting: false,
        turn_result: nil
    }

    data =
      if base.port == nil do
        # Cold start: claim a warm slot (may evict an LRU idle peer), then open the
        # process, run a hidden warm-up turn to force the MCP handshake, and queue
        # the real prompt to flush once warm-up completes.
        Streaming.WarmPool.request_slot(base.session_id, self())
        port = open_port_streaming(base)
        write_warmup_turn(port)
        # Fresh port bakes the current flags into the /mcp URL — any pending rebake
        # is satisfied by this cold open.
        %{
          base
          | port: port,
            warming_up: true,
            pending_rebake: false,
            pending_prompts: base.pending_prompts ++ [prompt]
        }
      else
        # Warm process: write the real turn straight to the already-open stdin.
        Streaming.WarmPool.touch(base.session_id, :running)
        write_user_turn(base.port, prompt)
        base
      end

    {:next_state, :running, data, [{:reply, from, :ok}]}
  end

  # Called after each event reduce in :running (streaming). Drives transitions off
  # the `result` stream event instead of a port exit.
  defp handle_streaming_progress(%{turn_result: nil} = data), do: {:keep_state, data}

  defp handle_streaming_progress(%{turn_result: :warmup_done, downgrade_pending: true} = data) do
    # Kill-switch downgrade requested during warm-up: drop to one-shot now and
    # re-route the queued real prompt(s) instead of starting a streaming turn.
    finalize_downgrade(%{data | warming_up: false, turn_result: nil})
  end

  defp handle_streaming_progress(%{turn_result: :warmup_done} = data) do
    # Warm-up turn done — MCP is connected. Flush the queued real prompt(s).
    data = flush_pending_to_stdin(%{data | warming_up: false, turn_result: nil})
    {:keep_state, data}
  end

  defp handle_streaming_progress(%{turn_result: {:complete, _ev}, downgrade_pending: true} = data) do
    # The turn we were waiting on (graceful kill-switch downgrade) finished.
    finalize_downgrade(%{data | turn_result: nil})
  end

  defp handle_streaming_progress(%{turn_result: {:complete, result_ev}} = data) do
    finalize_streaming_turn(result_ev, %{data | turn_result: nil})
  end

  # Convert a streaming runner to one-shot after a kill-switch downgrade. Tears
  # the persistent port down and re-routes any queued prompts through the
  # one-shot engine. Continuity is preserved via claude_session_id/--resume.
  defp finalize_downgrade(data) do
    prompts = data.pending_prompts
    data = teardown_port(%{data | downgrade_pending: false, interrupting: false})
    data = %{data | engine: :one_shot, pending_prompts: []}

    case prompts do
      [] ->
        session = db_call(data, :get_session!, [data.session_id])
        db_call(data, :update_session, [session, %{status: "idle"}])
        broadcast(data.session_id, {:status, :idle})
        AgentPresence.update_status(data.directory, data.session_id, "idle")
        {:next_state, :idle, data}

      _ ->
        # Deliver the queued prompt(s) via the one-shot engine (mirrors the
        # one-shot auto-resume combine).
        combined = Enum.join(prompts, "\n\n\n")
        data = resume_clears_waiting(data)
        new_port = open_port(combined, data)
        session = db_call(data, :get_session!, [data.session_id])
        db_call(data, :update_session, [session, %{status: "running"}])
        broadcast(data.session_id, {:status, :running})
        AgentPresence.update_status(data.directory, data.session_id, "running")

        {:next_state, :running,
         %{data | port: new_port, buffer: "", error_output: "", pending_questions: nil}}
    end
  end

  defp finalize_streaming_turn(result_ev, data) do
    decision =
      streaming_turn_decision(%{
        pending_prompts: data.pending_prompts,
        interrupting: data.interrupting,
        is_error: result_ev["is_error"] == true
      })

    case decision do
      :flush_queue ->
        # Interrupt or queued message(s): resume on the SAME warm process.
        data = resume_clears_waiting(data)
        data = flush_pending_to_stdin(%{data | interrupting: false, pending_questions: nil})
        {:keep_state, %{data | buffer: "", error_output: ""}}

      :idle_stop ->
        # Explicit interrupt with nothing queued — a user stop, not an error.
        finalize_streaming_idle(data, false)

      :error ->
        session = db_call(data, :get_session!, [data.session_id])
        db_call(data, :update_session, [session, %{status: "error"}])
        broadcast(data.session_id, {:status, :error})
        AgentPresence.update_status(data.directory, data.session_id, "error")
        # Process stays warm after a turn error — mark it idle-in-pool (evictable).
        Streaming.WarmPool.touch(data.session_id, :error)
        {next_data, actions} = consume_pending_rebake(%{data | interrupting: false})
        {:next_state, :error, next_data, actions}

      :success ->
        finalize_streaming_idle(data, true)
    end
  end

  # Pure model of the kill-switch downgrade decision (mirrors the {:downgrade,_}
  # handlers across :ready/:idle/:error/:running). Exposed for testing the table
  # without a live runner:
  #   already one-shot              -> :already_one_shot
  #   turn in flight + :interrupt   -> :pending_interrupt   (control_request, then drop)
  #   turn in flight + :graceful    -> :pending_after_turn  (finish, then drop)
  #   no turn, warm port            -> :teardown_one_shot
  #   no turn, cold                 -> :flip_one_shot
  @doc false
  def downgrade_target(:one_shot, _has_port?, _running?, _mode), do: :already_one_shot
  def downgrade_target(:streaming, _has_port?, true, :interrupt), do: :pending_interrupt
  def downgrade_target(:streaming, _has_port?, true, :graceful), do: :pending_after_turn
  def downgrade_target(:streaming, true, false, _mode), do: :teardown_one_shot
  def downgrade_target(:streaming, false, false, _mode), do: :flip_one_shot

  # Pure transition decision for a completed streaming turn. Exposed for testing
  # (stream-event injection through the state machine without a live CLI).
  @doc false
  def streaming_turn_decision(%{
        pending_prompts: pending,
        interrupting: interrupting,
        is_error: is_error
      }) do
    cond do
      pending != [] -> :flush_queue
      interrupting -> :idle_stop
      is_error -> :error
      true -> :success
    end
  end

  defp finalize_streaming_idle(data, generate_title?) do
    session = db_call(data, :get_session!, [data.session_id])

    {db_status, broadcast_status} =
      if data.pending_questions != nil, do: {"waiting", :waiting}, else: {"idle", :idle}

    db_call(data, :update_session, [session, %{status: db_status}])
    broadcast(data.session_id, {:status, broadcast_status})
    AgentPresence.update_status(data.directory, data.session_id, db_status)

    if generate_title? and (session.title == nil or session.title == "") do
      maybe_generate_title(data, data.first_prompt)
    end

    # Turn done, process stays warm awaiting input — evictable by the LRU cap.
    Streaming.WarmPool.touch(data.session_id, :idle)
    {next_data, actions} = consume_pending_rebake(%{data | interrupting: false})
    {:next_state, :idle, next_data, actions}
  end

  # Graceful teardown (idle timeout) sets port: nil BEFORE any exit arrives, so an
  # exit_status we still hold the port for is always an unexpected crash.
  defp handle_streaming_exit(code, state, data) do
    Logger.warning(
      "[streaming] claude process exited unexpectedly (code #{code}) for session " <>
        "#{data.session_id} in state #{state}"
    )

    # The warm process is gone — free its slot (idempotent).
    Streaming.WarmPool.release(data.session_id)

    data = %{
      data
      | port: nil,
        warming_up: false,
        interrupting: false,
        pending_prompts: [],
        turn_result: nil
    }

    if state == :running do
      # Crash mid-turn: surface the failure; do NOT auto-resend (avoids duplicate
      # side effects). The next message re-opens cold with --resume.
      data = handle_cli_error(code, data)
      session = db_call(data, :get_session!, [data.session_id])
      db_call(data, :update_session, [session, %{status: "error"}])
      broadcast(data.session_id, {:status, :error})
      AgentPresence.update_status(data.directory, data.session_id, "error")
      {:next_state, :error, data}
    else
      # Crash while idle/errored (no turn in flight): silently go cold; the next
      # message re-opens with --resume. Stay in the current state.
      {:keep_state, data}
    end
  end

  defp open_port_streaming(data) do
    claude_path = System.find_executable("claude") || raise "claude executable not found in PATH"

    opts =
      [cwd: data.directory, input_format: "stream-json"]
      |> maybe_put(:session_id, data.claude_session_id)
      |> maybe_put(:model, data.model)
      |> maybe_put(:system_prompt, build_system_prompt(data))
      |> maybe_put(:tools, orchestrator_tools(data.orchestrator))
      |> Keyword.put(:mcp_config, mcp_config(data))

    {args, port_opts} = Config.build_args(nil, opts)

    # Direct spawn — NO `script -qc` PTY wrapper. The streaming protocol writes
    # newline-delimited JSON to stdin; a PTY runs canonical mode (input echo, \n
    # translation) that would corrupt the NDJSON framing. Verified in the spike.
    Port.open(
      {:spawn_executable, claude_path},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:env, OrcaHub.Env.sanitized_env()}
      ] ++ port_opts
    )
  end

  defp write_user_turn(port, prompt), do: Port.command(port, user_turn_json(prompt))
  defp write_warmup_turn(port), do: Port.command(port, user_turn_json(@warmup_prompt))

  # NDJSON framing for a user turn over stdin. Public for testing.
  @doc false
  def user_turn_json(prompt) do
    Jason.encode!(%{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => prompt}]}
    }) <> "\n"
  end

  defp send_control_interrupt(%{port: port, req_counter: n} = data) do
    Port.command(port, control_interrupt_json("int_#{n}"))
    %{data | req_counter: n + 1, interrupting: true}
  end

  # NDJSON framing for a control_request interrupt over stdin. Public for testing.
  @doc false
  def control_interrupt_json(req_id) do
    Jason.encode!(%{
      "type" => "control_request",
      "request_id" => req_id,
      "request" => %{"subtype" => "interrupt"}
    }) <> "\n"
  end

  defp flush_pending_to_stdin(%{pending_prompts: []} = data), do: data

  defp flush_pending_to_stdin(%{pending_prompts: prompts, port: port} = data) do
    combined = Enum.join(prompts, "\n\n\n")
    Streaming.WarmPool.touch(data.session_id, :running)
    write_user_turn(port, combined)
    %{data | pending_prompts: [], buffer: "", error_output: ""}
  end

  defp teardown_port(%{port: port} = data) when not is_nil(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    # The warm process is gone — free its slot (idempotent).
    Streaming.WarmPool.release(data.session_id)
    %{data | port: nil, buffer: "", error_output: "", warming_up: false, turn_result: nil}
  end

  defp teardown_port(data), do: data

  # Arm the idle teardown timer only for a warm streaming process.
  defp idle_actions(%{engine: :streaming, port: port}) when not is_nil(port) do
    [{:state_timeout, @idle_timeout_ms, :idle_teardown}]
  end

  defp idle_actions(_), do: []

  defp make_user_event(prompt) do
    stamp(%{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => prompt}]}
    })
  end

  defp state_snapshot(status, data) do
    # An unanswered AskUserQuestion surfaces as the "waiting" status even though
    # the GenStatem state is :idle (clean exit) or :running (hung run).
    effective = if data.pending_questions != nil, do: :waiting, else: status

    %{
      status: effective,
      messages: data.messages,
      claude_session_id: data.claude_session_id,
      pending_questions: data.pending_questions
    }
  end

  defp open_port(prompt, data) do
    claude_path = System.find_executable("claude") || raise "claude executable not found in PATH"
    script_path = System.find_executable("script") || raise "script executable not found in PATH"

    opts =
      [cwd: data.directory]
      |> maybe_put(:session_id, data.claude_session_id)
      |> maybe_put(:model, data.model)
      |> maybe_put(:system_prompt, build_system_prompt(data))
      |> maybe_put(:tools, orchestrator_tools(data.orchestrator))
      |> Keyword.put(:mcp_config, mcp_config(data))

    {args, port_opts} = Config.build_args(prompt, opts)

    script_args =
      case :os.type() do
        {:unix, :darwin} ->
          ["-q", "/dev/null", claude_path | args]

        _ ->
          cmd = Enum.map_join([claude_path | args], " ", &Config.shell_escape/1)
          ["-qc", cmd, "/dev/null"]
      end

    Port.open(
      {:spawn_executable, script_path},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, script_args},
        {:env, OrcaHub.Env.sanitized_env()}
      ] ++
        port_opts
    )
  end

  # Streaming warm-up: suppress every event of the hidden warm-up turn from the
  # feed. Still capture the claude_session_id (for crash recovery / --resume) and
  # detect the warm-up turn's end so the queued real prompt can be flushed.
  defp handle_stream_event(event, %{warming_up: true} = data) do
    data =
      case event do
        %{"type" => "system", "session_id" => sid} when is_binary(sid) ->
          if is_nil(data.claude_session_id),
            do: update_session_status(data, %{claude_session_id: sid})

          %{data | claude_session_id: sid}

        _ ->
          data
      end

    case event do
      %{"type" => "result"} -> %{data | turn_result: :warmup_done}
      _ -> data
    end
  end

  defp handle_stream_event(
         %{"type" => "system", "subtype" => "status", "status" => "compacting"},
         data
       ) do
    update_session_status(data, %{status: "compacting"})
    broadcast(data.session_id, {:status, :compacting})
    AgentPresence.update_status(data.directory, data.session_id, "compacting")
    data
  end

  defp handle_stream_event(%{"type" => "system", "subtype" => "status", "status" => nil}, data) do
    # Status cleared (e.g. compacting finished) — restore running state
    update_session_status(data, %{status: "running"})
    broadcast(data.session_id, {:status, :running})
    AgentPresence.update_status(data.directory, data.session_id, "running")
    data
  end

  defp handle_stream_event(%{"type" => "system", "session_id" => sid} = event, data) do
    if data.claude_session_id == nil do
      update_session_status(data, %{claude_session_id: sid})
    end

    event = stamp(event)
    persist_message(data, event)
    broadcast(data.session_id, {:event, event})
    %{data | claude_session_id: sid, messages: data.messages ++ [event]}
  end

  # Assistant turn — may contain an AskUserQuestion tool_use that puts the
  # session into the "waiting" status until the user answers.
  defp handle_stream_event(%{"type" => "assistant", "message" => %{"content" => c}} = event, data)
       when is_list(c) do
    data = maybe_mark_waiting(event, data)
    event = stamp(event)
    persist_message(data, event)
    broadcast(data.session_id, {:event, event})
    %{data | messages: data.messages ++ [event]}
  end

  # User turn — a NON-error tool_result for the pending question means it was
  # actually answered (the synthetic is_error result does NOT count).
  defp handle_stream_event(%{"type" => "user", "message" => %{"content" => c}} = event, data)
       when is_list(c) do
    data = maybe_clear_waiting(event, data)
    event = stamp(event)
    persist_message(data, event)
    broadcast(data.session_id, {:event, event})
    %{data | messages: data.messages ++ [event]}
  end

  # Streaming: the `result` event is the turn-completion signal (replacing the
  # one-shot port exit). Persist/broadcast it like any message AND stash it so the
  # running info handler can drive the state transition after the event reduce.
  defp handle_stream_event(%{"type" => "result"} = event, %{engine: :streaming} = data) do
    event = stamp(event)
    persist_message(data, event)
    broadcast(data.session_id, {:event, event})
    %{data | messages: data.messages ++ [event], turn_result: {:complete, event}}
  end

  defp handle_stream_event(event, data) do
    event = stamp(event)
    persist_message(data, event)
    broadcast(data.session_id, {:event, event})
    %{data | messages: data.messages ++ [event]}
  end

  defp maybe_mark_waiting(event, data) do
    case AskUserQuestion.pending_questions([event]) do
      %{} = pending ->
        update_session_status(data, %{status: "waiting"})
        broadcast(data.session_id, {:status, :waiting})
        AgentPresence.update_status(data.directory, data.session_id, "waiting")
        %{data | pending_questions: pending}

      nil ->
        data
    end
  end

  defp maybe_clear_waiting(
         %{"message" => %{"content" => content}},
         %{
           pending_questions: %{tool_use_id: id}
         } = data
       )
       when is_list(content) do
    answered? =
      Enum.any?(content, fn
        %{"type" => "tool_result", "tool_use_id" => ^id} = r -> r["is_error"] != true
        _ -> false
      end)

    if answered?, do: %{data | pending_questions: nil}, else: data
  end

  defp maybe_clear_waiting(_event, data), do: data

  defp broadcast(session_id, payload) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", payload)
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session_id, payload})
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  # Orchestrator sessions get a restricted toolset: read-only file access plus web,
  # plus Write/Edit so they can persist their file-based memory under `.claude`.
  # Writes are NOT path-enforced (skip-permissions stays on); the system prompt
  # instructs orchestrators to confine their direct writes to `.claude` and to
  # delegate all other implementation work to worker sessions.
  @orchestrator_tools "Read,Glob,Grep,WebFetch,WebSearch,Write,Edit"
  defp orchestrator_tools(true), do: @orchestrator_tools
  defp orchestrator_tools(_), do: nil

  defp mcp_config(data) do
    port =
      case OrcaHubWeb.Endpoint.config(:http) do
        config when is_list(config) -> Keyword.get(config, :port, 4000)
        _ -> 4000
      end

    # Honor the env kill switch at bake time so a disabled node never advertises
    # code-exec mode (and a stale URL can't re-enable it).
    code_exec = OrcaHub.MCP.CodeExec.enabled?(data.code_exec)

    Logger.info(
      "[MCP] mcp_config: baking orca_session_id=#{inspect(data.session_id)} " <>
        "orchestrator=#{data.orchestrator == true} code_exec=#{code_exec} " <>
        "into /mcp URL at port-open time"
    )

    orca_server = %{
      "type" => "http",
      "url" =>
        "http://localhost:#{port}/mcp?orca_session_id=#{data.session_id}" <>
          "&orchestrator=#{data.orchestrator == true}" <>
          "&code_exec=#{code_exec}"
    }

    project_servers =
      if data.project_id,
        do: db_call(data, :list_enabled_servers_for_project, [data.project_id]),
        else: []

    session_servers = db_call(data, :list_enabled_servers_for_session, [data.session_id])

    scoped_servers =
      (project_servers ++ session_servers)
      |> Enum.uniq_by(& &1.id)
      |> Map.new(fn server ->
        entry = %{"type" => "http", "url" => server.url}

        entry =
          if map_size(server.headers) > 0,
            do: Map.put(entry, "headers", server.headers),
            else: entry

        {server.name, entry}
      end)

    Jason.encode!(%{"mcpServers" => Map.merge(scoped_servers, %{"orca" => orca_server})})
  end

  @doc false
  # Public for testing. Builds the --append-system-prompt text for a session.
  def build_system_prompt(data) do
    parts =
      [
        "Your OrcaHub session ID is #{data.session_id}.",
        orchestrator_system_prompt(data.orchestrator, data.session_id),
        code_exec_system_prompt(OrcaHub.MCP.CodeExec.enabled?(Map.get(data, :code_exec, false))),
        if(!data.orchestrator, do: commit_trailer_prompt(data.session_id)),
        if(!data.orchestrator, do: ask_user_question_prompt()),
        sibling_sessions_prompt(data.orchestrator),
        context_files_prompt(data.directory)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n\n")
  end

  # Only non-orchestrator sessions have the AskUserQuestion tool. Headless runs
  # auto-return a placeholder/denial tool result for it, and the model tends to
  # continue as if answered — so we explicitly instruct it to stop and wait.
  defp ask_user_question_prompt do
    """
    When you use the AskUserQuestion tool to ask the user something, the \
    environment will immediately return an automatic placeholder tool result \
    (it may look like an error or a denial such as "Answer questions?"). That \
    placeholder is NOT the user's answer — do not treat it as a response and do \
    not continue based on it. After calling AskUserQuestion, stop and end your \
    turn. The user's real answer will arrive as a separate follow-up message; \
    only act on the question once the user has actually responded.\
    """
    |> String.trim()
  end

  # Teaches a code-exec session its collapsed tool surface. Only added when the
  # feature is enabled for the session (and not killed node-wide).
  defp code_exec_system_prompt(false), do: nil

  defp code_exec_system_prompt(true) do
    """
    # Code Execution Mode

    Your MCP tool list is intentionally small: `run_elixir`, `search_tools`, and \
    `read_tool`. Every other OrcaHub and upstream tool is reachable from inside \
    `run_elixir` as a named `Tools.*` function — call several tools and stitch \
    their results together with the Elixir standard library in ONE snippet \
    instead of many separate tool calls.

    - **Discover tools** with `search_tools`/`read_tool`, or from inside code \
      with `Tools.search("query")`, `Tools.list()`, and `Tools.schema("name")`. \
      `Tools.search/1` and `Tools.list/0` return `{name, description}` TUPLES — \
      match the tuple (`Enum.map(fn {name, _} -> name end)`), do NOT index with \
      `["name"]`. `Tools.schema/1` returns a map (or nil). Only tool \
      *invocations* (below) auto-unwrap to maps/lists.
    - **Call a tool** as `Tools.<raw_mcp_name>(args)`, e.g. \
      `Tools.open_file(%{"file_path" => "lib/foo.ex"})` or \
      `Tools.github__get_issue(%{"number" => 7})`. Named functions \
      **auto-unwrap** the result (text → string; JSON → decoded map/list) and \
      **raise `Tools.Error`** if the tool fails — so they compose with `|>` and \
      `Enum`:

          Tools.github__list_issues(%{"repo" => "o/r"})
          |> Enum.filter(& &1["state"] == "open")
          |> Enum.map(& &1["title"])

    - For explicit error handling use `Tools.try_call("name", args)` which \
      returns `{:ok, value} | {:error, reason}`; for the faithful raw MCP \
      envelope use `Tools.call("name", args)`.
    - The value of the last expression (and any stdout) is returned to you. \
      Keep return values slim — filter/project before returning. Pure stdlib is \
      available; OrcaHub internals, File, and System are blocked.
    """
    |> String.trim()
  end

  defp orchestrator_system_prompt(false, _session_id), do: nil
  defp orchestrator_system_prompt(nil, _session_id), do: nil

  defp orchestrator_system_prompt(true, session_id) do
    """
    # Orchestrator Session

    You are an **orchestrator session**. Your role is to coordinate work across multiple worker sessions, NOT to do the work yourself.

    ## Your Capabilities

    You have read-only access to the codebase (Read, Glob, Grep) and web access (WebFetch, WebSearch) for research. You have Write/Edit access, but you must use it **only** to maintain your own file-based memory under a `.claude` directory (e.g. the project-local `./.claude/` or your home `~/.claude/projects/<slug>/memory/`). Do NOT edit project source files, run shell commands, or make any other changes directly — delegate all implementation work to worker sessions.

    ## How to Work

    **Important:** The OrcaHub MCP tools must be called by their full namespaced name — the MCP prefix followed by the tool name, e.g. `mcp__orca__start_session` (not just `start_session`). The same applies to every tool below (`mcp__orca__send_message_to_session`, `mcp__orca__schedule_heartbeat`, `mcp__orca__search_sessions`, `mcp__orca__archive_session`, `mcp__orca__cancel_heartbeat`, etc.).

    1. **Delegate all implementation work** to other sessions using:
       - `mcp__orca__start_session` — spawn a new worker session with a detailed prompt
       - `mcp__orca__send_message_to_session` — direct an existing session

    2. **Request callbacks** — When delegating work, explicitly ask the worker session to message you back when done:
       > "When you have completed this task, use `mcp__orca__send_message_to_session` to notify session #{session_id} with a summary of what you did."

    3. **Set up monitoring** — After spawning workers, use `mcp__orca__schedule_heartbeat` to wake yourself up periodically (e.g., every 2-5 minutes) to check on progress:
       > "Check on worker sessions. Use `mcp__orca__search_sessions` to see their status. If any are idle/error, review their work. If all work is complete, cancel the heartbeat."

    4. **Check in proactively** — If you don't hear back from a worker session within a reasonable time, send it a message asking for a status update.

    5. **Archive completed children** — When a worker session has finished its task, use `mcp__orca__archive_session` to archive it. This keeps the session list tidy. If you need to continue the conversation later, just send a message to the archived session — it will be automatically unarchived.

    6. **Cancel monitoring** — When all delegated work is complete, use `mcp__orca__cancel_heartbeat` to stop monitoring.

    ## Example Flow

    1. Analyze the task and break it into subtasks
    2. Spawn worker sessions for each subtask, requesting they message back when done
    3. Set a heartbeat to check on progress
    4. When workers report back or heartbeat fires, check status
    5. If issues arise, provide guidance or spawn additional workers
    6. As each worker finishes, archive its session to keep the list clean
    7. When all work is complete, cancel heartbeat and summarize results

    Remember: You orchestrate, you don't implement. Apart from writing to your own `.claude` memory, if you find yourself wanting to edit a file or run a command, spawn a worker session instead.
    """
    |> String.trim()
  end

  # Orchestrator sessions can use `search_sessions`; regular sessions cannot,
  # so point them at the `.agents/` directory to discover sibling session IDs.
  defp sibling_sessions_prompt(true) do
    "Other agent sessions may be active in this directory. Use the `mcp__orca__search_sessions` MCP tool to discover sibling sessions you may want to coordinate with."
  end

  defp sibling_sessions_prompt(_orchestrator) do
    "Other agent sessions may be active in this directory. Check the `.agents/` directory to discover active sessions and their IDs, then use the `mcp__orca__send_message_to_session` MCP tool to coordinate with them."
  end

  defp commit_trailer_prompt(session_id) do
    """
    When making git commits, ALWAYS append this trailer to the commit message:

    OrcaHub-Session: #{session_id}

    This links the commit to your OrcaHub session. Add it as a git trailer \
    (blank line after the commit body, then the trailer line). \
    Never omit this trailer.\
    """
    |> String.trim()
  end

  defp context_files_prompt(directory) do
    context_dir = Path.join(directory, ".context")

    if File.dir?(context_dir) do
      context_dir
      |> File.ls!()
      |> Enum.filter(&(Path.extname(&1) in ~w(.md .mmd)))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        content = File.read!(Path.join(context_dir, filename))
        "## #{Path.rootname(filename)}\n\n#{content}"
      end)
      |> case do
        [] -> nil
        parts -> "# Project Context\n\n#{Enum.join(parts, "\n\n")}"
      end
    else
      nil
    end
  end

  defp send_sigint(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-INT", "#{os_pid}"])
      nil -> :noop
    end
  end

  defp persist_message(data, event) do
    db_call(data, :create_message, [%{session_id: data.session_id, data: event}])
  end

  defp stamp(event), do: Map.put(event, "timestamp", NaiveDateTime.utc_now())

  def regenerate_title(session_id) do
    messages = HubRPC.list_messages(session_id)

    first_prompt =
      Enum.find_value(messages, fn msg ->
        case msg.data do
          %{"type" => "user", "message" => %{"content" => content}} when is_list(content) ->
            Enum.find_value(content, fn
              %{"type" => "text", "text" => text} -> text
              _ -> nil
            end)

          _ ->
            nil
        end
      end)

    # Called externally (same node), so db_node is nil (use local HubRPC)
    maybe_generate_title(%{db_node: nil, session_id: session_id}, first_prompt)
  end

  defp maybe_generate_title(%{session_id: session_id}, nil) do
    Logger.warning("Skipping title generation for session #{session_id}: no first_prompt")
  end

  defp maybe_generate_title(data, prompt) do
    session_id = data.session_id

    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      try do
        case generate_title(prompt) do
          {:ok, title} ->
            Logger.info("Generated title for session #{session_id}: #{title}")
            session = db_call(data, :get_session!, [session_id])
            db_call(data, :update_session, [session, %{title: title}])
            broadcast(session_id, {:title_updated, title})

            AgentPresence.write(session.directory, session_id, %{
              title: title,
              status: session.status
            })

          {:error, reason} ->
            Logger.warning(
              "Failed to generate title for session #{session_id}: #{inspect(reason)}"
            )

            broadcast(session_id, {:title_error, reason})
        end
      rescue
        e ->
          Logger.error(
            "Title generation crashed for session #{session_id}: #{Exception.message(e)}"
          )

          broadcast(session_id, {:title_error, Exception.message(e)})
      end
    end)
  end

  defp generate_title(summary) do
    {url, headers, model, api_type} = title_api_config()
    Logger.info("Title generation using model=#{model} url=#{url} api_type=#{api_type}")

    {json_body, extract_fn} = title_request_body(model, summary, api_type)

    resp = Req.post!(url, headers: headers, json: json_body, receive_timeout: 60_000)

    Logger.info("Title API response: #{inspect(resp.body)}")

    case resp.status do
      200 ->
        title =
          extract_fn.(resp.body)
          |> String.trim()
          |> String.slice(0, 255)

        {:ok, title}

      status ->
        {:error, "Title API returned #{status}: #{inspect(resp.body)}"}
    end
  end

  defp title_request_body(model, summary, :responses) do
    json = %{
      model: model,
      input: [
        %{
          role: "developer",
          content:
            "Generate a short title (max 6 words) for this coding session. Return only the title, no quotes or punctuation."
        },
        %{role: "user", content: "Generate a title for this session. First message: #{summary}"}
      ],
      reasoning: %{effort: "minimal"}
    }

    extract_fn = fn body ->
      # Responses API: output is a list, find the message type and extract text
      outputs = body["output"] || []

      Enum.find_value(outputs, "", fn item ->
        if item["type"] == "message" do
          get_in(item, ["content", Access.at(0), "text"]) || ""
        end
      end)
    end

    {json, extract_fn}
  end

  defp title_request_body(model, summary, :chat_completions) do
    json = %{
      model: model,
      messages: [
        %{
          role: "system",
          content:
            "Generate a short title (max 6 words) for this coding session. Return only the title, no quotes or punctuation."
        },
        %{role: "user", content: summary}
      ],
      max_completion_tokens: 200
    }

    extract_fn = fn body ->
      get_in(body, ["choices", Access.at(0), "message", "content"]) || ""
    end

    {json, extract_fn}
  end

  defp title_api_config do
    dr_token = Application.get_env(:orca_hub, :datarobot_api_token)
    dr_endpoint = Application.get_env(:orca_hub, :datarobot_endpoint)
    custom_model = Application.get_env(:orca_hub, :title_model)

    if dr_token && dr_endpoint do
      Logger.info(
        "Title API: using DataRobot gateway (endpoint=#{dr_endpoint}, token=#{if dr_token, do: "set", else: "MISSING"})"
      )

      url = String.trim_trailing(dr_endpoint, "/") <> "/genai/llmgw/responses"
      headers = [{"authorization", "Bearer #{dr_token}"}]
      model = custom_model || "azure/gpt-5-nano-2025-08-07"
      {url, headers, model, :responses}
    else
      api_key = Application.get_env(:orca_hub, :openai_api_key)

      Logger.info(
        "Title API: using OpenAI directly (api_key=#{if api_key, do: "set", else: "MISSING"})"
      )

      url = "https://api.openai.com/v1/chat/completions"
      headers = [{"authorization", "Bearer #{api_key}"}]
      model = custom_model || "gpt-4.1-nano"
      {url, headers, model, :chat_completions}
    end
  end

  defp extract_non_json_lines(data, buffer) do
    combined = buffer <> data
    {complete_lines, _remainder} = combined |> String.split("\n") |> Enum.split(-1)

    complete_lines
    |> Enum.reject(fn line ->
      stripped = Regex.replace(~r/\e\[[0-9;]*m/, line, "")
      line == "" or match?({:ok, _}, Jason.decode(stripped))
    end)
    |> Enum.join("\n")
    |> then(fn
      "" -> ""
      text -> text <> "\n"
    end)
  end
end
