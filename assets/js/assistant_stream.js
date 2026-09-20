// In-progress assistant bubble (voice_mode_spec.md §7.2 / contract C2).
//
// Mixed into the feed hook rather than being a second `phx-hook` — an element
// may only carry one — so this is a methods object, spread into the
// ScrollToBottom hook alongside TTSMethods. It lives in its own module (rather
// than inline in app.js) so `assistant_stream.check.mjs` can drive it under
// plain node against a DOM shim; nothing here touches Phoenix directly.
//
// It owns ONE DOM subtree per live assistant message, `#stream-<stream_id>`,
// parked in the server-rendered `#assistant-stream-slot` (which is
// `phx-update="ignore"`, so LiveView never patches over it). Nothing about the
// live text reaches a socket assign — the server pushes deltas and forgets
// them; a re-render mid-stream therefore costs the same as one with no stream
// at all. That "no assign per token" property is the whole point of this path
// and every rule below is written to preserve it.
//
// ## Lifetime (ORCAHUB3-114)
//
// The bubble used to have exactly ONE removal trigger: an `op: "stop"` push.
// Every way that push can go missing — an interrupt or crash that skips the
// backend's end-of-message frame, a socket disconnect that drops the push, a
// late event re-creating an already-removed bubble — left an orphan sitting
// under the persisted message, showing the same paragraph twice until a full
// page refresh. The server now sweeps open streams at turn end, but a push
// the client never receives cannot be the only guarantee, so the bubble's
// lifetime is now bounded from BOTH ends:
//
//   * `stop`/`clear` — the happy path, unchanged: wait (briefly) for the
//     persisted message to render, then swap.
//   * reconcile — any live bubble whose stream id is already rendered as a
//     persisted message is removed, whether or not a stop ever arrived. Runs
//     on every feed patch and on a slow interval.
//   * watchdog — a bubble with no activity for ASSISTANT_STREAM_MAX_IDLE_MS
//     is removed regardless, so "the persisted message never came either"
//     still terminates.
//   * `reconnected()` — everything is dropped. Deltas missed while
//     disconnected are unrecoverable by contract and the persisted message is
//     authoritative, so a bubble that survived the gap is stale by definition.
//   * finished ids are remembered, so a late delta can never resurrect a
//     bubble that was already swapped out.

// Every event is ALSO re-dispatched as a `window` CustomEvent so consumers
// that have no business touching the feed DOM (the streaming TTS producer,
// and any future host) can listen without coupling to this hook.
export const ASSISTANT_STREAM_EVENT = "orca:assistant-stream"

// How long to keep an orphaned live bubble around waiting for the persisted
// message to render before giving up and removing it anyway. Only reached
// when the persisted message never arrives (backend crash mid-turn) or
// renders without a text bubble at all.
export const ASSISTANT_STREAM_SETTLE_MS = 5000

// Absolute cap on a bubble's life with no events of its own. Generous on
// purpose: an extended-thinking block streams no text at all (thinking deltas
// are dropped by the adapters), so a live bubble can legitimately sit quiet
// for minutes mid-message. This is the backstop for "no stop, no persisted
// message, no further deltas — ever", not a latency budget.
export const ASSISTANT_STREAM_MAX_IDLE_MS = 5 * 60 * 1000

// How often the reconcile/watchdog sweep runs while any bubble is live. The
// timer only exists while `streamBubbles` is non-empty, so an idle session
// carries no interval at all.
export const ASSISTANT_STREAM_SWEEP_MS = 2000

// Remembering every finished id forever would leak on a long-lived page;
// remembering the recent ones is all a "late event resurrects a dead bubble"
// guard actually needs.
const FINISHED_STREAM_MEMORY = 64

export const AssistantStreamMethods = {
  assistantStreamMount() {
    this.streamBubbles = new Map()
    // Insertion-ordered, so trimming the oldest is just the first key.
    this.finishedStreams = new Set()
    this._streamSweepTimer = null

    this.handleEvent("assistant-stream", (payload) => {
      try {
        this.assistantStreamApply(payload)
      } finally {
        // Emitted even if the DOM half threw: TTS must not be silenced by a
        // rendering bug, and vice versa.
        window.dispatchEvent(new CustomEvent(ASSISTANT_STREAM_EVENT, { detail: payload }))
      }
    })
  },

  assistantStreamDestroy() {
    this.assistantStreamStopSweep()
    if (!this.streamBubbles) return
    for (const id of [...this.streamBubbles.keys()]) this.assistantStreamRemove(id)
    this.streamBubbles.clear()
    if (this.finishedStreams) this.finishedStreams.clear()
  },

  assistantStreamApply({ op, stream_id, block_index, text, block_type, name }) {
    // The server's end-of-turn sweep: nothing may still be streaming. Carries
    // no stream id by design — it is exactly the case where the server no
    // longer knows which ids the client is holding.
    if (op === "clear") {
      for (const id of [...this.streamBubbles.keys()]) this.assistantStreamFinish(id)
      return
    }

    if (!stream_id) return

    // A stream we already swapped out is DONE. Without this a late delta (or a
    // duplicate stop's chip) re-creates a bubble through
    // assistantStreamEnsure that nothing will ever stop again.
    if (this.finishedStreams && this.finishedStreams.has(stream_id)) return

    const entry = this.streamBubbles.get(stream_id)
    if (entry) entry.lastActivityAt = Date.now()

    switch (op) {
      case "start":
        this.assistantStreamEnsure(stream_id)
        break
      case "block_start":
        if (block_type === "text") this.assistantStreamBlock(stream_id, block_index)
        else if (block_type === "tool_use") this.assistantStreamChip(stream_id, name)
        // "thinking" renders nothing live — the persisted message collapses
        // it into a thinking block of its own (see MessageComponents).
        break
      case "delta":
        this.assistantStreamAppend(stream_id, block_index, text)
        break
      case "stop":
        this.assistantStreamFinish(stream_id)
        break
    }
  },

  assistantStreamEnsure(streamId) {
    const existing = this.streamBubbles.get(streamId)
    if (existing && existing.el.isConnected) return existing

    // Same guard as assistantStreamApply, for the internal callers
    // (assistantStreamBlock/Chip/Append) that can reach this directly.
    if (this.finishedStreams && this.finishedStreams.has(streamId)) return null

    const slot = document.getElementById("assistant-stream-slot")
    if (!slot) return null

    const el = document.createElement("div")
    el.id = `stream-${streamId}`
    el.className = "chat chat-start"
    el.dataset.assistantStream = streamId

    const header = document.createElement("div")
    header.className = "chat-header text-xs opacity-50 mb-1"
    header.textContent = "Assistant"

    const body = document.createElement("div")
    // Same bubble chrome as a persisted assistant message, minus `prose`:
    // this is plain text, not rendered markdown, so it keeps its newlines
    // via pre-wrap and gets re-rendered properly the moment the real
    // message lands.
    body.className =
      "chat-bubble max-w-none min-w-0 max-w-full break-words whitespace-pre-wrap"
    body.dataset.streamBody = ""

    el.appendChild(header)
    el.appendChild(body)
    slot.appendChild(el)

    const entry = { el, body, blocks: new Map(), lastActivityAt: Date.now() }
    this.streamBubbles.set(streamId, entry)
    this.assistantStreamStartSweep()
    this.assistantStreamFollow()
    return entry
  },

  assistantStreamBlock(streamId, blockIndex) {
    const entry = this.assistantStreamEnsure(streamId)
    if (!entry) return null
    const key = String(blockIndex ?? 0)
    if (entry.blocks.has(key)) return entry.blocks.get(key)

    const div = document.createElement("div")
    div.dataset.streamBlock = key
    entry.body.appendChild(div)
    entry.blocks.set(key, div)
    return div
  },

  // One line per tool call, never the payload (§7's "do not read 400 lines of
  // diff aloud" rule, applied to the eye as well as the ear).
  assistantStreamChip(streamId, name) {
    const entry = this.assistantStreamEnsure(streamId)
    if (!entry) return

    const chip = document.createElement("div")
    chip.className = "text-xs opacity-60 italic"
    chip.textContent = `${name || "tool"}…`
    entry.body.appendChild(chip)
    this.assistantStreamFollow()
  },

  assistantStreamAppend(streamId, blockIndex, text) {
    if (!text) return
    const div = this.assistantStreamBlock(streamId, blockIndex)
    if (!div) return
    // textContent, never innerHTML — model output is untrusted input here
    // exactly like anywhere else.
    div.textContent += text
    this.assistantStreamFollow()
  },

  // The persisted message replaces the live bubble, so removing it early
  // would flash the text out and back in; removing it late would show the
  // same paragraph twice. Poll for the real render (by the backend's own
  // message id, which IS the stream id — §7.1) and swap only then.
  assistantStreamFinish(streamId) {
    const entry = this.streamBubbles.get(streamId)
    if (!entry) return

    // A tool-only turn never renders a text bubble to wait for.
    if (!entry.body.textContent.trim()) {
      this.assistantStreamRemove(streamId)
      return
    }

    // Idempotent: a second stop (or a `clear` behind a stop) must not start a
    // second poll loop racing the first.
    if (entry.finishing) return
    entry.finishing = true

    const startedAt = Date.now()
    const poll = () => {
      if (!this.streamBubbles.has(streamId)) return
      if (
        this.assistantStreamPersisted(streamId) ||
        Date.now() - startedAt > ASSISTANT_STREAM_SETTLE_MS
      ) {
        this.assistantStreamRemove(streamId)
      } else {
        setTimeout(poll, 100)
      }
    }
    poll()
  },

  assistantStreamPersisted(streamId) {
    const escaped = typeof CSS !== "undefined" && CSS.escape ? CSS.escape(streamId) : streamId
    return !!(
      document.querySelector(`[data-message-id="${escaped}"]`) ||
      document.getElementById(`tts-text-${streamId}`)
    )
  },

  // ORCAHUB3-114 — the reconcile half, and the reason the bug is now
  // self-healing rather than stop-dependent: a live bubble whose persisted
  // message is on screen is a DUPLICATE, full stop. It does not matter
  // whether a stop was sent, dropped, or never generated.
  //
  // Called from the feed hook's updated() (so the duplicate never survives a
  // single patch) and from the sweep interval (so it is also caught when
  // nothing else re-renders).
  assistantStreamReconcile(now = Date.now()) {
    if (!this.streamBubbles || this.streamBubbles.size === 0) return

    for (const [streamId, entry] of [...this.streamBubbles]) {
      if (this.assistantStreamPersisted(streamId)) {
        this.assistantStreamRemove(streamId)
        continue
      }

      // The bubble was removed from the DOM by something else (a patch that
      // blew the slot away, a manual clear) — drop the bookkeeping too.
      if (!entry.el.isConnected) {
        this.assistantStreamRemove(streamId)
        continue
      }

      if (now - (entry.lastActivityAt || 0) > ASSISTANT_STREAM_MAX_IDLE_MS) {
        this.assistantStreamRemove(streamId)
      }
    }
  },

  // Missed deltas are unrecoverable by contract (the server does not replay
  // them) and the persisted message is authoritative, so anything still live
  // across a reconnect is stale by definition. Drop it immediately rather
  // than waiting for a stop that was pushed into a closed socket.
  assistantStreamReconnected() {
    if (!this.streamBubbles) return
    for (const id of [...this.streamBubbles.keys()]) this.assistantStreamRemove(id)
  },

  assistantStreamRemove(streamId) {
    const entry = this.streamBubbles.get(streamId)
    if (!entry) return
    this.streamBubbles.delete(streamId)
    entry.el.remove()
    this.assistantStreamMarkFinished(streamId)
    if (this.streamBubbles.size === 0) this.assistantStreamStopSweep()
  },

  assistantStreamMarkFinished(streamId) {
    if (!this.finishedStreams) return
    this.finishedStreams.add(streamId)
    while (this.finishedStreams.size > FINISHED_STREAM_MEMORY) {
      const oldest = this.finishedStreams.values().next().value
      this.finishedStreams.delete(oldest)
    }
  },

  assistantStreamStartSweep() {
    if (this._streamSweepTimer) return
    this._streamSweepTimer = setInterval(
      () => this.assistantStreamReconcile(),
      ASSISTANT_STREAM_SWEEP_MS
    )
  },

  assistantStreamStopSweep() {
    if (!this._streamSweepTimer) return
    clearInterval(this._streamSweepTimer)
    this._streamSweepTimer = null
  },

  // A growing bubble must pin the feed exactly like a new message does —
  // same `following` flag the LiveView-driven path uses, so a user who
  // scrolled up is never yanked back down.
  assistantStreamFollow() {
    if (this.following && typeof this.scrollToBottom === "function") {
      this.scrollToBottom(false)
    }
  }
}
