/**
 * Test harness for priv/pi/orca-memory.ts (agent-memory centralization).
 *
 * Drives the extension against a fake `pi` object and a fake
 * `ctx.sessionManager`, mirroring pi_identity_harness.mjs's approach for
 * orca-identity.ts — the idempotence rule (absent / stale / different
 * session id) is asserted directly rather than only inferred from the
 * Elixir side.
 *
 * Run by OrcaHub.Backend.PiTest's "orca-memory.ts idempotence" test, which
 * skips (loudly) if this node build can't import a .ts module. Node >= 22.18
 * strips TypeScript types natively, no build step or dependency.
 *
 * Prints one JSON line: {"passed": [...], "failed": [{name, detail}]}.
 */

const EXTENSION = new URL("../../../priv/pi/orca-memory.ts", import.meta.url).href;

const CHILD = "11111111-1111-4111-8111-111111111111";
const PARENT = "22222222-2222-4222-8222-222222222222";

const NOW = new Date("2026-09-09T12:00:00Z");
const RECENT = new Date(NOW.getTime() - 60 * 60 * 1000); // 1h ago
const STALE = new Date(NOW.getTime() - 7 * 60 * 60 * 1000); // 7h ago

function payload(overrides = {}) {
  return {
    session_id: CHILD,
    block: "- remember this",
    generated_at: NOW.toISOString(),
    ...overrides,
  };
}

// A `custom_message` entry shaped like docs/session-format.md's example.
function memoryEntry(sessionId, generatedAt, { withDetails = true, asBlocks = false } = {}) {
  const text = `[orca-memory session_id=${sessionId}]\n\n<orca-memory>\nold stuff\n</orca-memory>`;
  return {
    type: "custom_message",
    id: "e" + sessionId.slice(0, 4),
    parentId: null,
    customType: "orca-memory",
    content: asBlocks ? [{ type: "text", text }] : text,
    display: false,
    ...(withDetails ? { details: { sessionId, generatedAt: generatedAt?.toISOString() } } : {}),
  };
}

function inheritedHistory() {
  return [
    { type: "model_change", id: "m1", parentId: null },
    { type: "message", id: "u1", parentId: "m1", message: { role: "user", content: "hi" } },
  ];
}

// Minimal stand-ins for the two pi surfaces the extension touches.
function makePi({ withSendMessage = true } = {}) {
  const sent = [];
  const warnings = [];
  let handler;

  const pi = {
    on(event, fn) {
      if (event === "session_start") handler = fn;
    },
  };
  if (withSendMessage) {
    pi.sendMessage = (message, options) => sent.push({ message, options });
  }

  return {
    pi,
    sent,
    warnings,
    async fire(entries, env) {
      const prevEnv = process.env.ORCA_MEMORY;
      const prevError = console.error;
      if (env === undefined) delete process.env.ORCA_MEMORY;
      else process.env.ORCA_MEMORY = env;
      console.error = (msg) => warnings.push(String(msg));

      try {
        await handler({ reason: "startup" }, { sessionManager: { getEntries: () => entries } });
      } finally {
        console.error = prevError;
        if (prevEnv === undefined) delete process.env.ORCA_MEMORY;
        else process.env.ORCA_MEMORY = prevEnv;
      }
    },
  };
}

const results = { passed: [], failed: [] };

async function check(name, fn) {
  try {
    await fn();
    results.passed.push(name);
  } catch (err) {
    results.failed.push({ name, detail: err.message });
  }
}

function assert(cond, detail) {
  if (!cond) throw new Error(detail);
}

const orcaMemory = (await import(EXTENSION)).default;

async function harness(options = {}) {
  const h = makePi(options);
  await orcaMemory(h.pi);
  return h;
}

// 1. Fresh session, no prior entries: appends the block.
await check("fresh session with a block appends one memory message", async () => {
  const h = await harness();
  await h.fire([], JSON.stringify(payload()));

  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
  const { message, options } = h.sent[0];
  assert(message.customType === "orca-memory", `customType=${message.customType}`);
  assert(options.deliverAs === "nextTurn", `deliverAs=${options.deliverAs}`);
  assert(message.content.includes("<orca-memory>"), "missing wrapper open tag");
  assert(message.content.includes("- remember this"), "missing block content");
  assert(message.content.includes("</orca-memory>"), "missing wrapper close tag");
  assert(message.details.sessionId === CHILD, "details.sessionId not set");
});

// 2. Nothing recalled: no message at all, regardless of history.
await check("null block sends nothing", async () => {
  const h = await harness();
  await h.fire([], JSON.stringify(payload({ block: null })));

  assert(h.sent.length === 0, `expected 0 sends, got ${h.sent.length}`);
});

await check("empty-string block sends nothing", async () => {
  const h = await harness();
  await h.fire([], JSON.stringify(payload({ block: "   " })));

  assert(h.sent.length === 0, `expected 0 sends, got ${h.sent.length}`);
});

// 3. Same session, recent entry: no-op (prefix stays stable across reopens).
await check("recent entry for the same session appends nothing", async () => {
  const h = await harness();
  const entries = [...inheritedHistory(), memoryEntry(CHILD, RECENT)];
  await h.fire(entries, JSON.stringify(payload()));

  assert(h.sent.length === 0, `expected 0 sends, got ${h.sent.length}`);
});

// 4. Same session, stale (>6h) entry: refresh.
await check("stale entry (>6h) for the same session appends a refresh", async () => {
  const h = await harness();
  const entries = [...inheritedHistory(), memoryEntry(CHILD, STALE)];
  await h.fire(entries, JSON.stringify(payload()));

  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
});

// 5. Different session (fork/new identity): append even if recent.
await check("entry naming a different session appends, even if recent", async () => {
  const h = await harness();
  const entries = [...inheritedHistory(), memoryEntry(PARENT, RECENT)];
  await h.fire(entries, JSON.stringify(payload()));

  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
});

// 6. Only the LATEST memory entry decides.
await check("only the latest memory entry decides", async () => {
  const h = await harness();
  const entries = [
    memoryEntry(PARENT, STALE),
    ...inheritedHistory(),
    memoryEntry(CHILD, RECENT),
  ];
  await h.fire(entries, JSON.stringify(payload()));

  assert(h.sent.length === 0, `expected 0 sends, got ${h.sent.length}`);
});

// 7. Missing generatedAt on the stored entry: treat as stale, append.
await check("stored entry with unparseable generatedAt is treated as stale", async () => {
  const h = await harness();
  const entries = [memoryEntry(CHILD, undefined)];
  await h.fire(entries, JSON.stringify(payload()));

  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
});

// 8. The id must still be recoverable from an entry whose `details` a pi
//    version dropped — the in-content marker fallback (same as identity).
await check("falls back to the in-content marker when details is absent", async () => {
  const h = await harness();
  const entries = [memoryEntry(CHILD, RECENT, { withDetails: false })];
  await h.fire(entries, JSON.stringify(payload()));

  // No details.generatedAt to read -> undefined age -> treated as stale ->
  // appends. Marker recovery is what let it find sessionId === CHILD at all
  // (vs. treating it as "no history"), which matters for the divergence
  // case (fork), not this one — this just confirms no crash + safe default.
  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
});

await check("handles array-shaped content blocks (marker fallback, details absent)", async () => {
  const h = await harness();
  const entries = [memoryEntry(CHILD, RECENT, { withDetails: false, asBlocks: true })];
  await h.fire(entries, JSON.stringify(payload()));

  // No details on this entry -> sessionId recovered from the in-content
  // marker, but generatedAt has nowhere to come from -> unknown age -> stale
  // -> appends. Proves the array-content parse path itself doesn't crash.
  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
});

// 9. Spike finding shared with identity: sendMessage(nextTurn) materializes
//    LAZILY, so a second session_start in the SAME process still sees no
//    entry. The in-process guard is what stops a duplicate there.
await check("a second session_start in one process does not double-append", async () => {
  const h = await harness();
  await h.fire([], JSON.stringify(payload()));
  await h.fire([], JSON.stringify(payload()));

  assert(h.sent.length === 1, `expected 1 send across two session_starts, got ${h.sent.length}`);
});

// 10. Version skew: degrade, never crash.
await check("no pi.sendMessage: warns and no-ops instead of throwing", async () => {
  const h = await harness({ withSendMessage: false });
  await h.fire([], JSON.stringify(payload()));

  assert(h.warnings.length === 1, `expected 1 warning, got ${JSON.stringify(h.warnings)}`);
  assert(h.warnings[0].includes("pi.sendMessage"), h.warnings[0]);
});

await check("missing ORCA_MEMORY: warns and no-ops", async () => {
  const h = await harness();
  await h.fire([], undefined);

  assert(h.sent.length === 0, "should not send without a payload");
  assert(h.warnings.length === 1, `expected 1 warning, got ${JSON.stringify(h.warnings)}`);
});

await check("malformed ORCA_MEMORY: warns and no-ops", async () => {
  const h = await harness();
  await h.fire([], "{not json");

  assert(h.sent.length === 0, "should not send on malformed payload");
  assert(h.warnings[0].includes("not valid JSON"), h.warnings[0]);
});

console.log(JSON.stringify(results));
