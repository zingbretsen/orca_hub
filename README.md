# OrcaHub

A Phoenix LiveView web UI for managing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Create, monitor, and interact with multiple Claude Code CLI sessions from your browser.

## Quick Start with Docker

The fastest way to run OrcaHub — no Elixir or PostgreSQL installation needed.

1. **Clone and configure:**

   ```bash
   git clone https://github.com/zingbretsen/orca_hub.git
   cd orca_hub
   cp .env.example .env
   ```

   Edit `.env` to add API keys for title generation or other optional features (see [Environment Variables](#environment-variables)).

2. **Start:**

   ```bash
   docker compose up -d
   ```

   This builds the app, starts PostgreSQL, runs migrations, and serves OrcaHub at [localhost:4000](http://localhost:4000).

3. **Authenticate Claude Code** (one-time):

   ```bash
   docker compose exec app claude login
   ```

   Credentials are stored in a Docker volume and persist across restarts.

4. **Mount your project directories** by editing `docker-compose.yml`:

   ```yaml
   volumes:
     - claude_credentials:/home/orca/.claude
     - /home/user/projects/my-app:/home/orca/projects/my-app
   ```

   Then restart with `docker compose up -d`. When creating sessions in OrcaHub, set the working directory to `/home/orca/projects/my-app`.

   > **Note:** Set `PORT` in your `.env` to change the default port.

## Local Development Setup

If you prefer to run OrcaHub outside Docker (for development or customization):

### Prerequisites

- **Elixir & Erlang** — Install via [asdf](https://asdf-vm.com/) or see the [official Elixir installation guide](https://elixir-lang.org/install.html). OrcaHub requires Elixir ~> 1.15.
- **PostgreSQL** — Run via Docker (`docker compose up db -d`) or install locally.
- **Claude Code CLI** — Install the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) and authenticate it. OrcaHub spawns Claude sessions via the CLI.

### Getting Started

1. **Clone the repository:**

   ```bash
   git clone https://github.com/zingbretsen/orca_hub.git
   ```

2. **Configure environment variables:**

   ```bash
   cd orca_hub
   cp .env.example .env
   ```

   Edit `.env` if your database credentials differ from the defaults. Optionally add an `OPENAI_API_KEY` or DataRobot credentials for automatic session title generation.

3. **Start PostgreSQL** (if using Docker):

   ```bash
   docker compose up db -d
   ```

4. **Install dependencies and set up the database:**

   ```bash
   mix setup
   ```

   This fetches dependencies, creates the database, runs migrations, and builds assets.

5. **Start the server:**

   ```bash
   mix phx.server
   ```

   Visit [localhost:4000](http://localhost:4000).

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DB_USERNAME` | `orca_hub` | PostgreSQL username (local dev only) |
| `DB_PASSWORD` | `postgres` | PostgreSQL password (local dev only) |
| `DB_HOST` | `127.0.0.1` | PostgreSQL host (local dev only) |
| `DB_NAME` | `orca_hub_dev` | Database name (local dev only) |
| `DATABASE_URL` | — | Full database URL (Docker/production, e.g. `ecto://USER:PASS@HOST/DB`) |
| `SECRET_KEY_BASE` | auto-generated | Session signing key (Docker auto-generates and persists one) |
| `PHX_HOST` | `localhost` | Hostname for URL generation |
| `PORT` | `4000` | HTTP server port |
| `OPENAI_API_KEY` | — | Enables auto-generated session titles (via OpenAI directly) |
| `DATAROBOT_API_TOKEN` | — | DataRobot API token (alternative to OpenAI for title generation) |
| `DATAROBOT_ENDPOINT` | — | DataRobot API endpoint (required if using DataRobot) |
| `TITLE_MODEL` | `azure/gpt-4o-mini` | LLM model for title generation (used with DataRobot LLM Gateway) |

## Development

- **Logs:** `tail -f log/dev.log`
- **Live Dashboard:** [localhost:4000/dev/dashboard](http://localhost:4000/dev/dashboard)
- **Tests:** `mix test`
- **Linting:** `mix credo`

## Learn More

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view)
- [Phoenix Deployment Guides](https://hexdocs.pm/phoenix/deployment.html)
