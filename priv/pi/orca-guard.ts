/**
 * OrcaHub's pi force-command guard extension.
 *
 * Loaded as the FOURTH `-e` in `Backend.Pi.spawn_spec/2` (after orca.ts,
 * orca-mcp.ts, orca-plan.ts — see `lib/orca_hub/backend/pi.ex`'s
 * `common_args/1`, resolved through `Application.app_dir(:orca_hub,
 * "priv/pi/orca-guard.ts")` the same release-safe way as the other three).
 * See `backend_abstraction_spec.md` §12.7.
 *
 * Intercepts `bash` tool calls whose command has unambiguous "force"
 * semantics — discards local/remote state or skips a safety check the
 * underlying tool would otherwise perform — and requires an explicit user
 * confirmation via `ctx.ui.confirm` before letting the command run.
 * Confirmation flows through the SAME extension-UI reply loop
 * `priv/pi/orca.ts`'s `question` tool already uses (spec §12.3):
 * `ctx.ui.confirm` emits a blocking `extension_ui_request{method:"confirm"}`
 * on stdout, `Backend.Pi.handle_peer_request/2` stashes it and surfaces a
 * `pi_ui_request` event, `session_live/show.html.heex`'s dialog card renders
 * it, and the user's answer travels back via
 * `SessionRunner.answer_ui_request/3` -> `Backend.Pi.encode_ui_response/3`
 * as an `extension_ui_response{confirmed: true|false}` port write. This file
 * adds ZERO new Elixir plumbing — it only calls a dialog primitive the
 * runner already knows how to shuttle back and forth.
 *
 * ## Policy (explicit, deliberately narrow — see FORCE_COMMAND_PATTERNS)
 *
 * `rm` (including `rm -rf`) is explicitly EXEMPT — deleting files in the
 * agent's own working directory is an everyday, low-blast-radius operation,
 * and gating it would just train the user to reflexively click "confirm"
 * without reading, defeating the point of a guard entirely. This extension
 * only gates commands whose force flag discards shared or remote state, or
 * bypasses an interactive safety check (a force-pushed branch, a hard-reset
 * working tree, a force-deleted git branch, an auto-approved terraform
 * apply/destroy) — the class of mistake that's expensive or impossible to
 * undo locally. No `sudo` gating either — out of scope for this guard, a
 * different and much broader policy question.
 *
 * ## Composing with orca-plan.ts (plan mode) — no double-prompt
 *
 * pi runs every loaded extension's `tool_call` handlers in `-e` load order
 * and stops at the FIRST one whose result has `block: true` (verified
 * against the installed 0.80.3 binary's
 * `dist/core/extensions/runner.js`:`emitToolCall` — it iterates
 * `this.extensions` in load order, and the moment any handler's result has
 * `block: true` it does `return result` immediately, skipping every
 * remaining extension/handler). Because `orca-plan.ts` is loaded BEFORE this
 * extension (third `-e` vs fourth) and its own `tool_call` hook already
 * blocks every `bash` command that isn't on its read-only allowlist while
 * plan mode is enabled — which is every pattern this file matches, none of
 * which are read-only — orca-plan's block always fires first while planning,
 * and this extension's handler never even runs for a gated command in that
 * case. No shared state between the two extensions, no explicit "is plan
 * mode on?" check needed here — the `-e` flag order alone makes the two
 * hooks compose without a double prompt.
 *
 * ## AbortSignal (CRITICAL — see priv/pi/orca.ts's header for the full story)
 *
 * `ctx.ui.confirm` is a dialog method: it blocks pi waiting for an
 * `extension_ui_response` over the wire. Without threading the `tool_call`
 * handler's own `ctx.signal` into the `confirm` call, an OrcaHub "stop"
 * click (`{"type":"abort"}`) while this dialog is pending leaves the process
 * hung with no further stdout — live-verified for `orca.ts`'s `question`
 * tool and `orca-plan.ts`'s "what next?" dialog (see both files' headers).
 * `dialogOpts` below always passes `{ signal, timeout }` for exactly that
 * reason. Live-verified here too (see this extension's live-smoke section of
 * backend_abstraction_spec.md §12.7): `{"type":"abort"}` while this guard's
 * confirm dialog is pending resolves it immediately instead of hanging.
 *
 * `ctx.ui.confirm`'s own auto-resolve-on-timeout/abort/cancel value is
 * `false` (verified against the installed 0.80.3 binary's
 * `dist/modes/rpc/rpc-mode.js`: `confirm: (...) => createDialogPromise(opts,
 * false, ...)` — `false` is the `defaultValue` argument, returned on abort,
 * on timeout, AND on an explicit `{"cancelled":true}` response). That means
 * "declined", "timed out", and "aborted" all collapse to the same
 * `confirmed === false` result below with no extra handling needed — DENY is
 * the default on silence, exactly as required.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";

// 10 minutes — same rationale as orca.ts/orca-plan.ts's DIALOG_TIMEOUT_MS:
// long enough a distracted user doesn't lose the turn, short enough an
// abandoned session doesn't hold a confirmation dialog open forever.
const DIALOG_TIMEOUT_MS = 10 * 60 * 1000;

// Bash commands matching ANY of these patterns are gated behind a confirm
// dialog before they're allowed to run. Kept as a single flat array, one
// pattern per line with an inline comment, so it's trivially auditable and
// editable — see this file's header for the policy this list expresses
// (force semantics only; `rm` and `sudo` are deliberately NOT here).
export const FORCE_COMMAND_PATTERNS: RegExp[] = [
  // `--force` / `--force-with-lease` anywhere in the command — covers
  // `git push --force[-with-lease]`, `git checkout --force`,
  // `kubectl delete --force`, `gh pr merge --force`, `docker rm --force`,
  // and anything else spelling out the long flag.
  /--force(-with-lease)?\b/,
  // `git push ... -f` — the short-flag spelling of --force, not caught by
  // the pattern above. Scoped to `git push` so an unrelated short `-f`
  // elsewhere in the command (e.g. `grep -f patterns.txt`) doesn't
  // false-positive.
  /\bgit\s+push\b[^\n]*\s-f\b/,
  // `git reset --hard` — discards uncommitted changes and moves the branch
  // pointer, unlike a plain (safe, revertible) `git reset`.
  /\bgit\s+reset\b[^\n]*--hard\b/,
  // `git clean` with an -f-containing short-flag cluster (`-f`, `-df`,
  // `-fdx`, `-xdf`, …) — permanently deletes untracked files.
  // `git clean --force` is already caught by the generic `--force` pattern
  // above.
  /\bgit\s+clean\b[^\n]*\s-[a-zA-Z]*f[a-zA-Z]*\b/,
  // `git branch -D` — force-delete, discards commits with no other branch
  // pointing at them. Deliberately case-sensitive: `-d` (lowercase, safe —
  // refuses to delete a branch with unmerged work) is NOT gated.
  /\bgit\s+branch\b[^\n]*\s-D\b/,
  // `terraform apply|destroy -auto-approve` — skips the interactive plan
  // review, exactly the "are you sure?" step this guard exists to restore.
  /\bterraform\s+(apply|destroy)\b[^\n]*-auto-approve\b/i,
];

function matchedForceCommand(command: string): RegExp | undefined {
  return FORCE_COMMAND_PATTERNS.find((pattern) => pattern.test(command));
}

export default function orcaGuard(pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (!isToolCallEventType("bash", event)) return;

    const command = event.input.command;
    if (typeof command !== "string" || !matchedForceCommand(command)) return;

    if (!ctx.hasUI) {
      // No UI to confirm with (e.g. a headless one-shot run) — deny by
      // default rather than silently letting a force command through.
      return { block: true, reason: `User declined force command: ${command}` };
    }

    // Thread the tool call's own AbortSignal (CRITICAL — see header doc
    // above): without it, {"type":"abort"} while this dialog is pending
    // hangs pi instead of ending the turn.
    const dialogOpts = { signal: ctx.signal, timeout: DIALOG_TIMEOUT_MS };

    const confirmed = await ctx.ui.confirm(
      `Run force command: ${command}`,
      "This command has force semantics — it discards local/remote state or " +
        "skips a safety check the tool would otherwise perform. Confirm to proceed.",
      dialogOpts,
    );

    if (confirmed) return;

    // Declined, timed out, or aborted (all resolve `confirmed === false` per
    // this file's header doc) — DENY is the default on silence.
    return { block: true, reason: `User declined force command: ${command}` };
  });
}
