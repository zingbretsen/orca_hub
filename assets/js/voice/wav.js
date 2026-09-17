/* 16-bit PCM WAV encoding.
 *
 * The production path does NOT need this — the client ships raw PCM in an OVS1
 * frame and the server adds the 44-byte header for its multipart upload. It
 * exists for offline verification: the headless capture check dumps segments to
 * WAV and measures their speech onset the same way spikes/voice/harness.js
 * does, which is how the pre-roll (spec section 9 trap 4) is proved present.
 * Nothing in the app bundle imports it, so esbuild leaves it out.
 */

import { floatToInt16, TARGET_RATE } from "./frame"

export function encodeWav(f32, sampleRate = TARGET_RATE) {
  const n = f32.length
  const buf = new ArrayBuffer(44 + n * 2)
  const dv = new DataView(buf)
  const str = (o, s) => {
    for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i))
  }
  str(0, "RIFF")
  dv.setUint32(4, 36 + n * 2, true)
  str(8, "WAVE")
  str(12, "fmt ")
  dv.setUint32(16, 16, true)
  dv.setUint16(20, 1, true) // PCM
  dv.setUint16(22, 1, true) // mono
  dv.setUint32(24, sampleRate, true)
  dv.setUint32(28, sampleRate * 2, true)
  dv.setUint16(32, 2, true)
  dv.setUint16(34, 16, true)
  str(36, "data")
  dv.setUint32(40, n * 2, true)
  floatToInt16(f32, dv, 44)
  return buf
}

const rms = (x) => {
  let s = 0
  for (let i = 0; i < x.length; i++) s += x[i] * x[i]
  return Math.sqrt(s / (x.length || 1))
}

export const dbfs = (x) => 20 * Math.log10(Math.max(rms(x), 1e-12))

/** Position (ms) of the first 10 ms window within `relDb` of the peak — the
 * measurement that tells you whether the pre-roll actually made it in. */
export function onsetMs(f32, sampleRate = TARGET_RATE, relDb = -25) {
  const win = Math.round(sampleRate * 0.01)
  const n = Math.floor(f32.length / win)
  const e = []
  let peak = -Infinity
  for (let i = 0; i < n; i++) {
    const d = dbfs(f32.subarray(i * win, (i + 1) * win))
    e.push(d)
    if (d > peak) peak = d
  }
  const thr = peak + relDb
  for (let i = 0; i < n; i++) if (e[i] > thr) return +(i * 10).toFixed(1)
  return null
}
