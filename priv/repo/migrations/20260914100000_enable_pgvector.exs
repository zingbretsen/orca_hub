defmodule OrcaHub.Repo.Migrations.EnablePgvector do
  @moduledoc """
  Enables the pgvector `vector` extension, backing `issue_chunks.embedding`.

  IMPORTANT — prod enablement is a SEPARATE MANUAL STEP, not this migration.
  `CREATE EXTENSION` requires either a superuser or a `trusted` extension
  control file, and the app's `orca_hub` role is neither on the shared
  homelab Postgres. This migration therefore succeeds as a no-op once an
  operator has run the superuser command for that database (see `up/0`), and
  fails LOUDLY with that exact command if they haven't. Dev
  (`orca_hub_dev`) is already enabled; `orca_hub_prod` / `orca_hub_mini` are
  handled as a deploy-time step.
  """

  use Ecto.Migration

  # The shared homelab Postgres runs as a plain Docker container named
  # `postgres` on the k3s host, NOT inside k3s — so the superuser path is a
  # `docker exec` on that host rather than a psql connection over the LAN.
  @enable_command ~s|docker exec postgres psql -U postgres -d <DATABASE> -c "CREATE EXTENSION IF NOT EXISTS vector"|

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")
    # `execute/1` only BUFFERS the command — Ecto's migration runner flushes
    # it at the end of `up/0`, which would be outside this `rescue` and would
    # surface the raw Postgrex "permission denied to create extension" error.
    # Flushing here is what makes the operator-facing message below reachable.
    flush()
  rescue
    error ->
      reraise """
              Could not CREATE EXTENSION vector.

              The app's database role is not a superuser and pgvector's
              control file is not marked `trusted`, so the extension must be
              created ONCE per database by the `postgres` superuser. On the
              host running the shared Postgres container, run:

                  #{@enable_command}

              ...substituting the database this migration is running against
              (orca_hub_dev / orca_hub_mini / orca_hub_prod), then re-run
              `mix ecto.migrate`. This migration is a no-op once the
              extension exists.

              Original error: #{Exception.message(error)}
              """,
              __STACKTRACE__
  end

  # Deliberately NOT `DROP EXTENSION` — dropping it would cascade away every
  # `vector` column (issue_chunks.embedding) in a database whose extension
  # an operator installed out-of-band, and a non-superuser role can't
  # recreate it. Rolling this migration back leaves the extension in place.
  def down do
    :ok
  end
end
