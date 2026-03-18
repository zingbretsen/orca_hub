# Terminal System

Embedded web terminals powered by xterm.js, with PTY management via
`script -qc` running under an Erlang Port.

## Data Flow

```mermaid
sequenceDiagram
    participant User
    participant xterm as xterm.js<br>(Browser)
    participant Channel as TerminalChannel<br>(Phoenix Channel)
    participant Runner as TerminalRunner<br>(GenServer)
    participant PTY as script -qc<br>(Port)
    participant Shell as /bin/bash

    User->>xterm: Keystroke
    xterm->>Channel: push "input" {data: base64}
    Channel->>Runner: write(terminal_id, bytes)
    Runner->>PTY: Port.command(port, bytes)
    PTY->>Shell: stdin → shell

    Shell->>PTY: PTY output (echo + result)
    PTY->>Runner: stdout → Port {:data, bytes}
    Runner->>Runner: Append to scrollback buffer (64KB ring)
    Runner-->>Channel: PubSub broadcast<br>("term_output:#{id}")
    Channel->>xterm: push "output" {data: base64}
    xterm->>User: Render ANSI output
```

## Architecture

```mermaid
graph TB
    subgraph Browser
        XT["xterm.js<br>(Terminal hook)"]
    end

    subgraph "Phoenix (Web Layer)"
        WS["WebSocket<br>/terminal_socket"]
        CH["TerminalChannel<br>(per browser tab)"]
        LV_I["TerminalLive.Index<br>/terminals"]
        LV_S["TerminalLive.Show<br>/terminals/:id"]
    end

    subgraph "Core"
        TR["TerminalRunner<br>(GenServer, one per terminal)"]
        TS["TerminalSupervisor<br>(DynamicSupervisor)"]
        REG["TerminalRegistry<br>(Registry)"]
        CTX["Terminals Context"]
    end

    subgraph "PTY Layer"
        PY["script -qc /bin/bash<br>(Erlang Port)"]
        SH["/bin/bash"]
    end

    subgraph "Infrastructure"
        PS["Phoenix.PubSub<br>term_output:id"]
        DB["PostgreSQL<br>(terminals table)"]
    end

    XT <-->|"WebSocket<br>base64 I/O"| WS
    WS --> CH
    CH -->|"write/resize"| TR
    TR -->|"broadcast"| PS
    PS -->|"handle_info"| CH

    LV_I -->|"CRUD"| CTX
    LV_S -->|"start/stop"| TS

    TS -->|"start_child"| TR
    TR -->|"register"| REG
    TR -->|"Port.open"| PY
    PY --> SH
    CTX --> DB

    TR -->|"status updates"| PS
    PS -.->|"terminals topic"| LV_I
```

## PubSub Topic Design

```
term_output:<terminal_id>   → per-terminal output + status + exit events
                               (subscribed by TerminalChannel)

terminals                   → aggregate events for index page
                               (subscribed by TerminalLive.Index)
```

**Important:** The `term_output:` prefix is intentionally different from the
Channel topic `terminal:`. Phoenix Channels internally subscribe the channel
process to PubSub using the channel topic name. Using the same name would
cause double delivery (`:pg.join` allows duplicate joins).

## Terminal Lifecycle

```mermaid
stateDiagram-v2
    [*] --> stopped: Terminal created<br>(DB record)

    stopped --> running: start_terminal<br>(TerminalSupervisor)
    running --> stopped: stop_terminal<br>(graceful shutdown)
    running --> dead: PTY process exits<br>(non-zero or crash)
    dead --> running: start_terminal<br>(restart)
    stopped --> [*]: delete_terminal

    note right of running
        TerminalRunner GenServer active.
        Port open to Python PTY wrapper.
        Output streamed via PubSub.
        Scrollback buffer maintained (64KB).
    end note
```

## PTY Implementation

The PTY is managed via `script -qc /bin/bash /dev/null` spawned as an
Erlang Port — the same pattern used by `SessionRunner` for Claude CLI.
`script` allocates a PTY so the shell behaves as an interactive terminal
(colored output, line editing, etc.). The typescript file is `/dev/null`
so only PTY output flows through the port.

## Multi-Client Pairing

Multiple browser tabs can join the same `terminal:<id>` Channel topic.
Each receives the same output stream. Input from any client goes to the
same PTY. This enables user-agent pairing: a human and a Claude session
can both view and type in the same terminal.

## Cluster Integration

Terminals follow the same pattern as sessions:
- `runner_node` field tracks which node owns the PTY process
- `Cluster.start_terminal(node, id)` routes via `:erpc`
- `HubRPC` proxies DB operations to the hub node
- `TerminalRegistry` and `TerminalSupervisor` run on every node
