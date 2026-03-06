# OrcaHub

A Phoenix LiveView web UI for managing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Create, monitor, and interact with multiple Claude Code CLI sessions from your browser.

## Prerequisites

- **Elixir & Erlang** — Install via [asdf](https://asdf-vm.com/) or see the [official Elixir installation guide](https://elixir-lang.org/install.html). OrcaHub requires Elixir ~> 1.15.
- **PostgreSQL** — See [Database Setup](#database-setup) below.
- **Claude Code CLI** — Install the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) and authenticate it. OrcaHub spawns Claude sessions via the CLI.

## Database Setup

The easiest way to run PostgreSQL is with Docker:

```bash
docker compose up -d
```

This starts a PostgreSQL 17 instance with the default credentials (see `docker-compose.yml`). Data is persisted in a Docker volume.

If you already have PostgreSQL running locally, create a user and database matching your `.env` (see below) or adjust the credentials to match your setup.

## Getting Started

1. **Clone both repositories** (OrcaHub depends on [ex_orca](https://github.com/zingbretsen/ex_orca) as a sibling directory):

   ```bash
   git clone git@github.com:zingbretsen/orca_hub.git
   git clone git@github.com:zingbretsen/ex_orca.git
   ```

2. **Configure environment variables:**

   ```bash
   cd orca_hub
   cp .env.example .env
   ```

   Edit `.env` if your database credentials differ from the defaults. Optionally add an `OPENAI_API_KEY` for automatic session title generation.

3. **Start PostgreSQL** (if using Docker):

   ```bash
   docker compose up -d
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
| `DB_USERNAME` | `orca_hub` | PostgreSQL username |
| `DB_PASSWORD` | `postgres` | PostgreSQL password |
| `DB_HOST` | `127.0.0.1` | PostgreSQL host |
| `DB_NAME` | `orca_hub_dev` | Database name |
| `PORT` | `4000` | HTTP server port |
| `OPENAI_API_KEY` | — | Enables auto-generated session titles |

## Development

- **Logs:** `tail -f log/dev.log`
- **Live Dashboard:** [localhost:4000/dev/dashboard](http://localhost:4000/dev/dashboard)
- **Tests:** `mix test`
- **Linting:** `mix credo`

## Learn More

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view)
- [Phoenix Deployment Guides](https://hexdocs.pm/phoenix/deployment.html)
