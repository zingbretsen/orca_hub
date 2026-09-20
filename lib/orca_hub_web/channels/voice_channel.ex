defmodule OrcaHubWeb.VoiceChannel do
  @moduledoc """
  The server-side owner of a voice-mode session: ASR dispatch, intent
  adjudication, the accumulated draft, the SEND arming window, and the
  actual send.

  The wire contract — topic, the binary segment frame, every client and
  server event, and the join replies — is `voice_mode_spec.md` section 8.1,
  amended by section 8.2 (the global voice bar and the single send path) and
  section 8.3 (focus, the phase 2c intent classes and `ui_action`). Read all
  three before changing anything here; the browser hook
  (`assets/js/voice/`) and `OrcaHubWeb.VoiceBarLive` are written against the
  same text.

  ## Focus and UI actions (spec 8.3)

  Two events carry phase 2c: the client pushes `"ui_focus"` (`composer` vs
  `palette`, plus the visible candidate labels) and this channel pushes
  `"ui_action"` (`open_palette`, `close_palette`, `palette_query`, `select`,
  `navigate`, `back`, `open_help`). The routing decision is entirely
  `OrcaHub.Voice.Session`'s; this module only relays.

  ## Sending (spec 8.2, ORCAHUB3-86)

  This channel does NOT normally deliver the draft any more. On arming
  expiry (or `send_now`) it pushes `"send_request"` and waits for the
  browser to run the text through the page's real composer form, which is
  what consumes staged uploads and appends the attachment lines. The client
  answers with `sent_ack`, `send_failed` or `send_direct`; `send_direct` and
  the 5 s no-composer fallback are the only paths that still reach
  `Cluster.send_message(..., :queue)` here. See `OrcaHub.Voice.Session`.

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

  The join reply also carries `audio_constraints` — the three
  `getUserMedia` capture constraints (ORCAHUB3-105), camelCased for the Web
  Audio API — which the browser spreads into the constraint object it opens
  the microphone with. Those are the ONE field group whose change does NOT
  land on the next utterance: the browser reads them when it ARMS, so a
  change needs voice off and on again. Resolved values are logged at `:info`
  on every join.

  Alongside them the reply carries `release_mic_during_playback`
  (ORCAHUB3-105, default FALSE) — whether the browser STOPS the capture
  track while TTS plays instead of merely muting the VAD. A third timing
  again: it is read at each `orca:tts-state {playing: true}` edge from
  whatever the last join reply carried, so a change lands on the next JOIN
  (voice off/on, a retarget, or a socket rejoin) rather than on the next arm
  or the next utterance.

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

      constraints = capture_constraints(config)

      # ORCAHUB3-105: one info line per join, so a report about inaudible
      # audio can say what the microphone was ACTUALLY opened with instead of
      # what we assume the defaults are. The browser logs the same set (plus
      # what the track reports back) at `Capture.open`.
      Logger.info(
        "VoiceChannel: capture constraints for #{session_id}: #{inspect(constraints)} " <>
          "(applied on the browser's next arm), release_mic_during_playback=" <>
          "#{config.release_mic_during_playback}"
      )

      {:ok,
       %{
         state: Session.snapshot(state, now()),
         audio_constraints: constraints,
         release_mic_during_playback: config.release_mic_during_playback
       }, socket}
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
    do: apply_state(socket, &Session.send_now(&1, now()))

  def handle_in("cancel", _payload, socket),
    do: apply_state(socket, &Session.cancel/1)

  # §8.3.11 (ORCAHUB3-99): the page's own composer delivered the draft (a
  # TYPED send). Clears exactly what `cancel` clears and records NO undo —
  # the text is in the session, and a restore affordance for it would be an
  # invitation to send it twice.
  def handle_in("draft_delivered", _payload, socket),
    do: apply_state(socket, &Session.draft_delivered/1)

  # §8.3.11 (ORCAHUB3-99): put back the draft the last cancel threw away.
  # The client normally restores its OWN copy through `draft_edit` — the
  # sink can hold characters this side never saw — and falls back to this
  # when it has none (a rejoin, a second tab, the bar's own box).
  def handle_in("restore_draft", _payload, socket),
    do: apply_state(socket, &Session.restore/1)

  # -- spec 8.3, focus ------------------------------------------------------

  # What the user is looking at, plus the labels of whichever selectable list
  # is visible. The CLIENT owns this; the server never infers it, not even
  # from an `open_palette` it just emitted. `Session.ui_focus/3` normalises
  # whatever arrives, so a malformed payload degrades to composer focus with
  # no candidates rather than being dropped on the floor.
  def handle_in("ui_focus", payload, socket),
    do: apply_state(socket, &Session.ui_focus(&1, payload["focus"], payload["candidates"]))

  # -- spec 8.2, the single send path ----------------------------------------

  def handle_in("composer", payload, socket),
    do: apply_state(socket, &Session.composer(&1, payload["present"] == true))

  def handle_in("sent_ack", _payload, socket),
    do: apply_state(socket, &Session.sent_ack/1)

  def handle_in("send_failed", payload, socket) do
    reason =
      case payload["reason"] do
        reason when is_binary(reason) and reason != "" -> reason
        _ -> "The composer could not send that message."
      end

    apply_state(socket, &Session.send_failed(&1, reason))
  end

  def handle_in("send_direct", _payload, socket),
    do: apply_state(socket, &Session.send_direct/1)

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

  # §8.3.11 (ORCAHUB3-99): a cancel actually threw a draft away. The client
  # needs this as its OWN event rather than inferring it from a
  # `segment_result` — the armed spoken cancel clears 1500 ms after that
  # result, a palette-focus cancel emits the same result and clears nothing,
  # and the hook's sink-clear has to follow the clear, not the guess.
  #
  # `text` is the server's copy. The client keeps its own (the sink may hold
  # characters a debounced `draft_edit` had not delivered yet) and prefers
  # it when restoring.
  defp run_effect({:cancelled, text}, socket) do
    push(socket, "cancelled", %{text: text})
    socket
  end

  # Spec §8.3.5. The palette, the autocomplete dropdown and live navigation
  # all live in the browser — there is nothing to do here but say WHAT
  # happened and let the hook drive the DOM (never `window.location`, which
  # would reload the page out from under the bar, the mic and this channel).
  defp run_effect({:ui_action, kind, payload}, socket) do
    push(socket, "ui_action", %{kind: kind, payload: payload})
    socket
  end

  # Spec 8.2: the send goes out through the CLIENT's composer form, so that
  # staged uploads are consumed and the `[Attached image: …]` lines ride
  # along (ORCAHUB3-86). The answer comes back as `sent_ack` / `send_failed`
  # / `send_direct`, or as the 5 s deadline in `Session.tick/2`.
  defp run_effect({:send_request, text}, socket) do
    push(socket, "send_request", %{text: text})
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

  # A pure reshape of the config we already have — no Repo, so it needs no
  # HubRPC hop even on an agent node.
  defp capture_constraints(config), do: OrcaHub.ASRConfig.capture_constraints(config)

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
