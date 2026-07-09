#!/bin/sh
# Stands in for the real `codex` binary (the `:codex_executable` seam,
# mirrors `:claude_executable`/`:pi_executable`) for
# OrcaHub.CodexLoginRunnerTest. Supports the two subcommands the runner
# drives:
#
#   login --device-auth   -> prints a fixed verification URL + user code,
#                             then exits 0 (simulates a device-auth flow
#                             the user already approved from another
#                             browser).
#   login --with-api-key  -> reads the piped key off stdin, writes it to
#                             $FAKE_CODEX_KEY_OUT (a test-only
#                             introspection point OrcaHub itself never
#                             reads) so the test can assert the key was
#                             actually delivered, and exits 0 unless the
#                             key is literally "fail-me" (exercises the
#                             error path).
case "$1 $2" in
  "login --device-auth")
    echo "Starting device authorization flow..."
    echo "Visit https://chatgpt.com/device and enter code WDJB-MJHT to continue."
    exit 0
    ;;
  "login --with-api-key")
    key=$(cat)
    if [ -n "$FAKE_CODEX_KEY_OUT" ]; then
      printf '%s' "$key" > "$FAKE_CODEX_KEY_OUT"
    fi
    if [ "$key" = "fail-me" ]; then
      echo "invalid key" >&2
      exit 1
    fi
    exit 0
    ;;
  *)
    echo "fake_codex.sh: unexpected args: $*" >&2
    exit 1
    ;;
esac
