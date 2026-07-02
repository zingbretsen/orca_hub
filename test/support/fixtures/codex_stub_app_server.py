#!/usr/bin/env python3
"""
Minimal stand-in for `codex app-server` (backend_abstraction_spec.md §9 /
Phase 2 Step 4.4). Speaks just enough of the real wire protocol (verified
against codex-cli 0.142.5's generated JSON schema and a live handshake
capture) for `OrcaHub.Backend.Codex.CodexStubIntegrationTest` to drive a real
`OrcaHub.SessionRunner` through a full cold-open -> handshake -> turn ->
turn/completed cycle with NO network and NO real codex process.

Protocol handled on stdin (newline-delimited JSON, no "jsonrpc" field, IDs
echoed verbatim — §6.1):

  - "initialize" (id)      -> responds with a result, THEN reads (and
                               ignores) the "initialized" notification.
  - "thread/start" (id)    -> responds with `result.thread.id`.
  - "thread/resume" (id)   -> same response shape as thread/start (resume
                               coverage is minimal; this stub doesn't
                               distinguish threads).
  - "turn/start" (id)      -> responds with `result.turn`, then emits (in
                               order): item/completed{commandExecution},
                               item/completed{agentMessage},
                               thread/tokenUsage/updated, turn/completed.
  - "turn/interrupt" (id)  -> responds `{}`, then emits turn/completed with
                               status "interrupted" (no further items).

Every stdout write is followed by an explicit flush — this is a pipe, not a
tty, so Python's default buffering would otherwise stall the parent.
"""

import json
import sys

THREAD_ID = "stub-thread-1"
TURN_ID = "stub-turn-1"


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def handle_turn_start(req_id):
    send({"id": req_id, "result": {"turn": {"id": TURN_ID, "status": "inProgress", "items": [], "error": None}}})

    send(
        {
            "method": "item/completed",
            "params": {
                "threadId": THREAD_ID,
                "turnId": TURN_ID,
                "item": {
                    "type": "commandExecution",
                    "id": "cmd-stub-1",
                    "command": "echo hello",
                    "commandActions": [],
                    "cwd": "/tmp",
                    "status": "completed",
                    "aggregatedOutput": "hello\n",
                    "exitCode": 0,
                },
            },
        }
    )

    send(
        {
            "method": "item/completed",
            "params": {
                "threadId": THREAD_ID,
                "turnId": TURN_ID,
                "item": {
                    "type": "agentMessage",
                    "id": "msg-stub-1",
                    "text": "Hello from the stub Codex app-server!",
                    "phase": "final_answer",
                },
            },
        }
    )

    send(
        {
            "method": "thread/tokenUsage/updated",
            "params": {
                "threadId": THREAD_ID,
                "turnId": TURN_ID,
                "tokenUsage": {
                    "total": {
                        "totalTokens": 42,
                        "inputTokens": 30,
                        "outputTokens": 12,
                        "cachedInputTokens": 0,
                        "reasoningOutputTokens": 0,
                    },
                    "last": {
                        "totalTokens": 42,
                        "inputTokens": 30,
                        "outputTokens": 12,
                        "cachedInputTokens": 0,
                        "reasoningOutputTokens": 0,
                    },
                },
            },
        }
    )

    send(
        {
            "method": "turn/completed",
            "params": {
                "threadId": THREAD_ID,
                "turn": {"id": TURN_ID, "status": "completed", "items": [], "error": None, "durationMs": 5},
            },
        }
    )


def handle_turn_interrupt(req_id):
    send({"id": req_id, "result": {}})
    send(
        {
            "method": "turn/completed",
            "params": {
                "threadId": THREAD_ID,
                "turn": {"id": TURN_ID, "status": "interrupted", "items": [], "error": None},
            },
        }
    )


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            msg = json.loads(line)
        except ValueError:
            continue

        method = msg.get("method")
        req_id = msg.get("id")

        if method == "initialize" and req_id is not None:
            send(
                {
                    "id": req_id,
                    "result": {
                        "codexHome": "/tmp/stub-codex-home",
                        "platformFamily": "unix",
                        "platformOs": "linux",
                        "userAgent": "codex-stub/1.0",
                    },
                }
            )
        elif method == "initialized":
            pass  # notification, no response
        elif method in ("thread/start", "thread/resume") and req_id is not None:
            send({"id": req_id, "result": {"thread": {"id": THREAD_ID}}})
        elif method == "turn/start" and req_id is not None:
            handle_turn_start(req_id)
        elif method == "turn/interrupt" and req_id is not None:
            handle_turn_interrupt(req_id)
        # Unrecognized methods are ignored — the real app-server has a much
        # larger surface; this stub only needs the happy-path subset above.


if __name__ == "__main__":
    main()
