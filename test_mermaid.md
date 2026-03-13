# Mermaid Test

## Flowchart

```mermaid
graph TD
    A[Start] --> B{Decision}
    B -->|Yes| C[Do something]
    B -->|No| D[Do something else]
    C --> E[End]
    D --> E
```

## Sequence Diagram

```mermaid
sequenceDiagram
    participant User
    participant OrcaHub
    participant Claude

    User->>OrcaHub: Send prompt
    OrcaHub->>Claude: Forward to CLI
    Claude-->>OrcaHub: Stream response
    OrcaHub-->>User: Display messages
```
