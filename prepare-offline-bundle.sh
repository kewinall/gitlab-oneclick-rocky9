#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
VERSION="$(tr -d '\r\n' < "$SCRIPT_DIR/VERSION")"
OUTPUT_DIR="$(pwd)/gitlab-offline-bundle-v${VERSION}-x86_64"
FORCE="false"
EXTRA_IMAGES=()
TARGET_OS_MAJOR="9"
TARGET_ARCH="x86_64"

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash prepare-offline-bundle.sh [options]

Options:
  --output PATH              Output directory.
  --extra-image IMAGE:TAG    Add a CI/CD job image. Repeat as needed.
  --force                    Remove an existing output directory first.
  -h, --help                 Show this help.

The preparation host must have Internet access and be Rocky/RHEL-compatible
Linux 9 x86_64. The generated bundle is self-contained for an offline install.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --extra-image) EXTRA_IMAGES+=("${2:-}"); shift 2 ;;
    --force) FORCE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 || "${GITLAB_INSTALLER_TEST_MODE:-}" == "1" ]] || die "Run as root or with sudo."
[[ -n "$OUTPUT_DIR" ]] || die "--output cannot be empty."
[[ "$(uname -m)" == "$TARGET_ARCH" ]] || die "Run on an x86_64 preparation host. Detected: $(uname -m)"
command -v dnf >/dev/null 2>&1 || die "dnf is required on the preparation host."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."

if [[ -r "$OS_RELEASE_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$OS_RELEASE_FILE"
  [[ "${VERSION_ID%%.*}" == "$TARGET_OS_MAJOR" ]] || die "Preparation host must be Linux major version 9; detected ${VERSION_ID:-unknown}."
  case "${ID:-}" in
    rocky|rhel|almalinux|centos) ;;
    *) warn "Preparation is intended for Rocky/RHEL-compatible Linux 9. Detected: ${ID:-unknown}." ;;
  esac
fi

OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
[[ "$OUTPUT_DIR" != "/" ]] || die "Refusing to use / as the output directory."
case "$OUTPUT_DIR/" in
  "$SCRIPT_DIR/"*) die "Output directory cannot be inside the installer source directory." ;;
esac

if [[ -e "$OUTPUT_DIR" ]]; then
  [[ "$FORCE" == "true" ]] || die "$OUTPUT_DIR already exists. Use --force to replace it."
  rm -rf --one-file-system "$OUTPUT_DIR"
fi

log "Installing preparation tools on the connected host"
dnf install -y dnf-plugins-core curl skopeo gnupg2

if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
  log "Adding the official Docker RPM repository on the preparation host"
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
fi

install -d -m 0755 \
  "$OUTPUT_DIR/installer" \
  "$OUTPUT_DIR/rpms" \
  "$OUTPUT_DIR/images" \
  "$OUTPUT_DIR/keys" \
  "$OUTPUT_DIR/manifests"

log "Copying installer files into the offline bundle"
cp -a "$SCRIPT_DIR/." "$OUTPUT_DIR/installer/"
rm -rf "$OUTPUT_DIR/installer/.git" 2>/dev/null || true

log "Downloading Docker Engine and required Rocky Linux RPMs with dependencies"
PACKAGES=(
  dnf-plugins-core
  curl
  openssl
  tar
  rsync
  policycoreutils-python-utils
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

dnf download \
  --resolve \
  --alldeps \
  --destdir "$OUTPUT_DIR/rpms" \
  "${PACKAGES[@]}"

find "$OUTPUT_DIR/rpms" -maxdepth 1 -type f -name '*.rpm' -print -quit | grep -q . \
  || die "No RPM files were downloaded."

log "Downloading Docker repository signing key"
curl --fail --silent --show-error --location \
  https://download.docker.com/linux/rhel/gpg \
  --output "$OUTPUT_DIR/keys/docker-ce.gpg"
DOCKER_KEY_FINGERPRINT="$(gpg --show-keys --with-colons "$OUTPUT_DIR/keys/docker-ce.gpg" \
  | awk -F: '$1 == "fpr" { print $10; exit }')"
[[ "$DOCKER_KEY_FINGERPRINT" == "060A61C51B558A7F742B77AAC52FEB6B621E9F35" ]] \
  || die "Unexpected Docker signing-key fingerprint: ${DOCKER_KEY_FINGERPRINT:-missing}"

# Read the exact pinned image names from the installer configuration.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env.example"
IMAGES=(
  "$GITLAB_IMAGE"
  "$POSTGRES_IMAGE"
  "$RUNNER_IMAGE"
  "$RUNNER_DEFAULT_IMAGE"
)
for image in "${EXTRA_IMAGES[@]}"; do
  [[ -n "$image" && "$image" == *:* ]] || die "Extra image must include an explicit tag: $image"
  IMAGES+=("$image")
done

# Remove duplicate image references while retaining the original order.
UNIQUE_IMAGES=()
declare -A IMAGE_SEEN=()
for image in "${IMAGES[@]}"; do
  if [[ -z "${IMAGE_SEEN[$image]+x}" ]]; then
    UNIQUE_IMAGES+=("$image")
    IMAGE_SEEN[$image]=1
  fi
done

printf '%s\n' "${UNIQUE_IMAGES[@]}" > "$OUTPUT_DIR/manifests/images.txt"

log "Downloading pinned container images as Docker-compatible archives"
for image in "${UNIQUE_IMAGES[@]}"; do
  safe_name="$(printf '%s' "$image" | sed 's|[^A-Za-z0-9_.-]|_|g')"
  archive="$OUTPUT_DIR/images/${safe_name}.tar"
  log "Downloading image: $image"
  skopeo copy \
    --retry-times 3 \
    --override-os linux \
    --override-arch amd64 \
    "docker://$image" \
    "docker-archive:$archive:$image"
done

log "Writing package and bundle manifests"
: > "$OUTPUT_DIR/manifests/rpms.txt"
while IFS= read -r -d '' rpm_file; do
  rpm -qp --qf '%{NEVRA}\n' "$rpm_file" >> "$OUTPUT_DIR/manifests/rpms.txt"
done < <(find "$OUTPUT_DIR/rpms" -maxdepth 1 -type f -name '*.rpm' -print0 | sort -z)
sort -u -o "$OUTPUT_DIR/manifests/rpms.txt" "$OUTPUT_DIR/manifests/rpms.txt"

cat > "$OUTPUT_DIR/bundle.env" <<EOF_ENV
BUNDLE_FORMAT_VERSION=1
INSTALLER_VERSION=${VERSION}
TARGET_OS_MAJOR=${TARGET_OS_MAJOR}
TARGET_ARCH=${TARGET_ARCH}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GITLAB_IMAGE=${GITLAB_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
RUNNER_IMAGE=${RUNNER_IMAGE}
RUNNER_DEFAULT_IMAGE=${RUNNER_DEFAULT_IMAGE}
EOF_ENV

cat > "$OUTPUT_DIR/install-offline.sh" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$BUNDLE_DIR/installer/install.sh" --mode offline --offline-bundle "$BUNDLE_DIR" "$@"
EOF_INSTALL
chmod 0755 "$OUTPUT_DIR/install-offline.sh"

cp -a "$SCRIPT_DIR/verify-offline-bundle.sh" "$OUTPUT_DIR/verify-offline-bundle.sh"
chmod 0755 "$OUTPUT_DIR/verify-offline-bundle.sh"

cat > "$OUTPUT_DIR/README-OFFLINE.txt" <<EOF_README
GitLab Offline Bundle v${VERSION}

Verify on the offline target:
  sudo bash verify-offline-bundle.sh --target-check

Install:
  sudo bash install-offline.sh --host gitlab.example.com

Low-memory host:
  sudo bash install-offline.sh --host gitlab.example.com --low-memory

Equivalent direct installer command:
  sudo bash installer/install.sh --mode offline --offline-bundle "$PWD" --host gitlab.example.com

The default Runner job image ${RUNNER_DEFAULT_IMAGE} is included.
Additional CI/CD images must be added during bundle creation with --extra-image.
EOF_README

log "Generating SHA-256 checksums"
(
  cd "$OUTPUT_DIR"
  find . -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 sha256sum > SHA256SUMS
)

TOTAL_SIZE="$(du -sh "$OUTPUT_DIR" | awk '{print $1}')"
printf '\n============================================================\n'
printf 'Offline bundle created successfully.\n'
printf 'Path:        %s\n' "$OUTPUT_DIR"
printf 'Size:        %s\n' "$TOTAL_SIZE"
printf 'RPM count:   %s\n' "$(find "$OUTPUT_DIR/rpms" -maxdepth 1 -name '*.rpm' | wc -l)"
printf 'Image count: %s\n' "$(find "$OUTPUT_DIR/images" -maxdepth 1 -name '*.tar' | wc -l)"
printf '\nTransfer the entire directory to the offline Rocky Linux host.\n'
printf 'Then run:\n'
printf '  cd %q\n' "$OUTPUT_DIR"
printf '  sudo bash verify-offline-bundle.sh --target-check\n'
printf '  sudo bash install-offline.sh --host gitlab.example.com\n'
printf '============================================================\n'
