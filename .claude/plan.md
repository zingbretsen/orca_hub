# MCP Server Implementation Plan

## Overview
Add a hand-rolled MCP server (Streamable HTTP transport) to OrcaHub with two initial tools:
1. **`start_session_from_issue`** — Creates and starts a Claude session for a given issue
2. **`get_human_feedback`** — Posts a question into the queue and blocks until a human responds

No external MCP library — the protocol is simple enough for tools-only support.

## Architecture

### MCP Server GenServer (`lib/orca_hub/mcp/server.ex`)
- Manages MCP session state (session ID, initialized flag)
- Stores registered tools and dispatches `tools/call` requests
- Each MCP session gets its own GenServer, tracked by session ID in a Registry
- Handles JSON-RPC message routing: `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`

### MCP Plug (`lib/orca_hub/mcp/plug.ex`)
- Mounted at `/mcp` in the router
- **POST**: Parses JSON-RPC request, routes to the MCP Server GenServer, returns JSON response
- **GET**: Returns 405 (no server-initiated SSE needed for now)
- **DELETE**: Terminates the MCP session
- Manages `Mcp-Session-Id` header — generates on `initialize`, validates on subsequent requests
- Returns `Content-Type: application/json` (no SSE streaming needed for synchronous tool calls)

### Tools

#### `start_session_from_issue`
- **Input**: `{ issue_id: integer, prompt?: string }`
- **Behavior**:
  - Looks up the issue, creates a session (using the issue's project directory), starts the SessionRunner
  - Sends the issue description (+ optional extra prompt) as the first message
  - Updates issue status to `in_progress`
  - Returns the session ID

#### `get_human_feedback`
- **Input**: `{ question: string, session_id?: integer }`
- **Behavior**:
  - Creates a "feedback request" entry — stored in a new `feedback_requests` table
  - Broadcasts via PubSub so it shows up in the Queue UI alongside idle sessions
  - **Blocks** the MCP tool call (the GenServer waits) until a human submits a response via the Queue UI
  - Returns the human's response text

### Feedback Requests Schema (`lib/orca_hub/feedback/feedback_request.ex`)
- `id`, `question` (string), `session_id` (optional FK), `response` (string, nullable), `status` (pending/responded), timestamps
- Context module: `lib/orca_hub/feedback.ex`
- Migration: `create_feedback_requests`

### Queue UI Changes
- Load pending feedback requests alongside idle sessions in `QueueLive`
- Render feedback request cards with the question text and a response input
- On submit, update the feedback request and notify the waiting MCP GenServer via PubSub

## Files to Create
1. `lib/orca_hub/mcp/server.ex` — MCP session GenServer
2. `lib/orca_hub/mcp/plug.ex` — HTTP transport Plug
3. `lib/orca_hub/mcp/tools.ex` — Tool definitions and dispatch
4. `lib/orca_hub/feedback.ex` — Feedback context
5. `lib/orca_hub/feedback/feedback_request.ex` — Schema
6. `priv/repo/migrations/..._create_feedback_requests.exs` — Migration

## Files to Modify
1. `lib/orca_hub_web/router.ex` — Add `/mcp` route (forward to Plug)
2. `lib/orca_hub/application.ex` — Add MCP Registry to supervision tree
3. `lib/orca_hub_web/live/queue_live.ex` — Load and render feedback requests
4. `lib/orca_hub_web/live/queue_live.html.heex` — Feedback request cards with response form

## Implementation Order
1. Migration + Feedback schema/context
2. MCP Server GenServer (JSON-RPC handling, session management)
3. MCP Plug (HTTP transport)
4. Tool implementations
5. Router wiring
6. Queue UI integration for feedback requests
