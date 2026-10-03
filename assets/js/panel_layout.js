/* Which of the session page's two file-panel shells is on screen
 * (ORCAHUB3-130).
 *
 * SessionLive.Show renders the file panel twice, a desktop column
 * (`hidden lg:flex`) and a phone bottom-sheet modal (`lg:hidden`), and CSS
 * shows one. A display:none iframe still loads and runs, so the server
 * renders an open ARTIFACT (its sandboxed iframe) into only the shell this
 * reports. Two channels carry it:
 *
 *   panel_layout connect param   computed on every join (app.js's LiveSocket
 *                                `params` function), so a reconnect after a
 *                                resize sends a fresh value;
 *   "panel_layout" event         PanelLayoutHook, pushed when the viewport
 *                                crosses the breakpoint while connected.
 *
 * A browser that can't answer (no matchMedia) sends null, and the server
 * falls back to rendering both shells: a duplicate, never a blank panel.
 *
 * `win` is injectable so panel_layout.check.mjs can drive this against
 * fakes; production callers omit it. */

/* Mirrors the CSS `lg:` breakpoint used by the two file-panel shells in
 * session_live/show.html.heex: Tailwind v4's default `--breakpoint-lg`, which
 * it compiles to exactly this query (assets/css/app.css doesn't override it).
 * The range syntax is deliberate, not a stylistic copy of `(min-width:
 * 64rem)`: a browser too old to parse it matches NEITHER the CSS `lg:` rules
 * nor this, so both agree on "mobile". Change both together. */
export const PANEL_LAYOUT_MEDIA = "(width >= 64rem)"

function layoutOf(mql) {
  return mql.matches ? "desktop" : "mobile"
}

export function panelLayout(win) {
  const w = win || (typeof window !== "undefined" ? window : null)
  if (!w || typeof w.matchMedia !== "function") return null
  return layoutOf(w.matchMedia(PANEL_LAYOUT_MEDIA))
}

/* Mounted on `#panel-layout`, a hidden element the page ALWAYS renders (not
 * inside the `:if`'d panel), so a crossing is tracked while the panel is
 * closed too. The element carries the server's current value as
 * `data-panel-layout`; mounted() reconciles against it, which covers a
 * crossing between the join's params and this listener attaching. */
export const PanelLayoutHook = {
  mounted() {
    if (typeof window.matchMedia !== "function") return
    this._mql = window.matchMedia(PANEL_LAYOUT_MEDIA)
    this._onChange = () => this.pushEvent("panel_layout", { layout: layoutOf(this._mql) })
    this._mql.addEventListener("change", this._onChange)
    if (this.el.dataset.panelLayout !== layoutOf(this._mql)) this._onChange()
  },
  destroyed() {
    if (this._mql) this._mql.removeEventListener("change", this._onChange)
  },
}
