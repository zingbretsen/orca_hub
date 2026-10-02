/* The session page's mobile voice view (ORCAHUB3-113 phase C) — the hook
 * mounted on `#voice-view` in session_live/show.html.heex.
 *
 * Placeholder: registered early so the app.js seam (import + register) lands
 * in its own commit while the sibling workers edit app.js. The real hook
 * replaces this body; the export name and the `VoiceView` registration are
 * the contract.
 */
export const VoiceViewHook = {
  mounted() {},
  destroyed() {},
}
