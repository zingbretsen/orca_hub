defmodule OrcaHub.BuildInfo do
  @moduledoc """
  Compile-time build metadata (git SHA + build timestamp), exposed
  unauthenticated via `GET /api/version` so the deploy script can poll each
  running instance until it reports the SHA it just deployed.

  The SHA is resolved, in order:

    1. `priv/git_sha`, a file the Dockerfile generates (`echo "$GIT_SHA" >
       priv/git_sha`) before `mix compile` runs. Declared below via
       `@external_resource`, so Mix's compile manifest tracks this file's
       *content* and recompiles this module whenever it changes — even
       when the Dockerfile's BuildKit cache mount keeps `_build` warm
       across builds and `build_info.ex` itself is byte-identical. Without
       this, Mix has no way to know a plain `System.get_env("GIT_SHA")`
       read depends on anything, so once `_build` started persisting
       across builds it would skip recompiling this file forever and
       every instance would report whatever SHA was baked in the last time
       something else forced a real recompile.
    2. The `GIT_SHA` env var directly, for a compile happening outside the
       Dockerfile's generated-file step (e.g. a manual `docker build` that
       skips it, or a differently-shaped build path) but where GIT_SHA is
       still set.
    3. `git rev-parse --short HEAD`, shelled out at compile time — the path
       taken by `mix release` on a host checkout (local systemd, mini),
       where `.git` is present but nothing generates priv/git_sha.
    4. `"unknown"`, so dev/test compiles fine with none of the above.

  `@built_at` piggybacks on the same fix: it's only stale if this module
  isn't recompiled, and fixing that fixes both fields together.
  """

  @git_sha_file Path.expand("../../priv/git_sha", __DIR__)
  @external_resource @git_sha_file

  # Module attributes run during module-body compilation, before any
  # function in this module is callable — so the resolution logic has to be
  # inlined here rather than calling a local defp.
  @sha (case File.read(@git_sha_file) do
          {:ok, contents} ->
            String.trim(contents)

          {:error, _} ->
            case System.get_env("GIT_SHA") do
              sha when is_binary(sha) and sha != "" ->
                sha

              _ ->
                try do
                  case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
                    {sha, 0} -> String.trim(sha)
                    _ -> "unknown"
                  end
                rescue
                  _ -> "unknown"
                end
            end
        end)
  @built_at DateTime.utc_now() |> DateTime.to_iso8601()

  def sha, do: @sha
  def built_at, do: @built_at
end
