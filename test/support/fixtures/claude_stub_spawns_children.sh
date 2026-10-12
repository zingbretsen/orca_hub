#!/bin/sh
# ORCAHUB3-146 stand-in for `claude` (the `:claude_executable` seam): before
# blocking on stdin like claude_stub_noop.sh, it starts the three kinds of
# descendant a real agent CLI leaves behind, and records each pid under
# ./orca-stub-pids/ (the CLI's cwd is the session directory):
#
#   bg      a plain `&` child, still in the CLI's own process group
#   setsid  its own session and process group, the way Claude's Bash tool
#           starts every shell
#   orphan  double-forked out of a setsid'd shell that has already exited,
#           so it is reparented to init AND in a foreign process group
#           before any teardown starts. Only a cgroup or an inherited-env
#           marker can still find it.
#
# Every pid file is written to a temp name and renamed, so a reader never
# sees a half-written pid. The mode rides on a file in the session
# directory, since the CLI's own argv is the real claude argv:
#
#   orca-stub-turns  answer each stdin line with a successful stream-json
#                    `result` frame, so a streaming runner finishes its turns
#                    and sits warm in :idle
#   orca-stub-exit   exit 0 at once, the way a one-shot CLI ends its turn
#   (neither)        block on stdin until the port closes
dir="$PWD/orca-stub-pids"
mkdir -p "$dir"

record() { echo "$2" > "$dir/$1.tmp" && mv "$dir/$1.tmp" "$dir/$1"; }

sleep 300 &
record bg $!

setsid sh -c 'echo $$ > "$1.tmp" && mv "$1.tmp" "$1"; exec sleep 300' sh "$dir/setsid" &

setsid sh -c 'sleep 300 & echo $! > "$1.tmp" && mv "$1.tmp" "$1"' sh "$dir/orphan" &

record cli $$

if [ -f "$PWD/orca-stub-exit" ]; then
  # Not before every pid is on disk: the reap that follows this exit must
  # not win the race against the backgrounded writers.
  while [ ! -s "$dir/setsid" ] || [ ! -s "$dir/orphan" ]; do sleep 0.05; done
  exit 0
elif [ -f "$PWD/orca-stub-turns" ]; then
  while IFS= read -r _line; do
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"stub-146"}'
  done
else
  exec cat >/dev/null
fi
