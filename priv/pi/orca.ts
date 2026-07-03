/**
 * OrcaHub's pi extension.
 *
 * Loaded on every pi-backed OrcaHub session via `-e <path>` in
 * `Backend.Pi.spawn_spec/2` (lib/orca_hub/backend/pi.ex), resolved through
 * `Application.app_dir(:orca_hub, "priv/pi/orca.ts")` so it also works from
 * an OTP release (priv/ ships with the release by default — no extra
 * config needed).
 *
 * Registers a `question` tool that mirrors Claude Code's built-in
 * AskUserQuestion tool as closely as pi's RPC-mode dialog primitives allow:
 *
 *   - `options` given  -> `ctx.ui.select()` (single choice from a list)
 *   - `options` omitted -> `ctx.ui.input()` (free-form text)
 *
 * `ctx.ui.custom()` returns `undefined` in RPC mode (docs/rpc.md's
 * "Extension UI Protocol" section), so it is deliberately not used here —
 * select/input/confirm/editor are the only dialog primitives that actually
 * work over the RPC wire.
 *
 * Both dialogs pass a generous timeout so an unanswered question resolves
 * on its own instead of hanging the turn forever — pi's own agent-side
 * timeout machinery handles the auto-resolve (rpc.md: "If a dialog method
 * includes a timeout field, the agent-side will auto-resolve with a
 * default value when the timeout expires. The client does not need to
 * track timeouts."). This extension only needs to notice the resulting
 * `undefined` and turn it into a clear tool result.
 *
 * On the OrcaHub side, the request/response round trip for these dialogs
 * (an `extension_ui_request` on stdout, blocking until an
 * `extension_ui_response` arrives on stdin) is handled by
 * `OrcaHub.Backend.Pi.handle_peer_request/2` / `encode_ui_response/3`,
 * which normalize the request into a `pi_ui_request` event rendered by a
 * dedicated modal in `session_live/show.html.heex` (independent of
 * Claude's AskUserQuestion wizard — see that module's docs for why the two
 * answer mechanisms are kept separate rather than sharing one shape).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// 10 minutes — generous enough that a distracted user doesn't lose the
// turn, short enough that a genuinely abandoned session doesn't hold a
// dialog open indefinitely.
const DIALOG_TIMEOUT_MS = 10 * 60 * 1000;

const QuestionOption = Type.Object({
  label: Type.String({ description: "Short label for this choice" }),
  description: Type.Optional(
    Type.String({ description: "Optional one-line detail shown alongside the label" }),
  ),
});

const QuestionParams = Type.Object({
  question: Type.String({ description: "The question to ask the user" }),
  header: Type.Optional(
    Type.String({
      description: "Short category/header label for the question (e.g. 'Language', 'Deploy target')",
    }),
  ),
  options: Type.Optional(
    Type.Array(QuestionOption, {
      description:
        "Multiple-choice options for the user to pick from. Omit this field entirely to ask a free-form question instead.",
    }),
  ),
  multiSelect: Type.Optional(
    Type.Boolean({
      description:
        "Whether more than one option may apply. Note: the host UI currently only supports picking a single option — treat this as advisory.",
    }),
  ),
});

type QuestionOptionT = { label: string; description?: string };

type QuestionParamsT = {
  question: string;
  header?: string;
  options?: QuestionOptionT[];
  multiSelect?: boolean;
};

type QuestionDetails = {
  question: string;
  answer: string | null;
  timedOut?: boolean;
};

export default function orca(pi: ExtensionAPI) {
  pi.registerTool({
    name: "question",
    label: "Question",
    description:
      "Ask the user a clarifying question and wait for their answer before proceeding. " +
      "Pass 'options' for a multiple-choice question, or omit 'options' for free-form text input. " +
      "Use this whenever you need the user's input to proceed, instead of guessing.",
    promptSnippet: "Ask the user a clarifying multiple-choice or free-form question and wait for their answer",
    promptGuidelines: [
      "Use question to ask the user for input you need to proceed, instead of guessing or assuming.",
    ],
    parameters: QuestionParams,

    async execute(_toolCallId, params: QuestionParamsT, signal, _onUpdate, ctx) {
      if (!ctx.hasUI) {
        return {
          content: [
            {
              type: "text",
              text: "No UI available to ask the user — proceed with your best judgement.",
            },
          ],
          details: { question: params.question, answer: null } satisfies QuestionDetails,
        };
      }

      const title = params.header ? `${params.header}: ${params.question}` : params.question;
      // Wire the tool's own AbortSignal into the dialog: without this, an
      // OrcaHub "stop" click mid-dialog (SessionRunner.encode_interrupt/2 ->
      // {"type":"abort"}) has no way to unblock a pending ctx.ui.select/
      // input call — pi's `abort` cancels the agent loop, but a dialog
      // that's already awaiting user input only resolves via an actual
      // extension_ui_response or its own `timeout`. Passing `signal` lets
      // pi tie the dialog to the SAME abort — live-verified: without this,
      // {"type":"abort"} while a `select` dialog was pending left the
      // process hung with no further stdout for 60+s; with it, the dialog
      // resolves immediately and the turn ends normally.
      const dialogOpts = { signal, timeout: DIALOG_TIMEOUT_MS };

      if (params.options && params.options.length > 0) {
        const options = params.options;
        const displayLabels = options.map((o) =>
          o.description ? `${o.label} — ${o.description}` : o.label,
        );

        const choice = await ctx.ui.select(title, displayLabels, dialogOpts);

        if (choice === undefined) {
          return {
            content: [{ type: "text", text: "The user did not answer in time." }],
            details: { question: params.question, answer: null, timedOut: true } satisfies QuestionDetails,
          };
        }

        const index = displayLabels.indexOf(choice);
        const answer = index >= 0 ? options[index].label : choice;

        return {
          content: [{ type: "text", text: `User answered: ${answer}` }],
          details: { question: params.question, answer } satisfies QuestionDetails,
        };
      }

      const value = await ctx.ui.input(title, "Type your answer...", dialogOpts);

      if (value === undefined) {
        return {
          content: [{ type: "text", text: "The user did not answer in time." }],
          details: { question: params.question, answer: null, timedOut: true } satisfies QuestionDetails,
        };
      }

      return {
        content: [{ type: "text", text: `User answered: ${value}` }],
        details: { question: params.question, answer: value } satisfies QuestionDetails,
      };
    },
  });
}
