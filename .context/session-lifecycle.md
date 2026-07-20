# Session Lifecycle

SessionRunner is a GenStatem (`callback_mode: :state_functions`) with 4
states: `ready`, `idle`, `running`, `error`. `"waiting"` and `"compacting"`
are **not** separate GenStatem states — they're persisted `status` strings /
broadcasts overlaid on `idle`/`running` (see notes below). Which engine
drives a turn (one-shot vs streaming) is decided per-message by
`resolve_engine/1` — see `.context/message-flow.md` — but both engines land
on the same four states below.

```mermaid
stateDiagram-v2
    [*] --> ready: Session created\n(no messages yet)
    [*] --> idle: Session resumed\n(has saved messages)

    ready --> running: send_message
    idle --> running: send_message
    error --> running: send_message

    running --> idle: Turn completes cleanly\n(port exit code 0, or\nstreaming "result" event)\nno pending prompts
    running --> running: Turn completes,\npending prompts queued\n(auto-resume / steer)
    running --> error: Turn fails\n(port exit code ≠ 0)\nno pending prompts

    idle --> idle: idle_teardown timeout (15 min)\nor evict_warm (WarmPool pressure):\ncloses warm port, stays idle
    error --> error: idle_teardown timeout\nor evict_warm: closes warm port

    running --> idle: kill-switch downgrade\n(streaming → one-shot,\ngraceful: finishes turn first)

    note right of running
        One-shot: CLI process active via fresh Port per turn.
        Streaming: long-lived warm Port reused across turns;
        a turn arriving mid-run steers in place or sends a
        control_request interrupt (port survives).
        Messages persisted and broadcast either way.
        "compacting" and "waiting" statuses are persisted to
        DB and broadcast without a GenStatem state transition.
    end note

    note right of idle
        Streaming engine only: entering idle/error with a live
        port arms a 15-minute idle_teardown state_timeout.
        On fire (or on-demand evict_warm from WarmPool under
        capacity pressure), the port is closed and its WarmPool
        slot released — session stays idle/error but goes cold.
        Next message re-opens the port with --resume / a native
        resume id.
    end note
```

## Notes

- **`waiting`**: set when a turn completes with an unanswered
  `AskUserQuestion` pending — the GenStatem stays in `idle` (clean exit) or
  `running` (still-hung turn), but the persisted/broadcast `status` shows
  `"waiting"` until a queued answer resumes it.
- **`downgrade`**: the runtime kill switch (`Streaming.disable!/1`) forcing a
  warm streaming session back to the one-shot engine — `:graceful` finishes
  the in-flight turn first, `:interrupt` cuts it short immediately.
- **`evict_warm`**: `Streaming.WarmPool` reclaiming a warm port under
  per-node capacity pressure (`ORCA_MAX_WARM_SESSIONS`, default 6) by
  tearing down the least-recently-used idle/error session; a `running`
  session always refuses eviction.
