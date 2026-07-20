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
  - {"type":"prompt","message":"PAUSE_FOR_STEER"} -> the same "prompt"
                                        response + agent_start as above, then
                                        PAUSES (no further events) instead of
                                        completing — simulates a still-running
                                        turn so a test can drive
                                        OrcaHub.Backend.Pi's mid-turn steering
                                        path (backend_abstraction_spec.md
                                        §12.6).
  - {"type":"prompt","message":"TRIGGER_ERROR"} -> the same "prompt" response
                                        + agent_start as above, then an
                                        agent_end whose last assistant message
                                        has stopReason "error" (mirrors a
                                        genuine CLI-reported failure, e.g. "not
                                        logged in") — no tool calls, no
                                        success text. Lets a test drive a
                                        REAL turn-level streaming error against
                                        a live warm port (SessionRunner's
                                        :error-state warm-port teardown fix).
  - {"type":"steer","message":…}   -> {"type":"response","command":"steer",
                                        "success":true}, then emits (in
                                        order): queue_update (queue now
                                        empty), compaction_start/compaction_end
                                        (reason "manual"), message_end{text
                                        "Steered: <message>"}, agent_end —
                                        only meaningful after a
                                        PAUSE_FOR_STEER prompt.
  - {"type":"prompt","message":"/plan"} -> (spec §12.4, SessionRunner.
                                        toggle_plan_mode/1's happy path)
                                        mirrors the REAL binary's live-verified
                                        behavior for a pure extension command:
                                        NO agent_start/agent_end at all, just
                                        a fire-and-forget
                                        extension_ui_request{method:"setStatus",
                                        statusKey:"orca-plan-mode"} (the
                                        orca-plan.ts broadcastPlanState() call)
                                        followed by
                                        {"type":"response","command":"prompt",
                                        "success":true}.
  - {"type":"compact"}             -> (spec §12.8, SessionRunner.
                                        compact_session/1's happy path)
                                        mirrors handle_steer's posture: acks
                                        with a response, then emits
                                        compaction_start/compaction_end (with
                                        a populated "result", the SUCCESS
                                        shape from docs/rpc.md — the live
                                        binary's own "session too small"
                                        errorMessage failure shape is already
                                        covered by pi_test.exs's normalize/2
                                        unit tests + the live smoke, not
                                        re-derived here).

Every stdout write is flushed explicitly — this is a pipe, not a tty.
"""

import json
import os
import sys

SESSION_ID = "stub-pi-session-1"

# Optional command-received log (backend_abstraction_spec.md §12.6 test
# support): when set, every command's "type" is appended to this file, one
# per line, so a test can assert exactly which commands were sent (e.g. that
# a mid-turn steer never fell back to "abort").
STUB_LOG = os.environ.get("PI_STUB_LOG")


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log_command(msg_type):
    if STUB_LOG:
        with open(STUB_LOG, "a") as f:
            f.write(msg_type + "\n")


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


def handle_plan_toggle():
    # Live-verified against the real 0.80.3 binary (spec §12.4): a pure
    # extension command never starts an agent turn — just the
    # fire-and-forget status broadcast, then the prompt ack.
    send(
        {
            "type": "extension_ui_request",
            "id": "plan-status-1",
            "method": "setStatus",
            "statusKey": "orca-plan-mode",
            "statusText": json.dumps({"enabled": True, "executing": False}),
        }
    )
    send({"type": "response", "command": "prompt", "success": True})


def handle_prompt(message):
    if message == "ask a question":
        handle_ask_a_question(message)
        return

    if message == "/plan":
        handle_plan_toggle()
        return

    send({"type": "response", "command": "prompt", "success": True})
    send({"type": "agent_start"})

    if message == "PAUSE_FOR_STEER":
        # spec §12.6 test support: stop here and wait for a "steer" command
        # instead of completing immediately — simulates a turn that's still
        # in flight (mid tool-call loop) when the user sends a mid-turn
        # message, exercising OrcaHub.Backend.Pi's steering path (see
        # handle_steer below) instead of the default happy path below.
        return

    if message == "TRIGGER_ERROR":
        send(
            {
                "type": "agent_end",
                "messages": [
                    {"role": "user", "content": [{"type": "text", "text": message}]},
                    {
                        "role": "assistant",
                        "content": [],
                        "usage": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0}},
                        "stopReason": "error",
                        "errorMessage": "Not logged in · Please run /login",
                    },
                ],
                "willRetry": False,
            }
        )
        return

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


def handle_steer(message):
    # spec §12.6: mirrors what a real turn does with a mid-flight steer —
    # acks the command, reports the (now-empty) queue, runs a manual
    # compaction, then finishes the turn with text that echoes the steered
    # instruction (so the test can tell the steer was actually delivered,
    # not dropped/queued-and-resent).
    send({"type": "response", "command": "steer", "success": True})
    send({"type": "queue_update", "steering": [], "followUp": []})
    send({"type": "compaction_start", "reason": "manual"})
    send(
        {
            "type": "compaction_end",
            "reason": "manual",
            "result": {
                "summary": "Summary of conversation...",
                "firstKeptEntryId": "abc123",
                "tokensBefore": 1000,
                "estimatedTokensAfter": 200,
                "details": {},
            },
            "aborted": False,
            "willRetry": False,
        }
    )

    steered_text = "Steered: " + message

    send(
        {
            "type": "message_end",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": steered_text}],
                "usage": {"input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.00002}},
                "stopReason": "stop",
            },
        }
    )

    send(
        {
            "type": "agent_end",
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "PAUSE_FOR_STEER"}]},
                {
                    "role": "assistant",
                    "content": [{"type": "text", "text": steered_text}],
                    "usage": {"input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": 0.00002}},
                    "stopReason": "stop",
                },
            ],
            "willRetry": False,
        }
    )


def handle_compact():
    # spec §12.8: mirrors handle_steer's posture (ack, then async lifecycle
    # events) — the SUCCESS shape from docs/rpc.md's own "compact" example,
    # since the "too small" errorMessage failure shape is exercised via the
    # real pi binary in the live smoke + unit-tested directly in
    # pi_test.exs's normalize/2 coverage.
    send({"type": "response", "command": "compact", "success": True, "data": {
        "summary": "Summary of conversation...",
        "firstKeptEntryId": "abc123",
        "tokensBefore": 150000,
        "estimatedTokensAfter": 32000,
        "details": {},
    }})
    send({"type": "compaction_start", "reason": "manual"})
    send(
        {
            "type": "compaction_end",
            "reason": "manual",
            "result": {
                "summary": "Summary of conversation...",
                "firstKeptEntryId": "abc123",
                "tokensBefore": 150000,
                "estimatedTokensAfter": 32000,
                "details": {},
            },
            "aborted": False,
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
        log_command(msg_type)

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
        elif msg_type == "steer":
            handle_steer(msg.get("message", ""))
        elif msg_type == "compact":
            handle_compact()
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
