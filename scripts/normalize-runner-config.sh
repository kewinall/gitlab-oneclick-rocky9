#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"
CONFIG="${CONFIG:-$STACK_DIR/runner/config/config.toml}"

if [[ "${GITLAB_INSTALLER_TEST_MODE:-0}" != "1" && $EUID -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi
[[ -f "$STACK_DIR/.env" ]] || { echo "$STACK_DIR/.env was not found." >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "$CONFIG was not found." >&2; exit 1; }

# shellcheck disable=SC1091
source "$STACK_DIR/.env"

: "${RUNNER_CPUS:=2}"
: "${RUNNER_MEMORY:=4g}"

BACKUP="${CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
TMP="${CONFIG}.tmp.$$"
cp -a "$CONFIG" "$BACKUP"

if awk \
  -v cpus="$RUNNER_CPUS" \
  -v memory="$RUNNER_MEMORY" '
function emit_settings() {
  print "    cpus = \"" cpus "\""
  print "    memory = \"" memory "\""
  print "    memory_swap = \"" memory "\""
  print "    shm_size = 268435456"
  print "    pull_policy = \"if-not-present\""
}
{
  if ($0 ~ /^[[:space:]]*\[runners\.docker\][[:space:]]*$/) {
    in_docker = 1
    found_docker = 1
    print
    emit_settings()
    next
  }

  if (in_docker && $0 ~ /^[[:space:]]*\[/) {
    in_docker = 0
  }

  if (in_docker && $0 ~ /^[[:space:]]*(cpus|memory|memory_swap|shm_size|pull_policy)[[:space:]]*=/) {
    next
  }

  print
}
END {
  if (!found_docker) {
    exit 42
  }
}
' "$CONFIG" > "$TMP"; then
  :
else
  rc=$?
  rm -f "$TMP"
  echo "Failed to normalize $CONFIG (awk exit $rc). Backup: $BACKUP" >&2
  exit "$rc"
fi

install -m 0600 "$TMP" "$CONFIG"
rm -f "$TMP"

echo "Runner configuration normalized."
echo "Backup: $BACKUP"
