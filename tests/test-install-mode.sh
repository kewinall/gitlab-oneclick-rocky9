#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_failure() {
  local expected="$1"
  shift
  local output="$TMP/out.$RANDOM"
  if GITLAB_INSTALLER_TEST_MODE=1 bash "$ROOT/install.sh" "$@" >"$output" 2>&1; then
    echo "Expected command to fail: install.sh $*" >&2
    cat "$output" >&2
    exit 1
  fi
  grep -Fq -- "$expected" "$output" || {
    echo "Expected error not found: $expected" >&2
    cat "$output" >&2
    exit 1
  }
}

expect_failure "Invalid --mode 'invalid'" \
  --mode invalid --host gitlab.test

expect_failure "Specify the installation mode only once." \
  --mode online --offline --host gitlab.test

expect_failure "--mode offline requires --offline-bundle PATH." \
  --mode offline --host gitlab.test

expect_failure "--mode offline requires --offline-bundle PATH." \
  --offline --host gitlab.test

expect_failure "--offline-bundle cannot be used with --mode online." \
  --mode online --offline-bundle /tmp/not-used --host gitlab.test

help_output="$(bash "$ROOT/install.sh" --help)"
grep -Fq -- '--mode MODE' <<<"$help_output"
grep -Fq -- '--online' <<<"$help_output"
grep -Fq -- '--offline' <<<"$help_output"
grep -Fq -- '--offline-bundle PATH' <<<"$help_output"

grep -Fq -- '--mode offline --offline-bundle "$BUNDLE_DIR"' \
  "$ROOT/prepare-offline-bundle.sh"

printf '[PASS] Installation mode argument validation passed.\n'
