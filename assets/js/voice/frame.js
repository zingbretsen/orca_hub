/* The OVS1 binary segment frame — the pinned voice channel contract (spec 8.1).
 *
 * Little-endian, 20-byte header, then raw 16 kHz mono int16 PCM:
 *
 *   0..3    magic  "OVS1"
 *   4..7    seq            u32  per-channel, monotonically increasing from 1
 *   8..11   start_sample   u32  absolute 16 kHz index of the first PCM sample
 *   12..15  sample_count   u32  int16 samples that follow
 *   16..19  flags          u32  bit0 forced_end, bit1 padded
 *
 * The client ships RAW PCM; the SERVER wraps it in a WAV header for the ASR
 * upload. No base64 anywhere — Phoenix carries ArrayBuffer payloads natively.
 */

export const MAGIC = "OVS1"
export const HEADER_BYTES = 20

export const FLAG_FORCED_END = 1 << 0
export const FLAG_PADDED = 1 << 1

export const TARGET_RATE = 16000
/** Client-side hard cap: the segment is split (bit0) as it approaches 18 s. */
export const MAX_SEGMENT_SAMPLES = 18 * TARGET_RATE
/** Below this a completed segment is extended from the ring buffer (bit1).
 * Sub-0.8 s clips are the real hallucination mode on this ASR endpoint. */
export const MIN_SEGMENT_SAMPLES = Math.round(0.8 * TARGET_RATE)

export function floatToInt16(f32, dv, byteOffset) {
  let o = byteOffset
  for (let i = 0; i < f32.length; i++) {
    const s = Math.max(-1, Math.min(1, f32[i]))
    dv.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7fff, true)
    o += 2
  }
  return o
}

export function buildSegmentFrame({ seq, startSample, samples, flags = 0 }) {
  const n = samples.length
  const buf = new ArrayBuffer(HEADER_BYTES + n * 2)
  const dv = new DataView(buf)
  for (let i = 0; i < 4; i++) dv.setUint8(i, MAGIC.charCodeAt(i))
  dv.setUint32(4, seq >>> 0, true)
  dv.setUint32(8, startSample >>> 0, true)
  dv.setUint32(12, n >>> 0, true)
  dv.setUint32(16, flags >>> 0, true)
  floatToInt16(samples, dv, HEADER_BYTES)
  return buf
}

/** Inverse of buildSegmentFrame — used by the headless checks, and handy when
 * eyeballing a frame in the console. */
export function parseSegmentFrame(buf) {
  const dv = new DataView(buf)
  let magic = ""
  for (let i = 0; i < 4; i++) magic += String.fromCharCode(dv.getUint8(i))
  const sampleCount = dv.getUint32(12, true)
  const samples = new Float32Array(sampleCount)
  for (let i = 0; i < sampleCount; i++) {
    samples[i] = dv.getInt16(HEADER_BYTES + i * 2, true) / 0x8000
  }
  return {
    magic,
    seq: dv.getUint32(4, true),
    startSample: dv.getUint32(8, true),
    sampleCount,
    flags: dv.getUint32(16, true),
    samples,
  }
}
