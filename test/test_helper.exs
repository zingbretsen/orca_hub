# Tests tagged :distributed make the test VM itself a real distributed
# Erlang node (Node.start/:peer/Node.connect — see cluster_distributed_test.exs).
# That's process-wide state that races with unrelated async tests if run in
# the same pass, so they're excluded here and must be run separately, serially:
#
#   mix test                    # excludes :distributed (this file's default)
#   mix test --only distributed # the distributed-only pass
ExUnit.start(exclude: [:distributed])
Ecto.Adapters.SQL.Sandbox.mode(OrcaHub.Repo, :manual)
