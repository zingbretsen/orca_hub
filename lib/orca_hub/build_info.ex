defmodule OrcaHub.BuildInfo do
  @moduledoc """
  Compile-time build metadata (git SHA + build timestamp), exposed
  unauthenticated via `GET /api/version` so the deploy script can poll each
  running instance until it reports the SHA it just deployed.

  The SHA is resolved two ways to support both build paths:

    - `mix release` on a host checkout (local systemd, mini): git is
      available in the working directory, so this shells out to
      `git rev-parse --short HEAD` at compile time.
    - `docker build`: the build context has no `.git` dir (only `lib`,
      `priv`, `assets`, `rel` are copied in), so `git rev-parse` would fail.
      The Dockerfile instead accepts a `GIT_SHA` build ARG and exports it as
      an ENV before `mix compile` runs; that takes priority here.
  """

  # Module attributes run during module-body compilation, before any
  # function in this module is callable — so the resolution logic has to be
  # inlined here rather than calling a local defp.
  @sha (case System.get_env("GIT_SHA") do
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
        end)
  @built_at DateTime.utc_now() |> DateTime.to_iso8601()

  def sha, do: @sha
  def built_at, do: @built_at
end
