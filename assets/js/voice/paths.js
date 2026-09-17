/* Where the voice runtime's non-bundled assets live.
 *
 * `assets.build` / `assets.deploy` copy them into priv/static/assets/voice/
 * (see the `orca_hub_voice` esbuild profile in config/config.exs):
 *
 *   capture-worklet.js            our AudioWorklet (must be a separate file:
 *                                 audioWorklet.addModule() takes a URL)
 *   ort-wasm-simd-threaded.mjs    onnxruntime-web's emscripten glue
 *   ort-wasm-simd-threaded.wasm   onnxruntime-web's wasm binary (~14 MB raw)
 *   silero_vad_v5.onnx            the VAD model (~2.3 MB)
 *
 * `mix phx.digest` writes BOTH a digested copy and the original name, so the
 * plain names below keep resolving in prod. ort and the model are fetched by
 * name by code we do not control the URL construction of end-to-end, so we
 * deliberately use the UNdigested path and buy back immutable caching with a
 * `?vsn=` query string: Plug.Static answers any request whose query string
 * starts with `vsn=` with `cache_control_for_vsn_requests`
 * ("public, max-age=31536000, immutable"). The vsn value is the pinned
 * upstream version, so bumping the dependency busts the cache — a plain
 * `?vsn=d` would not, because these filenames carry no version.
 */

export const VOICE_ASSET_BASE = "/assets/voice/"

// Keep in sync with assets/package.json (both pinned exactly).
export const ORT_VERSION = "1.29.0"
export const VAD_WEB_VERSION = "0.0.31"

export function ortWasmPaths() {
  return {
    wasm: `${VOICE_ASSET_BASE}ort-wasm-simd-threaded.wasm?vsn=ort${ORT_VERSION}`,
    mjs: `${VOICE_ASSET_BASE}ort-wasm-simd-threaded.mjs?vsn=ort${ORT_VERSION}`,
  }
}

export function sileroModelUrl() {
  return `${VOICE_ASSET_BASE}silero_vad_v5.onnx?vsn=vad${VAD_WEB_VERSION}`
}

// Our own source, so no immutable cache — it changes between deploys and its
// name does not. ETag revalidation on ~3 KB is free.
export function captureWorkletUrl() {
  return `${VOICE_ASSET_BASE}capture-worklet.js`
}
