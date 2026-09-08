# Tests tagged :distributed make the test VM itself a real distributed
# Erlang node (Node.start/:peer/Node.connect — see cluster_distributed_test.exs).
# That's process-wide state that races with unrelated async tests if run in
# the same pass, so they're excluded here and must be run separately, serially:
#
#   mix test                    # excludes :distributed (this file's default)
#   mix test --only distributed # the distributed-only pass
#
# Tests tagged :repro are defect reproductions that FAIL in the current unfixed
# state — executable proof the defect is real, and a free regression test once
# fixed. They're excluded so master stays green; run them on demand with
# `mix test --only repro`; the tag comes off in the same commit as the fix:
#
#   mix test                    # excludes :repro (this file's default)
#   mix test --only repro       # the repro-only pass
# Tests tagged :s3 hit a real S3-compatible endpoint (OrcaHub.ObjectStore.S3,
# ORCAHUB3-72) and only do anything when ORCA_S3_ENDPOINT is actually set —
# excluded by default so a dev box without MinIO configured doesn't need one:
#
#   mix test                    # excludes :s3 (this file's default)
#   mix test --only s3          # the s3-only pass, needs ORCA_S3_* set
ExUnit.start(exclude: [:distributed, :repro, :s3])
Ecto.Adapters.SQL.Sandbox.mode(OrcaHub.Repo, :manual)
