#!/bin/sh
# Stands in for the real `pi` binary when tests exercise Backend.Pi.models/0
# (the `:pi_executable` seam): answers `--list-models` with a fixed catalog
# in the exact aligned-table format pi 0.80.3 prints, and fails on anything
# else so an unexpected invocation is loud.
if [ "$1" = "--list-models" ]; then
  cat <<'EOF'
provider   model                                           context  max-out  thinking  images
fireworks  accounts/fireworks/models/glm-5p2               1.0M     131.1K   yes       no
fireworks  accounts/fireworks/models/kimi-k2p6             262K     262K     yes       yes
EOF
  exit 0
fi
echo "pi_stub_list_models.sh: unexpected args: $*" >&2
exit 1
