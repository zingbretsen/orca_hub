// Standalone checks for the TTS text normalizer (`cleanTextForTTS`). The
// repo has no JS test runner, so this is a plain node script:
//
//     node assets/js/tts_text.check.mjs
//
// Exits non-zero on the first broken expectation. Keep it in sync with the
// rules in tts_text.js.
import {
  cleanTextForTTS, HASH_SPOKEN_CHARS, EXTENSION_MAP, TERM_MAP,
  speakCodeSpan, extractSpeakableFromElement, splitIntoChunksWithOffsets, resolveChunkRange,
} from "./tts_text.js"

let pass = 0, fail = 0
const eq = (name, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g === w) { pass++; console.log(`  ok   ${name}`) }
  else { fail++; console.log(`  FAIL ${name}\n       got  ${g}\n       want ${w}`) }
}

// -- regressions: behaviour that already existed ----------------------------

eq("term map: GenServer", cleanTextForTTS("a GenServer crashed"), "a gen server crashed")
eq("term map: iex", cleanTextForTTS("open iex"), "open I E X")
eq("symbol: arrow", cleanTextForTTS("a -> b"), "a to b")
eq("path to filename", cleanTextForTTS("see /lib/orca_hub/session_runner.ex for it"),
   "see session runner dot ex for it")
eq("underscores in prose", cleanTextForTTS("the foo_bar variable"), "the foo bar variable")
eq("markdown header stripped", cleanTextForTTS("# Title\nbody"), "Title body")
eq("code block dropped", cleanTextForTTS("before\n```\ncode\n```\nafter"), "before. after")
eq("inline code keeps content", cleanTextForTTS("run `mix test` now"), "run mix test now")

// -- A. extension pronunciation ---------------------------------------------

eq("standalone .ex", cleanTextForTTS("open show.ex"), "open show dot ex")
eq("standalone .md", cleanTextForTTS("read README.md"), "read README dot markdown")
eq("standalone .py", cleanTextForTTS("run foo.py"), "run foo dot pie")
eq("standalone .exs", cleanTextForTTS("script.exs"), "script dot ex s")
eq("standalone .mjs newly added to alternation", cleanTextForTTS("bundle.mjs"), "bundle dot M J S")
eq("standalone .lock newly added to alternation", cleanTextForTTS("mix.lock"), "mix dot lock")
eq("standalone .json", cleanTextForTTS("data.json"), "data dot jason")
eq("standalone .yml", cleanTextForTTS("ci.yml"), "ci dot yamel")
eq("standalone .html", cleanTextForTTS("index.html"), "index dot H T M L")
eq("path with known extension", cleanTextForTTS("see /a/b/foo.md here"), "see foo dot markdown here")
eq("path with unknown extension keeps raw text (no invented pronunciation)",
   cleanTextForTTS("see /a/b/archive.rar here"), "see archive dot rar here")
eq("standalone unknown extension untouched (unchanged from before)",
   cleanTextForTTS("archive.rar"), "archive.rar")
eq(".heex file: term map does not swallow the dot",
   cleanTextForTTS("HEEx templates live in show.heex"), "heeks templates live in show dot heeks")
eq("lowercase heex in prose (not a filename) is left alone — a deliberate narrowing, see TERM_MAP comment",
   cleanTextForTTS("the heex templating language"), "the heex templating language")

// -- B. git hashes / UUIDs ---------------------------------------------------

eq("bare hash: digit+letter always counts, no keyword needed", cleanTextForTTS("landed at 4dc631d today"),
   "landed at 4 D C 6 today")
eq("hash after keyword with intervening paren", cleanTextForTTS("see commit (4dc631d) for the fix"),
   "see commit (4 D C 6) for the fix")
eq("hash after keyword with intervening unmatched backtick (streaming partial chunk)",
   cleanTextForTTS("sha `4dc631d is the fix"), "sha `4 D C 6 is the fix")
eq("pure-letter hex NOT rewritten without a keyword", cleanTextForTTS("we deadbeef today"), "we deadbeef today")
eq("pure-letter hex IS rewritten with a keyword", cleanTextForTTS("ref deadbeef is old"), "ref D E A D is old")
eq("pure-digit token is not a hash without a keyword", cleanTextForTTS("there are 1234567 items"),
   "there are 1234567 items")
eq("pure-digit token IS a hash with a keyword", cleanTextForTTS("revision 1234567 broke it"),
   "revision 1 2 3 4 broke it")
eq("plain english word, no digit, no keyword: untouched", cleanTextForTTS("cafebabe"), "cafebabe")
eq("HASH_SPOKEN_CHARS tuning knob is 4", HASH_SPOKEN_CHARS, 4)
eq("uuid rewritten to first HASH_SPOKEN_CHARS chars",
   cleanTextForTTS("session 8f14e45f-ceea-467e-adde-cd0f0143ea0d done"), "session 8 F 1 4 done")
eq("uuid rule runs before bare-hash rule (no double match on its hex segments)",
   cleanTextForTTS("id 8f14e45f-ceea-467e-adde-cd0f0143ea0d"), "id 8 F 1 4")

// -- C. units -----------------------------------------------------------

eq("Hz invariant, count 1", cleanTextForTTS("1 Hz"), "1 hertz")
eq("Hz invariant, count > 1", cleanTextForTTS("60 Hz"), "60 hertz")
eq("GHz with decimal", cleanTextForTTS("a 3.5GHz chip"), "a 3.5 gigahertz chip")
eq("ms singular", cleanTextForTTS("wait 1ms"), "wait 1 millisecond")
eq("ms plural", cleanTextForTTS("wait 250ms"), "wait 250 milliseconds")
eq("ns plural", cleanTextForTTS("12 ns"), "12 nanoseconds")
eq("MB singular", cleanTextForTTS("a 1 MB file"), "a 1 megabyte file")
eq("MB plural", cleanTextForTTS("a 12 MB file"), "a 12 megabytes file")
eq("case matters: lowercase mb untouched", cleanTextForTTS("12 mb of foo"), "12 mb of foo")
eq("KB/s rate tried before bare KB in the alternation", cleanTextForTTS("throughput 5 KB/s"),
   "throughput 5 kilobytes per second")
eq("Mbps invariant per-second phrase", cleanTextForTTS("a 100 Mbps link"), "a 100 megabits per second link")
eq("px plural", cleanTextForTTS("a 200px wide box"), "a 200 pixels wide box")
eq("px singular", cleanTextForTTS("a 1px border"), "a 1 pixel border")
eq("fps invariant", cleanTextForTTS("running at 60fps"), "running at 60 frames per second")
eq("rpm invariant", cleanTextForTTS("2000 rpm"), "2000 revolutions per minute")
eq("percent before a word (no \\b needed after %)", cleanTextForTTS("50% done"), "50 percent done")
eq("percent before punctuation (the literal \\b template would fail here)",
   cleanTextForTTS("it's 100%."), "it's 100 percent.")
eq("comma-grouped thousands still pluralizes (not exactly \"1\")",
   cleanTextForTTS("1,000 MB"), "1,000 megabytes")
eq("bare s/m/h left alone — too ambiguous", cleanTextForTTS("wait 5s or 3m or 1h"), "wait 5s or 3m or 1h")

// -- D. ordering / no rule eats another's input ------------------------------

eq("hash resolved before the path regex ever sees it",
   cleanTextForTTS("commit 4dc631d touched /lib/foo/bar.ex"), "commit 4 D C 6 touched bar dot ex")
eq("unit rewrite does not create a token the filename regex re-splits",
   cleanTextForTTS("download.py is 12MB"), "download dot pie is 12 megabytes")
eq("relative path, 2+ segments with extension (the pre-existing defect)",
   cleanTextForTTS("see lib/orca_hub/tts.ex for it"), "see tts dot ex for it")
eq("relative path, 1 slash + extension", cleanTextForTTS("edit assets/js/app.js"), "edit app dot J S")
eq("absolute path (regression, unchanged from before)",
   cleanTextForTTS("see /a/b/foo.md here"), "see foo dot markdown here")
eq("relative directory-only path, 2+ slashes", cleanTextForTTS("in priv/static/assets"), "in assets")
eq("relative path with 1 slash, no extension: left alone (ambiguous with prose)",
   cleanTextForTTS("and/or"), "and/or")
eq("fraction-looking text with 1 slash, no extension: left alone",
   cleanTextForTTS("open 24/7"), "open 24/7")

// -- E. speakCodeSpan: identifier splitting inside code spans ---------------

eq("code span: bracket punctuation collapsed to spaces", speakCodeSpan("%{foo: 1}"), "% foo: 1")
eq("code span: a whole shell command tokenizes normally, not mangled as one blob",
   speakCodeSpan("mix test --only repro"), "mix test --only repro")
eq("code span: PascalCase split on case transitions", speakCodeSpan("SessionRunner"), "Session Runner")
eq("code span: camelCase split on case transitions", speakCodeSpan("handleEvent"), "handle Event")
eq("code span: acronym-run then PascalCase boundary", speakCodeSpan("TTSPlayer"), "TTS Player")
eq("code span: snake_case split on internal underscore", speakCodeSpan("my_var"), "my var")
eq("code span: a flag is left alone (dash, no case/underscore transition)",
   speakCodeSpan("--skip-arm64"), "--skip-arm64")
eq("code span: a path is left untouched so the downstream path rule can still resolve it",
   speakCodeSpan("lib/orca_hub/tts.ex"), "lib/orca_hub/tts.ex")

eq("inline code backtick rule speaks the span instead of reading it verbatim",
   cleanTextForTTS("call `handleEvent` please"), "call handle Event please")
eq("inline code containing a path still resolves through the path rule afterwards",
   cleanTextForTTS("see `lib/orca_hub/tts.ex` here"), "see tts dot ex here")

// -- F. extractSpeakableFromElement: DOM walk (pre dropped, code spoken) ----
// Hand-built fake-DOM object literals — nodeType/nodeName/childNodes/
// textContent only, the same shape a real DOM node exposes, so the walker
// under test never knows the difference. Unlike a real element, a plain
// object literal has no computed textContent, so fixtures set it explicitly
// on every element (not just text nodes) wherever the walker reads it.
const textNode = (s) => ({ nodeType: 3, textContent: s })
const elNode = (name, children, textContent) => ({ nodeType: 1, nodeName: name, childNodes: children, textContent })
// extractSpeakableFromElement returns { text, spans } (provenance for the
// highlight feature) — most of section F only cares about the text.
const extractText = (el) => extractSpeakableFromElement(el).text

eq("extractSpeakableFromElement: a <pre> subtree vanishes silently, no announcement",
   cleanTextForTTS(extractText(elNode("DIV", [
     textNode("before "),
     elNode("PRE", [elNode("CODE", [textNode("secret_code_here")], "secret_code_here")], "secret_code_here"),
     textNode(" after"),
   ]))),
   "before after.")
eq("extractSpeakableFromElement: an inline <code> span is routed through speakCodeSpan",
   cleanTextForTTS(extractText(elNode("DIV", [
     textNode("Rename "),
     elNode("CODE", [textNode("SessionRunner")], "SessionRunner"),
     textNode(" please"),
   ]))),
   "Rename Session Runner please.")
eq("INVARIANT: a message that is entirely a fenced code block extracts to the empty string, " +
   "not a stray \".\" — ttsStart's `if (!text) return` gate depends on this to stay a no-op " +
   "(no playback, no ttsEmitState, no half-started player) instead of emitting {playing: true} " +
   "with nothing to guarantee a matching {playing: false} (see tts_text.js's header comment)",
   cleanTextForTTS(extractText(elNode("DIV", [
     elNode("PRE", [elNode("CODE", [textNode("defmodule Foo do\n  :ok\nend")], "defmodule Foo do\n  :ok\nend")],
       "defmodule Foo do\n  :ok\nend"),
   ]))),
   "")

// -- G. splitIntoChunksWithOffsets / resolveChunkRange (highlight feature) --

{
  const bubble = elNode("DIV", [
    textNode("Run "),
    elNode("CODE", [textNode("mix test")], "mix test"),
    textNode(" then check the file. It matters a lot for correctness across the whole test suite, honestly."),
  ])
  const { text, spans } = extractSpeakableFromElement(bubble)
  const chunks = splitIntoChunksWithOffsets(text)
  eq("splitIntoChunksWithOffsets: one chunk for a short message (under the 80-char threshold)",
     chunks.length, 1)
  eq("splitIntoChunksWithOffsets: chunk text matches the raw slice at its own offsets",
     chunks[0].text, text.slice(chunks[0].start, chunks[0].end))
  const range = resolveChunkRange(spans, chunks[0].start, chunks[0].end)
  eq("resolveChunkRange: a chunk starting inside plain text resolves to that text node",
     range.startNode.nodeType, 3)
  eq("resolveChunkRange: start offset 0 for a chunk starting at the very first character",
     range.startOffset, 0)
}

{
  // A chunk that starts AND ends inside the same <code> span: coarse "node"
  // mode selects the whole node's contents via (node, 0)..(node,
  // childNodes.length) rather than a character offset.
  const bubble = elNode("DIV", [elNode("CODE", [textNode("SessionRunner")], "SessionRunner")])
  const { text, spans } = extractSpeakableFromElement(bubble)
  const chunks = splitIntoChunksWithOffsets(text)
  const range = resolveChunkRange(spans, chunks[0].start, chunks[0].end)
  eq("resolveChunkRange: a code-only chunk resolves to the <code> node itself",
     range.startNode.nodeName, "CODE")
  eq("resolveChunkRange: a 'node'-mode start offset is 0 (before all children)",
     range.startOffset, 0)
  eq("resolveChunkRange: a 'node'-mode end offset is childNodes.length (after all children)",
     range.endOffset, range.endNode.childNodes.length)
}

{
  // Two sentences, each independently over the 80-char threshold, must
  // become two chunks with two DIFFERENT, correctly-ordered ranges.
  const bubble = elNode("DIV", [
    textNode("This is the first sentence and it is long enough on its own to trip the eighty character threshold rule."),
    textNode(" This is the second sentence, also long enough by itself to trip the same eighty character threshold rule again."),
  ])
  const { text, spans } = extractSpeakableFromElement(bubble)
  const chunks = splitIntoChunksWithOffsets(text)
  eq("splitIntoChunksWithOffsets: two long sentences become two chunks", chunks.length, 2)
  const r0 = resolveChunkRange(spans, chunks[0].start, chunks[0].end)
  const r1 = resolveChunkRange(spans, chunks[1].start, chunks[1].end)
  eq("resolveChunkRange: the second chunk's range starts after the first chunk's",
     r1.startOffset > r0.startOffset, true)
}

eq("resolveChunkRange: an empty/inverted range resolves to null rather than throwing",
   resolveChunkRange([{ start: 0, end: 5, node: textNode("hello"), mode: "text" }], 3, 3),
   null)

// splitIntoChunksWithOffsets chunks the RAW text and cleanTextForTTS is run
// per-chunk afterwards (see tts_text.js's header comment on why) — the OLD
// architecture cleaned the WHOLE text first and split the cleaned text.
// These two orders are not guaranteed identical: they can diverge whenever a
// cleaning rule changes a sentence's length enough to move which side of the
// 80-char threshold it lands on. Replicated inline (not imported) since
// production no longer has the old code path to import.
function oldCleanThenSplit(text) {
  const raw = cleanTextForTTS(text).split(/(?<=[.!?])\s+/)
  const minChars = 80
  const chunks = []
  let buffer = ""
  for (const sentence of raw) {
    buffer = buffer ? buffer + " " + sentence : sentence
    if (buffer.length >= minChars) { chunks.push(buffer.trim()); buffer = "" }
  }
  if (buffer.trim()) {
    if (chunks.length > 0 && buffer.trim().length < minChars) chunks[chunks.length - 1] += " " + buffer.trim()
    else chunks.push(buffer.trim())
  }
  return chunks
}
function newSplitThenClean(text) {
  return splitIntoChunksWithOffsets(text).map((c) => cleanTextForTTS(c.text))
}

{
  // A realistic sample: several sentences mixing prose, a relative path, a
  // git hash, and a unit — exactly the content this feature exists to
  // highlight correctly. On this sample the two orderings AGREE.
  const sample = "I looked into the bug you reported and found the root cause. It was in " +
    "lib/orca_hub/session_runner.ex, right where the timeout is computed. The fix landed in " +
    "commit 4dc631d, which also touched three other files across the module. After that change " +
    "the p50 latency dropped from 842ms to about 210ms in local testing. I also updated " +
    "priv/static/assets/js/app.js to match, since the old bundle still referenced the removed " +
    "export. Let me know if you see any regressions once this deploys, and I will keep an eye " +
    "on the dashboards for the rest of the day."
  eq("PARITY: raw-then-cleaned chunking matches cleaned-then-chunked on a realistic mixed sample",
     JSON.stringify(newSplitThenClean(sample)), JSON.stringify(oldCleanThenSplit(sample)))
}

{
  // KNOWN, REPORTED DIVERGENCE: a sentence containing a long path that
  // collapses drastically once cleaned (here, an absolute path down to just
  // its filename) can independently cross the 80-char threshold in its RAW
  // form and flush as its own chunk, even though the CLEANED text would
  // have stayed short enough to merge with the next sentence. Pinned here
  // as a known, accepted difference from chunking BEFORE cleaning — not a
  // bug to fix, since chunking after cleaning has no DOM positions left to
  // highlight (see tts_text.js's header comment).
  const sample = "See /some/very/long/absolute/path/to/a/deeply/nested/file/that/is/extremely/verbose/" +
    "for/testing/purposes/only.ex for details. This second sentence is deliberately plain prose " +
    "with no shrinkage at all from cleaning, long on its own."
  eq("DIVERGENCE (known, reported): old cleaned-then-split produces ONE merged chunk here",
     oldCleanThenSplit(sample).length, 1)
  eq("DIVERGENCE (known, reported): new raw-then-split produces TWO chunks here " +
     "(the raw path sentence alone already crosses 80 chars, before cleaning shrinks it)",
     newSplitThenClean(sample).length, 2)
}

eq("EXTENSION_MAP has exactly the spec's list",
   Object.keys(EXTENSION_MAP).sort().join(","),
   ["md", "txt", "py", "ex", "exs", "heex", "eex", "leex", "js", "mjs", "ts", "json", "yml", "yaml",
    "toml", "css", "html", "sh", "rb", "rs", "go", "lock"].sort().join(","))
eq("TERM_MAP's literal-word UUID entry is untouched", TERM_MAP["UUID"], "U U I D")

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
