#!/usr/bin/env python3
"""
Minimal stand-in for `pi --mode rpc` / `pi -p --mode json`
(backend_abstraction_spec.md §12.2 / §9): speaks just enough of the real
0.80.3-verified wire protocol for `OrcaHub.Backend.Pi.PiStubIntegrationTest`
to drive a real `OrcaHub.SessionRunner` through a full cold-open -> turn ->
agent_end cycle with NO network and NO real pi install.

Always runs in "rpc-shaped" mode regardless of the `--mode`/`-p` flags the
adapter passes (this stub only needs to exercise the :streaming spawn path,
which is all `OrcaHub.SessionRunner` uses when a real executable/stub is
resolvable) — it reads commands from stdin and emits events to stdout.

Protocol handled on stdin (newline-delimited JSON, commands optionally carry
an "id", the stub does not use one on its own emitted events per the real
protocol's "events never have an id" rule — spec's docs/rpc.md):

  - {"type":"get_state"}           -> {"type":"response","command":"get_state",
                                        "success":true,"data":{"sessionId":…}}
  - {"type":"prompt","message":…}  -> {"type":"response","command":"prompt",
                                        "success":true}, then emits (in order):
                                        agent_start, message_end{toolCall bash},
                                        tool_execution_end, message_end{text},
                                        agent_end.
  - {"type":"abort"}               -> {"type":"response","command":"abort",
                                        "success":true} (no further events —
                                        mirrors the codex stub's posture that a
                                        genuine mid-flight race isn't
                                        reproducible against a stub that
                                        answers synchronously).

Every stdout write is flushed explicitly — this is a pipe, not a tty.
"""

import json
import sys

SESSION_ID = "stub-pi-session-1"


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def handle_prompt(message):
    send({"type": "response", "command": "prompt", "success": True})
    send({"type": "agent_start"})

    send(
        {
            "type": "message_end",
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "thinking", "thinking": "Need to run bash.", "thinkingSignature": ""},
                    {
                        "type": "toolCall",
                        "id": "call-stub-1",
                        "name": "bash",
                        "arguments": {"command": "echo hello"},
                    },
                ],
                "usage": {"input": 100, "output": 20, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.0001}},
                "stopReason": "toolUse",
            },
        }
    )

    send(
        {
            "type": "tool_execution_end",
            "toolCallId": "call-stub-1",
            "toolName": "bash",
            "result": {"content": [{"type": "text", "text": "hello\n"}]},
            "isError": False,
        }
    )

    send(
        {
            "type": "message_end",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "Hello from the stub pi agent!"}],
                "usage": {"input": 30, "output": 12, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.00005}},
                "stopReason": "stop",
            },
        }
    )

    send(
        {
            "type": "agent_end",
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": message}]},
                {
                    "role": "assistant",
                    "content": [
                        {"type": "thinking", "thinking": "Need to run bash.", "thinkingSignature": ""},
                        {
                            "type": "toolCall",
                            "id": "call-stub-1",
                            "name": "bash",
                            "arguments": {"command": "echo hello"},
                        },
                    ],
                    "usage": {"input": 100, "output": 20, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.0001}},
                    "stopReason": "toolUse",
                },
                {
                    "role": "toolResult",
                    "toolCallId": "call-stub-1",
                    "toolName": "bash",
                    "content": [{"type": "text", "text": "hello\n"}],
                    "isError": False,
                },
                {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "Hello from the stub pi agent!"}],
                    "usage": {"input": 30, "output": 12, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.00005}},
                    "stopReason": "stop",
                },
            ],
            "willRetry": False,
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

        msg_type = msg.get("type")

        if msg_type == "get_state":
            send(
                {
                    "type": "response",
                    "command": "get_state",
                    "success": True,
                    "data": {
                        "sessionId": SESSION_ID,
                        "sessionFile": "/tmp/stub-pi-session/session.jsonl",
                        "messageCount": 0,
                        "pendingMessageCount": 0,
                    },
                }
            )
        elif msg_type == "prompt":
            handle_prompt(msg.get("message", ""))
        elif msg_type == "abort":
            send({"type": "response", "command": "abort", "success": True})
        # Unrecognized commands are ignored — the real pi has a much larger
        # surface; this stub only needs the happy-path subset above.


if __name__ == "__main__":
    main()
