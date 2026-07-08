#!/bin/sh
# Stands in for the real `claude` binary (the `:claude_executable` seam,
# mirrors `:codex_executable`/`:pi_executable`) for tests that only need a
# session to reach a live SessionRunner/port without making any real network
# calls or emitting any events — e.g. ApiRunController's POST-create test,
# which only asserts on the DB rows/response the controller writes BEFORE
# the port is opened. Just reads and discards stdin until the port closes.
exec cat >/dev/null
