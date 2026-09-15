defmodule OrcaHub.Repo.Migrations.EnablePgvector do
  @moduledoc """
  Precondition check: fails loudly if the pgvector `vector` extension isn't
  already installed, instead of trying to install it.

  This migration deliberately does NOT run `CREATE EXTENSION` — the app's
  `orca_hub` role is not a superuser, and this Postgres image's
  `vector.control` has no `trusted` line, so `CREATE EXTENSION vector` is
  superuser-only no matter who owns the database. On 2026-09-14 an earlier
  version of this migration tried it anyway and crash-looped the prod k3s
  hub pod on every boot; the deploy had to be rolled back. Enabling the
  extension is now a manual, one-time-per-database provisioning step run by
  the `postgres` superuser (see `up/0` for the exact command) — this
  migration only verifies that step already happened.
  """

  use Ecto.Migration

  # The shared homelab Postgres runs as a plain Docker container named
  # `postgres` on the k3s host, NOT inside k3s — so the superuser path is a
  # `docker exec` on that host rather than a psql connection over the LAN.
  @enable_command ~s|docker exec postgres psql -U postgres -d <DATABASE> -c "CREATE EXTENSION IF NOT EXISTS vector"|

  def up do
    %{rows: rows} = repo().query!("select 1 from pg_extension where extname = 'vector'")

    if rows == [] do
      raise """
      pgvector's `vector` extension is not installed on this database.

      This migration cannot install it: the app's database role is not a
      superuser, and pgvector's control file is not marked `trusted`, so
      only the `postgres` superuser can run `CREATE EXTENSION vector`. On
      the host running the shared Postgres container, run:

          #{@enable_command}

      ...substituting this database's name, then re-run `mix ecto.migrate`.
      """
    end
  end

  # Deliberately NOT `DROP EXTENSION` — dropping it would cascade away every
  # `vector` column (issue_chunks.embedding) in a database whose extension
  # an operator installed out-of-band, and a non-superuser role can't
  # recreate it. Rolling this migration back leaves the extension in place.
  def down do
    :ok
  end
end
