defmodule OrcaHub.Repo.Migrations.EnablePgvector do
  @moduledoc """
  Precondition check: fails loudly if the pgvector `vector` extension isn't
  already installed, instead of trying to install it.

  This migration deliberately does NOT run `CREATE EXTENSION` — nothing
  guarantees a fresh database has had it installed yet, and this migration
  isn't the place to fix that. On 2026-09-14 an earlier version of this
  migration tried to install it anyway and crash-looped the prod k3s hub
  pod on every boot; the deploy had to be rolled back. Enabling the
  extension is a manual, one-time-per-database provisioning step (see
  `up/0` for the exact command) — this migration only verifies that step
  already happened. The shared Postgres image now marks pgvector's
  `vector.control` `trusted = true`, so the database's own owner role can
  run `CREATE EXTENSION vector` itself; the `postgres` superuser form is
  only needed as a fallback for a database still owned by `postgres`.
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

      This migration deliberately doesn't install it for you. pgvector's
      control file is marked `trusted`, so the database's own owner role
      can run `CREATE EXTENSION vector` itself — or, as the `postgres`
      superuser on the host running the shared Postgres container, run:

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
