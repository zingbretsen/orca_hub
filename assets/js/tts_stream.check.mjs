// Standalone checks for the streaming-TTS accumulator (voice_mode_spec.md
// §7.3 / C3). The repo has no JS test runner, so this is a plain node script:
//
//     node assets/js/tts_stream.check.mjs
//
// Exits non-zero on the first broken expectation. Keep it in sync with the
// thresholds in tts_stream.js — it is the only executable coverage the
// release/fence/threshold rules have.
import { createTtsStreamAccumulator, toolAnnouncement } from "./tts_stream.js"

let pass = 0, fail = 0
const eq = (name, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g === w) { pass++; console.log(`  ok   ${name}`) }
  else { fail++; console.log(`  FAIL ${name}\n       got  ${g}\n       want ${w}`) }
}

// 1. a short sentence is NOT released (< 40 chars)
{
  const a = createTtsStreamAccumulator(0)
  eq("short sentence holds", a.push("Hi there. ", 10), [])
}

// 2. a sentence >= 40 chars releases at the boundary, remainder stays
{
  const a = createTtsStreamAccumulator(0)
  const out = a.push("This sentence is definitely long enough to speak. And th", 10)
  eq("long sentence releases", out, ["This sentence is definitely long enough to speak."])
  eq("remainder held", a.push("", 11), [])
}

// 3. several short sentences coalesce into ONE chunk at the last boundary
{
  const a = createTtsStreamAccumulator(0)
  eq("coalesces to last boundary",
     a.push("One. Two. Three. Four. Five. Six. Seven. Eight. Nine and more text", 10),
     ["One. Two. Three. Four. Five. Six. Seven. Eight."])
}

// 4. no sentence end, buffer over 240 chars -> clause boundary release
{
  const a = createTtsStreamAccumulator(0)
  const long = "alpha beta gamma delta epsilon zeta eta theta, " .repeat(6)   // 276 chars, clause commas
  const out = a.push(long, 10)
  eq("clause release happened", out.length, 1)
  eq("clause chunk ends at a comma", out[0].endsWith(","), true)
}

// 5. idle release: >= 20 chars, >= 1500ms, cut at last whitespace
{
  const a = createTtsStreamAccumulator(0)
  a.push("a partial thought that never ends with punctuation", 100)
  eq("no idle release before 1500ms", a.tick(1000), [])
  eq("idle release after 1500ms", a.tick(1700), ["a partial thought that never ends with"])
}

// 6. idle release needs >= 20 chars
{
  const a = createTtsStreamAccumulator(0)
  a.push("too short", 0)
  eq("idle holds under 20 chars", a.tick(9999), [])
}

// 7. fenced code is never spoken, and the fence lines themselves are dropped
{
  const a = createTtsStreamAccumulator(0)
  eq("prose before the fence released on its own",
     a.push("Here is the fix for the crash you reported.\n", 10),
     ["Here is the fix for the crash you reported."])
  const during = a.push("```elixir\ndef foo, do: :bar\nIO.puts(\"hello world!\") \n", 20)
  eq("nothing from inside the fence", during, [])
  const after = a.push("```\nThat change makes the whole suite pass again.\n", 30)
  eq("prose after the fence released, code dropped",
     after, ["That change makes the whole suite pass again."])
}

// 8. a partial line that could still become a fence is held back
{
  const a = createTtsStreamAccumulator(0)
  eq("prose released", a.push("This is a long enough sentence to be spoken aloud.\n", 10),
     ["This is a long enough sentence to be spoken aloud."])
  eq("partial backticks do not leak", a.push("``", 20), [])
  eq("still nothing after the fence opens", a.push("`elixir\ncode here\n", 30), [])
}

// 9. flush drains the remainder
{
  const a = createTtsStreamAccumulator(0)
  a.push("a tail with no terminator", 10)
  eq("flush drains", a.flush(20), ["a tail with no terminator"])
  eq("flush is idempotent", a.flush(30), [])
}

// 10. flush inside an open fence drops the code
{
  const a = createTtsStreamAccumulator(0)
  a.push("Prose before the fence.\n```\nsecret code\n", 10)
  eq("unterminated fence dropped at flush", a.flush(20), ["Prose before the fence."])
}

// 11. tool announcements
eq("Bash", toolAnnouncement("Bash"), "running a command")
eq("Edit", toolAnnouncement("Edit"), "editing a file")
eq("Write", toolAnnouncement("Write"), "editing a file")
eq("Read", toolAnnouncement("Read"), "reading a file")
eq("Grep", toolAnnouncement("Grep"), "searching")
eq("Glob", toolAnnouncement("Glob"), "searching")
eq("WebSearch", toolAnnouncement("WebSearch"), "searching the web")
eq("WebFetch", toolAnnouncement("WebFetch"), "searching the web")
eq("mcp__ prefix", toolAnnouncement("mcp__orca__run_elixir"), "calling a tool")
eq("unknown", toolAnnouncement("Sparkle"), "running a tool")
eq("nil", toolAnnouncement(null), "running a tool")

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
