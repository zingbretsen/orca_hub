# Turn-end push payload contract (Gotify)

**Status: OPT-IN, OFF BY DEFAULT.** When enabled, a genuine SessionRunner
`running -> idle | error` transition fires ONE Gotify notification for the
sessions Zach talks to himself (roots, orchestrators, trigger sessions — see
"When it fires" for what's suppressed). Nothing is sent unless
`ORCA_NOTIFY_ON_FINISH` is set on the runner's node (see "Enabling it").
This is distinct from the `send_notification` MCP tool, which is per-call and
only fires when an agent asks for it.

**Why it defaults off (D6).** It shipped default-ON for the Android app
(ebf8ffb), and every session turn end on every node buzzed the phone — a flood
in practice. Zach then decided (D6) the app will receive finish events from a
**direct authenticated Phoenix channel on the hub** instead of via Gotify, so
Gotify is no longer this feature's delivery path for the primary consumer. The
code paths below are deliberately KEPT and still work — the push is now
something you turn on for a node when you want it, not the default behaviour.
The hub channel itself is a later phase and does not exist yet.

The consumer this payload was designed for is the unified Android app (phone +
Wear + Android Auto) — see `/home/zach/experiments/orca-watch/DESIGN.md` §7c,
§1.4 and risk **R12**. That app renders its `MessagingStyle` notification
**entirely from this payload**: when OrcaHub is unreachable (the "reply from
the car, VPN down" scenario) the client cannot call back to fill anything in.
**Anything missing from the push is missing forever.** Treat the four fields
below as a contract, not a convenience, and do not rename or drop one without
changing the client — the same four fields are the obvious starting shape for
the hub channel that replaces this path.

## The wire shape

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

Only when `ORCA_NOTIFY_ON_FINISH` is enabled on the runner's node, and then
only from `SessionRunner.handle_turn_end/3`, which is reached from exactly the
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
- **every node where `ORCA_NOTIFY_ON_FINISH` is unset** — the default (see
  "Enabling it" below); an explicit `false` / `0` also suppresses;
- a hub with no `GOTIFY_TOKEN`, which is a SILENT no-op — `{:ok, :skipped}`,
  no log line, so an unconfigured hub produces no per-turn log spam.

There is deliberately **no per-session opt-out**: `sessions` has no generic
settings map to hang one off, and the brief ruled out inventing a migration.
`notify_parent` is NOT reused for this — it means "ping my parent session",
a different audience and a different decision; the child suppression above is
unconditional and does not consult it. A per-session push flag is a later,
separate call.

## Where it runs

`maybe_notify_finished/3` spawns a `Task.Supervisor` child, so delivery can
never block or crash the transition; the task itself rescues/catches
everything and only logs.

The runner may be on an agent node. It sends only `session_id`,
`session_title` and `status` through `HubRPC.send_session_finished_notification/1`;
the hub fills in `excerpt` (a DB read) and the click URL (from the HUB's
endpoint URL, which is the public ingress host — an agent node's `PHX_HOST`
is typically a LAN address). So an agent node needs neither `GOTIFY_TOKEN`
nor DB access for this, exactly like the `send_notification` tool.

## Enabling it

`ORCA_NOTIFY_ON_FINISH=true` (or `1`) turns the push on. **Defaults OFF** (D6,
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

`test/orca_hub/session_finish_notification_test.exs` (contract, suppression,
the opt-in switch — its `setup` enables the flag, since every delivery AND
suppression assertion there would otherwise pass for the wrong reason) and the
extras-passthrough block in
`test/orca_hub/mcp/tools/notify_test.exs`.
