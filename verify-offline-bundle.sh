#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
TARGET_CHECK="false"

log()  { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  bash verify-offline-bundle.sh [--target-check]

Options:
  --target-check   Also verify the current host OS major version and architecture.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-check) TARGET_CHECK="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

for required in \
  bundle.env \
  SHA256SUMS \
  install-offline.sh \
  installer/install.sh \
  keys/docker-ce.gpg \
  manifests/images.txt \
  manifests/rpms.txt; do
  [[ -f "$BUNDLE_DIR/$required" ]] || die "Missing bundle file: $required"
done
find "$BUNDLE_DIR/rpms" -maxdepth 1 -type f -name '*.rpm' -print -quit | grep -q . \
  || die "The bundle contains no RPM files."
find "$BUNDLE_DIR/images" -maxdepth 1 -type f -name '*.tar' -print -quit | grep -q . \
  || die "The bundle contains no container image archives."

# shellcheck disable=SC1091
source "$BUNDLE_DIR/bundle.env"
[[ "${BUNDLE_FORMAT_VERSION:-}" == "1" ]] || die "Unsupported bundle format: ${BUNDLE_FORMAT_VERSION:-missing}"

(
  cd "$BUNDLE_DIR"
  sha256sum -c SHA256SUMS
)
log "All SHA-256 checksums are valid."

if [[ "$TARGET_CHECK" == "true" ]]; then
  [[ -r "$OS_RELEASE_FILE" ]] || die "Cannot read $OS_RELEASE_FILE."
  # shellcheck disable=SC1091
  source "$OS_RELEASE_FILE"
  [[ "${VERSION_ID%%.*}" == "$TARGET_OS_MAJOR" ]] \
    || die "Bundle targets OS major $TARGET_OS_MAJOR, but this host is ${VERSION_ID:-unknown}."
  [[ "$(uname -m)" == "$TARGET_ARCH" ]] \
    || die "Bundle targets $TARGET_ARCH, but this host is $(uname -m)."
  case "${ID:-}" in
    rocky|rhel|almalinux|centos) ;;
    *) die "Unsupported target distribution: ${ID:-unknown}" ;;
  esac
  log "Target host is compatible: ${PRETTY_NAME:-$ID}, $(uname -m)."
fi

log "Offline bundle v${INSTALLER_VERSION:-unknown} is complete."
