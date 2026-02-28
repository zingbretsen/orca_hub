defmodule OrcaHub.SessionRunner do
  use GenServer
  require Logger

  alias ExOrca.{Config, StreamParser}
  alias OrcaHub.Sessions

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def via(session_id), do: {:via, Registry, {OrcaHub.SessionRegistry, session_id}}

  def send_message(session_id, prompt) do
    GenServer.call(via(session_id), {:send_message, prompt})
  end

  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  end

  def interrupt(session_id) do
    GenServer.call(via(session_id), :interrupt)
  end

  # Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    session = Sessions.get_session!(session_id)
    saved_messages = Sessions.list_messages(session_id) |> Enum.map(& &1.data)

    {:ok,
     %{
       session_id: session_id,
       claude_session_id: session.claude_session_id,
       directory: session.directory,
       model: session.model,
       port: nil,
       buffer: "",
       status: :idle,
       messages: saved_messages,
       first_prompt: nil
     }}
  end

  @impl true
  def handle_call({:send_message, _prompt}, _from, %{status: :running} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, prompt}, _from, state) do
    user_event = %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => prompt}]}
    }

    persist_message(state.session_id, user_event)
    broadcast(state.session_id, {:event, user_event})

    port = open_port(prompt, state)
    broadcast(state.session_id, {:status, :running})
    Sessions.update_session(Sessions.get_session!(state.session_id), %{status: "running"})
    first_prompt = state.first_prompt || prompt
    {:reply, :ok, %{state | port: port, status: :running, buffer: "", messages: state.messages ++ [user_event], first_prompt: first_prompt}}
  end

  def handle_call(:interrupt, _from, %{status: :running, port: port} = state) when not is_nil(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-INT", "#{os_pid}"])
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, Map.take(state, [:status, :messages, :claude_session_id]), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {events, new_buffer} = StreamParser.parse(data, state.buffer)

    new_state =
      Enum.reduce(events, %{state | buffer: new_buffer}, fn event, acc ->
        handle_event(event, acc)
      end)

    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.info("Claude CLI exited (code #{code}) for session #{state.session_id}")
    new_status = if code == 0, do: :idle, else: :error
    session = Sessions.get_session!(state.session_id)
    Sessions.update_session(session, %{status: to_string(new_status)})
    broadcast(state.session_id, {:status, new_status})

    if code == 0 && (session.title == nil || session.title == "") do
      Logger.info("Attempting title generation for session #{state.session_id}, first_prompt: #{inspect(state.first_prompt)}")
      maybe_generate_title(state.session_id, state.first_prompt)
    end

    {:noreply, %{state | port: nil, status: new_status}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp open_port(prompt, state) do
    claude_path = System.find_executable("claude")
    script_path = System.find_executable("script")

    opts =
      [cwd: state.directory]
      |> maybe_put(:session_id, state.claude_session_id)
      |> maybe_put(:model, state.model)

    {args, port_opts} = Config.build_args(prompt, opts)
    cmd = Enum.map_join([claude_path | args], " ", &shell_escape/1)

    Port.open(
      {:spawn_executable, script_path},
      [:binary, :exit_status, :stderr_to_stdout,
       {:args, ["-qc", cmd, "/dev/null"]}] ++ port_opts
    )
  end

  defp handle_event(%{"type" => "system", "session_id" => sid} = event, state) do
    if state.claude_session_id == nil do
      Sessions.update_session(Sessions.get_session!(state.session_id), %{claude_session_id: sid})
    end

    persist_message(state.session_id, event)
    broadcast(state.session_id, {:event, event})
    %{state | claude_session_id: sid, messages: state.messages ++ [event]}
  end

  defp handle_event(event, state) do
    persist_message(state.session_id, event)
    broadcast(state.session_id, {:event, event})
    %{state | messages: state.messages ++ [event]}
  end

  defp broadcast(session_id, payload) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", payload)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp persist_message(session_id, event) do
    Sessions.create_message(%{session_id: session_id, data: event})
  end

  defp maybe_generate_title(session_id, nil) do
    Logger.warning("Skipping title generation for session #{session_id}: no first_prompt")
  end

  defp maybe_generate_title(session_id, prompt) do
    Task.start(fn ->
      try do
        case generate_title(prompt) do
          {:ok, title} ->
            Logger.info("Generated title for session #{session_id}: #{title}")
            session = Sessions.get_session!(session_id)
            Sessions.update_session(session, %{title: title})
            broadcast(session_id, {:title_updated, title})

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
    api_key = Application.get_env(:orca_hub, :openai_api_key)

    resp =
      Req.post!("https://api.openai.com/v1/chat/completions",
        headers: [{"authorization", "Bearer #{api_key}"}],
        json: %{
          model: "gpt-4.1-nano",
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

    Logger.info("OpenAI response: #{inspect(resp.body)}")

    case resp.status do
      200 ->
        title = get_in(resp.body, ["choices", Access.at(0), "message", "content"])
        {:ok, String.trim(title || "")}

      status ->
        {:error, "OpenAI returned #{status}: #{inspect(resp.body)}"}
    end
  end

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
end
