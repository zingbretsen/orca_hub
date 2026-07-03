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
  - {"type":"prompt","message":"say hi"} -> {"type":"response","command":"prompt",
                                        "success":true}, then emits (in order):
                                        agent_start, message_end{toolCall bash},
                                        tool_execution_end, message_end{text},
                                        agent_end.
  - {"type":"prompt","message":"ask a question"} -> same response, then emits
                                        (in order): agent_start,
                                        message_end{toolCall "question"},
                                        extension_ui_request{method:"select"}
                                        (blocking — see below),
                                        tool_execution_end, message_end{text
                                        reflecting the answer}, agent_end.
                                        Exercises the "pi backend groundwork"
                                        extension-UI reply loop
                                        (Backend.Pi.handle_peer_request/2 /
                                        encode_ui_response/3,
                                        SessionRunner.answer_ui_request/3):
                                        after emitting the
                                        extension_ui_request this BLOCKS
                                        reading one more stdin line for the
                                        matching extension_ui_response,
                                        mirroring the real pi binary's
                                        documented blocking behavior.
  - {"type":"abort"}               -> {"type":"response","command":"abort",
                                        "success":true} (no further events —
                                        mirrors the codex stub's posture that a
                                        genuine mid-flight race isn't
                                        reproducible against a stub that
                                        answers synchronously).
  - {"type":"get_session_stats"}   -> {"type":"response",
                                        "command":"get_session_stats",
                                        "success":true,"data":{"tokens":…,
                                        "cost":…,"contextUsage":…}} — the real
                                        Backend.Pi queues exactly this command
                                        after every agent_end (spec §12.3); no
                                        "id" on either side, matching the real
                                        adapter's usage.

Every stdout write is flushed explicitly — this is a pipe, not a tty.
"""

import json
import sys

SESSION_ID = "stub-pi-session-1"


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def handle_ask_a_question(message):
    send({"type": "response", "command": "prompt", "success": True})
    send({"type": "agent_start"})

    send(
        {
            "type": "message_end",
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "toolCall",
                        "id": "call-question-1",
                        "name": "question",
                        "arguments": {
                            "question": "Red or blue?",
                            "options": [{"label": "Red"}, {"label": "Blue"}],
                        },
                    }
                ],
                "usage": {"input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.00001}},
                "stopReason": "toolUse",
            },
        }
    )

    send(
        {
            "type": "extension_ui_request",
            "id": "ui-req-1",
            "method": "select",
            "title": "Red or blue?",
            "options": ["Red", "Blue"],
            "timeout": 600000,
        }
    )

    # Block for the extension_ui_response — mirrors the real binary's
    # documented blocking behavior for dialog methods (docs/rpc.md).
    answer_line = sys.stdin.readline()
    try:
        answer = json.loads(answer_line) if answer_line.strip() else {}
    except ValueError:
        answer = {}
    value = answer.get("value", "(no answer)")

    send(
        {
            "type": "tool_execution_end",
            "toolCallId": "call-question-1",
            "toolName": "question",
            "result": {"content": [{"type": "text", "text": f"User answered: {value}"}]},
            "isError": False,
        }
    )

    send(
        {
            "type": "message_end",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": f"You picked {value}."}],
                "usage": {"input": 5, "output": 5, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.00001}},
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
                    "content": [{"type": "text", "text": f"You picked {value}."}],
                    "usage": {"input": 5, "output": 5, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.00001}},
                    "stopReason": "stop",
                },
            ],
        }
    )


def handle_prompt(message):
    if message == "ask a question":
        handle_ask_a_question(message)
        return

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
        elif msg_type == "get_session_stats":
            send(
                {
                    "type": "response",
                    "command": "get_session_stats",
                    "success": True,
                    "data": {
                        "sessionFile": "/tmp/stub-pi-session/session.jsonl",
                        "sessionId": SESSION_ID,
                        "tokens": {
                            "input": 130,
                            "output": 32,
                            "cacheRead": 0,
                            "cacheWrite": 0,
                            "total": 162,
                        },
                        "cost": 0.00015,
                        "contextUsage": {"tokens": 200, "contextWindow": 128000, "percent": 1},
                    },
                }
            )
        # Unrecognized commands are ignored — the real pi has a much larger
        # surface; this stub only needs the happy-path subset above.


if __name__ == "__main__":
    main()
