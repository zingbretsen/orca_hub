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
       messages: saved_messages
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
    {:reply, :ok, %{state | port: port, status: :running, buffer: "", messages: state.messages ++ [user_event]}}
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
    Sessions.update_session(Sessions.get_session!(state.session_id), %{status: to_string(new_status)})
    broadcast(state.session_id, {:status, new_status})
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

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
end
