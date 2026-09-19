// Text normalization for TTS — the one place that turns rendered
// message/chunk text into something a speech synthesizer won't mangle.
//
// Pure, DOM-free on purpose, same rationale as tts_stream.js: the repo has
// no browser test runner, so this lives in its own module with a plain-node
// companion check script (`node assets/js/tts_text.check.mjs`). It must be
// safe on PARTIAL text — the streaming path calls it on a mid-message
// sentence, not just on a whole rendered bubble.
//
// `ttsCleanText` in app.js is a thin delegate to `cleanTextForTTS` here; it
// is kept because it's referenced by name in tts_stream.js's header comment
// and called from two sites (ttsExtractText, ttsStreamEnqueue). `ttsExtractText`
// itself delegates DOM extraction to `extractSpeakableFromElement` below,
// rather than `bubble.innerText`, so fenced code blocks (rendered as `<pre>`
// by the time the bubble is real HTML — no backticks left for
// `cleanTextForTTS`'s markdown-strip rule to see) are dropped, and inline
// `<code>` spans go through the same `speakCodeSpan` identifier-splitter as
// the streaming path's backtick rule.
//
// INVARIANT (agreed with voice mode, load-bearing): a message that is
// entirely a fenced code block must make `cleanTextForTTS` return the empty
// string, not e.g. a stray "." — app.js's `ttsStart` gates its `this.playing
// = true` / `ttsEmitState()` behind `if (!text) return`, and the voice hook
// latches its mic-mute on that emitted `{playing}` boolean, so a `true` with
// no matching `false` (a one-chunk player that "plays" punctuation and never
// really starts) leaves the mic dead with no error and no recovery short of
// toggling voice off and on. See the whitespace-cleanup step's trim-before-
// the-period-rule comment below for the mechanics.
//
// Rule order (each step runs on the previous step's output, and later rules
// must not re-mangle an earlier rule's result):
//   markdown strip -> term map -> symbols -> units -> UUIDs -> hashes
//   -> paths -> standalone filenames -> underscores -> whitespace
// Units/UUIDs/hashes run BEFORE paths/filenames so a hash or byte-count
// token never gets torn apart by the path/filename regexes; the term map
// runs before all of it so e.g. "HEEx" doesn't collide with the later
// extension pronunciation of a literal ".heex" file.

// Elixir/programming term pronunciations. Deliberately no lowercase
// "heex"/"eex" entries here (unlike the capitalized "HEEx"/"EEx" prose
// forms) — they'd collide with EXTENSION_MAP below and swallow the dot in
// an actual ".heex"/".eex" filename before the extension rule ever saw it
// (e.g. "show.heex" -> "show.heeks" instead of "show dot heeks"). Prose
// almost always spells the templating language capitalized; lowercase
// "heex"/"eex" in real text is overwhelmingly a file extension.
export const TERM_MAP = {
  "HEEx": "heeks",
  "EEx": "eeks",
  "defp": "def p",
  "defmodule": "def module",
  "GenServer": "gen server",
  "PubSub": "pub sub",
  "LiveView": "live view",
  "ExUnit": "ex unit",
  "iex": "I E X",
  "CSRF": "C S R F",
  "JSONL": "JSON lines",
  "nginx": "engine x",
  "stdin": "standard in",
  "stdout": "standard out",
  "stderr": "standard error",
  "CLI": "C L I",
  "OTP": "O T P",
  "npm": "N P M",
  "UUID": "U U I D",
  "regex": "regex",
  "phx": "phoenix",
}

// File-extension pronunciations, shared by the path-with-directories branch
// and the standalone-filename branch below. An extension NOT in this map
// keeps today's behaviour: it is spoken as its raw letters (e.g. "dot rar").
export const EXTENSION_MAP = {
  md: "markdown",
  txt: "text",
  py: "pie",
  ex: "ex",
  exs: "ex s", // exs is Elixir script
  heex: "heeks",
  eex: "eeks",
  leex: "leeks",
  js: "J S",
  mjs: "M J S",
  ts: "T S",
  json: "jason",
  yml: "yamel",
  yaml: "yamel",
  toml: "tommel",
  css: "C S S",
  html: "H T M L",
  sh: "shell",
  rb: "ruby",
  rs: "rust",
  go: "go",
  lock: "lock",
}

function pronounceExtension(ext) {
  return EXTENSION_MAP[ext] || ext
}

// How many leading characters of a hash/UUID get spelled out. A tuning
// knob: 4 is how humans disambiguate a git commit at a glance, and it's
// short enough to stay intelligible spoken as individual letters/digits.
export const HASH_SPOKEN_CHARS = 4

function pronounceHex(str, n = HASH_SPOKEN_CHARS) {
  return str.slice(0, n).toUpperCase().split("").join(" ")
}

// A candidate hash may be preceded by one of these keywords, with `(`,
// backtick, `@` or whitespace allowed in between (e.g. "commit (4dc631d)").
const HASH_KEYWORD_RE = /\b(?:commit|sha|revision|rev|hash|ref|at)$/i
const HASH_KEYWORD_FILLER_RE = /[(`@\s]+$/

function hasHashKeywordBefore(text, index) {
  const trimmed = text.slice(0, index).replace(HASH_KEYWORD_FILLER_RE, "")
  return HASH_KEYWORD_RE.test(trimmed)
}

// Lowercase hex only — no English word mixes digits and letters, so that
// alone rules out false positives like "defaced"/"deadbeef"/"cafebabe"
// (those only convert when a hash keyword actually precedes them).
const BARE_HASH_RE = /\b[0-9a-f]{7,40}\b/g

function replaceHashes(text) {
  return text.replace(BARE_HASH_RE, (match, offset, full) => {
    const looksLikeHash = /\d/.test(match) && /[a-f]/.test(match)
    if (!looksLikeHash && !hasHashKeywordBefore(full, offset)) return match
    return pronounceHex(match)
  })
}

// Full UUIDs (8-4-4-4-12 hex — session ids, etc.) get the same treatment.
// Runs BEFORE the bare-hash rule so a UUID's hex segments aren't matched
// (and spoken) a second time by it.
const UUID_RE = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi

function replaceUuids(text) {
  return text.replace(UUID_RE, (match) => pronounceHex(match))
}

const plural = (numStr) => (numStr === "1" ? "" : "s")

// Only a unit ATTACHED to a number is rewritten — case-sensitive (MB vs
// mb matters, same as the term map above). Ordered so a longer/more
// specific token (e.g. "KB/s") is tried before a token it starts with
// ("KB"), which matters because regex alternation picks the first
// alternative that matches at a position, not the longest one.
const UNIT_FORMATTERS = [
  ["KB/s", () => "kilobyte", true, " per second"],
  ["MB/s", () => "megabyte", true, " per second"],
  ["GB/s", () => "gigabyte", true, " per second"],
  ["kHz", () => "kilohertz", false, ""],
  ["MHz", () => "megahertz", false, ""],
  ["GHz", () => "gigahertz", false, ""],
  ["Hz", () => "hertz", false, ""],
  ["ms", () => "millisecond", true, ""],
  ["ns", () => "nanosecond", true, ""],
  ["Mbps", () => "megabits per second", false, ""],
  ["Gbps", () => "gigabits per second", false, ""],
  ["Kbps", () => "kilobits per second", false, ""],
  ["KB", () => "kilobyte", true, ""],
  ["kB", () => "kilobyte", true, ""],
  ["MB", () => "megabyte", true, ""],
  ["GB", () => "gigabyte", true, ""],
  ["TB", () => "terabyte", true, ""],
  ["px", () => "pixel", true, ""],
  ["fps", () => "frames per second", false, ""],
  ["rpm", () => "revolutions per minute", false, ""],
  ["%", () => "percent", false, ""],
]

const UNIT_LOOKUP = new Map(UNIT_FORMATTERS.map(([token, ...rest]) => [token, rest]))

// "%" is a symbol, not a word char, so a trailing `\b` (a transition
// between a word and non-word char) would fail to match it whenever it's
// followed by whitespace/punctuation — i.e. almost always ("50% done").
// Every other unit is alphabetic and keeps the literal `\b` from the spec.
const UNIT_ALTERNATION = UNIT_FORMATTERS
  .map(([token]) => (token === "%" ? "%" : `${token}\\b`))
  .join("|")
const UNIT_RE = new RegExp(`(\\d[\\d,]*(?:\\.\\d+)?)\\s*(${UNIT_ALTERNATION})`, "g")

function replaceUnits(text) {
  return text.replace(UNIT_RE, (match, numStr, token) => {
    const [nameFn, pluralize, suffix] = UNIT_LOOKUP.get(token)
    const name = nameFn() + (pluralize ? plural(numStr) : "")
    return `${numStr} ${name}${suffix}`
  })
}

// Elements that stand for a paragraph/line/cell break in rendered markdown —
// extractSpeakableFromElement emits a blank-line (two newlines) after each,
// which the `\n{2,}` -> ". " rule downstream turns into a sentence break.
// <pre> is deliberately absent: it's skipped wholesale, not walked.
const BLOCK_TAGS = new Set([
  "P", "DIV", "LI", "UL", "OL", "H1", "H2", "H3", "H4", "H5", "H6",
  "BLOCKQUOTE", "TABLE", "TR", "TD", "TH", "HR",
])

// Punctuation collapsed to a space ONLY inside a code span — bracket noise
// like `%{foo: 1}` otherwise reads badly aloud. `/`, `.` and `-` are
// deliberately NOT in this list: they must survive so the path/extension/
// hash rules downstream still fire on a path or hash inside a code span.
const CODE_BRACKET_RE = /[(){}\[\]]/g

// lower/digit -> upper ("handleEvent" -> "handle Event") and the acronym
// boundary upper-run -> upper+lower ("TTSPlayer" -> "TTS Player").
function splitCamelCase(token) {
  return token
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
}

// Splits one whitespace-delimited token from inside a code span into
// speakable words: snake_case on internal underscores, camelCase/PascalCase
// on case transitions. Left alone: flags ("--skip-arm64"), bare words,
// numbers — anything with no internal case/underscore transition to split
// on. A token containing "/" is left completely untouched: it's path-like,
// and the path/extension/hash rules downstream (which run after inline code
// is resolved, in the same cleanTextForTTS pass) already handle it — a
// pre-emptive split here (e.g. "orca_hub" -> "orca hub" inside
// "lib/orca_hub/tts.ex") would insert a space into what those regexes need
// to see as one contiguous slash-separated run, breaking the match.
function splitIdentifierToken(token) {
  if (token.includes("/")) return token
  let out = token
  if (/\w_\w/.test(out)) out = out.replace(/_/g, " ")
  return splitCamelCase(out)
}

// Turns the text of an inline (or standalone) `<code>` span into something
// speakable, one whitespace-delimited token at a time — an inline span is
// often a whole shell command ("mix test --only repro"), which must still
// read as the command, tokenized normally, not as a single mangled blob.
export function speakCodeSpan(code) {
  return code
    .replace(CODE_BRACKET_RE, " ")
    .split(/\s+/)
    .filter(Boolean)
    .map(splitIdentifierToken)
    .join(" ")
}

// Walks a rendered message bubble and returns its speakable text. This is
// the DOM-extraction counterpart to cleanTextForTTS's inline-code/fence
// rules: by the time a bubble is rendered HTML, there are no backticks left
// for those regexes to see, so code-block/code-span handling has to happen
// here, at walk time, instead. `<pre>` subtrees (fenced code blocks) are
// dropped entirely and SILENTLY — no "code block" announcement, matching
// how tts_stream.js's accumulator withholds fenced content on the streaming
// path. Written against only nodeType/nodeName/childNodes/textContent (the
// same shape on a real DOM node or a plain object literal) so it's
// exercisable from the node-only check script.
export function extractSpeakableFromElement(el) {
  let out = ""
  const walk = (node) => {
    if (!node) return
    if (node.nodeType === 3) { // TEXT_NODE
      out += node.textContent || ""
      return
    }
    if (node.nodeType !== 1) return // skip comments etc.
    const tag = (node.nodeName || "").toUpperCase()
    if (tag === "PRE") return // fenced code block: silent, not read aloud
    if (tag === "BR") {
      out += "\n"
      return
    }
    if (tag === "CODE") {
      out += speakCodeSpan(node.textContent || "")
      return
    }
    for (const child of node.childNodes || []) walk(child)
    if (BLOCK_TAGS.has(tag)) out += "\n\n"
  }
  walk(el)
  return out
}

export function cleanTextForTTS(text) {
  // Strip markdown artifacts that innerText might preserve
  text = text.replace(/^#{1,6}\s+/gm, "")          // markdown headers
  text = text.replace(/```[\s\S]*?```/g, "")        // code blocks (only ever
                                                      // fires on the streaming
                                                      // path — a rendered
                                                      // bubble's backticks are
                                                      // long gone by the time
                                                      // extractSpeakableFromElement
                                                      // hands text here)
  text = text.replace(/`([^`]+)`/g, (m, content) => speakCodeSpan(content)) // inline code

  // Elixir/programming term pronunciations (run BEFORE path/hash replacements)
  for (const [term, replacement] of Object.entries(TERM_MAP)) {
    text = text.replace(new RegExp(`\\b${term}\\b`, "g"), replacement)
  }

  // Symbols
  text = text.replace(/->/g, " to ")

  // Units attached to a number (5 KB/s, 12ms, 50%, ...)
  text = replaceUnits(text)

  // UUIDs, then bare git-style hashes (UUIDs first so their hex segments
  // aren't re-matched by the bare-hash rule below)
  text = replaceUuids(text)
  text = replaceHashes(text)

  // File paths with directories: extract just the filename. Three shapes,
  // in order:
  //  1. absolute paths (leading slash) — any number of directory segments,
  //     final segment need not have an extension. Requires a leading slash
  //     as its unambiguous "this is a path" signal, and a lookbehind makes
  //     sure that slash isn't just the interior separator of a relative
  //     path (without it, "lib/orca_hub/tts.ex" matches starting at the
  //     "/" after "lib", stranding "lib" as an unmangled prefix — the
  //     original bug, just relocated to this rule instead of removed).
  //  2. relative paths whose FINAL segment has a file extension — the
  //     extension is itself an unambiguous filename signal, so one slash
  //     is enough ("lib/tts.ex"). Deliberately does NOT require a leading
  //     slash, and so must not require one at the match start either, or
  //     it reproduces the absolute-only bug this replaced: matching would
  //     be forced to start AT an interior slash, stranding the segment
  //     before it (e.g. "lib/orca_hub/tts.ex" -> "lib" + "orca_hub" eaten
  //     mid-word -> "liborca hub dot ex"). Leaving the start unanchored
  //     lets the engine try from index 0, consuming the whole path.
  //  3. relative, directory-only (no extension on the final segment) —
  //     needs two or more slashes. A single slash here is indistinguishable
  //     from ordinary prose ("and/or", "24/7"), so it is deliberately left
  //     alone; two or more is unambiguous enough to treat as a path
  //     ("priv/static/assets").
  const stripPathDirs = (filename) =>
    filename
      .replace(/_/g, " ")
      .replace(/\.(\w+)$/, (m, ext) => ` dot ${pronounceExtension(ext)}`)
  text = text.replace(/(?<![\w.-])(?:\/[\w.-]+)+\/([\w.-]+)/g, (match, filename) => stripPathDirs(filename))
  text = text.replace(/(?:[\w.-]+\/)+([\w.-]+\.[A-Za-z0-9]+)/g, (match, filename) => stripPathDirs(filename))
  text = text.replace(/(?:[\w.-]+\/){2,}([\w.-]+)/g, (match, filename) => stripPathDirs(filename))

  // Standalone filenames (word.ext): "show.ex" -> "show dot ex"
  const extAlternation = Object.keys(EXTENSION_MAP).join("|")
  text = text.replace(new RegExp(`\\b(\\w[\\w-]*)\\.(${extAlternation})\\b`, "g"),
    (match, name, ext) => `${name.replace(/_/g, " ")} dot ${pronounceExtension(ext)}`
  )

  // Remaining underscores to spaces (variable names etc.)
  text = text.replace(/_/g, " ")

  // Text with no real content at all — e.g. extractSpeakableFromElement on a
  // bubble that's entirely a dropped <pre>, which contributes nothing but
  // its own trailing block-boundary newlines ("\n\n") — must come back as
  // the empty string, not fall into the blank-line -> ". " rule below and
  // come out as a stray "." (see the module header comment's INVARIANT
  // note: a truthy "." would defeat ttsStart's `if (!text) return` gate).
  // Checked here rather than folded into the generic whitespace cleanup so
  // real content keeps its existing trailing-period behaviour untouched.
  if (!text.trim()) return ""

  // Clean up excessive whitespace
  text = text.replace(/\n{2,}/g, ". ")
  text = text.replace(/\s+/g, " ")

  return text.trim()
}
