#!/usr/bin/env bash
# Convenience wrapper for deploy.sh --cleanup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: cleanup.sh --target kind --benchmark <name> [--cluster NAME] [--namespace NS]

Removes only resources/images owned by this benchmark project.
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

exec "${SCRIPT_DIR}/deploy.sh" "$@" --cleanup
