#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/os-release" <<'OS'
ID=rocky
VERSION_ID=9.8
PRETTY_NAME="Rocky Linux 9.8"
OS

cat > "$TMP/bin/dnf" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$DNF_CALL_LOG"
if [[ " $* " == *" download "* ]]; then
  dest=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --destdir) dest="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$dest"
  : > "$dest/docker-ce-1.0-1.el9.x86_64.rpm"
  : > "$dest/curl-1.0-1.el9.x86_64.rpm"
fi
exit 0
MOCK

cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 1
printf 'mock docker key\n' > "$out"
MOCK

cat > "$TMP/bin/gpg" <<'MOCK'
#!/usr/bin/env bash
cat <<'OUT'
pub:-:4096:1:C52FEB6B621E9F35:0:0::::::
fpr:::::::::060A61C51B558A7F742B77AAC52FEB6B621E9F35:
OUT
MOCK

cat > "$TMP/bin/skopeo" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
dest="${!#}"
rest="${dest#docker-archive:}"
archive="${rest%%:*}"
mkdir -p "$(dirname "$archive")"
tar -cf "$archive" --files-from /dev/null
printf '%s\n' "$*" >> "$SKOPEO_CALL_LOG"
MOCK

cat > "$TMP/bin/rpm" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "-qp" ]]; then
  file="${!#}"
  base="$(basename "$file" .rpm)"
  printf '%s\n' "$base"
  exit 0
fi
exit 0
MOCK
chmod 0755 "$TMP/bin"/*

OUT="$TMP/offline-bundle"
if ! GITLAB_INSTALLER_TEST_MODE=1 \
  DNF_CALL_LOG="$TMP/dnf.calls" \
  SKOPEO_CALL_LOG="$TMP/skopeo.calls" \
  OS_RELEASE_FILE="$TMP/os-release" \
  PATH="$TMP/bin:$PATH" \
  bash "$ROOT/prepare-offline-bundle.sh" \
    --output "$OUT" \
    --extra-image python:3.13-slim > "$TMP/prepare.log" 2>&1
then
  echo "Offline bundle preparation mock failed:" >&2
  cat "$TMP/prepare.log" >&2
  exit 1
fi

test -f "$OUT/bundle.env"
test -f "$OUT/install-offline.sh"
grep -Fq -- '--mode offline --offline-bundle "$BUNDLE_DIR"' "$OUT/install-offline.sh"
test -f "$OUT/installer/install.sh"
test -f "$OUT/keys/docker-ce.gpg"
test -f "$OUT/SHA256SUMS"
test "$(find "$OUT/rpms" -type f -name '*.rpm' | wc -l)" -ge 2
test "$(find "$OUT/images" -type f -name '*.tar' | wc -l)" -eq 5
grep -qx 'python:3.13-slim' "$OUT/manifests/images.txt"
grep -q -- '--resolve --alldeps' "$TMP/dnf.calls"
grep -q 'docker://gitlab/gitlab-ce:19.1.1-ce.0' "$TMP/skopeo.calls"
OS_RELEASE_FILE="$TMP/os-release" bash "$OUT/verify-offline-bundle.sh" --target-check >/dev/null

printf '[PASS] Offline bundle preparation and verification test passed.\n'
