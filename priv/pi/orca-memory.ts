/**
 * OrcaHub's agent-memory-centralization extension.
 *
 * ## Why memory is a session entry, not system-prompt text
 *
 * `Backend.Pi.system_prompt/1` is a pure function of
 * `(orchestrator, code_exec, commit_trailer)` (pi_fork_spec.md §5.1) —
 * `--append-system-prompt` sits at byte 0, and a forked child's cheap warm
 * resume only happens when its inherited prefix is byte-identical to the
 * parent's. A recalled-memory block is exactly the kind of per-session (and
 * per-moment — the memory service can return different results turn to
 * turn) content that must NOT live there. It rides ORCA_MEMORY instead,
 * delivered the same way `orca-identity.ts` delivers session identity: a
 * `custom_message` session entry, appended at `session_start`. Env is
 * invisible to the KV cache, so this costs nothing.
 *
 * ## Config: ORCA_MEMORY
 *
 * `Backend.Pi.pi_env/1` computes this once per port-open (streaming) or per
 * turn (one-shot), via `OrcaHub.Backend.SharedPrompts.memory_context_block/2`
 * — a 3s-timeout-guarded call into `OrcaHub.MemoryClient.context_block/3`:
 *
 *   { "session_id":   "...",       // required
 *     "block":        "..."|null,  // recalled-memory text, or null if none
 *     "generated_at": "..." }      // ISO 8601, when this payload was built
 *
 * `block` is RAW text — this extension does the `<orca-memory>` wrapping,
 * mirroring how `Backend.Claude`/`Backend.Codex` wrap it inline in the user
 * turn.
 *
 * ## The idempotence rule
 *
 * At `session_start`, read the existing entries and find the latest
 * `orca-memory` entry. Append a fresh one only if:
 *
 *   - there is no such entry (fresh session or a fork of a parent that
 *     predates this extension), OR
 *   - the latest entry names a DIFFERENT session id (a forked child, or any
 *     other session-identity divergence), OR
 *   - the latest entry's `generatedAt` is more than 6 hours old (a
 *     long-lived warm session's memory context goes stale — refresh it
 *     periodically rather than never again after the first turn).
 *
 * Nothing to append at all when `block` is null/empty — there's no content
 * worth a message, and skipping avoids moving bytes in the inherited prefix
 * for no reason. This mirrors `orca-identity.ts`'s idempotence rule closely;
 * see that file's header for the two spike findings it documents
 * (`reason: "fork"` is NOT how fork detection works; `pi.sendMessage`'s
 * `deliverAs: "nextTurn"` write is lazy) — both apply here unchanged.
 *
 * ## Version skew — degrade, never crash
 *
 * Same posture as `orca-identity.ts`: if `pi.sendMessage` is missing, log a
 * warning and no-op instead of throwing. Losing memory injection is
 * survivable (the model just starts this session without recalled context);
 * a thrown error at `session_start` breaking the whole session is far worse.
 *
 * Like `orca-identity.ts`, this logs to stderr only — `--mode rpc`'s stdout
 * is the NDJSON RPC channel and any write there corrupts it.
 */

const CUSTOM_TYPE = "orca-memory";
const STALE_AFTER_MS = 6 * 60 * 60 * 1000;

const MARKER = (sessionId: string) => `[${CUSTOM_TYPE} session_id=${sessionId}]`;
const MARKER_RE = new RegExp(`\\[${CUSTOM_TYPE} session_id=([^\\]\\s]+)\\]`);

type MemoryPayload = {
  session_id?: string;
  block?: string | null;
  generated_at?: string;
};

type LatestMemory = { sessionId: string; generatedAtMs: number | undefined };

// A `custom_message`'s `content` is "String or (TextContent | ImageContent)[]"
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

function memoryEntryInfo(entry: any): LatestMemory | undefined {
  const detailsId = entry?.details?.sessionId;
  const detailsGeneratedAt = entry?.details?.generatedAt;

  const sessionId =
    typeof detailsId === "string" && detailsId ? detailsId : MARKER_RE.exec(entryText(entry))?.[1];

  if (!sessionId) return undefined;

  const generatedAtMs =
    typeof detailsGeneratedAt === "string" ? Date.parse(detailsGeneratedAt) : NaN;

  return { sessionId, generatedAtMs: Number.isNaN(generatedAtMs) ? undefined : generatedAtMs };
}

// The LATEST orca-memory entry's info, or undefined when the history has
// none. `getEntries()` returns entries in file order, so the last match is
// the most recent one.
function latestMemory(entries: any[]): LatestMemory | undefined {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry?.type === "custom_message" && entry?.customType === CUSTOM_TYPE) {
      const info = memoryEntryInfo(entry);
      if (info) return info;
    }
  }
  return undefined;
}

function shouldAppend(previous: LatestMemory | undefined, sessionId: string, nowMs: number): boolean {
  if (!previous) return true;
  if (previous.sessionId !== sessionId) return true;
  // Unknown age (generatedAt missing/unparseable on the stored entry) —
  // treat as stale rather than silently never refreshing again.
  if (previous.generatedAtMs === undefined) return true;
  return nowMs - previous.generatedAtMs > STALE_AFTER_MS;
}

function renderMemory(sessionId: string, block: string): string {
  return `${MARKER(sessionId)}\n\n<orca-memory>\n${block}\n</orca-memory>`;
}

export default function orcaMemory(pi: any) {
  // Suppresses a duplicate queue within a single process only (same spike
  // finding as orca-identity.ts — sendMessage's nextTurn write is lazy, so a
  // second session_start with no turn in between wouldn't see the first
  // one's entry yet).
  let queuedForSessionId: string | undefined;

  let loggedOnce = false;
  const logOnce = (message: string) => {
    if (loggedOnce) return;
    loggedOnce = true;
    console.error(`[orca-memory] ${message}`);
  };

  pi.on("session_start", async (_event: any, ctx: any) => {
    const raw = process.env.ORCA_MEMORY;
    if (!raw) {
      logOnce("ORCA_MEMORY not set — memory not injected");
      return;
    }

    let payload: MemoryPayload;
    try {
      payload = JSON.parse(raw) as MemoryPayload;
    } catch (err) {
      logOnce(`ORCA_MEMORY is not valid JSON (${(err as Error).message}) — skipping`);
      return;
    }

    const sessionId = payload.session_id;
    if (typeof sessionId !== "string" || sessionId === "") {
      logOnce("ORCA_MEMORY has no session_id — skipping");
      return;
    }

    const block = payload.block;
    if (typeof block !== "string" || block.trim() === "") {
      // Nothing recalled for this session right now — no message to send,
      // and nothing to record either (a future launch with real content
      // will find no prior entry and append normally).
      return;
    }

    if (typeof pi.sendMessage !== "function") {
      logOnce(
        "this pi build has no pi.sendMessage — recalled memory NOT injected. " +
          "The session will proceed without it.",
      );
      return;
    }

    if (queuedForSessionId === sessionId) return;

    let entries: any[] = [];
    try {
      const fromManager = ctx?.sessionManager?.getEntries?.();
      if (Array.isArray(fromManager)) entries = fromManager;
      else logOnce("ctx.sessionManager.getEntries() unavailable — appending memory unchecked");
    } catch (err) {
      logOnce(`ctx.sessionManager.getEntries() failed (${(err as Error).message})`);
    }

    const previous = latestMemory(entries);
    const generatedAtMs = typeof payload.generated_at === "string" ? Date.parse(payload.generated_at) : NaN;
    const nowMs = Number.isNaN(generatedAtMs) ? Date.now() : generatedAtMs;

    if (!shouldAppend(previous, sessionId, nowMs)) return;

    pi.sendMessage(
      {
        customType: CUSTOM_TYPE,
        content: renderMemory(sessionId, block),
        display: false,
        details: { sessionId, generatedAt: payload.generated_at },
      },
      { deliverAs: "nextTurn" },
    );

    queuedForSessionId = sessionId;
  });
}
