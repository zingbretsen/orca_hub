/**
 * Test harness for priv/pi/orca-identity.ts (pi_fork_spec.md §5.1).
 *
 * Drives the extension against a fake `pi` object and a fake
 * `ctx.sessionManager`, so the idempotence rule — the thing that makes BOTH
 * cold reopens and forks behave correctly with no fork special-casing — is
 * asserted directly rather than only inferred from the Elixir side.
 *
 * Run by OrcaHub.Backend.PiTest's "orca-identity.ts idempotence" test, which
 * skips (loudly) if this node build can't import a .ts module. Node >= 22.18
 * strips TypeScript types natively, no build step or dependency.
 *
 * Prints one JSON line: {"passed": [...], "failed": [{name, detail}]}.
 */

const EXTENSION = new URL("../../../priv/pi/orca-identity.ts", import.meta.url).href;

const CHILD = "11111111-1111-4111-8111-111111111111";
const PARENT = "22222222-2222-4222-8222-222222222222";

const PAYLOAD = {
  session_id: CHILD,
  commit_trailer: "TRAILER-FRAGMENT for " + CHILD,
  issue_trailer: "ISSUE-FRAGMENT ORCA-142",
  open_issues: "# Your Open Issues\n- [ORCA-1] something (open)",
};

// A `custom_message` entry shaped exactly like docs/session-format.md's
// example, i.e. what ctx.sessionManager.getEntries() hands back.
function identityEntry(sessionId, { withDetails = true, asBlocks = false } = {}) {
  const text = `[orca-identity session_id=${sessionId}]\n\nYour OrcaHub session ID is ${sessionId}.`;
  return {
    type: "custom_message",
    id: "e" + sessionId.slice(0, 4),
    parentId: null,
    customType: "orca-identity",
    content: asBlocks ? [{ type: "text", text }] : text,
    display: false,
    ...(withDetails ? { details: { sessionId } } : {}),
  };
}

function inheritedHistory() {
  return [
    { type: "model_change", id: "m1", parentId: null },
    { type: "thinking_level_change", id: "t1", parentId: "m1" },
    { type: "message", id: "u1", parentId: "t1", message: { role: "user", content: "hi" } },
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
      const prevEnv = process.env.ORCA_IDENTITY;
      const prevError = console.error;
      if (env === undefined) delete process.env.ORCA_IDENTITY;
      else process.env.ORCA_IDENTITY = env;
      console.error = (msg) => warnings.push(String(msg));

      try {
        await handler({ reason: "startup" }, { sessionManager: { getEntries: () => entries } });
      } finally {
        console.error = prevError;
        if (prevEnv === undefined) delete process.env.ORCA_IDENTITY;
        else process.env.ORCA_IDENTITY = prevEnv;
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

const orcaIdentity = (await import(EXTENSION)).default;

async function harness(options = {}) {
  const h = makePi(options);
  await orcaIdentity(h.pi);
  return h;
}

// 1. Fresh session: nothing to inherit, so the full identity is queued.
await check("fresh session appends one identity message", async () => {
  const h = await harness();
  await h.fire([], JSON.stringify(PAYLOAD));

  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
  const { message, options } = h.sent[0];
  assert(message.customType === "orca-identity", `customType=${message.customType}`);
  assert(options.deliverAs === "nextTurn", `deliverAs=${options.deliverAs}`);
  assert(message.content.includes(`Your OrcaHub session ID is ${CHILD}`), "missing id line");
  assert(message.content.includes(PAYLOAD.commit_trailer), "missing commit trailer");
  assert(message.content.includes(PAYLOAD.issue_trailer), "missing issue trailer");
  assert(message.content.includes(PAYLOAD.open_issues), "missing open issues");
  assert(!message.content.includes("forked from"), "fresh session should not mention a fork");
  assert(message.details.sessionId === CHILD, "details.sessionId not set");
});

// 2. THE cold-reopen case: the latest identity entry already names this
//    session, so appending anything would move bytes in a prefix that has to
//    stay stable across reopens.
await check("cold reopen of the same session appends nothing", async () => {
  const h = await harness();
  await h.fire([...inheritedHistory(), identityEntry(CHILD)], JSON.stringify(PAYLOAD));

  assert(h.sent.length === 0, `expected 0 sends, got ${h.sent.length}`);
});

// 3. THE fork case, falling out of the same rule with no fork-specific code.
await check("fork child appends exactly one identity update naming both ids", async () => {
  const h = await harness();
  await h.fire([...inheritedHistory(), identityEntry(PARENT)], JSON.stringify(PAYLOAD));

  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
  const content = h.sent[0].message.content;
  assert(content.includes(`you are now session ${CHILD}`), "update does not name the child");
  assert(content.includes(`forked from session ${PARENT}`), "update does not name the parent");
  assert(content.includes(PAYLOAD.commit_trailer), "update does not restate the trailer");
  assert(h.sent[0].message.details.previousSessionId === PARENT, "details.previousSessionId");
});

// 4. Only the LATEST identity entry decides — a fork of a fork must not be
//    confused by the grandparent's entry sitting earlier in the history.
await check("only the latest identity entry decides", async () => {
  const h = await harness();
  await h.fire(
    [identityEntry("33333333-3333-4333-8333-333333333333"), ...inheritedHistory(), identityEntry(PARENT)],
    JSON.stringify(PAYLOAD),
  );

  assert(h.sent.length === 1, `expected 1 send, got ${h.sent.length}`);
  assert(h.sent[0].message.content.includes(`forked from session ${PARENT}`), "wrong parent");
});

// 5. The id must still be recoverable from an entry whose `details` a pi
//    version dropped — hence the in-content marker.
await check("falls back to the in-content marker when details is absent", async () => {
  const h = await harness();
  await h.fire([identityEntry(CHILD, { withDetails: false })], JSON.stringify(PAYLOAD));

  assert(h.sent.length === 0, "marker-only entry should still suppress the append");
});

await check("handles array-shaped content blocks", async () => {
  const h = await harness();
  await h.fire(
    [identityEntry(CHILD, { withDetails: false, asBlocks: true })],
    JSON.stringify(PAYLOAD),
  );

  assert(h.sent.length === 0, "block-shaped entry should still suppress the append");
});

// 6. Spike finding: sendMessage(deliverAs:"nextTurn") materializes LAZILY, so
//    a second session_start in the SAME process still sees no entry. The
//    in-process guard is what stops a duplicate there.
await check("a second session_start in one process does not double-append", async () => {
  const h = await harness();
  await h.fire([], JSON.stringify(PAYLOAD));
  await h.fire([], JSON.stringify(PAYLOAD));

  assert(h.sent.length === 1, `expected 1 send across two session_starts, got ${h.sent.length}`);
});

// 7. Q5 version skew: degrade, never crash.
await check("no pi.sendMessage: warns and no-ops instead of throwing", async () => {
  const h = await harness({ withSendMessage: false });
  await h.fire([], JSON.stringify(PAYLOAD));

  assert(h.warnings.length === 1, `expected 1 warning, got ${JSON.stringify(h.warnings)}`);
  assert(h.warnings[0].includes("pi.sendMessage"), h.warnings[0]);
});

await check("missing ORCA_IDENTITY: warns and no-ops", async () => {
  const h = await harness();
  await h.fire([], undefined);

  assert(h.sent.length === 0, "should not send without a payload");
  assert(h.warnings.length === 1, `expected 1 warning, got ${JSON.stringify(h.warnings)}`);
});

await check("malformed ORCA_IDENTITY: warns and no-ops", async () => {
  const h = await harness();
  await h.fire([], "{not json");

  assert(h.sent.length === 0, "should not send on malformed payload");
  assert(h.warnings[0].includes("not valid JSON"), h.warnings[0]);
});

console.log(JSON.stringify(results));
