defmodule OrcaHubWeb.VoiceChannel do
  @moduledoc """
  The server-side owner of a voice-mode session: ASR dispatch, intent
  adjudication, the accumulated draft, the SEND arming window, and the
  actual send.

  The wire contract — topic, the binary segment frame, every client and
  server event, and the join replies — is `voice_mode_spec.md` section 8.1.
  Read it before changing anything here; slices E (browser hook) and F
  (LiveView panel) are written against the same text.

  ## Thin adapter over a pure state machine

  All of the interesting behaviour lives in `OrcaHub.Voice.Session`, which
  is pure: it takes a state and returns `{state, effects}`. This module only

    * decodes the 20-byte `"OVS1"` binary frame,
    * runs ASR calls in a `Task` so `handle_in/3` never blocks (the lane's
      warm p50 is 570-1350 ms and a cold start up to 35 s),
    * owns the two timers (the arming deadline and the short-segment hold)
      via a single idempotent `:tick` message, and
    * pushes `"state"` / `"segment_result"` / `"sent"`.

  ASR results come back as `{:asr_result, seq, result}` and are applied in
  `seq` order by the state machine, which buffers out-of-order completions.

  ## Config

  `HubRPC.resolve_asr_config/0` — ALWAYS through `HubRPC`, since an agent
  node has no DB of its own. `OrcaHub.ASRConfig` deliberately has no cache
  because TTS resolves per REQUEST; a voice session instead resolves ONCE at
  join and again on `retry_warmup`, which is the natural "I changed the
  settings, try again" gesture. A config change therefore takes effect on
  the next join or retry, not mid-utterance.

  ## Ownership

  Exactly one voice owner per session. On join the channel looks for a
  `%{voice: true}` entry in `OrcaHub.SessionViewersRegistry` and refuses
  with `voice_owned` if one exists, else registers its own. The registry is
  a `keys: :duplicate` registry that `SessionLive.Show` also registers in
  (with `%{}`), and its abandoned-session cleanup only checks for
  emptiness, so the extra entry is harmless. The claim is released
  automatically when this channel process exits.

  The registry is PER NODE: the claim covers the node that terminates the
  websocket, which is the node that served the page. Two tabs served by
  different nodes could each hold a claim; that is the same scope
  `SessionLive.Show`'s presence marker has, and a single browser's tabs
  always land on one node behind the ingress.

  ## Node routing

  The channel NEVER re-routes. It resolves the session through
  `HubRPC.get_session/1`, its node through `Cluster.runner_node_for/1`, and
  refuses the join with `node_unavailable` when that node is set but not
  connected — rather than quietly sending the draft somewhere else.
  """
  use Phoenix.Channel

  require Logger

  alias OrcaHub.{Cluster, HubRPC}
  alias OrcaHub.Voice.{ASR, Session}

  @registry OrcaHub.SessionViewersRegistry

  # Spec 8.1's binary segment frame: magic + four little-endian u32s.
  @magic "OVS1"
  @header_bytes 20

  @impl true
  def join("voice:" <> session_id, _params, socket) do
    with {:ok, session} <- fetch_session(session_id),
         {:ok, runner_node} <- resolve_node(session),
         :ok <- claim_voice(session_id) do
      config = resolve_config()
      state = Session.new(threshold: config.threshold)

      socket =
        socket
        |> assign(:session_id, session_id)
        |> assign(:runner_node, runner_node)
        |> assign(:config, config)
        |> assign(:state, state)

      send(self(), :warmup)

      {:ok, %{state: Session.snapshot(state, now())}, socket}
    else
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  # -- client -> server ------------------------------------------------------

  @impl true
  def handle_in("segment", {:binary, frame}, socket) do
    case decode_frame(frame) do
      {:ok, decoded} ->
        apply_state(socket, &Session.segment_received(&1, decoded, now()))

      {:error, detail} ->
        push(socket, "segment_result", %{
          seq: 0,
          text: "",
          intent: nil,
          score: 0.0,
          elapsed_seconds: 0.0,
          duration: 0.0,
          action: "error",
          detail: detail
        })

        {:noreply, socket}
    end
  end

  def handle_in("speech_start", _payload, socket),
    do: apply_state(socket, &Session.speech_start/1)

  def handle_in("mic", payload, socket) do
    muted = payload["muted"] == true
    apply_state(socket, &Session.mic(&1, muted))
  end

  def handle_in("send_now", _payload, socket),
    do: apply_state(socket, &Session.send_now/1)

  def handle_in("cancel", _payload, socket),
    do: apply_state(socket, &Session.cancel/1)

  def handle_in("draft_edit", payload, socket) do
    text = payload["text"]

    if is_binary(text),
      do: apply_state(socket, &Session.draft_edit(&1, text)),
      else: {:noreply, socket}
  end

  def handle_in("retry_warmup", _payload, socket) do
    # Re-resolve, so a settings change (a new URL, a longer timeout) is
    # picked up by the retry rather than needing a rejoin.
    socket = assign(socket, :config, resolve_config())
    send(self(), :warmup)
    apply_state(socket, &Session.retry_warmup/1)
  end

  def handle_in(event, _payload, socket) do
    Logger.debug("VoiceChannel: ignoring unknown event #{inspect(event)}")
    {:noreply, socket}
  end

  # -- internal messages -----------------------------------------------------

  @impl true
  def handle_info(:warmup, socket) do
    config = socket.assigns.config
    channel = self()

    Task.start(fn ->
      send(channel, {:warmup_result, guarded(fn -> ASR.warmup(config) end)})
    end)

    {:noreply, socket}
  end

  def handle_info({:warmup_result, {:ok, %{elapsed_ms: ms}}}, socket) do
    Logger.debug("VoiceChannel: ASR warm in #{ms} ms")
    apply_state(socket, &Session.warm_ok/1)
  end

  def handle_info({:warmup_result, {:error, reason}}, socket) do
    message = ASR.describe_error(reason, socket.assigns.config)
    apply_state(socket, &Session.warm_error(&1, message))
  end

  def handle_info({:asr_result, seq, result}, socket) do
    result =
      case result do
        {:ok, res} -> {:ok, res}
        {:error, reason} -> {:error, ASR.describe_error(reason, socket.assigns.config)}
      end

    apply_state(socket, &Session.transcript(&1, seq, result, now()))
  end

  def handle_info(:tick, socket), do: apply_state(socket, &Session.tick(&1, now()))

  def handle_info({:send_result, result}, socket),
    do: apply_state(socket, &Session.send_result(&1, result))

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- effects ---------------------------------------------------------------

  # Runs one pure transition and then performs its effects. Every transition
  # ends with a full `"state"` push — the contract says the snapshot goes out
  # after every change, and a snapshot is cheap.
  defp apply_state(socket, fun) do
    {state, effects} = fun.(socket.assigns.state)
    socket = assign(socket, :state, state)
    socket = Enum.reduce(effects, socket, &run_effect/2)
    push(socket, "state", Session.snapshot(socket.assigns.state, now()))
    {:noreply, socket}
  end

  defp run_effect({:segment_result, result}, socket) do
    push(socket, "segment_result", result)
    socket
  end

  defp run_effect({:dispatch, seq, pcm}, socket) do
    config = socket.assigns.config
    channel = self()

    Task.start(fn ->
      send(channel, {:asr_result, seq, guarded(fn -> ASR.transcribe(pcm, config) end)})
    end)

    socket
  end

  defp run_effect({:schedule_tick, ms}, socket) do
    Process.send_after(self(), :tick, ms)
    socket
  end

  defp run_effect({:sent, text}, socket) do
    push(socket, "sent", %{text: text})
    socket
  end

  defp run_effect({:send, text}, socket) do
    %{runner_node: runner_node, session_id: session_id} = socket.assigns
    channel = self()
    sender = sender()

    Task.start(fn ->
      send(channel, {:send_result, sender.(runner_node, session_id, text, :queue)})
    end)

    socket
  end

  # `ASR` promises never to raise on a network or HTTP problem, but a task
  # that dies anyway would leave its seq in `awaiting` forever and wedge
  # `pending` at a non-zero count — so an unexpected exception becomes an
  # ordinary error result instead.
  defp guarded(fun) do
    fun.()
  rescue
    error -> {:error, {:transport, error}}
  catch
    :exit, reason -> {:error, {:transport, {:exit, reason}}}
  end

  # The delivery function, injectable so a test can observe the send without
  # standing up a real runner: `config :orca_hub, :voice_sender, fun/4`.
  # Defaults to the real cross-node delivery, which is ALWAYS `:queue` —
  # a spoken send must not cancel an in-flight turn (spec section 8).
  defp sender, do: Application.get_env(:orca_hub, :voice_sender, &Cluster.send_message/4)

  # -- join helpers ----------------------------------------------------------

  defp fetch_session(session_id) do
    case HubRPC.get_session(session_id) do
      %{archived_at: nil} = session ->
        {:ok, session}

      %{archived_at: _} ->
        {:error, :archived}

      nil ->
        {:error, :not_found}

      other ->
        Logger.warning("VoiceChannel: unexpected session lookup result: #{inspect(other)}")
        {:error, :not_found}
    end
  rescue
    error ->
      Logger.warning("VoiceChannel: session lookup failed: #{inspect(error)}")
      {:error, :not_found}
  end

  defp resolve_node(session) do
    case Cluster.runner_node_for(session) do
      nil ->
        {:ok, nil}

      runner_node ->
        if Cluster.node_available?(runner_node),
          do: {:ok, runner_node},
          else: {:error, :node_unavailable}
    end
  end

  # The claim and the check are not atomic, but the registry is per node and
  # two joins for the same session in the same millisecond would have to come
  # from the same browser; the cost of losing that race is two capturing
  # tabs, not corruption.
  defp claim_voice(session_id) do
    owned? =
      @registry
      |> Registry.lookup(session_id)
      |> Enum.any?(fn {_pid, value} -> is_map(value) and Map.get(value, :voice) == true end)

    if owned? do
      {:error, :voice_owned}
    else
      {:ok, _} = Registry.register(@registry, session_id, %{voice: true})
      :ok
    end
  end

  defp resolve_config, do: HubRPC.resolve_asr_config()

  # -- frame decoding --------------------------------------------------------

  defp decode_frame(
         <<@magic, seq::little-32, start_sample::little-32, sample_count::little-32,
           flags::little-32, pcm::binary>>
       ) do
    if byte_size(pcm) == sample_count * 2 do
      {:ok,
       %{
         seq: seq,
         start_sample: start_sample,
         sample_count: sample_count,
         flags: flags,
         pcm: pcm
       }}
    else
      {:error,
       "segment frame length mismatch: header claims #{sample_count} samples " <>
         "(#{sample_count * 2} bytes), got #{byte_size(pcm)}"}
    end
  end

  defp decode_frame(frame) when is_binary(frame) and byte_size(frame) < @header_bytes,
    do: {:error, "segment frame truncated: #{byte_size(frame)} bytes, need at least 20"}

  defp decode_frame(_frame), do: {:error, "segment frame has a bad magic (expected OVS1)"}

  defp now, do: System.monotonic_time(:millisecond)
end
