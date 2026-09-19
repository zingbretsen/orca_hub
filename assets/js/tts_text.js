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
// and called from two sites (ttsExtractText, ttsStreamEnqueue).
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

export function cleanTextForTTS(text) {
  // Strip markdown artifacts that innerText might preserve
  text = text.replace(/^#{1,6}\s+/gm, "")          // markdown headers
  text = text.replace(/```[\s\S]*?```/g, "")        // code blocks
  text = text.replace(/`([^`]+)`/g, "$1")           // inline code (keep content)

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

  // Clean up excessive whitespace
  text = text.replace(/\n{2,}/g, ". ")
  text = text.replace(/\s+/g, " ")

  return text.trim()
}
