#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
PROJECT_NAME="gitlab-oneclick-rocky9"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid VERSION: $VERSION" >&2
  exit 1
}

mkdir -p "$DIST_DIR"
rm -f \
  "$DIST_DIR/${PROJECT_NAME}-v${VERSION}.zip" \
  "$DIST_DIR/${PROJECT_NAME}-v${VERSION}.tar.gz" \
  "$DIST_DIR/${PROJECT_NAME}-v${VERSION}.SHA256SUMS"

DEST="$STAGE/$PROJECT_NAME"
mkdir -p "$DEST"

tar \
  --exclude='.git' \
  --exclude='dist' \
  --exclude='gitlab-offline-bundle-*' \
  --exclude='*.log' \
  -C "$ROOT" \
  -cf - . | tar -C "$DEST" -xf -

find "$DEST" -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0644 "$DEST"/*.md "$DEST"/LICENSE "$DEST"/VERSION 2>/dev/null || true

(
  cd "$STAGE"
  zip -qr "$DIST_DIR/${PROJECT_NAME}-v${VERSION}.zip" "$PROJECT_NAME"
  tar -czf "$DIST_DIR/${PROJECT_NAME}-v${VERSION}.tar.gz" "$PROJECT_NAME"
)

(
  cd "$DIST_DIR"
  sha256sum \
    "${PROJECT_NAME}-v${VERSION}.zip" \
    "${PROJECT_NAME}-v${VERSION}.tar.gz" \
    > "${PROJECT_NAME}-v${VERSION}.SHA256SUMS"
)

printf 'Release artifacts created in %s\n' "$DIST_DIR"
