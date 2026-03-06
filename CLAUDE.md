# OrcaHub

Phoenix LiveView app for managing Claude Code sessions via a web UI.

## Development

- `mix phx.server` to start the dev server
- Logs are written to `log/dev.log` — use `tail -f log/dev.log` to monitor

## Architecture

- **SessionRunner** (`lib/orca_hub/session_runner.ex`): GenServer that manages a Claude CLI session via a port. Sends prompts, parses streaming JSON output, persists messages, and broadcasts events via PubSub.
- **SessionLive.Show** (`lib/orca_hub_web/live/session_live/show.ex`): LiveView for viewing/interacting with a session. Handles message sending, image uploads, and file uploads.
- **MessageComponents** (`lib/orca_hub_web/components/message_components.ex`): Function components for rendering the message feed (user, assistant, tool use, results, system events).
- **OrcaHub.Claude** (`lib/orca_hub/claude/`): Modules for interacting with Claude CLI — builds CLI args (`Config`), parses streaming NDJSON output (`StreamParser`), and fetches usage metrics (`Usage`).

## Common issues

- Database timestamps are `NaiveDateTime` — convert to `DateTime` (with `"Etc/UTC"`) before passing to `DateTime.diff/3` or other `DateTime` functions

## Key patterns

- Messages are stored as flexible maps in a `data` column (no fixed schema for message content)
- File uploads save to the session's working directory so Claude can access them via its Read tool
- Document uploads are saved to the session's working directory for Claude to access
- Index tables use `row_click` with `JS.navigate` to make rows clickable to the show page (no separate View/Edit action links). See projects and issues index pages for examples.
- Sessions are grouped by directory in the index view, sorted by most recently updated
- Title auto-generation uses OpenAI API (`gpt-5-nano`)

## Dependencies

- Phoenix LiveView ~> 1.1
- Req for HTTP requests
- DaisyUI/Tailwind for styling
