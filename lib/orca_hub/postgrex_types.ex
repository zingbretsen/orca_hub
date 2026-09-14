# pgvector's `vector` (plus `halfvec`/`sparsevec`) column types are not part of
# Postgrex's built-in extension set, so Postgrex needs a custom types module
# that combines pgvector's extensions with the Postgres adapter's own. Without
# this, reading an `issue_chunks.embedding` back out of the DB fails with an
# "no extension found for oid" error.
#
# `Postgrex.Types.define/3` DEFINES a module at compile time, which is why this
# file holds no `defmodule` of its own. The module is wired into the Repo via
# `config :orca_hub, OrcaHub.Repo, types: OrcaHub.PostgrexTypes` in
# config/config.exs (shared by dev/test/prod), mirroring phx-app's
# lib/phx_app/postgrex_types.ex.
Postgrex.Types.define(
  OrcaHub.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
