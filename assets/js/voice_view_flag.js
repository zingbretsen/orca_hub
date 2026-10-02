/* The mobile voice view's global flag (ORCAHUB3-113 phase C) — the one seam
 * every voice-view participant shares, kept in its own module so the Voice
 * hook, a page's layout hook and the TTS code all import THE same names.
 *
 * The view is three independent facts, all attributes on <html>:
 *
 *   data-voice-view="on"      voice mode is on — set by the Voice hook from
 *                             USER INTENT (`this.active`), never from
 *                             `_micLive()` (the OS can kill the mic while the
 *                             user still wants voice: D8 keeps the view up
 *                             with "Tap to resume") and never from
 *                             VoiceBarLive's `voice_on` assign (it resets to
 *                             false on a socket remount, ORCAHUB3-91).
 *   data-voice-layout="..."   the current PAGE draws a voice layout — set by
 *                             that page's own hook on mount, removed on
 *                             destroy or when the page suppresses it (C1: a
 *                             question that needs a tap answer). One flag,
 *                             each page draws its own (D11).
 *   VOICE_VIEW_MEDIA          a phone-width viewport (D2: desktop unchanged).
 *
 * <html> sits OUTSIDE every LiveView root, so no patch can ever strip these —
 * the reason they live there rather than on an element a LiveView renders.
 * The CSS half is the `voice-view` custom variant in assets/css/app.css,
 * which spells the same three conditions; change both together.
 *
 * `doc` / `win` are injectable so a node check script can drive this against
 * fakes; production callers omit them. */

export const VOICE_VIEW_MEDIA = "(max-width: 767px)"

/* The mic states the strip already distinguishes. "starting" = voice on, the
 * mic not yet granted; "live" = capturing; "released" = deliberately let go
 * during playback (ORCAHUB3-105, not a failure: D8 shows nothing for it);
 * "stopped" = voice on but the mic is gone (the OS killed it, or arming
 * failed) and only a tap can bring it back. */
export const VOICE_MIC_STATES = ["live", "released", "stopped", "starting"]

function root(doc) {
  const d = doc || (typeof document !== "undefined" ? document : null)
  return d && d.documentElement ? d.documentElement : null
}

export function setVoiceView(on, doc) {
  const html = root(doc)
  if (!html) return
  if (on) html.dataset.voiceView = "on"
  else delete html.dataset.voiceView
}

export function setVoiceLayout(name, doc) {
  const html = root(doc)
  if (!html) return
  if (name) html.dataset.voiceLayout = name
  else delete html.dataset.voiceLayout
}

/* Not part of the cross-worker contract's setter list (the Voice hook is its
 * only writer), but exported so a reader can import the state names rather
 * than retype them. An unknown state clears the attribute instead of
 * writing it, so a CSS rule keyed on a value can never match a typo. */
export function setVoiceMic(state, doc) {
  const html = root(doc)
  if (!html) return
  if (VOICE_MIC_STATES.includes(state)) html.dataset.voiceMic = state
  else delete html.dataset.voiceMic
}

export function voiceViewFlagOn(doc) {
  const html = root(doc)
  return !!(html && html.dataset.voiceView)
}

export function voiceViewMediaMatches(win) {
  const w = win || (typeof window !== "undefined" ? window : null)
  return !!(w && typeof w.matchMedia === "function" && w.matchMedia(VOICE_VIEW_MEDIA).matches)
}

/* `data-voice-mic`, derived — never latched. The inputs are the Voice hook's
 * own fields, read at each transition that already re-renders the strip.
 *
 * The one distinction that matters is "stopped" versus "starting", because
 * "stopped" puts a big "Tap to resume" over the voice view (D8): any state the
 * hook is still working its way out of by itself — joining the channel,
 * arming, the 250 ms coalesced repair, the repair itself, a release being
 * handed back — is "starting", or that button would flash on every toggle-on
 * and every screen unlock. "stopped" is what is left: voice is on, nothing is
 * capturing, and nothing is trying to — only a tap can bring it back.
 *
 * `live` outranks `starting`: if audio is flowing, the mic is live, whatever
 * else is in flight. `released` outranks both, because a deliberate release
 * (ORCAHUB3-105) is not a failure and must never read as one. */
export function voiceMicState({ active, released, live, starting } = {}) {
  if (!active) return null
  if (released) return "released"
  if (live) return "live"
  if (starting) return "starting"
  return "stopped"
}

/* C5: after a MANUAL picker retarget, does the screen follow? Only in voice
 * mode on a phone, and never to the page already on screen (that would be a
 * pointless navigation that re-mounts the page under the user). Auto-follow
 * never asks this at all: it is the PAGE moving the target, so the page is
 * already the one being shown. */
export function pickNavigates({ flagOn, mediaMatches, pageSessionId, pickedId } = {}) {
  if (!flagOn || !mediaMatches || !pickedId) return false
  return pageSessionId !== pickedId
}

/* Is the voice view actually on screen right now? Exactly the CSS variant's
 * condition, evaluated from JS: flag on, a page layout present, phone width.
 * A false here means the user is looking at a normal page (desktop, or a
 * page with no voice layout, or a suppressed one), whatever voice is doing. */
export function voiceViewShowing(doc, win) {
  const html = root(doc)
  return !!(html && html.dataset.voiceView && html.dataset.voiceLayout && voiceViewMediaMatches(win))
}
