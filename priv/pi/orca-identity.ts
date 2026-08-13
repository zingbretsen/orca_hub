/**
 * OrcaHub's session-identity extension (pi_fork_spec.md §5.1).
 *
 * ## Why identity is a session entry, not system-prompt text
 *
 * A pi fork (`pi --fork <parent.jsonl>`, §4) only pays off if the child's
 * inherited prefix is BYTE-IDENTICAL to the parent's — the serving layer
 * matches longest-common-prefix from byte 0, so a single differing byte
 * before the inherited history throws away cache reuse of the ENTIRE prefix
 * and turns a ~2s warm resume back into a ~26s cold prefill.
 *
 * `--append-system-prompt` sits at byte 0. So `Backend.Pi.system_prompt/1`
 * is now a pure function of `(orchestrator, code_exec, commit_trailer)` —
 * every per-session-divergent fragment (the session id line, the
 * OrcaHub-Session commit trailer, the OrcaHub-Issue trailer, and the
 * time-varying open-issues list) moved OUT of the flag and into this
 * extension, delivered as a `custom_message` session entry instead.
 *
 * `custom_message` is the right entry type: "Custom messages participate in
 * LLM context" (docs/extensions.md). `pi.appendEntry()` does NOT — it is
 * explicitly TUI-only and never reaches the model, so it cannot carry
 * identity.
 *
 * ## Config: ORCA_IDENTITY
 *
 * `Backend.Pi.pi_env/1` injects a JSON payload — same pattern as
 * `orca-mcp.ts`'s `ORCA_MCP_URL`, read at `session_start`:
 *
 *   { "session_id": "...",          // required
 *     "commit_trailer": "..."|null, // OrcaHub-Session trailer instruction
 *     "issue_trailer":  "..."|null, // OrcaHub-Issue trailer, when linked
 *     "open_issues":    "..."|null } // issues_spec.md §10 resume hook
 *
 * Env is invisible to the KV cache, so this whole payload varying per child
 * costs nothing.
 *
 * ## The idempotence rule (this is the whole trick)
 *
 * At `session_start`, read the existing entries and append ONLY when the
 * latest `orca-identity` entry names a DIFFERENT session id. Both behaviors
 * we need fall out of that one rule, with no fork special-casing anywhere:
 *
 * - **Cold reopen of the same session** — the latest identity entry already
 *   names this id, so we no-op. The prefix is therefore stable across
 *   reopens, which is a win for every long-lived pi session, not just forks
 *   (today's `open_issues_prompt` re-query busts the prefix on every single
 *   cold reopen).
 * - **A forked child's first spawn** — the inherited history's latest
 *   identity entry names the PARENT, so we append an identity update
 *   ("you are now <child>, forked from <parent>") exactly at the divergence
 *   point. Everything above it is untouched inherited context.
 *
 * ### Two spike findings this implementation must honor
 *
 * (`pi_fork_spike_findings.md`, ground-truthed 2026-08-13 against pi 0.83.0)
 *
 * 1. **Do NOT gate fork detection on `event.reason === "fork"`.** A CLI-level
 *    `--fork` is a fresh process and reports `reason: "startup"`, exactly
 *    like any other cold start — the docs' `"fork"` reason only fires for
 *    interactive `/fork`//`clone` switching a LIVE session mid-process.
 *    Divergence is detected purely from entry content below.
 * 2. **`pi.sendMessage(…, {deliverAs: "nextTurn"})` materializes LAZILY.**
 *    The entry is NOT in `getEntries()` right after the call — it lands
 *    later, as a child of the next user message. So this never treats "I
 *    just sent it" as "it is on disk". A process torn down before its first
 *    prompt leaves no entry at all; the next launch's check then sees a
 *    stale/absent identity and re-queues, which is self-healing rather than
 *    a stuck state. `queuedForSessionId` below only suppresses a duplicate
 *    within ONE process (two `session_start`s with no turn between them).
 *
 * ## Version skew (spec §12 Q5) — degrade, never crash
 *
 * `pi.sendMessage` and the `custom_message` entry type are verified in pi
 * 0.83.0; the adapter itself was live-verified against 0.80.3 and nodes may
 * skew. If `pi.sendMessage` is missing, this logs a warning and no-ops
 * instead of throwing — a thrown error at `session_start` would break the
 * session outright, which is far worse than the failure it would report.
 *
 * Identity loss is survivable: MCP tools still act as the correct session
 * regardless of prompt text, because `ORCA_MCP_URL`'s `orca_session_id`
 * query param binds the connection, not this message. The commit trailer is
 * the main text-level identity actually at risk.
 *
 * Like `orca-mcp.ts`, this logs to stderr only — `--mode rpc`'s stdout is
 * the NDJSON RPC channel and any write there corrupts it.
 */

const CUSTOM_TYPE = "orca-identity";

// Machine-readable marker carried in the message body. The next process
// parses its own id back out of this to run the idempotence check.
// Duplicated into `details.sessionId` (persisted, but per docs not sent to
// the LLM), which is preferred when present — the marker is the fallback for
// any pi version that drops `details` on the floor.
const MARKER = (sessionId: string) => `[${CUSTOM_TYPE} session_id=${sessionId}]`;
const MARKER_RE = new RegExp(`\\[${CUSTOM_TYPE} session_id=([^\\]\\s]+)\\]`);

type IdentityPayload = {
  session_id?: string;
  commit_trailer?: string | null;
  issue_trailer?: string | null;
  open_issues?: string | null;
};

// A custom_message's `content` is "String or (TextContent | ImageContent)[]"
// (docs/session-format.md). Normalize both, and tolerate an entry that nests
// the payload under `message` the way assistant/user entries do.
function entryText(entry: any): string {
  const content = entry?.content ?? entry?.message?.content;
  if (typeof content === "string") return content;

  if (Array.isArray(content)) {
    return content
      .filter((block: any) => block && block.type === "text" && typeof block.text === "string")
      .map((block: any) => block.text as string)
      .join("\n");
  }

  return "";
}

function identitySessionId(entry: any): string | undefined {
  const fromDetails = entry?.details?.sessionId;
  if (typeof fromDetails === "string" && fromDetails) return fromDetails;

  const match = MARKER_RE.exec(entryText(entry));
  return match ? match[1] : undefined;
}

// The session id named by the LATEST orca-identity entry, or undefined when
// the history has none (a genuinely fresh session, or a fork of a parent
// that predates this extension). `getEntries()` returns entries in file
// order, so the last match is the most recent one.
function latestIdentitySessionId(entries: any[]): string | undefined {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry?.type === "custom_message" && entry?.customType === CUSTOM_TYPE) {
      const id = identitySessionId(entry);
      if (id) return id;
    }
  }
  return undefined;
}

function renderIdentity(payload: IdentityPayload, previousSessionId?: string): string {
  const sessionId = payload.session_id as string;

  const parts: string[] = [MARKER(sessionId)];

  if (previousSessionId) {
    // The divergence point of a fork: everything above this entry is the
    // parent's inherited context, and the model needs to know the id it has
    // been using is no longer its own.
    parts.push(
      `Your OrcaHub session ID has changed: you are now session ${sessionId}, ` +
        `forked from session ${previousSessionId}. The conversation above this ` +
        `point is inherited context from ${previousSessionId} — it is yours to ` +
        `use, but you are a separate session now. From here on, use ` +
        `${sessionId} wherever your own session id is required.`,
    );
  } else {
    parts.push(`Your OrcaHub session ID is ${sessionId}.`);
  }

  for (const fragment of [payload.commit_trailer, payload.issue_trailer, payload.open_issues]) {
    if (typeof fragment === "string" && fragment.trim() !== "") parts.push(fragment);
  }

  return parts.join("\n\n");
}

export default function orcaIdentity(pi: any) {
  // Suppresses a duplicate queue within a single process only (see finding 2
  // above); it is NOT the idempotence mechanism, the entry check is.
  let queuedForSessionId: string | undefined;

  let loggedOnce = false;
  const logOnce = (message: string) => {
    if (loggedOnce) return;
    loggedOnce = true;
    console.error(`[orca-identity] ${message}`);
  };

  pi.on("session_start", async (_event: any, ctx: any) => {
    const raw = process.env.ORCA_IDENTITY;
    if (!raw) {
      logOnce("ORCA_IDENTITY not set — session identity not injected");
      return;
    }

    let payload: IdentityPayload;
    try {
      payload = JSON.parse(raw) as IdentityPayload;
    } catch (err) {
      logOnce(`ORCA_IDENTITY is not valid JSON (${(err as Error).message}) — skipping`);
      return;
    }

    const sessionId = payload.session_id;
    if (typeof sessionId !== "string" || sessionId === "") {
      logOnce("ORCA_IDENTITY has no session_id — skipping");
      return;
    }

    // Version skew (Q5): no sendMessage, no identity message. Warn loudly
    // and continue — never throw out of session_start.
    if (typeof pi.sendMessage !== "function") {
      logOnce(
        "this pi build has no pi.sendMessage — session identity NOT injected. " +
          "MCP tools still bind to the right session via ORCA_MCP_URL, but the " +
          "model will not know its session id or commit trailer.",
      );
      return;
    }

    if (queuedForSessionId === sessionId) return;

    let entries: any[] = [];
    try {
      const fromManager = ctx?.sessionManager?.getEntries?.();
      if (Array.isArray(fromManager)) entries = fromManager;
      else logOnce("ctx.sessionManager.getEntries() unavailable — appending identity unchecked");
    } catch (err) {
      logOnce(`ctx.sessionManager.getEntries() failed (${(err as Error).message})`);
    }

    const previous = latestIdentitySessionId(entries);

    // The idempotence rule: same id already named by the latest identity
    // entry -> nothing to say, and saying it anyway would move bytes in a
    // prefix that must stay stable across cold reopens.
    if (previous === sessionId) return;

    pi.sendMessage(
      {
        customType: CUSTOM_TYPE,
        content: renderIdentity(payload, previous),
        display: false,
        details: { sessionId, previousSessionId: previous },
      },
      { deliverAs: "nextTurn" },
    );

    queuedForSessionId = sessionId;
  });
}
