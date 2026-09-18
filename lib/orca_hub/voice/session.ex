defmodule OrcaHub.Voice.Session do
  @moduledoc """
  The PURE state machine behind `OrcaHubWeb.VoiceChannel` — draft
  accumulation, the SEND arming window, short-segment hold/merge, and ASR
  result ordering.

  The normative behaviour is `voice_mode_spec.md` section 8.1 ("VoiceChannel
  wire contract"); read it before changing anything here.

  Nothing in this module opens a socket, spawns a task, starts a timer or
  makes an HTTP call. Every function takes a state and returns
  `{state, effects}`, where `effects` is a list the CHANNEL executes:

    * `{:dispatch, seq, pcm}` — post this PCM to ASR (in a task), then feed
      the answer back through `transcript/4` under the same `seq`
    * `{:segment_result, map}` — push one `"segment_result"` event
    * `{:send_request, text}` — push one `"send_request"` event and let the
      CLIENT deliver it through the page's composer (spec §8.2, the single
      send path); the answer comes back as `sent_ack/1`, `send_failed/2` or
      `send_direct/1`
    * `{:send, text}` — hand `text` to `Cluster.send_message(..., :queue)`,
      then feed the answer back through `send_result/2`
    * `{:sent, text}` — push one `"sent"` event; the draft is already cleared
    * `{:schedule_tick, ms}` — call `tick/2` no later than `ms` from now

  `tick/2` is IDEMPOTENT and deadline-driven: it fires whatever deadlines
  have actually passed, so a duplicated or late `{:schedule_tick, _}` costs
  nothing and a lost one only delays. All times are MONOTONIC milliseconds
  supplied by the caller (`System.monotonic_time(:millisecond)`), which is
  what makes every timing rule here testable without sleeping.

  ## The state machine

  A segment arrives (`segment_received/3`) and is, in order:

    1. dropped as `dropped_muted` if the client's mic is muted;
    2. refused as `error` if it is over the lane's 20 s cap;
    3. HELD for up to 1500 ms if it is under the ~0.8 s ASR floor (spec
       3.2) — the next segment is CONCATENATED onto it and the merged clip
       dispatched; if nothing arrives, a client-PADDED segment (frame flag
       bit1) is dispatched anyway and an unpadded one is `dropped_short`;
    4. otherwise dispatched.

  Results are applied in DISPATCH order: `awaiting` is the ordered list of
  dispatched segments and out-of-order completions sit in `buffered` until
  their turn. A merge consumes two seqs and produces ONE entry, which is why
  the ordering is an explicit list rather than a counter.

  An applied transcript is classified by `OrcaHub.Voice.Intent`: no command
  appends to the draft, `:send` strips the command and opens the 1500 ms
  arming window, `:cancel` clears everything, `:stop`/`:pause` strip and
  append but do nothing else (phase 3 owns them). The arming window is
  cancelled by speech onset, an explicit cancel, a manual draft edit, and by
  any segment that appends text. It is never OPENED at all when speech
  resumed between the command segment's receipt and its transcript landing
  (`armable?/2`), which is the ~0.6-1.1 s window the `speech_start` cancel
  cannot see.

  `pending` in the snapshot counts segments that are dispatched-but-unapplied
  PLUS a held one — i.e. everything on its way to ASR that the user has not
  seen a result for yet.

  ## The single send path (spec §8.2, ORCAHUB3-86)

  A send is no longer delivered by this side of the wire. When the arming
  window expires (or `send_now/1` fires) the state machine emits
  `{:send_request, text}` and parks in `send_pending`, status `sending`. The
  browser is expected to run the draft through the page's REAL composer form
  — which is what consumes staged uploads, appends the `[Attached image: …]`
  lines and applies `handle_delivery_result/3`'s semantics — and report back:

    * `sent_ack/1` — the composer's `clear-prompt` arrived: clear the draft
      and push `"sent"`, exactly as phase 1's own delivery did.
    * `send_failed/2` — the composer refused (busy session, unavailable
      node): KEEP the draft, surface the reason. Nothing is retried
      automatically; the text is still in the box.
    * `send_direct/1` — the page has no composer for the target session (the
      user is on `/queue`), so fall back to `{:send, text}`, i.e. phase 1's
      `Cluster.send_message(..., :queue)`.

  `send_pending` carries a 5 s deadline and the `composer_present` flag as of
  the moment the request went out. If the client says nothing before it
  expires, an absent composer means the direct path (the client is simply
  not on a session page and its `send_direct` was lost) while a PRESENT one
  means a visible error — a composer that was reported and then went silent
  is a bug, and silently double-delivering around it is how ORCAHUB3-86 got
  filed in the first place.
  """

  alias OrcaHub.Cluster
  alias OrcaHub.Voice.{ASR, Intent}

  # Spec 5.1: the SEND arming window. The spec calls it configurable; it is
  # not a phase-1 config knob (the matcher threshold is, and comes from
  # ASRConfig).
  @arming_ms 1500

  # How long a sub-0.8 s segment waits for a neighbour to merge with.
  @hold_ms 1500

  # Spec 8.2: how long a `send_request` waits for the client to say what
  # happened before the server decides for itself.
  @send_request_ms 5000

  # Spec 3.2 / section 6, in SAMPLES at 16 kHz: the pre-dispatch floor and
  # the lane's hard cap. `OrcaHub.Voice.ASR` enforces both a second time.
  @min_samples 12_800
  @max_samples 320_000

  # Frame flag bit1: the client already padded this sub-0.8 s segment from
  # its ring buffer, so it is worth dispatching even unmerged.
  @flag_padded 0x2

  @type frame :: %{
          seq: non_neg_integer(),
          start_sample: non_neg_integer(),
          sample_count: non_neg_integer(),
          flags: non_neg_integer(),
          pcm: binary()
        }

  @type effect ::
          {:dispatch, non_neg_integer(), binary()}
          | {:segment_result, map()}
          | {:send_request, String.t()}
          | {:send, String.t()}
          | {:sent, String.t()}
          | {:schedule_tick, non_neg_integer()}

  defstruct threshold: Intent.default_threshold(),
            draft: "",
            muted: false,
            warm: false,
            warming: true,
            sending: false,
            error: nil,
            # ordered list of %{seq:, merged_from: [seq], speech_at:}
            # dispatched to ASR — `speech_at` is `speech_starts` as of the
            # moment the segment was RECEIVED, see `armable?/2`
            awaiting: [],
            # seq => {:ok, asr_result} | {:error, message} completions not
            # yet applied, because an earlier seq has not come back
            buffered: %{},
            # %{seq:, pcm:, sample_count:, flags:, until:, speech_at:} — the
            # short segment waiting for a neighbour to merge with
            held: nil,
            # monotonic ms at which the SEND arming window expires
            arming_until: nil,
            # spec 8.2: the client last told us whether the page it is on
            # has a composer form for the target session. Decides the
            # timeout fallback, not the request itself.
            composer_present: false,
            # %{text:, until:, composer:} — a `send_request` the client has
            # not answered yet
            send_pending: nil,
            # monotonically increasing count of VAD speech onsets, compared
            # against a segment's `speech_at` when its result lands
            speech_starts: 0

  @doc """
  A fresh voice session.

  Options:

    * `:threshold` — the `OrcaHub.Voice.Intent` matcher threshold, normally
      `ASRConfig.resolve/0`'s `:threshold`.
  """
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    %__MODULE__{threshold: Keyword.get(opts, :threshold, Intent.default_threshold())}
  end

  @doc "The arming window, in milliseconds."
  def arming_ms, do: @arming_ms

  @doc "How long a sub-floor segment is held waiting for a merge, in milliseconds."
  def hold_ms, do: @hold_ms

  @doc "How long a `send_request` waits for the client to answer, in milliseconds."
  def send_request_ms, do: @send_request_ms

  # -- warm-up ---------------------------------------------------------------

  @doc "The ASR warm-up ping succeeded: the lane is warm and any error clears."
  @spec warm_ok(%__MODULE__{}) :: {%__MODULE__{}, [effect()]}
  def warm_ok(state), do: {%{state | warm: true, warming: false, error: nil}, []}

  @doc "The ASR warm-up ping failed: `message` is shown until a retry."
  @spec warm_error(%__MODULE__{}, String.t()) :: {%__MODULE__{}, [effect()]}
  def warm_error(state, message), do: {%{state | warming: false, error: message}, []}

  @doc """
  The user asked to re-fire the warm-up ping: back to `warming`, error
  cleared. The channel fires the actual `ASR.warmup/1` task.
  """
  @spec retry_warmup(%__MODULE__{}) :: {%__MODULE__{}, [effect()]}
  def retry_warmup(state), do: {%{state | warming: true, error: nil}, []}

  # -- client events ---------------------------------------------------------

  @doc """
  VAD speech onset. Cancels an open arming window IMMEDIATELY — the chip has
  to die on onset, not ~600 ms later when the segment completes.

  It also bumps `speech_starts`, which is how an onset cancels an arming
  window that has not OPENED yet: the command segment closes 600 ms
  (VAD redemption) after speech offset and its ASR round trip takes another
  ~0.5 s, so an onset landing in that ~0.6-1.1 s gap would otherwise be
  forgotten by the time the `:send` result arrived and armed. See
  `armable?/2`.
  """
  @spec speech_start(%__MODULE__{}) :: {%__MODULE__{}, [effect()]}
  def speech_start(state),
    do: {%{state | arming_until: nil, speech_starts: state.speech_starts + 1}, []}

  @doc "Mirrors the client's half-duplex mic state."
  @spec mic(%__MODULE__{}, boolean()) :: {%__MODULE__{}, [effect()]}
  def mic(state, muted?), do: {%{state | muted: !!muted?}, []}

  @doc "The user edited the draft by hand. Replaces the draft, cancels arming."
  @spec draft_edit(%__MODULE__{}, String.t()) :: {%__MODULE__{}, [effect()]}
  def draft_edit(state, text) when is_binary(text),
    do: {%{state | draft: text, arming_until: nil}, []}

  @doc """
  Clears the draft and any arming window.

  Also abandons an outstanding `send_request` — a spoken "orca cancel" that
  lands while one is in flight means the user changed their mind, and
  letting the 5 s deadline fall back to a direct send afterwards would
  deliver the very text they just cancelled.
  """
  @spec cancel(%__MODULE__{}) :: {%__MODULE__{}, [effect()]}
  def cancel(state),
    do: {%{state | draft: "", arming_until: nil, send_pending: nil, sending: false}, []}

  @doc """
  The client reported whether the page it is on has a composer form bound to
  the target session (spec §8.2's `"composer"` event). Sent at join, at every
  retarget, and whenever the page's composer appears or disappears.
  """
  @spec composer(%__MODULE__{}, boolean()) :: {%__MODULE__{}, [effect()]}
  def composer(state, present?), do: {%{state | composer_present: !!present?}, []}

  @doc """
  The manual Send button: sends the current draft immediately, with no
  arming window. A no-op on an empty draft.

  `now` is the caller's monotonic clock, so the 5 s `send_request` deadline
  is testable without sleeping.
  """
  @spec send_now(%__MODULE__{}, integer()) :: {%__MODULE__{}, [effect()]}
  def send_now(state, now \\ System.monotonic_time(:millisecond))
  def send_now(%__MODULE__{draft: ""} = state, _now), do: {state, []}
  def send_now(state, now), do: request_send(state, now)

  # Spec 8.2: the SERVER no longer delivers. It asks the client to run the
  # draft through the real composer and waits @send_request_ms for an answer.
  defp request_send(state, now) do
    pending = %{
      text: state.draft,
      until: now + @send_request_ms,
      composer: state.composer_present
    }

    {%{state | sending: true, arming_until: nil, send_pending: pending},
     [{:send_request, state.draft}, {:schedule_tick, @send_request_ms}]}
  end

  @doc """
  The client ran the draft through the composer and the LiveView pushed
  `clear-prompt` — i.e. delivery SUCCEEDED, uploads and attachment lines
  included. Clears the draft and pushes `"sent"`, exactly as phase 1's own
  delivery did.

  A no-op when nothing is pending, so a duplicate ack (or one racing the 5 s
  fallback) cannot clear a draft the user has since rebuilt.
  """
  @spec sent_ack(%__MODULE__{}) :: {%__MODULE__{}, [effect()]}
  def sent_ack(%__MODULE__{send_pending: nil} = state), do: {state, []}

  def sent_ack(%__MODULE__{send_pending: pending} = state),
    do: sent(%{state | send_pending: nil}, pending.text)

  @doc """
  The composer refused the send (busy session, unavailable node, …). The
  draft is KEPT — the text is still sitting in the user's composer box and
  losing the server's copy would desynchronise the two.
  """
  @spec send_failed(%__MODULE__{}, String.t()) :: {%__MODULE__{}, [effect()]}
  def send_failed(%__MODULE__{send_pending: nil} = state, _reason), do: {state, []}

  def send_failed(state, reason) when is_binary(reason),
    do: {%{state | send_pending: nil, sending: false, error: reason}, []}

  @doc """
  The page has no composer for the target session, so the server delivers
  the draft itself with `Cluster.send_message(..., :queue)` — phase 1's
  path, unchanged. The outcome comes back through `send_result/2`.
  """
  @spec send_direct(%__MODULE__{}) :: {%__MODULE__{}, [effect()]}
  def send_direct(%__MODULE__{send_pending: nil} = state), do: {state, []}

  def send_direct(%__MODULE__{send_pending: pending} = state),
    do: {%{state | send_pending: nil, sending: true}, [{:send, pending.text}]}

  @doc """
  The outcome of the channel's `Cluster.send_message(..., :queue)` call.

  `{:queued, _}` is exactly as much a success as `:ok` (the message still
  arrives, just deferred to the target's turn end) — same reading as
  `SessionLive.Show.handle_delivery_result/3`.
  """
  @spec send_result(%__MODULE__{}, term()) :: {%__MODULE__{}, [effect()]}
  def send_result(state, :ok), do: sent(state)
  def send_result(state, {:queued, _status}), do: sent(state)

  def send_result(state, {:error, :busy}),
    do: {%{state | sending: false, error: "Session is busy"}, []}

  def send_result(state, {:error, reason} = error) do
    message = Cluster.node_unavailable_message(error) || "Could not send: #{inspect(reason)}"
    {%{state | sending: false, error: message}, []}
  end

  def send_result(state, other),
    do: {%{state | sending: false, error: "Could not send: #{inspect(other)}"}, []}

  defp sent(state, text \\ nil) do
    text = text || state.draft

    {%{state | sending: false, draft: "", arming_until: nil, send_pending: nil, error: nil},
     [{:sent, text}]}
  end

  # -- segments --------------------------------------------------------------

  @doc """
  A decoded binary segment frame from the client.

  Applies the muted / 20 s cap / 0.8 s floor ladder described in the
  moduledoc and returns the resulting effects.
  """
  @spec segment_received(%__MODULE__{}, frame(), integer()) :: {%__MODULE__{}, [effect()]}
  def segment_received(%__MODULE__{muted: true} = state, frame, _now) do
    {state, [result_effect(frame.seq, "dropped_muted", detail: "mic muted")]}
  end

  def segment_received(state, frame, now) do
    case state.held do
      nil -> classify(state, frame, [], now)
      held -> merge_held(state, held, frame, now)
    end
  end

  # A held sub-floor segment plus the one that just arrived, concatenated.
  # The merged clip carries the LATER seq (the frame that triggered the
  # dispatch) and remembers the seq it swallowed, so the per-utterance log
  # explains where the missing seq went.
  defp merge_held(state, held, frame, now) do
    merged = %{
      seq: frame.seq,
      start_sample: held.start_sample,
      sample_count: held.sample_count + frame.sample_count,
      flags: Bitwise.bor(held.flags, frame.flags),
      pcm: held.pcm <> frame.pcm
    }

    classify(%{state | held: nil}, merged, [held.seq], now)
  end

  defp classify(state, frame, merged_from, now) do
    detail = merge_detail(merged_from)

    cond do
      frame.sample_count > @max_samples ->
        {state,
         [
           result_effect(frame.seq, "error", detail: join_detail(detail, "segment over 20 s cap"))
         ]}

      frame.sample_count < @min_samples ->
        hold(state, frame, merged_from, now)

      true ->
        dispatch(state, frame, merged_from, state.speech_starts)
    end
  end

  defp dispatch(state, frame, merged_from, speech_at) do
    entry = %{seq: frame.seq, merged_from: merged_from, speech_at: speech_at}
    {%{state | awaiting: state.awaiting ++ [entry]}, [{:dispatch, frame.seq, frame.pcm}]}
  end

  # Spec 3.2: never discard a short segment outright — hold it for a merge,
  # and only decide what to do with it when the hold expires.
  defp hold(state, frame, merged_from, now) do
    held = %{
      seq: frame.seq,
      merged_from: merged_from,
      start_sample: frame.start_sample,
      sample_count: frame.sample_count,
      flags: frame.flags,
      pcm: frame.pcm,
      until: now + @hold_ms,
      speech_at: state.speech_starts
    }

    {%{state | held: held}, [{:schedule_tick, @hold_ms}]}
  end

  # -- ASR results -----------------------------------------------------------

  @doc """
  One ASR completion, keyed by the `seq` it was dispatched under.

  `result` is `{:ok, ASR.result()}` or `{:error, message}` — the channel
  renders `ASR.describe_error/2` before calling, so this module never needs
  the resolved config.

  Completions are BUFFERED and applied in dispatch order; a result for a seq
  that was never dispatched (or was already applied) is ignored.
  """
  @spec transcript(
          %__MODULE__{},
          non_neg_integer(),
          {:ok, map()} | {:error, String.t()},
          integer()
        ) ::
          {%__MODULE__{}, [effect()]}
  def transcript(state, seq, result, now) do
    if Enum.any?(state.awaiting, &(&1.seq == seq)) do
      drain(%{state | buffered: Map.put(state.buffered, seq, result)}, now, [])
    else
      {state, []}
    end
  end

  defp drain(%__MODULE__{awaiting: [%{seq: seq} = entry | rest]} = state, now, acc) do
    case Map.pop(state.buffered, seq) do
      {nil, _buffered} ->
        {state, acc}

      {result, buffered} ->
        {state, effects} =
          apply_result(%{state | awaiting: rest, buffered: buffered}, entry, result, now)

        drain(state, now, acc ++ effects)
    end
  end

  defp drain(state, _now, acc), do: {state, acc}

  defp apply_result(state, entry, {:error, message}, _now) do
    {state,
     [
       result_effect(entry.seq, "error",
         detail: join_detail(merge_detail(entry.merged_from), message)
       )
     ]}
  end

  defp apply_result(state, entry, {:ok, res}, now) do
    base = [
      text: res.text,
      elapsed_seconds: res.elapsed_seconds,
      duration: res.duration,
      detail: merge_detail(entry.merged_from)
    ]

    state = %{state | error: nil}

    if ASR.silence?(res) do
      {state, [result_effect(entry.seq, "dropped_silence", base)]}
    else
      {intent, score} = Intent.intent(res.text, threshold: state.threshold)
      classify_intent(state, entry, res, intent, score, Keyword.put(base, :score, score), now)
    end
  end

  defp classify_intent(state, entry, res, nil, _score, base, _now) do
    {append(state, res.text), [result_effect(entry.seq, "appended", base)]}
  end

  defp classify_intent(state, entry, res, :send, _score, base, now) do
    remainder = Intent.strip_command(res.text, :send, threshold: state.threshold)
    state = if remainder == "", do: state, else: append(state, remainder)

    cond do
      state.draft == "" ->
        base = Keyword.put(base, :detail, join_detail(Keyword.get(base, :detail), "empty draft"))
        {state, [result_effect(entry.seq, "send", base)]}

      not armable?(state, entry) ->
        base =
          Keyword.put(
            base,
            :detail,
            join_detail(Keyword.get(base, :detail), "arming skipped: speech resumed")
          )

        {state, [result_effect(entry.seq, "send", base)]}

      true ->
        action = if remainder == "", do: "dropped_command_only", else: "send"
        state = %{state | arming_until: now + @arming_ms}
        {state, [result_effect(entry.seq, action, base), {:schedule_tick, @arming_ms}]}
    end
  end

  defp classify_intent(state, entry, _res, :cancel, _score, base, _now) do
    {%{state | draft: "", arming_until: nil}, [result_effect(entry.seq, "cancel", base)]}
  end

  defp classify_intent(state, entry, res, intent, _score, base, _now)
       when intent in [:stop, :pause] do
    remainder = Intent.strip_command(res.text, intent, threshold: state.threshold)
    state = if remainder == "", do: state, else: append(state, remainder)
    base = Keyword.put(base, :intent_name, to_string(intent))
    {state, [result_effect(entry.seq, "ignored_stop_pause", base)]}
  end

  # Spec 5.1: the arming chip dies on "any further speech". `speech_start/1`
  # covers an onset once the window is OPEN; this covers the ~0.6-1.1 s blind
  # spot before it opens — the command segment closes 600 ms after speech
  # offset (VAD redemption) and its ASR round trip costs another ~0.5 s, so an
  # onset in between would otherwise arm a send the user had already talked
  # over. Only onsets STRICTLY AFTER the segment was received count; the one
  # that started the command utterance itself arrives before receipt and is
  # already folded into `entry.speech_at`.
  defp armable?(state, entry), do: state.speech_starts <= entry.speech_at

  # Appending is also what cancels an open arming window — the user kept
  # talking, so whatever they said is not a confirmation of the last send.
  defp append(state, text) do
    text = String.trim(text)

    draft =
      case {state.draft, text} do
        {draft, ""} -> draft
        {"", text} -> text
        {draft, text} -> draft <> " " <> text
      end

    %{state | draft: draft, arming_until: nil}
  end

  # -- timers ----------------------------------------------------------------

  @doc """
  Fires any deadline that has passed: the SEND arming window, and the
  short-segment hold.

  Idempotent — safe to call at any time, from any number of stale timers.
  """
  @spec tick(%__MODULE__{}, integer()) :: {%__MODULE__{}, [effect()]}
  def tick(state, now) do
    {state, hold_effects} = expire_hold(state, now)
    {state, arming_effects} = expire_arming(state, now)
    {state, request_effects} = expire_send_request(state, now)
    {state, hold_effects ++ arming_effects ++ request_effects}
  end

  defp expire_hold(%__MODULE__{held: nil} = state, _now), do: {state, []}

  defp expire_hold(%__MODULE__{held: held} = state, now) when is_map(held) do
    if now < held.until do
      {state, []}
    else
      state = %{state | held: nil}
      detail = merge_detail(held.merged_from)

      if Bitwise.band(held.flags, @flag_padded) != 0 do
        # The client already padded this one from its ring buffer, so it is
        # the best clip that will ever exist for this utterance — spend the
        # round trip rather than silently dropping speech.
        dispatch(state, held, held.merged_from, held.speech_at)
      else
        {state,
         [
           result_effect(held.seq, "dropped_short",
             detail: join_detail(detail, "under the 0.8 s ASR floor, nothing to merge with")
           )
         ]}
      end
    end
  end

  defp expire_arming(%__MODULE__{arming_until: nil} = state, _now), do: {state, []}

  defp expire_arming(state, now) do
    if now < state.arming_until do
      {state, []}
    else
      state = %{state | arming_until: nil}

      if state.draft == "" do
        {state, []}
      else
        request_send(state, now)
      end
    end
  end

  defp expire_send_request(%__MODULE__{send_pending: nil} = state, _now), do: {state, []}

  defp expire_send_request(%__MODULE__{send_pending: pending} = state, now) do
    cond do
      now < pending.until ->
        {state, []}

      # No composer was ever reported: the client is off a session page and
      # its `send_direct` was simply lost. Deliver the phase-1 way.
      not pending.composer ->
        {%{state | send_pending: nil, sending: true}, [{:send, pending.text}]}

      # A composer WAS reported and then said nothing. Do not guess — a
      # silent second delivery here is exactly the double-send ORCAHUB3-86
      # exists to prevent. Keep the draft, say so.
      true ->
        {%{
           state
           | send_pending: nil,
             sending: false,
             error: "The composer did not respond — nothing was sent. Try again."
         }, []}
    end
  end

  # -- snapshot --------------------------------------------------------------

  @doc """
  The full client-facing snapshot (spec 8.1's `"state"` event).

  `status` precedence is error > sending > arming > transcribing > warming >
  listening; `muted` is orthogonal to all of them.
  """
  @spec snapshot(%__MODULE__{}, integer()) :: map()
  def snapshot(state, now \\ System.monotonic_time(:millisecond)) do
    %{
      status: status(state),
      draft: state.draft,
      muted: state.muted,
      warm: state.warm,
      pending: pending(state),
      arming_ms: arming_remaining(state, now),
      error: state.error
    }
  end

  defp status(%__MODULE__{error: error}) when is_binary(error), do: "error"
  defp status(%__MODULE__{sending: true}), do: "sending"
  defp status(%__MODULE__{arming_until: until}) when is_integer(until), do: "arming"
  defp status(%__MODULE__{warming: true}), do: "warming"

  defp status(state) do
    if pending(state) > 0, do: "transcribing", else: "listening"
  end

  defp pending(state), do: length(state.awaiting) + if(state.held, do: 1, else: 0)

  defp arming_remaining(%__MODULE__{arming_until: nil}, _now), do: nil
  defp arming_remaining(%__MODULE__{arming_until: until}, now), do: max(until - now, 0)

  # -- shared helpers --------------------------------------------------------

  defp result_effect(seq, action, fields) do
    {:segment_result,
     %{
       seq: seq,
       text: Keyword.get(fields, :text, ""),
       intent: nil,
       score: Keyword.get(fields, :score, 0.0),
       elapsed_seconds: Keyword.get(fields, :elapsed_seconds, 0.0),
       duration: Keyword.get(fields, :duration, 0.0),
       action: action,
       detail: Keyword.get(fields, :detail)
     }
     |> put_intent(action, Keyword.get(fields, :intent_name))}
  end

  # The wire field is the command NAME, so it is derivable from the action
  # for every path that has one.
  defp put_intent(map, _action, name) when is_binary(name), do: %{map | intent: name}
  defp put_intent(map, "send", _), do: %{map | intent: "send"}
  defp put_intent(map, "dropped_command_only", _), do: %{map | intent: "send"}
  defp put_intent(map, "cancel", _), do: %{map | intent: "cancel"}
  defp put_intent(map, _action, _), do: map

  defp merge_detail([]), do: nil

  defp merge_detail(seqs),
    do: "merged with segment #{Enum.map_join(seqs, ", ", &to_string/1)}"

  defp join_detail(nil, detail), do: detail
  defp join_detail(prefix, nil), do: prefix
  defp join_detail(prefix, detail), do: "#{prefix}; #{detail}"
end
