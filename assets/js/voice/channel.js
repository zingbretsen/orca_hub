/* Voice channel client — the transport half of the pinned contract (spec 8.1).
 *
 * Reuses the existing UserSocket at /terminal_socket via the same shared
 * `window.__terminalSocket` that assets/js/terminal_hook.js opens, so voice
 * mode never adds a second WebSocket.
 *
 * Topic is `voice:<session_id>` with NO client_ref suffix — unlike terminals,
 * there must be exactly ONE voice owner per session, and a second join from any
 * tab is rejected by the server with reason "voice_owned".
 */

import { Socket } from "phoenix"

export function sharedSocket() {
  if (!window.__terminalSocket) {
    window.__terminalSocket = new Socket("/terminal_socket")
    window.__terminalSocket.connect()
  }
  return window.__terminalSocket
}

export const JOIN_ERRORS = {
  not_found: "That session no longer exists.",
  voice_owned: "Voice mode is already open for this session in another tab or window.",
  node_unavailable:
    "The node this session runs on is offline. Voice mode will not re-route it to another node.",
  archived: "This session is archived.",
}

export class VoiceChannel {
  constructor(sessionId, handlers = {}) {
    this.sessionId = sessionId
    this.handlers = handlers
    this.channel = null
    this.seq = 0
  }

  join() {
    const socket = sharedSocket()
    this.channel = socket.channel(`voice:${this.sessionId}`)

    this.channel.on("state", (state) => this.handlers.onState && this.handlers.onState(state))
    this.channel.on(
      "segment_result",
      (r) => this.handlers.onSegmentResult && this.handlers.onSegmentResult(r)
    )
    this.channel.on("sent", (m) => this.handlers.onSent && this.handlers.onSent(m))
    // Spec 8.2 / ORCAHUB3-86: the server asks the CLIENT to deliver the draft
    // through the page's real composer, so staged uploads and the
    // "[Attached image: ...]" lines ride along. Answered with sent_ack /
    // send_failed / send_direct.
    this.channel.on(
      "send_request",
      (m) => this.handlers.onSendRequest && this.handlers.onSendRequest(m)
    )

    return new Promise((resolve, reject) => {
      this.channel
        .join()
        .receive("ok", (resp) => {
          if (resp && resp.state && this.handlers.onState) this.handlers.onState(resp.state)
          resolve(resp)
        })
        .receive("error", (resp) => {
          const reason = (resp && resp.reason) || "unknown"
          reject(new Error(JOIN_ERRORS[reason] || `Could not open voice mode (${reason}).`))
        })
        .receive("timeout", () => reject(new Error("Timed out opening the voice channel.")))
    })
  }

  joined() {
    return !!this.channel && this.channel.state === "joined"
  }

  push(event, payload = {}) {
    if (!this.joined()) return null
    return this.channel.push(event, payload)
  }

  /** Binary push. Phoenix's serializer sends an ArrayBuffer payload as a raw
   * binary frame; the server sees `handle_in("segment", {:binary, bin}, _)`. */
  pushSegment(arrayBuffer) {
    if (!this.joined()) return null
    return this.channel.push("segment", arrayBuffer)
  }

  nextSeq() {
    return ++this.seq
  }

  leave() {
    if (this.channel) {
      try {
        this.channel.leave()
      } catch (_e) {
        /* socket may already be gone */
      }
      this.channel = null
    }
  }
}
