# Session Lifecycle

SessionRunner is a GenStatem with 5 states.

```mermaid
stateDiagram-v2
    [*] --> ready: Session created\n(no messages yet)
    [*] --> idle: Session resumed\n(has saved messages)

    ready --> running: send_message
    idle --> running: send_message
    error --> running: send_message

    running --> idle: CLI exits (code 0)\nno pending prompts
    running --> running: CLI exits\npending prompts\n(auto-resume)
    running --> error: CLI exits (code ≠ 0)\nno pending prompts
    running --> waiting: get_human_feedback\nMCP tool called
    running --> compacting: context window full\n(auto-compact)

    compacting --> running: compact complete

    waiting --> running: feedback answered\n+ pending prompts
    waiting --> idle: feedback answered\nno pending prompts
    waiting --> running: CLI exits\npending feedback\n(auto-resume)

    note right of running
        CLI process active via Port.
        Streams NDJSON events.
        Messages persisted and broadcast.
    end note

    note right of waiting
        Blocks until human responds
        via MCP feedback tool.
    end note
```
