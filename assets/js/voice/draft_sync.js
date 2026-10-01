/**
 * How the `Voice` hook reconciles a server `state.draft` with the sink
 * textarea (the target's composer, or the bar's own box) — pure, so
 * `draft_sync.check.mjs` can pin it without a browser.
 *
 * ORCAHUB3-120 made this necessary. Before it the server only ever APPENDED,
 * so an incoming draft was always "what the box showed, plus more". Now a
 * rolling LLM cleanup can rewrite text the box already shows — in the middle
 * of it, at any moment, asynchronously — so "the server is newer" is no
 * longer a safe assumption. The rule that keeps typing safe:
 *
 *   only overwrite the box when it still holds EXACTLY what this hook last
 *   wrote into it. Anything else means someone typed (or a page widget
 *   edited it) and the server has not caught up yet: re-assert the box's
 *   text as a `draft_edit` and let the server reconcile, never the reverse.
 *
 * §8.2's merge rule is kept as it was: a `draft_edit` still debouncing means
 * the box is the newer truth, and an empty `state.draft` never empties a
 * non-empty box (clearing is explicit only).
 */

/** What `_renderDraft` should do with an incoming server draft.
 *
 *  - `value`       the sink's current text
 *  - `incoming`    the server's `state.draft`
 *  - `lastWritten` what the hook last wrote into THIS element, or null when
 *                  it has no record (it never wrote there, or the sink moved)
 *  - `debouncing`  a typed `draft_edit` is still waiting to go out
 *
 * Returns one of:
 *  - "keep"     leave the box alone, push nothing
 *  - "in_sync"  the box already shows it; just remember that
 *  - "reassert" the user changed the box since our last write — push the
 *               box's text as a `draft_edit` instead of overwriting it
 *  - "write"    write `incoming` into the box
 *
 * With no record (`lastWritten == null`) the pre-ORCAHUB3-120 behaviour
 * stands: the server's draft is written, exactly as an append always was.
 */
export function draftSinkAction({ value, incoming, lastWritten, debouncing }) {
  if (debouncing) return "keep"
  if (value === incoming) return "in_sync"
  if (incoming === "" && value !== "") return "keep"
  if (lastWritten != null && value !== lastWritten) return "reassert"
  return "write"
}

/** Where a caret at `pos` in `before` belongs once the text becomes `after`.
 *
 * The common prefix and suffix are untouched text: a caret inside the prefix
 * stays put, one inside the suffix moves by the length difference, and one
 * inside the rewritten middle goes to the END of the rewrite (the nearest
 * point both texts still agree on). An append is the old behaviour exactly —
 * everything before the end is prefix. Offsets are UTF-16 code units, the
 * same unit as `selectionStart`.
 */
export function mapCaret(before, after, pos) {
  const max = Math.min(before.length, after.length)
  let prefix = 0
  while (prefix < max && before[prefix] === after[prefix]) prefix++
  let suffix = 0
  while (
    suffix < max - prefix &&
    before[before.length - 1 - suffix] === after[after.length - 1 - suffix]
  ) {
    suffix++
  }
  if (pos <= prefix) return Math.min(pos, after.length)
  if (pos >= before.length - suffix) return Math.max(pos + after.length - before.length, 0)
  return after.length - suffix
}
