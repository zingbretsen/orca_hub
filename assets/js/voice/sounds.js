/* Voice-mode audio feedback — ORCAHUB3-93.
 *
 * Two cues, and only ever for a VOICE send:
 *
 *   sent-2 "pneumatic send"  one 270 ms chiff-then-ping, on CONFIRMED delivery
 *   tick-1 "clock tick"      one 45 ms noise transient every 3.5 s while the
 *                            target session is working
 *
 * ## Why this is synthesised and not a WAV
 *
 * The recipes below are the ones measured in the candidate set: rendered
 * through a real Chrome `OfflineAudioContext` at 48 kHz and diffed sample by
 * sample against the reference WAVs. `tick-1` came out BIT-IDENTICAL; the
 * worst deviation anywhere in the set was 32 LSB of 32768 (Chrome's sine
 * wavetable interpolation), correlation 1.000000. So synthesising costs zero
 * asset bytes and loses nothing: the shipped pair as files is 13.3 kB
 * gzipped, this module is well under 1 kB.
 *
 * ## The constants are measurements, not taste
 *
 * `sent-2` peaks at −18 dBFS and `tick-1` at −24 dBFS — the tick is
 * deliberately 6 dB quieter because it repeats up to ~17 times per answer
 * under an OPEN MICROPHONE. Turn them down from there, never up, without
 * re-running the VAD measurement described below.
 *
 * ## The hard constraint: the mic is open while these play
 *
 * Voice mode is half-duplex via `orca:tts-state` — TTS playback pauses the
 * VAD, drops frames and pushes `mic {muted, reason: "tts"}`. A tick every
 * 3.5 s must NOT drive that machinery or the microphone is chopped up for the
 * entire wait and dictation during a turn becomes impossible.
 *
 * Nothing here dispatches `orca:tts-state`, and that is structural rather
 * than a convention: these sounds are WebAudio graphs on their own
 * `AudioContext`, while `orca:tts-state` is dispatched only by the TTS
 * engine's single `Audio()` element in app.js. There is no path from one to
 * the other.
 *
 * Measured rather than argued, 2026-09-19, in headless Chrome with the mic
 * armed for 42.6 s: the page played 13 real ticks while the MICROPHONE was
 * fed a file containing 11 ticks and 2 send sounds at FULL SCALE (no
 * speaker-to-mic path loss, no AEC, a -55 dBFS room floor, and one spoken
 * phrase only 4 dB louder than the tick). Result: 1348 VAD frames processed,
 * ONE segment — the spoken phrase, transcribed "Hello there." — zero
 * `orca:tts-state` dispatches, zero `mic {reason: "tts"}` pushes, and
 * `muted` false on all 400 samples. Re-run it before changing a level.
 *
 * ## Why its own AudioContext
 *
 * `Capture` owns an `AudioContext` too, but it CLOSES it whenever the mic is
 * re-armed (a phone screen coming back on), and a closed context cannot be
 * reused. Holding our own means a tick in flight across a mic repair does not
 * throw. It is created lazily, on the first sound — which can only ever
 * follow the mic-button gesture, so the autoplay policy is already satisfied.
 */

const DB = (db) => Math.pow(10, db / 20)

/** Which candidate won each role. See RECIPES.md in the candidate set for the
 * two runners-up and why they lost. */
export const SENT_SOUND = "sent-2"
export const TICK_SOUND = "tick-1"

/** Spacing of the waiting tick. The FIRST tick is one full period out, so a
 * fast answer never ticks at all. */
export const TICK_PERIOD_S = 3.5

/** Hard stop on the tick, however the bar's `stop` signal is lost — a
 * backend with no deltas that also never reports idle, a dropped LiveView
 * socket, a session whose node went away. A missed signal costs three minutes
 * of quiet clicking, never an afternoon of it. */
export const WAITING_MAX_MS = 180_000

/** localStorage key. ABSENCE means ON (see `soundsEnabled`), unlike
 * `orca:tts-stream` — the default is the other way round. */
export const SOUNDS_KEY = "orca:voice-sounds"

/**
 * GainNode envelope: linear attack from silence, exponential decay, hard stop.
 *
 * The trailing setValueAtTime(0) matters — exponentialRampToValueAtTime can
 * never reach zero, so without it the node would idle forever at −80 dBFS.
 */
function envGain(ctx, t0, atk, dec, peak) {
  const g = ctx.createGain()
  g.gain.value = 0
  g.gain.setValueAtTime(0, t0)
  g.gain.linearRampToValueAtTime(peak, t0 + atk)
  g.gain.exponentialRampToValueAtTime(1e-4, t0 + atk + dec)
  g.gain.setValueAtTime(0, t0 + atk + dec)
  return g
}

function osc(ctx, freq, t0, stopAt) {
  const o = ctx.createOscillator()
  o.type = "sine"
  o.frequency.value = freq
  o.start(t0)
  o.stop(stopAt)
  return o
}

function gainNode(ctx, v) {
  const g = ctx.createGain()
  g.gain.value = v
  return g
}

function filt(ctx, type, freq, Q) {
  const f = ctx.createBiquadFilter()
  f.type = type
  f.frequency.value = freq
  f.Q.value = Q
  return f
}

/**
 * White noise starting at ABSOLUTE context time `at`.
 *
 * The candidate module took a RELATIVE offset here and passed it straight to
 * `start()`, which is invisible offline (an OfflineAudioContext renders from
 * t = 0, so relative and absolute agree) and invisible for a sound fired
 * "now". It is fatal for a sound scheduled AHEAD, which is exactly what the
 * waiting tick does: the buffer would start immediately and be long finished
 * by the time its envelope opened three seconds later — and tick-1 is nothing
 * BUT noise, so every scheduled tick would have been silent.
 *
 * The seed is fixed rather than `Math.random()` so every tick is the same tick
 * — a clock does not vary — and so an offline render reproduces the measured
 * WAV exactly.
 */
function noiseSource(ctx, lengthSec, at, seed) {
  const n = Math.max(1, Math.round(lengthSec * ctx.sampleRate))
  const buf = ctx.createBuffer(1, n, ctx.sampleRate)
  const d = buf.getChannelData(0)
  let x = seed >>> 0
  for (let i = 0; i < n; i++) {
    x ^= x << 13
    x >>>= 0
    x ^= x >>> 17
    x ^= x << 5
    x >>>= 0
    d[i] = (x / 4294967296) * 2 - 1
  }
  const src = ctx.createBufferSource()
  src.buffer = buf
  src.start(at)
  return src
}

function connect(...nodes) {
  for (let i = 0; i < nodes.length - 1; i++) nodes[i].connect(nodes[i + 1])
  return nodes[nodes.length - 1]
}

export const BUILDERS = {
  /**
   * sent-2 "Pneumatic send" — a breathy chiff of escaping air resolving onto
   * one clean C8 ping, over a 28 ms 196 Hz thump for body. Departure then
   * arrival, which is exactly the semantics of "delivered", and not a chime.
   *
   * The ping was deliberately moved from G7 (3136 Hz, inside the 300–3400 Hz
   * speech band) up to C8 (4186 Hz, above it); that one change took the worst
   * 32 ms in-band frame from −29.6 to −56.4 dBFS.
   *
   * The 196 Hz thump is the one element in male-F0 territory. It survives
   * because it is BELOW the 300 Hz band floor, is a bare sine with no
   * harmonic stack (nothing resembling a voiced glottal source), and lasts
   * 28 ms — about 5.5 pitch periods, where voiced speech needs hundreds. The
   * VAD measurement agreed, so the line stays; deleting it is the fallback
   * that costs only some weight.
   */
  "sent-2": (ctx, out, t) => {
    const dur = 0.27
    const bus = gainNode(ctx, 0.13323)
    bus.connect(out)

    connect(
      noiseSource(ctx, dur, t, 23),
      envGain(ctx, t, 0.003, 0.04, 1.0),
      filt(ctx, "bandpass", 5000, 1.2),
      gainNode(ctx, 1.6),
      bus
    )

    connect(osc(ctx, 195.998, t, t + dur), envGain(ctx, t, 0.001, 0.028, 0.45), bus)
    connect(osc(ctx, 4186.01, t + 0.03, t + dur), envGain(ctx, t + 0.03, 0.002, 0.185, 0.95), bus)
    return dur
  },

  /**
   * tick-1 "Clock tick" — a 22 ms noise transient with resonances at 5.2 and
   * 8 kHz. No tonal content at all, so there is nothing periodic for a speech
   * model to latch onto, 61% of its energy sits above 8 kHz where the VAD's
   * 16 kHz front end cannot see it, and its effective duration is 12 ms.
   *
   * Its ~9 kHz centroid is the cost: on a hard-rolled-off laptop speaker it
   * can read as faint. If it needs to be louder, raise `gain` at the call
   * site rather than switching candidates — it has more VAD headroom to spend
   * than anything else in the set (worst in-band frame −75.6 dBFS).
   */
  "tick-1": (ctx, out, t) => {
    const dur = 0.045
    const bus = gainNode(ctx, 0.154218)
    bus.connect(out)

    const src = connect(noiseSource(ctx, dur, t, 101), envGain(ctx, t, 0.0005, 0.022, 1.0))
    connect(src, filt(ctx, "bandpass", 5200, 2.0), gainNode(ctx, 1.0), bus)
    connect(src, filt(ctx, "bandpass", 8000, 2.0), gainNode(ctx, 0.6), bus)
    return dur
  },
}

export const DURATIONS = { "sent-2": 0.27, "tick-1": 0.045 }

/** Fire one sound into `out` (defaults to `ctx.destination`). `when` is on the
 * context's own clock; `gain` scales the shipped level. */
export function playSound(ctx, name, { when = null, gain = 1.0, out = null } = {}) {
  const t = when === null ? ctx.currentTime + 0.005 : when
  const bus = gainNode(ctx, gain)
  bus.connect(out || ctx.destination)
  BUILDERS[name](ctx, bus, t)
  return t + DURATIONS[name]
}

/** Read the persisted preference. DEFAULT ON: the sounds only ever follow an
 * explicit spoken send, so the first time anyone hears one they asked for it
 * out loud a moment earlier. */
export function soundsEnabled() {
  try {
    return window.localStorage.getItem(SOUNDS_KEY) !== "0"
  } catch (_e) {
    return true
  }
}

export function persistSoundsEnabled(enabled) {
  try {
    if (enabled) window.localStorage.removeItem(SOUNDS_KEY)
    else window.localStorage.setItem(SOUNDS_KEY, "0")
  } catch (_e) {
    /* private mode / storage disabled — the in-memory flag still holds */
  }
}

/**
 * The voice bar's two cues, and the waiting-tick scheduler.
 *
 * One instance per hook. `enabled` gates playback only — start/stop of the
 * waiting state is tracked either way, so toggling the preference mid-wait
 * takes effect on the next tick rather than needing the wait restarted.
 */
export class VoiceSounds {
  // `maxWaitMs` is production's WAITING_MAX_MS everywhere except the headless
  // check, which shortens it so the cap can be PROVEN rather than asserted in
  // a comment — the cap is the last line of defence when every one of the
  // bar's four stop signals is lost (a dropped PubSub message, a backend that
  // emits none of them), so "it probably works" is not good enough for it.
  constructor({ enabled = true, maxWaitMs = WAITING_MAX_MS } = {}) {
    this.enabled = !!enabled
    this.maxWaitMs = maxWaitMs
    this.ctx = null
    this.waiting = false
    this._timer = null
    this._cap = null
    this._next = 0
    // Counters, for the headless VAD measurement and for eyeballing in the
    // console via `window.__orcaVoice.sounds.stats`.
    this.stats = { sent: 0, ticks: 0, waits: 0, stops: 0, capped: 0, suppressed: 0 }
  }

  setEnabled(enabled) {
    this.enabled = !!enabled
    // Turning it off mid-wait silences the tick immediately; the wait itself
    // keeps running so turning it back on resumes ticking.
    if (!this.enabled) this._clearTimer()
    else if (this.waiting) this._startTimer()
  }

  /** Confirmed delivery — the channel's `"sent"` event, which the server
   * pushes only after the composer's `clear-prompt` (or after a direct
   * delivery returned :ok). Never on recognition, never on `send_failed`. */
  sent() {
    this.stats.sent++
    this._play(SENT_SOUND)
  }

  /** The target session is working. Idempotent: a second send while already
   * waiting restarts the cap but does not double the tick. */
  startWaiting() {
    this.stats.waits++
    this._clearTimer()
    this.waiting = true
    if (this._cap) clearTimeout(this._cap)
    this._cap = setTimeout(() => {
      this.stats.capped++
      this.stopWaiting()
    }, this.maxWaitMs)
    if (this.enabled) this._startTimer()
  }

  /** The answer started (or the turn settled, or voice went off). */
  stopWaiting() {
    if (this.waiting) this.stats.stops++
    this.waiting = false
    this._clearTimer()
    if (this._cap) {
      clearTimeout(this._cap)
      this._cap = null
    }
  }

  destroy() {
    this.stopWaiting()
    const ctx = this.ctx
    this.ctx = null
    if (ctx && ctx.state !== "closed") ctx.close().catch(() => {})
  }

  // ------------------------------------------------------------- internals

  _startTimer() {
    const ctx = this._context()
    if (!ctx) return
    this._next = ctx.currentTime + TICK_PERIOD_S
    // Schedule one tick AHEAD against `ctx.currentTime` rather than firing
    // from the timer callback: the main thread is rendering streamed tokens
    // while this runs, and a callback-driven tick wobbles audibly.
    this._timer = setInterval(() => {
      const c = this.ctx
      if (!c || !this.waiting || !this.enabled) return
      while (this._next < c.currentTime + TICK_PERIOD_S) {
        this.stats.ticks++
        playSound(c, TICK_SOUND, { when: this._next })
        this._next += TICK_PERIOD_S
      }
    }, Math.min(500, (TICK_PERIOD_S * 1000) / 2))
  }

  _clearTimer() {
    if (this._timer) clearInterval(this._timer)
    this._timer = null
  }

  _play(name) {
    if (!this.enabled) {
      this.stats.suppressed++
      return
    }
    const ctx = this._context()
    if (!ctx) return
    playSound(ctx, name)
  }

  /** Lazily open our own context, and nudge it if the browser suspended it
   * (a backgrounded tab). `resume()` is fire-and-forget — a sound that cannot
   * play must never throw into the send path. */
  _context() {
    if (!this.ctx) {
      const Ctor = typeof window !== "undefined" && (window.AudioContext || window.webkitAudioContext)
      if (!Ctor) return null
      try {
        this.ctx = new Ctor()
      } catch (_e) {
        return null
      }
    }
    if (this.ctx.state === "suspended") this.ctx.resume().catch(() => {})
    return this.ctx
  }
}
