// Streaming TTS sentence accumulator — voice_mode_spec.md §7.3 (contract C3).
//
// Pure, DOM-free and network-free on purpose: this is the only part of the
// streaming-speech path with interesting logic (fence tracking, boundary
// choice, three competing release thresholds), and the repo has no browser
// test runner, so it lives in its own module where `node --input-type=module`
// can exercise it directly. Everything that touches audio, the chunk queue or
// the network stays in `TTSMethods` in app.js.
//
// Feed it deltas with `push(text, now)`, poke it on a timer with `tick(now)`,
// and drain it at a block/stream boundary with `flush()`. Each returns an
// ARRAY of released chunk strings (usually empty) — the caller is responsible
// for `ttsCleanText`-ing and enqueueing them.

// The one sentence-boundary rule, shared with `ttsSplitIntoChunks` in app.js
// so the streaming producer and the whole-message producer can never drift
// into speaking to two different rhythms.
export const SENTENCE_BOUNDARY = /(?<=[.!?])\s+/

// Same rule, as a global scanner: used to find WHERE the boundaries are
// rather than to split on them.
const SENTENCE_BOUNDARY_SCAN = /(?<=[.!?])\s/g

// A clause boundary is the fallback release point for a buffer that has run
// long with no sentence end in sight (a list, a colon-led preamble, an
// unusually long sentence).
const CLAUSE_BOUNDARY_SCAN = /(?<=[,;:])\s/g

// §7.3's thresholds, verbatim.
export const MIN_SENTENCE_CHARS = 40
export const MAX_BUFFER_CHARS = 240
export const IDLE_RELEASE_MS = 1500
export const IDLE_MIN_CHARS = 20

// A complete line that opens or closes a fenced code block. Indentation is
// allowed (list-nested code blocks); an info string ("```elixir") is only
// legal on the OPENING fence, which is why the closing test also compares the
// marker character.
const FENCE_LINE = /^\s{0,3}(`{3,}|~{3,})\s*(\S*)\s*$/

// Could this PARTIAL (not yet newline-terminated) line still turn into a
// fence marker? While it could, its text is held back rather than spoken, so
// a code fence's opening line never gets read aloud as prose.
const PARTIAL_FENCE = /^\s{0,3}[`~]*$/

export function createTtsStreamAccumulator(now = 0) {
  return new TtsStreamAccumulator(now)
}

export class TtsStreamAccumulator {
  constructor(now = 0) {
    // Text known to be speakable (complete lines, fences already stripped).
    this.buf = ""
    // The current, not-yet-newline-terminated line. Held out of `buf`
    // because it might still become a fence marker.
    this.line = ""
    this.inFence = false
    this.fenceChar = null
    this.lastReleaseAt = now
    this.started = false
  }

  // Feed one delta. Returns the chunks it made releasable, if any.
  push(text, now = this.lastReleaseAt) {
    // The idle clock runs from the first TEXT, not from the stream's start:
    // a model that thinks for two seconds before writing would otherwise
    // arrive with the 1500ms rule already satisfied and have its opening
    // sentence chopped at whatever word happened to land first (observed:
    // "Volcanoes are massive geological formations that release molten" /
    // "rock, known as magma …").
    if (!this.started && text) {
      this.started = true
      this.lastReleaseAt = now
    }
    if (text) this._absorb(text)
    return this._release(now)
  }

  // Time-based release: called on a timer by the producer, because the
  // 1500ms rule has to fire on silence, when no delta is arriving to carry
  // it. A no-op unless that threshold is actually met.
  tick(now) {
    const s = this._releasable()
    if (s.trim().length < IDLE_MIN_CHARS) return []
    if (now - this.lastReleaseAt < IDLE_RELEASE_MS) return []

    // Cut at the last whitespace so a half-typed word is never handed to the
    // synthesizer; if there is no whitespace at all it is one long token and
    // waiting longer would not help.
    const cut = s.lastIndexOf(" ")
    return this._emit(cut > 0 ? cut + 1 : s.length, now)
  }

  // Everything left, spoken as-is: a block or stream just ended, so there is
  // no more text coming that could complete the sentence.
  flush(now = this.lastReleaseAt) {
    // An unterminated fence means the model was still inside code when the
    // block ended — drop it rather than reading backticks aloud.
    const s = this.inFence ? this.buf : this._releasable()
    this.buf = ""
    this.line = ""
    this.inFence = false
    this.fenceChar = null
    this.lastReleaseAt = now
    const chunk = s.trim()
    return chunk ? [chunk] : []
  }

  // --- internals -----------------------------------------------------

  // Split incoming text into complete lines, classify each as fence
  // marker / inside-fence / speakable, and keep the trailing partial line
  // aside.
  _absorb(text) {
    const parts = (this.line + text).split("\n")
    this.line = parts.pop()

    for (const line of parts) {
      const fence = line.match(FENCE_LINE)

      if (fence) {
        const marker = fence[1][0]
        if (!this.inFence) {
          this.inFence = true
          this.fenceChar = marker
        } else if (marker === this.fenceChar) {
          this.inFence = false
          this.fenceChar = null
        }
        // The marker line itself is never spoken, open or close.
        continue
      }

      if (this.inFence) continue

      this.buf += line + "\n"
    }
  }

  // What may be considered for release right now: the confirmed-speakable
  // buffer, plus the partial line when it cannot still become a fence.
  _releasable() {
    if (this.inFence) return this.buf
    if (PARTIAL_FENCE.test(this.line)) return this.buf
    return this.buf + this.line
  }

  _release(now) {
    const s = this._releasable()
    if (!s) return []

    // 1. A sentence ended and there is enough of it to be worth speaking.
    //    Take the LAST boundary available, so several short sentences
    //    arriving in one delta go out as one chunk rather than a stutter.
    const sentenceCut = lastMatchEnd(s, SENTENCE_BOUNDARY_SCAN)
    if (sentenceCut > 0 && s.slice(0, sentenceCut).trim().length >= MIN_SENTENCE_CHARS) {
      return this._emit(sentenceCut, now)
    }

    // 2. No sentence end in sight and the buffer has run long — cut at a
    //    clause boundary instead of waiting for punctuation that may never
    //    come (bulleted lists, especially).
    if (s.length > MAX_BUFFER_CHARS) {
      const clauseCut = lastMatchEnd(s, CLAUSE_BOUNDARY_SCAN)
      if (clauseCut > 0) return this._emit(clauseCut, now)
    }

    return []
  }

  // Release `s.slice(0, n)` and drop it from the buffers. The cut can land
  // inside the partial line, so both are consumed in order.
  _emit(n, now) {
    const s = this._releasable()
    const chunk = s.slice(0, n).trim()

    if (n <= this.buf.length) {
      this.buf = this.buf.slice(n)
    } else {
      this.line = this.line.slice(n - this.buf.length)
      this.buf = ""
    }

    this.lastReleaseAt = now
    return chunk ? [chunk] : []
  }
}

// Index just past the last match of a /g regex, or -1. (`lastIndexOf` can't
// express "punctuation followed by whitespace".)
function lastMatchEnd(s, scanner) {
  scanner.lastIndex = 0
  let end = -1
  let m
  while ((m = scanner.exec(s)) !== null) {
    end = m.index + m[0].length
    if (m[0].length === 0) scanner.lastIndex++
  }
  return end
}

// A tool call is announced, never read out (§7's "the feed is mostly tool
// calls, diffs and file lists" rule). One short phrase per tool_use block.
const TOOL_PHRASES = {
  Bash: "running a command",
  Edit: "editing a file",
  MultiEdit: "editing a file",
  Write: "editing a file",
  NotebookEdit: "editing a file",
  Read: "reading a file",
  Grep: "searching",
  Glob: "searching",
  WebSearch: "searching the web",
  WebFetch: "searching the web"
}

export function toolAnnouncement(name) {
  if (!name) return "running a tool"
  if (TOOL_PHRASES[name]) return TOOL_PHRASES[name]
  if (name.startsWith("mcp__")) return "calling a tool"
  return "running a tool"
}
