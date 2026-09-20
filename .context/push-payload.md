# Turn-end push payload contract (two wires)

**The contract now rides TWO wires**, from ONE hub-side fan-out
(`OrcaHub.SessionEvents.turn_end/1`), for one genuine SessionRunner
`running -> idle | error` transition:

1. **The `session_events` channel — ALWAYS.** A
   `OrcaHubWeb.Endpoint.broadcast/3` on `"session_events:all"` and
   `"session_events:<session_id>"`, consumed over the token-authenticated
   `/api/v1/socket` (`OrcaHubWeb.ApiSocket` +
   `OrcaHubWeb.SessionEventsChannel`, scope `sessions:read`). This is D6's
   delivery path for the Android app and is NOT gated on any flag. Its wire
   shape — the four fields below plus `occurred_at` — is documented for
   clients in `docs/api.md` ("Session events socket").
2. **Gotify — OPT-IN, OFF BY DEFAULT.** The same four fields under
   `extras["orca"]`, sent only when `ORCA_NOTIFY_ON_FINISH` is set on the
   RUNNER's node (see "Enabling it"). Both are distinct from the
   `send_notification` MCP tool, which is per-call and only fires when an
   agent asks for it.

Both wires are fed the SAME resolved title and excerpt (the DB read happens
once, on the hub), and both are gated by the SAME suppression predicate,
`SessionRunner.turn_end_push_eligible?/2` — they cannot drift.

**Why Gotify defaults off (D6).** It shipped default-ON for the Android app
(ebf8ffb), and every session turn end on every node buzzed the phone — a
flood in practice. Zach then decided (D6) the app receives finish events from
the direct authenticated channel on the hub instead, so Gotify is no longer
this feature's delivery path for the primary consumer. The code paths below
are deliberately KEPT and still work — the Gotify push is now something you
turn on for a node when you want it, not the default behaviour.

The consumer this payload was designed for is the unified Android app (phone +
Wear + Android Auto) — see `/home/zach/experiments/orca-watch/DESIGN.md` §7c,
§1.4 and risk **R12**. That app renders its `MessagingStyle` notification
**entirely from this payload**: when OrcaHub is unreachable (the "reply from
the car, VPN down" scenario) the client cannot call back to fill anything in.
**Anything missing from the push is missing forever.** Treat the four fields
below as a contract, not a convenience, and do not rename or drop one without
changing the client — they are the SAME four fields on both wires, which is
what made D6 a change of transport rather than of contract.

## The wire shape — channel (primary)

`OrcaHubWeb.Endpoint.broadcast("session_events:all" | "session_events:<id>",
"turn_end", payload)`, forwarded verbatim to every joined client:

```json
{
  "session_id":    "3bac88a6-…",
  "session_title": "the worker",
  "status":        "idle",
  "excerpt":       "All three migrations applied cleanly.",
  "occurred_at":   "2026-09-19T18:04:12.123456Z"
}
```

`occurred_at` (ISO 8601 UTC, the hub's clock at fan-out) is the ONE field
the channel adds over Gotify's `extras.orca`: a channel payload is a map,
so there is no reason to make the client infer an arrival time it can hold
in a high-water mark. Client-facing docs, including the socket URL, the
topics, the `ping` reply and the no-backlog/reconnect rules, live in
`docs/api.md` ("Session events socket").

## The wire shape — Gotify (opt-in)

`POST <gotify>/message?token=…`

```json
{
  "title":    "the worker",                 // session title ("⚠ …" when status=error)
  "message":  "All three migrations applied cleanly.",   // == excerpt
  "priority": 4,                            // 4 for idle, 8 for error
  "extras": {
    "orca": {
      "session_id":    "3bac88a6-…",
      "session_title": "the worker",
      "status":        "idle",              // "idle" | "error"
      "excerpt":       "All three migrations applied cleanly."
    },
    "client::notification": {"click": {"url": "https://orca…/sessions/<id>"}}
  }
}
```

- `session_id` — the reply target. Without it a reply cannot be addressed.
- `session_title` — falls back to the same dumb first-prompt truncation
  `SessionRunner.fallback_title/1` uses when the session is still untitled
  (the server-side fallback title is written during the SAME transition, with
  no ordering guarantee, so the push cannot rely on reading it back).
- `status` — `"idle"` or `"error"`; changes the client's tone and channel.
- `excerpt` — `last_assistant_text` from `Sessions.session_tail/2`, whitespace
  collapsed and truncated to 400 chars on a WORD boundary with a trailing `…`.
  `""` (never `null`) when the turn produced no assistant text. The rule lives
  in `Sessions.truncate_excerpt/2`, shared with
  `GET /api/v1/sessions/recent?include_tail=true` — the notification body and
  the in-app list row it opens must not disagree about where the text stops.

`extras.orca` is namespaced so it can never collide with Gotify's own
`client::*` extras. `Notify.build_extras/1` takes a generic `extras` map
passthrough, merged under the caller's own keys; `markdown`/`click_url` still
add their `client::*` entries on top and win any key clash.

## When it fires

The CHANNEL broadcast fires on every eligible turn end, with no flag; the
GOTIFY push additionally requires `ORCA_NOTIFY_ON_FINISH` on the runner's
node. Both come only from
`SessionRunner.handle_turn_end/3`, which is reached from exactly the
five `running -> idle|error` paths (one-shot exit, streaming idle, streaming
error, streaming port-exit-mid-turn, kill-switch downgrade). So: once per turn
end, on the transition itself — never from an idle heartbeat or a status
refresh, and never for a session that was not running this turn.

Suppressed for:

- background sessions (`kind: "memory_extraction"`);
- CHILD sessions (`parent_session_id` set and not the session's own id) — a
  worker reports to its orchestrator, not to the phone, so a twenty-worker
  swarm doesn't buzz once per worker per turn. The phone/Auto/Wear surfaces
  exist for the sessions Zach talks to himself: roots, orchestrators (roots)
  and trigger sessions. A child adopted via `detach_session` becomes a root
  and starts notifying again, no flag needed;
- archived sessions (`archived_at` set);
- non-turn-end statuses — `"waiting"` (an unanswered AskUserQuestion) and
  `"compacting"` both map to `nil` via `notify_status/1`;
- (GOTIFY ONLY) **every node where `ORCA_NOTIFY_ON_FINISH` is unset** — the
  default (see "Enabling it" below); an explicit `false` / `0` also
  suppresses. The channel broadcast is unaffected by the flag;
- (GOTIFY ONLY) a hub with no `GOTIFY_TOKEN`, which is a SILENT no-op —
  `{:ok, :skipped}`, no log line, so an unconfigured hub produces no
  per-turn log spam.

The first four bullets are ONE predicate,
`SessionRunner.turn_end_push_eligible?/2`, consulted once before the hub hop
— so a suppression rule can never apply to one wire and not the other.

There is deliberately **no per-session opt-out**: `sessions` has no generic
settings map to hang one off, and the brief ruled out inventing a migration.
`notify_parent` is NOT reused for this — it means "ping my parent session",
a different audience and a different decision; the child suppression above is
unconditional and does not consult it. A per-session push flag is a later,
separate call.

## Where it runs

`SessionRunner.maybe_emit_turn_end/3` spawns a `Task.Supervisor` child, so
neither wire can block or crash the transition; the task itself
rescues/catches everything and only logs, and the hub-side fan-out
(`OrcaHub.SessionEvents.turn_end/1`) additionally rescues around each
broadcast and around the Gotify hand-off, so one failing wire cannot take
the other down.

The runner may be on an agent node. It sends only `session_id`,
`session_title`, `status` and `gotify:` (its own node's flag) through
`HubRPC.send_session_turn_end/1`; the hub fills in `excerpt` (ONE DB read,
shared by both wires) and the click URL (from the HUB's endpoint URL, which
is the public ingress host — an agent node's `PHX_HOST` is typically a LAN
address). So an agent node needs neither `GOTIFY_TOKEN` nor DB access for
this, exactly like the `send_notification` tool. PubSub auto-distributes via
`:pg`, so a socket held on any node still receives the broadcast.

## Enabling it

`ORCA_NOTIFY_ON_FINISH=true` (or `1`) turns the GOTIFY push on — it does not
gate the channel broadcast, which always fires. **Defaults OFF** (D6,
above) — unset, empty, `false` and `0` all mean no push, so there is nothing
to "silence": a node stays quiet until someone opts it in. It is read on the
RUNNER's node (`SessionRunner.finish_notifications_enabled?/0` →
`Application.get_env(:orca_hub, :notify_on_finish, false) == true`, set from
the env var in `config/runtime.exs`), so set it on the node whose sessions
should push, not only on the hub. The MCP `send_notification` tool is
unaffected by it and keeps working regardless.

In `:test`, `config/runtime.exs` forces `:gotify_token` to `nil` regardless of
a developer's `.env`, because `mix test` drives real turn-end transitions —
tests that want the HTTP path set `:gotify_token` plus `:gotify_req_options`
(`plug: {Req.Test, …}`) themselves.

## Tests

`test/orca_hub/session_turn_end_broadcast_test.exs` (the channel wire: the
five fields, the per-session topic, suppression, and that it fires with the
Gotify flag OFF),
`test/orca_hub_web/channels/session_events_channel_test.exs` (socket auth,
topic authorization, `ping`, no-backlog-on-join),
`test/orca_hub/session_finish_notification_test.exs` (the Gotify wire's
contract, suppression,
the opt-in switch — its `setup` enables the flag, since every delivery AND
suppression assertion there would otherwise pass for the wrong reason) and the
extras-passthrough block in
`test/orca_hub/mcp/tools/notify_test.exs`.
