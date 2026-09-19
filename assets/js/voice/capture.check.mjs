// Standalone checks for the runtime-configurable capture constraints
// (voice_mode_spec.md §4, ORCAHUB3-105). The repo has no JS test runner, so
// this is a plain node script, same convention as tts_stream.check.mjs:
//
//     node assets/js/voice/capture.check.mjs
//
// Exits non-zero on the first broken expectation. It is the only executable
// proof that what the hub resolves is what `getUserMedia` is actually asked
// for — a real browser cannot answer the question this issue is about
// (headless Chrome has no audio routing), but it can and must answer whether
// the constraint object arrives intact.
import {
  AUDIO_CONSTRAINTS,
  DEFAULT_TUNABLE_CONSTRAINTS,
  FIXED_CONSTRAINTS,
  audioConstraints,
  Capture,
} from "./capture.js"

let pass = 0,
  fail = 0
const eq = (name, got, want) => {
  const g = JSON.stringify(got),
    w = JSON.stringify(want)
  if (g === w) {
    pass++
    console.log(`  ok   ${name}`)
  } else {
    fail++
    console.log(`  FAIL ${name}\n       got  ${g}\n       want ${w}`)
  }
}

// The literal `AUDIO_CONSTRAINTS` held before ORCAHUB3-105 split it. Written
// out by hand on purpose: if the defaults ever drift, this is the thing that
// notices. The server side asserts the same shape from the Elixir end
// (test/orca_hub/asr_config_test.exs reads this very file).
const SHIPPED_BEFORE = {
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
  channelCount: 1,
  voiceIsolation: false,
}

// 1. defaults are unchanged — shipping the knob changes nothing
eq("AUDIO_CONSTRAINTS is what we shipped", AUDIO_CONSTRAINTS, SHIPPED_BEFORE)
eq("no server value -> shipped defaults", audioConstraints(undefined), SHIPPED_BEFORE)
eq("empty server value -> shipped defaults", audioConstraints({}), SHIPPED_BEFORE)

// 2. a configured value wins, per field, and the rest stay on the defaults
eq("echoCancellation false is honoured", audioConstraints({ echoCancellation: false }), {
  ...SHIPPED_BEFORE,
  echoCancellation: false,
})
eq(
  "all three configurable independently",
  audioConstraints({ echoCancellation: false, noiseSuppression: false, autoGainControl: true }),
  { ...SHIPPED_BEFORE, echoCancellation: false, noiseSuppression: false }
)

// 3. the wire cannot inject or override anything else
eq("unknown keys ignored", audioConstraints({ sampleRate: 8000, deviceId: "x" }), SHIPPED_BEFORE)
eq(
  "the pinned constraints are not overridable",
  audioConstraints({ channelCount: 2, voiceIsolation: true }),
  SHIPPED_BEFORE
)
eq(
  "non-boolean values fall back rather than reaching getUserMedia",
  audioConstraints({ echoCancellation: "false", noiseSuppression: 0, autoGainControl: null }),
  SHIPPED_BEFORE
)
eq("a non-object payload is ignored", audioConstraints("nope"), SHIPPED_BEFORE)
eq("null is ignored", audioConstraints(null), SHIPPED_BEFORE)

// 4. ...and that object is the one `open()` hands getUserMedia. This is the
//    end of the plumbing: hub -> join reply -> hook -> Capture -> the API.
{
  const calls = []
  globalThis.window = { isSecureContext: true, location: { origin: "https://test" } }
  // node ships a real `navigator` with only a getter, so define rather than
  // assign — the module reads `navigator.mediaDevices` off the global.
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      mediaDevices: {
        getUserMedia: async (opts) => {
          calls.push(opts)
          return { getAudioTracks: () => [] }
        },
      },
    },
  })
  globalThis.AudioContext = class {
    constructor() {
      this.state = "running"
    }
    async resume() {}
  }

  const capture = new Capture({ constraints: { echoCancellation: false } })
  await capture.open()

  eq("open() requests exactly one stream", calls.length, 1)
  eq("open() passes the resolved constraints", calls[0], {
    audio: { ...SHIPPED_BEFORE, echoCancellation: false },
  })

  const plain = new Capture({})
  await plain.open()
  eq("an unconfigured Capture still asks for the defaults", calls[1], { audio: SHIPPED_BEFORE })
}

// 5. the hook's two wiring lines. A STATIC check, and labelled as one: the
//    hook itself cannot be imported under node (it pulls in onnxruntime and
//    the phoenix socket), and the one thing a headless browser could add here
//    — whether the OS actually re-routes audio — is precisely what headless
//    Chrome cannot observe, having no audio routing at all. So this asserts
//    the two lines that connect the join reply to `Capture` are still there,
//    rather than pretending to measure them.
{
  const { readFileSync } = await import("node:fs")
  const hook = readFileSync(new URL("./voice_hook.js", import.meta.url), "utf8")

  eq(
    "the join reply is read into this.audioConstraints",
    /_readAudioConstraints\(reply\)/.test(hook) &&
      /this\.audioConstraints = next/.test(hook),
    true
  )
  eq(
    "_arm() hands them to Capture",
    /new Capture\(\{[^}]*constraints: this\.audioConstraints/s.test(hook),
    true
  )
}

// 6. the split is exhaustive — no constraint got dropped on the way through
eq(
  "tunable + fixed covers every key",
  Object.keys({ ...DEFAULT_TUNABLE_CONSTRAINTS, ...FIXED_CONSTRAINTS }).sort(),
  Object.keys(SHIPPED_BEFORE).sort()
)

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
