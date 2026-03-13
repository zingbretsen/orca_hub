defmodule OrcaHub.SessionRunner do
  use GenStatem
  require Logger

  alias OrcaHub.Claude.{Config, StreamParser}
  alias OrcaHub.{AgentPresence, Feedback, Sessions}

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

  def notify_feedback_requested(session_id) do
    GenStatem.cast(via(session_id), :feedback_requested)
  end

  def notify_feedback_answered(session_id) do
    GenStatem.cast(via(session_id), :feedback_answered)
  end

  # Callbacks

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    session = Sessions.get_session!(session_id)

    saved_messages =
      Sessions.list_messages(session_id)
      |> Enum.map(fn msg -> Map.put(msg.data, "timestamp", msg.inserted_at) end)

    initial_state = if saved_messages == [], do: :ready, else: :idle

    AgentPresence.write(session.directory, session_id, %{
      title: session.title,
      status: to_string(initial_state)
    })

    data = %{
      session_id: session_id,
      claude_session_id: session.claude_session_id,
      directory: session.directory,
      model: session.model,
      port: nil,
      buffer: "",
      error_output: "",
      issue_id: session.issue_id,
      messages: saved_messages,
      first_prompt: nil,
      pending_prompts: []
    }

    {:ok, initial_state, data}
  end

  # ── :ready state ─────────────────────────────────────────────────────
  # Session has been created but no messages have been sent yet.

  def ready({:call, from}, {:send_message, prompt}, data) do
    start_running(from, prompt, data)
  end

  def ready({:call, from}, :interrupt, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def ready({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:ready, data)}]}
  end

  def ready(:cast, _msg, _data), do: :keep_state_and_data
  def ready(:info, _msg, _data), do: :keep_state_and_data

  # ── :idle state ──────────────────────────────────────────────────────
  # Session has completed at least one run and is waiting for the next message.

  def idle({:call, from}, {:send_message, prompt}, data) do
    start_running(from, prompt, data)
  end

  def idle({:call, from}, :interrupt, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def idle({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:idle, data)}]}
  end

  def idle(:cast, _msg, _data), do: :keep_state_and_data
  def idle(:info, _msg, _data), do: :keep_state_and_data

  # ── :running state ──────────────────────────────────────────────────

  def running({:call, from}, {:send_message, prompt}, %{port: port} = data) when not is_nil(port) do
    user_event = make_user_event(prompt)
    persist_message(data.session_id, user_event)
    broadcast(data.session_id, {:event, user_event})

    # Interrupt the running CLI — SIGINT lets it finish in-progress tool calls gracefully
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-INT", "#{os_pid}"])

    {:keep_state,
     %{data |
       pending_prompts: data.pending_prompts ++ [prompt],
       messages: data.messages ++ [user_event]
     },
     [{:reply, from, :ok}]}
  end

  def running({:call, from}, :interrupt, %{port: port}) when not is_nil(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-INT", "#{os_pid}"])
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def running({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:running, data)}]}
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
      Enum.reduce(events, %{data | buffer: new_buffer, error_output: error_output}, fn event, acc ->
        handle_stream_event(event, acc)
      end)

    {:keep_state, new_data}
  end

  def running(:info, {port, {:exit_status, code}}, %{port: port} = data) do
    Logger.info("Claude CLI exited (code #{code}) for session #{data.session_id}")

    case data.pending_prompts do
      [_ | _] = prompts ->
        # Auto-resume with queued prompts bundled into a single message
        combined_prompt = Enum.join(prompts, "\n\n\n")
        Logger.info("Auto-resuming session #{data.session_id} with #{length(prompts)} pending prompt(s)")
        new_port = open_port(combined_prompt, data)
        {:keep_state, %{data | port: new_port, buffer: "", error_output: "", pending_prompts: []}}

      [] ->
        new_status = if code == 0, do: :idle, else: :error
        data = handle_cli_error(code, data)

        session = Sessions.get_session!(data.session_id)
        Sessions.update_session(session, %{status: to_string(new_status)})
        broadcast(data.session_id, {:status, new_status})
        AgentPresence.update_status(data.directory, data.session_id, to_string(new_status))

        if code == 0 && (session.title == nil || session.title == "") do
          Logger.info("Attempting title generation for session #{data.session_id}, first_prompt: #{inspect(data.first_prompt)}")
          maybe_generate_title(data.session_id, data.first_prompt)
        end

        {:next_state, new_status, %{data | port: nil}}
    end
  end

  def running(:cast, :feedback_requested, data) do
    Sessions.update_session(Sessions.get_session!(data.session_id), %{status: "waiting"})
    broadcast(data.session_id, {:status, :waiting})
    AgentPresence.update_status(data.directory, data.session_id, "waiting")
    {:next_state, :waiting, data}
  end

  def running(:info, _msg, _data), do: :keep_state_and_data

  # ── :waiting state ───────────────────────────────────────────────────
  # Agent has asked a question via get_human_feedback. The port may still
  # be open (agent keeps working) or may have already exited.

  def waiting({:call, from}, {:send_message, prompt}, %{port: port} = data) when not is_nil(port) do
    user_event = make_user_event(prompt)
    persist_message(data.session_id, user_event)
    broadcast(data.session_id, {:event, user_event})

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-INT", "#{os_pid}"])

    Sessions.update_session(Sessions.get_session!(data.session_id), %{status: "running"})
    broadcast(data.session_id, {:status, :running})
    AgentPresence.update_status(data.directory, data.session_id, "running")

    {:next_state, :running,
     %{data |
       pending_prompts: data.pending_prompts ++ [prompt],
       messages: data.messages ++ [user_event]
     },
     [{:reply, from, :ok}]}
  end

  def waiting({:call, from}, {:send_message, prompt}, data) do
    start_running(from, prompt, data)
  end

  def waiting({:call, from}, :interrupt, %{port: port}) when not is_nil(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-INT", "#{os_pid}"])
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def waiting({:call, from}, :interrupt, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def waiting({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:waiting, data)}]}
  end

  def waiting(:info, {port, {:data, raw}}, %{port: port} = data) do
    {events, new_buffer} = StreamParser.parse(raw, data.buffer)
    error_lines = extract_non_json_lines(raw, data.buffer)

    error_output =
      if error_lines != "" do
        data.error_output <> error_lines
      else
        data.error_output
      end

    new_data =
      Enum.reduce(events, %{data | buffer: new_buffer, error_output: error_output}, fn event, acc ->
        handle_stream_event(event, acc)
      end)

    {:keep_state, new_data}
  end

  def waiting(:info, {port, {:exit_status, code}}, %{port: port} = data) do
    Logger.info("Claude CLI exited (code #{code}) for session #{data.session_id} (waiting for feedback)")

    case data.pending_prompts do
      [_ | _] = prompts ->
        combined_prompt = Enum.join(prompts, "\n\n\n")
        Logger.info("Auto-resuming session #{data.session_id} with #{length(prompts)} pending prompt(s)")
        new_port = open_port(combined_prompt, data)
        {:keep_state, %{data | port: new_port, buffer: "", error_output: "", pending_prompts: []}}

      [] ->
        # CLI finished but question is still pending — stay in :waiting with port: nil
        data = handle_cli_error(code, data)

        session = Sessions.get_session!(data.session_id)

        if code == 0 && (session.title == nil || session.title == "") do
          maybe_generate_title(data.session_id, data.first_prompt)
        end

        {:keep_state, %{data | port: nil}}
    end
  end

  def waiting(:cast, :feedback_answered, data) do
    case Feedback.list_pending_requests_for_session(data.session_id) do
      [_ | _] ->
        # More questions pending — stay in :waiting
        :keep_state_and_data

      [] when data.port != nil ->
        # All answered, agent still running — back to :running
        Sessions.update_session(Sessions.get_session!(data.session_id), %{status: "running"})
        broadcast(data.session_id, {:status, :running})
        AgentPresence.update_status(data.directory, data.session_id, "running")
        {:next_state, :running, data}

      [] ->
        # All answered, agent finished — go to :idle
        Sessions.update_session(Sessions.get_session!(data.session_id), %{status: "idle"})
        broadcast(data.session_id, {:status, :idle})
        AgentPresence.update_status(data.directory, data.session_id, "idle")
        {:next_state, :idle, data}
    end
  end

  def waiting(:cast, :feedback_requested, _data), do: :keep_state_and_data

  def waiting(:info, _msg, _data), do: :keep_state_and_data

  # ── :error state ─────────────────────────────────────────────────────
  # Same as idle — accepts new messages to retry, rejects interrupts.

  def error({:call, from}, {:send_message, prompt}, data) do
    start_running(from, prompt, data)
  end

  def error({:call, from}, :interrupt, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def error({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, state_snapshot(:error, data)}]}
  end

  def error(:cast, _msg, _data), do: :keep_state_and_data
  def error(:info, _msg, _data), do: :keep_state_and_data

  # ── Terminate ────────────────────────────────────────────────────────

  @impl true
  def terminate(_reason, _state, data) do
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

      persist_message(data.session_id, error_event)
      broadcast(data.session_id, {:event, error_event})
      %{data | messages: data.messages ++ [error_event]}
    else
      data
    end
  end

  defp handle_cli_error(_code, data), do: data

  defp start_running(from, prompt, data) do
    user_event = make_user_event(prompt)
    persist_message(data.session_id, user_event)
    broadcast(data.session_id, {:event, user_event})

    port = open_port(prompt, data)
    session = Sessions.get_session!(data.session_id)
    if session.archived_at, do: Sessions.unarchive_session(session)
    Sessions.update_session(session, %{status: "running"})
    broadcast(data.session_id, {:status, :running})
    AgentPresence.update_status(data.directory, data.session_id, "running")

    first_prompt = data.first_prompt || prompt

    {:next_state, :running,
     %{data | port: port, buffer: "", error_output: "", messages: data.messages ++ [user_event], first_prompt: first_prompt},
     [{:reply, from, :ok}]}
  end

  defp make_user_event(prompt) do
    stamp(%{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => prompt}]}
    })
  end

  defp state_snapshot(status, data) do
    %{status: status, messages: data.messages, claude_session_id: data.claude_session_id}
  end

  defp open_port(prompt, data) do
    claude_path = System.find_executable("claude")
    script_path = System.find_executable("script")

    opts =
      [cwd: data.directory]
      |> maybe_put(:session_id, data.claude_session_id)
      |> maybe_put(:model, data.model)
      |> maybe_put(:system_prompt, build_system_prompt(data))
      |> Keyword.put(:mcp_config, mcp_config(data.session_id))

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
      [:binary, :exit_status, :stderr_to_stdout,
       {:args, script_args}] ++ port_opts
    )
  end

  defp handle_stream_event(%{"type" => "system", "subtype" => "status", "status" => "compacting"}, data) do
    Sessions.update_session(Sessions.get_session!(data.session_id), %{status: "compacting"})
    broadcast(data.session_id, {:status, :compacting})
    AgentPresence.update_status(data.directory, data.session_id, "compacting")
    data
  end

  defp handle_stream_event(%{"type" => "system", "subtype" => "status", "status" => nil}, data) do
    # Status cleared (e.g. compacting finished) — restore running state
    Sessions.update_session(Sessions.get_session!(data.session_id), %{status: "running"})
    broadcast(data.session_id, {:status, :running})
    AgentPresence.update_status(data.directory, data.session_id, "running")
    data
  end

  defp handle_stream_event(%{"type" => "system", "session_id" => sid} = event, data) do
    if data.claude_session_id == nil do
      Sessions.update_session(Sessions.get_session!(data.session_id), %{claude_session_id: sid})
    end

    event = stamp(event)
    persist_message(data.session_id, event)
    broadcast(data.session_id, {:event, event})
    %{data | claude_session_id: sid, messages: data.messages ++ [event]}
  end

  defp handle_stream_event(event, data) do
    event = stamp(event)
    persist_message(data.session_id, event)
    broadcast(data.session_id, {:event, event})
    %{data | messages: data.messages ++ [event]}
  end

  defp broadcast(session_id, payload) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", payload)
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session_id, payload})
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp mcp_config(session_id) do
    port =
      case OrcaHubWeb.Endpoint.config(:http) do
        config when is_list(config) -> Keyword.get(config, :port, 4000)
        _ -> 4000
      end

    Jason.encode!(%{
      "mcpServers" => %{
        "orca" => %{
          "type" => "http",
          "url" => "http://localhost:#{port}/mcp?orca_session_id=#{session_id}"
        }
      }
    })
  end

  defp build_system_prompt(data) do
    parts =
      [
        "Your OrcaHub session ID is #{data.session_id}.",
        commit_trailer_prompt(data.session_id),
        issue_system_prompt(data.issue_id),
        siblings_system_prompt(data.directory, data.session_id),
        context_files_prompt(data.directory)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n\n")
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

  defp issue_system_prompt(nil), do: nil

  defp issue_system_prompt(issue_id) do
    """
    You are working on OrcaHub issue #{issue_id}.

    You have MCP tools to interact with this issue:
    - `get_issue`: Read the issue's current state including previous approaches and notes
    - `update_issue`: Append to the issue's approaches_tried and notes fields

    Before starting work, call `get_issue` with issue_id "#{issue_id}" to see what previous sessions have tried.

    When you make progress or finish, call `update_issue` to record what you attempted and your findings. This is append-only — never try to rewrite or remove previous entries. Only add information about your own approach and results.
    """
    |> String.trim()
  end

  defp siblings_system_prompt(directory, session_id) do
    case AgentPresence.list_siblings(directory, session_id) do
      [] ->
        nil

      siblings ->
        sibling_lines =
          Enum.map(siblings, fn {id, content} ->
            status = extract_field(content, "Status") || "unknown"
            task = extract_field(content, "Task") || "unknown"
            "- Session #{id} (#{status}): #{task}"
          end)
          |> Enum.join("\n")

        """
        Other active agent sessions in this directory:
        #{sibling_lines}

        You can send a message to another session using the `send_message_to_session` MCP tool.
        Check the .agents/ directory for updated session statuses.
        """
        |> String.trim()
    end
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

  defp extract_field(content, field) do
    case Regex.run(~r/\*\*#{field}:\*\* (.+)/, content) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp persist_message(session_id, event) do
    Sessions.create_message(%{session_id: session_id, data: event})
  end

  defp stamp(event), do: Map.put(event, "timestamp", NaiveDateTime.utc_now())

  defp maybe_generate_title(session_id, nil) do
    Logger.warning("Skipping title generation for session #{session_id}: no first_prompt")
  end

  defp maybe_generate_title(session_id, prompt) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      try do
        case generate_title(prompt) do
          {:ok, title} ->
            Logger.info("Generated title for session #{session_id}: #{title}")
            session = Sessions.get_session!(session_id)
            Sessions.update_session(session, %{title: title})
            broadcast(session_id, {:title_updated, title})
            AgentPresence.write(session.directory, session_id, %{title: title, status: session.status})

          {:error, reason} ->
            Logger.warning("Failed to generate title for session #{session_id}: #{inspect(reason)}")
            broadcast(session_id, {:title_error, reason})
        end
      rescue
        e ->
          Logger.error("Title generation crashed for session #{session_id}: #{Exception.message(e)}")
          broadcast(session_id, {:title_error, Exception.message(e)})
      end
    end)
  end

  defp generate_title(summary) do
    {url, headers, model} = title_api_config()
    Logger.info("Title generation using model=#{model} url=#{url}")

    resp =
      Req.post!(url,
        headers: headers,
        json: %{
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
      )

    Logger.info("Title API response: #{inspect(resp.body)}")

    case resp.status do
      200 ->
        title = get_in(resp.body, ["choices", Access.at(0), "message", "content"])
        {:ok, String.trim(title || "")}

      status ->
        {:error, "Title API returned #{status}: #{inspect(resp.body)}"}
    end
  end

  defp title_api_config do
    dr_token = Application.get_env(:orca_hub, :datarobot_api_token)
    dr_endpoint = Application.get_env(:orca_hub, :datarobot_endpoint)
    custom_model = Application.get_env(:orca_hub, :title_model)

    if dr_token && dr_endpoint do
      Logger.info("Title API: using DataRobot gateway (endpoint=#{dr_endpoint}, token=#{if dr_token, do: "set", else: "MISSING"})")
      url = String.trim_trailing(dr_endpoint, "/") <> "/genai/llmgw/chat/completions"
      headers = [{"authorization", "Bearer #{dr_token}"}]
      model = custom_model || "azure/gpt-4o-mini"
      {url, headers, model}
    else
      api_key = Application.get_env(:orca_hub, :openai_api_key)
      Logger.info("Title API: using OpenAI directly (api_key=#{if api_key, do: "set", else: "MISSING"})")
      url = "https://api.openai.com/v1/chat/completions"
      headers = [{"authorization", "Bearer #{api_key}"}]
      model = custom_model || "gpt-4.1-nano"
      {url, headers, model}
    end
  end

  defp extract_non_json_lines(data, buffer) do
    combined = buffer <> data
    {complete_lines, _remainder} = combined |> String.split("\n") |> Enum.split(-1)

    complete_lines
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(fn line ->
      stripped = Regex.replace(~r/\e\[[0-9;]*m/, line, "")
      match?({:ok, _}, Jason.decode(stripped))
    end)
    |> Enum.join("\n")
    |> then(fn
      "" -> ""
      text -> text <> "\n"
    end)
  end
end
