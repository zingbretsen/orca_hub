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
ExUnit.start(exclude: [:distributed, :repro])
Ecto.Adapters.SQL.Sandbox.mode(OrcaHub.Repo, :manual)
