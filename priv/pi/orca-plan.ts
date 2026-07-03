/**
 * OrcaHub's pi plan-mode extension.
 *
 * Vendored + adapted from pi's own example extension
 * (`examples/extensions/plan-mode/{index,utils}.ts` in the
 * `@earendil-works/pi-coding-agent` package) — a read-only exploration mode:
 * while enabled, built-in write tools (`edit`/`write`) are disabled and
 * `bash` is restricted to an allowlist of read-only commands (spec §12.4).
 *
 * Loaded on every pi-backed OrcaHub session via a second `-e <path>` in
 * `Backend.Pi.spawn_spec/2` (`lib/orca_hub/backend/pi.ex`), right after
 * `orca.ts`, resolved the same way through
 * `Application.app_dir(:orca_hub, "priv/pi/orca-plan.ts")`.
 *
 * Deviations from the upstream example (deliberate, for OrcaHub embedding):
 *
 *   - **`registerShortcut` dropped.** Keyboard shortcuts are a TUI-only
 *     concept (there is no terminal on the other end of `--mode rpc`) — the
 *     upstream `Ctrl+Alt+P` binding is simply not applicable here. `/plan`
 *     (the command) is the only toggle surface pi exposes over RPC, and it's
 *     exactly what `SessionRunner`'s toggle path (see
 *     `OrcaHub.Backend.Pi.encode_toggle_plan_mode/1` /
 *     `SessionRunner.toggle_plan_mode/1`) sends.
 *   - **AbortSignal threaded into every dialog call** (the "groundwork"
 *     lesson, spec §12.3): `ctx.ui.select`/`ctx.ui.editor` in the `agent_end`
 *     handler below now pass `{ signal: ctx.signal, timeout:
 *     DIALOG_TIMEOUT_MS }`. Without `signal`, an OrcaHub "stop" click
 *     (`{"type":"abort"}`) while the post-plan "what next?" dialog is
 *     pending leaves the process hung with no further stdout — exactly the
 *     failure mode `priv/pi/orca.ts`'s `question` tool hit before that fix.
 *     A generous 10-minute timeout (matching `orca.ts`) is added for the
 *     same reason: an abandoned dialog must resolve on its own via pi's own
 *     timeout machinery rather than hang the turn forever.
 *   - **`"questionnaire"` replaced with `"question"` in `PLAN_MODE_TOOLS`.**
 *     The upstream example references a tool named `questionnaire` that
 *     doesn't exist in this deployment; `priv/pi/orca.ts` (loaded first, via
 *     the earlier `-e`) registers a `question` tool with equivalent intent
 *     (ask the user a clarifying question) — reusing OrcaHub's own tool
 *     keeps read-only clarifying questions available while planning, exactly
 *     like the upstream extension intended with its own tool.
 *   - **`utils.ts` inlined** — single file, per project convention for small
 *     extensions (`orca.ts` is also single-file).
 *
 * Everything else (bash allowlist/denylist patterns, plan extraction from a
 * `Plan:` section, `[DONE:n]` progress tracking, session persistence via
 * `pi.appendEntry("plan-mode", …)`, the post-plan "what next?" dialog) is
 * unchanged from the upstream example.
 */

import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { AssistantMessage, TextContent } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// 10 minutes — same rationale as priv/pi/orca.ts's DIALOG_TIMEOUT_MS: long
// enough that a distracted user doesn't lose the turn, short enough that a
// genuinely abandoned session doesn't hold a dialog open indefinitely.
const DIALOG_TIMEOUT_MS = 10 * 60 * 1000;

// ── utils.ts, inlined ────────────────────────────────────────────────────

// Destructive commands blocked in plan mode.
const DESTRUCTIVE_PATTERNS = [
  /\brm\b/i,
  /\brmdir\b/i,
  /\bmv\b/i,
  /\bcp\b/i,
  /\bmkdir\b/i,
  /\btouch\b/i,
  /\bchmod\b/i,
  /\bchown\b/i,
  /\bchgrp\b/i,
  /\bln\b/i,
  /\btee\b/i,
  /\btruncate\b/i,
  /\bdd\b/i,
  /\bshred\b/i,
  /(^|[^<])>(?!>)/,
  />>/,
  /\bnpm\s+(install|uninstall|update|ci|link|publish)/i,
  /\byarn\s+(add|remove|install|publish)/i,
  /\bpnpm\s+(add|remove|install|publish)/i,
  /\bpip\s+(install|uninstall)/i,
  /\bapt(-get)?\s+(install|remove|purge|update|upgrade)/i,
  /\bbrew\s+(install|uninstall|upgrade)/i,
  /\bgit\s+(add|commit|push|pull|merge|rebase|reset|checkout|branch\s+-[dD]|stash|cherry-pick|revert|tag|init|clone)/i,
  /\bsudo\b/i,
  /\bsu\b/i,
  /\bkill\b/i,
  /\bpkill\b/i,
  /\bkillall\b/i,
  /\breboot\b/i,
  /\bshutdown\b/i,
  /\bsystemctl\s+(start|stop|restart|enable|disable)/i,
  /\bservice\s+\S+\s+(start|stop|restart)/i,
  /\b(vim?|nano|emacs|code|subl)\b/i,
];

// Safe read-only commands allowed in plan mode.
const SAFE_PATTERNS = [
  /^\s*cat\b/,
  /^\s*head\b/,
  /^\s*tail\b/,
  /^\s*less\b/,
  /^\s*more\b/,
  /^\s*grep\b/,
  /^\s*find\b/,
  /^\s*ls\b/,
  /^\s*pwd\b/,
  /^\s*echo\b/,
  /^\s*printf\b/,
  /^\s*wc\b/,
  /^\s*sort\b/,
  /^\s*uniq\b/,
  /^\s*diff\b/,
  /^\s*file\b/,
  /^\s*stat\b/,
  /^\s*du\b/,
  /^\s*df\b/,
  /^\s*tree\b/,
  /^\s*which\b/,
  /^\s*whereis\b/,
  /^\s*type\b/,
  /^\s*env\b/,
  /^\s*printenv\b/,
  /^\s*uname\b/,
  /^\s*whoami\b/,
  /^\s*id\b/,
  /^\s*date\b/,
  /^\s*cal\b/,
  /^\s*uptime\b/,
  /^\s*ps\b/,
  /^\s*top\b/,
  /^\s*htop\b/,
  /^\s*free\b/,
  /^\s*git\s+(status|log|diff|show|branch|remote|config\s+--get)/i,
  /^\s*git\s+ls-/i,
  /^\s*npm\s+(list|ls|view|info|search|outdated|audit)/i,
  /^\s*yarn\s+(list|info|why|audit)/i,
  /^\s*node\s+--version/i,
  /^\s*python\s+--version/i,
  /^\s*curl\s/i,
  /^\s*wget\s+-O\s*-/i,
  /^\s*jq\b/,
  /^\s*sed\s+-n/i,
  /^\s*awk\b/,
  /^\s*rg\b/,
  /^\s*fd\b/,
  /^\s*bat\b/,
  /^\s*eza\b/,
];

function isSafeCommand(command: string): boolean {
  const isDestructive = DESTRUCTIVE_PATTERNS.some((p) => p.test(command));
  const isSafe = SAFE_PATTERNS.some((p) => p.test(command));
  return !isDestructive && isSafe;
}

interface TodoItem {
  step: number;
  text: string;
  completed: boolean;
}

function cleanStepText(text: string): string {
  let cleaned = text
    .replace(/\*{1,2}([^*]+)\*{1,2}/g, "$1") // Remove bold/italic
    .replace(/`([^`]+)`/g, "$1") // Remove code
    .replace(
      /^(Use|Run|Execute|Create|Write|Read|Check|Verify|Update|Modify|Add|Remove|Delete|Install)\s+(the\s+)?/i,
      "",
    )
    .replace(/\s+/g, " ")
    .trim();

  if (cleaned.length > 0) {
    cleaned = cleaned.charAt(0).toUpperCase() + cleaned.slice(1);
  }
  if (cleaned.length > 50) {
    cleaned = `${cleaned.slice(0, 47)}...`;
  }
  return cleaned;
}

function extractTodoItems(message: string): TodoItem[] {
  const items: TodoItem[] = [];
  const headerMatch = message.match(/\*{0,2}Plan:\*{0,2}\s*\n/i);
  if (!headerMatch) return items;

  const planSection = message.slice(message.indexOf(headerMatch[0]) + headerMatch[0].length);
  const numberedPattern = /^\s*(\d+)[.)]\s+\*{0,2}([^*\n]+)/gm;

  for (const match of planSection.matchAll(numberedPattern)) {
    const text = match[2]
      .trim()
      .replace(/\*{1,2}$/, "")
      .trim();
    if (text.length > 5 && !text.startsWith("`") && !text.startsWith("/") && !text.startsWith("-")) {
      const cleaned = cleanStepText(text);
      if (cleaned.length > 3) {
        items.push({ step: items.length + 1, text: cleaned, completed: false });
      }
    }
  }
  return items;
}

function extractDoneSteps(message: string): number[] {
  const steps: number[] = [];
  for (const match of message.matchAll(/\[DONE:(\d+)\]/gi)) {
    const step = Number(match[1]);
    if (Number.isFinite(step)) steps.push(step);
  }
  return steps;
}

function markCompletedSteps(text: string, items: TodoItem[]): number {
  const doneSteps = extractDoneSteps(text);
  for (const step of doneSteps) {
    const item = items.find((t) => t.step === step);
    if (item) item.completed = true;
  }
  return doneSteps.length;
}

// ── index.ts (plan-mode extension) ──────────────────────────────────────

// Tools active while planning: read-only built-ins plus OrcaHub's own
// `question` tool (registered by orca.ts, loaded before this extension) in
// place of the upstream example's nonexistent "questionnaire" tool.
const PLAN_MODE_TOOLS = ["read", "bash", "grep", "find", "ls", "question"];
const NORMAL_MODE_TOOLS = ["read", "bash", "edit", "write"];
const PLAN_MODE_DISABLED_TOOLS = new Set<string>(["edit", "write"]);
const PLAN_MANAGED_TOOLS = new Set<string>([...PLAN_MODE_TOOLS, ...NORMAL_MODE_TOOLS]);

interface PlanModeState {
  enabled: boolean;
  todos?: TodoItem[];
  executing?: boolean;
  toolsBeforePlanMode?: string[];
}

function isAssistantMessage(m: AgentMessage): m is AssistantMessage {
  return m.role === "assistant" && Array.isArray(m.content);
}

function getTextContent(message: AssistantMessage): string {
  return message.content
    .filter((block): block is TextContent => block.type === "text")
    .map((block) => block.text)
    .join("\n");
}

export default function orcaPlanMode(pi: ExtensionAPI): void {
  let planModeEnabled = false;
  let executionMode = false;
  let todoItems: TodoItem[] = [];
  let toolsBeforePlanMode: string[] | undefined;

  pi.registerFlag("plan", {
    description: "Start in plan mode (read-only exploration)",
    type: "boolean",
    default: false,
  });

  // Structured, machine-readable status broadcast (spec §12.4) — a
  // fire-and-forget `setStatus` UI call OrcaHub's SessionRunner surfaces as
  // a normalized `pi_plan_mode` event (`Backend.Pi.handle_peer_request/2`),
  // independent of `ctx.ui.notify`'s free-text message. This is how
  // `SessionLive.Show`'s `@plan_mode` assign learns the TRUE post-toggle
  // state rather than string-matching a human-readable notification.
  function broadcastPlanState(ctx: ExtensionContext): void {
    ctx.ui.setStatus(
      "orca-plan-mode",
      JSON.stringify({ enabled: planModeEnabled, executing: executionMode }),
    );
  }

  function uniqueToolNames(toolNames: string[]): string[] {
    return [...new Set(toolNames)];
  }

  function getPlanModeTools(activeToolNames: string[]): string[] {
    return uniqueToolNames([
      ...activeToolNames.filter((name) => !PLAN_MODE_DISABLED_TOOLS.has(name)),
      ...PLAN_MODE_TOOLS,
    ]);
  }

  function getNormalModeTools(activeToolNames: string[]): string[] {
    return uniqueToolNames([
      ...NORMAL_MODE_TOOLS,
      ...activeToolNames.filter((name) => !PLAN_MANAGED_TOOLS.has(name)),
    ]);
  }

  function enablePlanModeTools(): void {
    if (toolsBeforePlanMode === undefined) {
      toolsBeforePlanMode = pi.getActiveTools();
    }
    pi.setActiveTools(getPlanModeTools(toolsBeforePlanMode));
  }

  function restoreNormalModeTools(): void {
    pi.setActiveTools(toolsBeforePlanMode ?? getNormalModeTools(pi.getActiveTools()));
    toolsBeforePlanMode = undefined;
  }

  function persistState(): void {
    pi.appendEntry("plan-mode", {
      enabled: planModeEnabled,
      todos: todoItems,
      executing: executionMode,
      toolsBeforePlanMode,
    });
  }

  function togglePlanMode(ctx: ExtensionContext): void {
    planModeEnabled = !planModeEnabled;
    executionMode = false;
    todoItems = [];

    if (planModeEnabled) {
      enablePlanModeTools();
      ctx.ui.notify("Plan mode enabled. Built-in write tools disabled.");
    } else {
      restoreNormalModeTools();
      ctx.ui.notify("Plan mode disabled. Full access restored.");
    }
    broadcastPlanState(ctx);
    persistState();
  }

  pi.registerCommand("plan", {
    description: "Toggle plan mode (read-only exploration)",
    handler: async (_args, ctx) => togglePlanMode(ctx),
  });

  pi.registerCommand("todos", {
    description: "Show current plan todo list",
    handler: async (_args, ctx) => {
      if (todoItems.length === 0) {
        ctx.ui.notify("No todos. Create a plan first with /plan", "info");
        return;
      }
      const list = todoItems.map((item, i) => `${i + 1}. ${item.completed ? "✓" : "○"} ${item.text}`).join("\n");
      ctx.ui.notify(`Plan Progress:\n${list}`, "info");
    },
  });

  // Block destructive bash commands in plan mode.
  pi.on("tool_call", async (event) => {
    if (!planModeEnabled || event.toolName !== "bash") return;

    const command = event.input.command as string;
    if (!isSafeCommand(command)) {
      return {
        block: true,
        reason: `Plan mode: command blocked (not allowlisted). Use /plan to disable plan mode first.\nCommand: ${command}`,
      };
    }
  });

  // Filter out stale plan mode context when not in plan mode.
  pi.on("context", async (event) => {
    if (planModeEnabled) return;

    return {
      messages: event.messages.filter((m) => {
        const msg = m as AgentMessage & { customType?: string };
        if (msg.customType === "plan-mode-context") return false;
        if (msg.role !== "user") return true;

        const content = msg.content;
        if (typeof content === "string") {
          return !content.includes("[PLAN MODE ACTIVE]");
        }
        if (Array.isArray(content)) {
          return !content.some(
            (c) => c.type === "text" && (c as TextContent).text?.includes("[PLAN MODE ACTIVE]"),
          );
        }
        return true;
      }),
    };
  });

  // Inject plan/execution context before agent starts.
  pi.on("before_agent_start", async () => {
    if (planModeEnabled) {
      return {
        message: {
          customType: "plan-mode-context",
          content: `[PLAN MODE ACTIVE]
You are in plan mode - a read-only exploration mode for safe code analysis.

Restrictions:
- Built-in edit and write tools are disabled
- Other currently active tools remain available
- Bash is restricted to an allowlist of read-only commands

Ask clarifying questions using the question tool.

Create a detailed numbered plan under a "Plan:" header:

Plan:
1. First step description
2. Second step description
...

Do NOT attempt to make changes - just describe what you would do.`,
          display: false,
        },
      };
    }

    if (executionMode && todoItems.length > 0) {
      const remaining = todoItems.filter((t) => !t.completed);
      const todoList = remaining.map((t) => `${t.step}. ${t.text}`).join("\n");
      return {
        message: {
          customType: "plan-execution-context",
          content: `[EXECUTING PLAN - Full tool access enabled]

Remaining steps:
${todoList}

Execute each step in order.
After completing a step, include a [DONE:n] tag in your response.`,
          display: false,
        },
      };
    }
  });

  // Track progress after each turn.
  pi.on("turn_end", async (event, ctx) => {
    if (!executionMode || todoItems.length === 0) return;
    if (!isAssistantMessage(event.message)) return;

    const text = getTextContent(event.message);
    if (markCompletedSteps(text, todoItems) > 0) {
      broadcastPlanState(ctx);
    }
    persistState();
  });

  // Handle plan completion and plan mode UI.
  pi.on("agent_end", async (event, ctx) => {
    // Check if execution is complete.
    if (executionMode && todoItems.length > 0) {
      if (todoItems.every((t) => t.completed)) {
        const completedList = todoItems.map((t) => `~~${t.text}~~`).join("\n");
        pi.sendMessage(
          { customType: "plan-complete", content: `**Plan Complete!** ✓\n\n${completedList}`, display: true },
          { triggerTurn: false },
        );
        executionMode = false;
        todoItems = [];
        broadcastPlanState(ctx);
        persistState(); // Save cleared state so resume doesn't restore old execution mode
      }
      return;
    }

    if (!planModeEnabled || !ctx.hasUI) return;

    // Extract todos from last assistant message.
    const lastAssistant = [...event.messages].reverse().find(isAssistantMessage);
    if (lastAssistant) {
      const extracted = extractTodoItems(getTextContent(lastAssistant));
      if (extracted.length > 0) {
        todoItems = extracted;
      }
    }

    if (todoItems.length === 0) return;
    persistState();

    // Show plan steps and prompt for next action. Both dialog calls below
    // thread `ctx.signal` (the current agent AbortSignal) so an OrcaHub
    // "stop" click (`{"type":"abort"}`) while either is pending resolves the
    // dialog immediately instead of hanging — see this file's header doc and
    // priv/pi/orca.ts's identical fix for the `question` tool.
    const dialogOpts = { signal: ctx.signal, timeout: DIALOG_TIMEOUT_MS };

    const todoListText = todoItems.map((t, i) => `${i + 1}. ☐ ${t.text}`).join("\n");
    const planTodoListMessage = {
      customType: "plan-todo-list",
      content: `**Plan Steps (${todoItems.length}):**\n\n${todoListText}`,
      display: true,
    };

    const choice = await ctx.ui.select(
      "Plan mode - what next?",
      ["Execute the plan (track progress)", "Stay in plan mode", "Refine the plan"],
      dialogOpts,
    );

    if (choice?.startsWith("Execute")) {
      const firstTodoItem = todoItems[0];
      if (!firstTodoItem) return;

      planModeEnabled = false;
      executionMode = true;
      restoreNormalModeTools();
      broadcastPlanState(ctx);
      persistState();

      const remainingList = todoItems.map((t) => `${t.step}. ${t.text}`).join("\n");
      const execMessage = `Execute the plan.

Remaining steps:
${remainingList}

Start with: ${firstTodoItem.text}
After completing a step, include a [DONE:n] tag in your response.`;
      pi.sendMessage(planTodoListMessage, { deliverAs: "followUp" });
      pi.sendMessage(
        { customType: "plan-mode-execute", content: execMessage, display: true },
        { triggerTurn: true, deliverAs: "followUp" },
      );
    } else if (choice === "Refine the plan") {
      const refinement = await ctx.ui.editor("Refine the plan:", "", dialogOpts);
      if (refinement?.trim()) {
        pi.sendMessage(planTodoListMessage, { deliverAs: "followUp" });
        pi.sendUserMessage(refinement.trim(), { deliverAs: "followUp" });
      }
    }
    // choice === undefined (timeout or {"type":"abort"} while pending): stay
    // in plan mode, no further action — same posture as orca.ts's `question`
    // tool on a timed-out/aborted dialog.
  });

  // Restore state on session start/resume.
  pi.on("session_start", async (_event, ctx) => {
    if (pi.getFlag("plan") === true) {
      planModeEnabled = true;
    }

    const entries = ctx.sessionManager.getEntries();

    // Restore persisted state.
    const planModeEntry = entries
      .filter((e: { type: string; customType?: string }) => e.type === "custom" && e.customType === "plan-mode")
      .pop() as { data?: PlanModeState } | undefined;

    if (planModeEntry?.data) {
      planModeEnabled = planModeEntry.data.enabled ?? planModeEnabled;
      todoItems = planModeEntry.data.todos ?? todoItems;
      executionMode = planModeEntry.data.executing ?? executionMode;
      toolsBeforePlanMode = planModeEntry.data.toolsBeforePlanMode ?? toolsBeforePlanMode;
    }

    // On resume: re-scan messages to rebuild completion state.
    // Only scan messages AFTER the last "plan-mode-execute" to avoid picking up [DONE:n] from previous plans.
    const isResume = planModeEntry !== undefined;
    if (isResume && executionMode && todoItems.length > 0) {
      let executeIndex = -1;
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i] as { type: string; customType?: string };
        if (entry.customType === "plan-mode-execute") {
          executeIndex = i;
          break;
        }
      }

      const messages: AssistantMessage[] = [];
      for (let i = executeIndex + 1; i < entries.length; i++) {
        const entry = entries[i];
        if (entry.type === "message" && "message" in entry && isAssistantMessage(entry.message as AgentMessage)) {
          messages.push(entry.message as AssistantMessage);
        }
      }
      const allText = messages.map(getTextContent).join("\n");
      markCompletedSteps(allText, todoItems);
    }

    if (planModeEnabled) {
      enablePlanModeTools();
    }
    broadcastPlanState(ctx);
  });
}
