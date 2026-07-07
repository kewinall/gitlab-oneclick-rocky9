#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="/srv/gitlab-stack"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
GITLAB_HOST=""
HTTP_PORT="80"
SSH_PORT="2222"
RUNNER_TOKEN=""
REMOVE_PODMAN="false"
SKIP_FIREWALL="false"
LOW_MEMORY="false"
OFFLINE_BUNDLE=""
INSTALL_MODE="online"
INSTALL_MODE_EXPLICIT="false"
INSTALL_MODE_ARGUMENTS=0
GITLAB_IMAGE="gitlab/gitlab-ce:19.1.1-ce.0"
RUNNER_IMAGE="gitlab/gitlab-runner:alpine-v19.1.1"
POSTGRES_IMAGE="postgres:17.10-bookworm"
RUNNER_DEFAULT_IMAGE="alpine:3.23"

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\n\033[1;31mDeployment failed at line %s (exit %s).\033[0m\n' "${BASH_LINENO[0]}" "$rc" >&2
  if command -v docker >/dev/null 2>&1 && [[ -d "$STACK_DIR" ]]; then
    (cd "$STACK_DIR" && docker compose ps) || true
  fi
  exit "$rc"
}
trap on_error ERR

usage() {
  cat <<'USAGE'
Usage:
  Online:
    sudo bash install.sh --mode online --host gitlab.example.com [options]

  Offline:
    sudo bash install.sh --mode offline --offline-bundle /path/to/bundle \
      --host gitlab.example.com [options]

Required:
  --host HOSTNAME             GitLab DNS hostname or resolvable host name.

Installation mode:
  --mode MODE                 online or offline; default: online
  --online                    Alias for --mode online
  --offline                   Alias for --mode offline
  --offline-bundle PATH       Prepared bundle directory; required in offline mode.

General options:
  --http-port PORT            Host HTTP port, default: 80
  --ssh-port PORT             GitLab SSH port, default: 2222
  --runner-token TOKEN        Optional runner authentication token (glrt-...).
  --stack-dir PATH            Deployment directory, default: /srv/gitlab-stack
  --remove-podman             Remove Podman/Buildah/runc if they conflict.
  --skip-firewall             Do not modify firewalld rules.
  --low-memory                Use 1 Puma worker and Sidekiq concurrency 5.
  -h, --help                  Show this help.

Rules:
  * online mode must not use --offline-bundle.
  * offline mode requires --offline-bundle and never pulls from external repos.
  * --offline-bundle without --mode remains accepted for v1.3 compatibility,
    but explicit --mode offline is recommended.

This installer refuses to overwrite an existing stack. For a clean reinstall:
  sudo bash uninstall.sh --purge-data --yes
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) GITLAB_HOST="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --runner-token) RUNNER_TOKEN="${2:-}"; shift 2 ;;
    --stack-dir) STACK_DIR="${2:-}"; shift 2 ;;
    --remove-podman) REMOVE_PODMAN="true"; shift ;;
    --skip-firewall) SKIP_FIREWALL="true"; shift ;;
    --low-memory) LOW_MEMORY="true"; shift ;;
    --mode)
      INSTALL_MODE="${2:-}"
      INSTALL_MODE_EXPLICIT="true"
      INSTALL_MODE_ARGUMENTS=$((INSTALL_MODE_ARGUMENTS + 1))
      shift 2
      ;;
    --online)
      INSTALL_MODE="online"
      INSTALL_MODE_EXPLICIT="true"
      INSTALL_MODE_ARGUMENTS=$((INSTALL_MODE_ARGUMENTS + 1))
      shift
      ;;
    --offline)
      INSTALL_MODE="offline"
      INSTALL_MODE_EXPLICIT="true"
      INSTALL_MODE_ARGUMENTS=$((INSTALL_MODE_ARGUMENTS + 1))
      shift
      ;;
    --offline-bundle) OFFLINE_BUNDLE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 || "${GITLAB_INSTALLER_TEST_MODE:-}" == "1" ]] || die "Run this installer as root or with sudo."
[[ -n "$GITLAB_HOST" ]] || die "--host is required."
[[ "$GITLAB_HOST" != "localhost" ]] || die "localhost is not a valid GitLab hostname."
[[ "$GITLAB_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Invalid hostname: $GITLAB_HOST"
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 )) || die "Invalid HTTP port."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "Invalid SSH port."
[[ "$HTTP_PORT" != "$SSH_PORT" ]] || die "HTTP and Git SSH ports must be different."
(( INSTALL_MODE_ARGUMENTS <= 1 )) || die "Specify the installation mode only once."
[[ "$INSTALL_MODE" == "online" || "$INSTALL_MODE" == "offline" ]] \
  || die "Invalid --mode '$INSTALL_MODE'; expected online or offline."

# Backward compatibility with v1.3.0: specifying only --offline-bundle implies
# offline mode. New deployments should use --mode offline explicitly.
if [[ -n "$OFFLINE_BUNDLE" && "$INSTALL_MODE_EXPLICIT" != "true" ]]; then
  warn "--offline-bundle without --mode is deprecated; assuming --mode offline."
  INSTALL_MODE="offline"
fi

if [[ "$INSTALL_MODE" == "online" && -n "$OFFLINE_BUNDLE" ]]; then
  die "--offline-bundle cannot be used with --mode online."
fi
if [[ "$INSTALL_MODE" == "offline" && -z "$OFFLINE_BUNDLE" ]]; then
  die "--mode offline requires --offline-bundle PATH."
fi

if [[ "$INSTALL_MODE" == "offline" ]]; then
  OFFLINE_BUNDLE="$(realpath -e "$OFFLINE_BUNDLE")"
  [[ -f "$OFFLINE_BUNDLE/verify-offline-bundle.sh" ]] || die "Invalid offline bundle: verifier not found."
  log "Verifying offline bundle before changing the host"
  bash "$OFFLINE_BUNDLE/verify-offline-bundle.sh" --target-check
  # The bundle is checksum-verified before its metadata is loaded.
  # shellcheck disable=SC1091
  source "$OFFLINE_BUNDLE/bundle.env"
  CURRENT_INSTALLER_VERSION="$(tr -d '\r\n' < "$SCRIPT_DIR/VERSION")"
  [[ "${INSTALLER_VERSION:-}" == "$CURRENT_INSTALLER_VERSION" ]] \
    || die "Offline bundle version ${INSTALLER_VERSION:-unknown} does not match installer version $CURRENT_INSTALLER_VERSION."
  GITLAB_IMAGE="${GITLAB_IMAGE:?Missing GITLAB_IMAGE in bundle.env}"
  POSTGRES_IMAGE="${POSTGRES_IMAGE:?Missing POSTGRES_IMAGE in bundle.env}"
  RUNNER_IMAGE="${RUNNER_IMAGE:?Missing RUNNER_IMAGE in bundle.env}"
  RUNNER_DEFAULT_IMAGE="${RUNNER_DEFAULT_IMAGE:?Missing RUNNER_DEFAULT_IMAGE in bundle.env}"
fi

log "Selected installation mode: ${INSTALL_MODE}"
[[ "$INSTALL_MODE" != "offline" ]] || log "Offline bundle: ${OFFLINE_BUNDLE}"

EXISTING_CONTAINER="false"
if command -v docker >/dev/null 2>&1 \
  && docker ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -Eq '^(gitlab|gitlab-postgres|gitlab-runner)$'; then
  EXISTING_CONTAINER="true"
fi
if [[ -e "$STACK_DIR/compose.yaml" || "$EXISTING_CONTAINER" == "true" ]]; then
  die "An existing GitLab stack was detected. Run: sudo bash $SCRIPT_DIR/uninstall.sh --stack-dir '$STACK_DIR' --purge-data --yes"
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
else
  die "Cannot detect the operating system."
fi
case "${ID:-}" in
  rocky|rhel|almalinux|centos) ;;
  *) warn "Tested for Rocky/RHEL-compatible Linux 9. Detected: ${ID:-unknown}." ;;
esac
[[ "${VERSION_ID%%.*}" == "9" ]] || warn "Expected major version 9, detected ${VERSION_ID:-unknown}."

if ! getent hosts "$GITLAB_HOST" >/dev/null 2>&1; then
  warn "DNS hostname $GITLAB_HOST does not currently resolve. Create the DNS record before browser access and Runner registration."
fi

MEM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
PARENT_DIR="$(dirname "$STACK_DIR")"
mkdir -p "$PARENT_DIR"
DISK_GB=$(df -Pk "$PARENT_DIR" | awk 'NR==2 {print int($4/1024/1024)}')
(( MEM_GB >= 8 )) || warn "Only ${MEM_GB} GB RAM detected. Installation may fail or perform poorly."
(( DISK_GB >= 60 )) || warn "Only ${DISK_GB} GB free near ${STACK_DIR}."

if command -v ss >/dev/null 2>&1; then
  ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)${HTTP_PORT}$" && die "TCP port ${HTTP_PORT} is already in use."
  ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)${SSH_PORT}$" && die "TCP port ${SSH_PORT} is already in use."
fi

CONFLICTING_PACKAGES=()
for pkg in \
  docker docker-client docker-client-latest docker-common docker-latest \
  docker-latest-logrotate docker-logrotate docker-engine \
  podman podman-docker buildah runc; do
  rpm -q "$pkg" >/dev/null 2>&1 && CONFLICTING_PACKAGES+=("$pkg")
done
if (( ${#CONFLICTING_PACKAGES[@]} > 0 )); then
  if [[ "$REMOVE_PODMAN" == "true" ]]; then
    log "Removing packages that may conflict with Docker CE"
    dnf remove -y "${CONFLICTING_PACKAGES[@]}" || true
  elif ! command -v docker >/dev/null 2>&1; then
    die "Podman/Buildah/runc is installed. Review its use, then rerun with --remove-podman on a dedicated host."
  fi
fi

if [[ "$INSTALL_MODE" == "offline" ]]; then
  log "Installing required RPMs from the offline bundle"
  rpm --import "$OFFLINE_BUNDLE/keys/docker-ce.gpg"
  mapfile -d '' OFFLINE_RPMS < <(find "$OFFLINE_BUNDLE/rpms" -maxdepth 1 -type f -name '*.rpm' -print0 | sort -z)
  (( ${#OFFLINE_RPMS[@]} > 0 )) || die "No RPM files were found in the offline bundle."
  dnf install -y \
    --disablerepo='*' \
    --setopt=install_weak_deps=False \
    "${OFFLINE_RPMS[@]}"
else
  log "Installing required operating system packages"
  dnf install -y dnf-plugins-core curl openssl tar rsync policycoreutils-python-utils
  if ! command -v docker >/dev/null 2>&1; then
    log "Adding the official Docker repository"
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    log "Installing Docker Engine and Docker Compose plugin"
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
fi

systemctl enable --now docker
docker version >/dev/null
docker compose version >/dev/null

log "Creating persistent directories under ${STACK_DIR}"
install -d -m 0750 "$STACK_DIR"
install -d -m 0750 \
  "$STACK_DIR/gitlab/config" \
  "$STACK_DIR/gitlab/logs" \
  "$STACK_DIR/gitlab/data" \
  "$STACK_DIR/postgres/data" \
  "$STACK_DIR/runner/config" \
  "$STACK_DIR/backups" \
  "$STACK_DIR/scripts"
install -d -m 0700 "$STACK_DIR/secrets"

install -m 0640 "$SCRIPT_DIR/compose.yaml" "$STACK_DIR/compose.yaml"
for script in backup.sh ensure-gitlab-db.sh lib-gitlab.sh normalize-runner-config.sh repair-runner.sh register-runner.sh status.sh upgrade.sh verify-install.sh wait-gitlab.sh; do
  install -m 0750 "$SCRIPT_DIR/scripts/$script" "$STACK_DIR/scripts/$script"
done
install -m 0640 "$SCRIPT_DIR/README.md" "$STACK_DIR/README.md"

if [[ ! -s "$STACK_DIR/secrets/postgres_admin_password.txt" ]]; then
  umask 077
  openssl rand -base64 48 | tr -d '\n' > "$STACK_DIR/secrets/postgres_admin_password.txt"
fi
if [[ ! -s "$STACK_DIR/secrets/gitlab_db_password.txt" ]]; then
  umask 077
  openssl rand -base64 48 | tr -d '\n' > "$STACK_DIR/secrets/gitlab_db_password.txt"
fi
# Docker Compose standalone secrets are file-backed. The containing host
# directory is root-only (0700), while the files must be readable by the
# non-root postgres process inside the container.
chmod 0444 "$STACK_DIR/secrets/postgres_admin_password.txt" "$STACK_DIR/secrets/gitlab_db_password.txt"

EXTERNAL_URL="http://${GITLAB_HOST}"
[[ "$HTTP_PORT" == "80" ]] || EXTERNAL_URL="http://${GITLAB_HOST}:${HTTP_PORT}"
PUMA_WORKERS=2
SIDEKIQ_CONCURRENCY=10
if [[ "$LOW_MEMORY" == "true" ]]; then
  PUMA_WORKERS=1
  SIDEKIQ_CONCURRENCY=5
fi

cat > "$STACK_DIR/.env" <<EOF_ENV
COMPOSE_PROJECT_NAME=gitlab-stack

INSTALL_MODE=${INSTALL_MODE}
GITLAB_IMAGE=${GITLAB_IMAGE}
RUNNER_IMAGE=${RUNNER_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}

GITLAB_HOSTNAME=${GITLAB_HOST}
GITLAB_EXTERNAL_URL=${EXTERNAL_URL}
GITLAB_HTTP_PORT=${HTTP_PORT}
GITLAB_SSH_PORT=${SSH_PORT}

GITLAB_PUMA_WORKERS=${PUMA_WORKERS}
GITLAB_SIDEKIQ_CONCURRENCY=${SIDEKIQ_CONCURRENCY}

RUNNER_DESCRIPTION=rocky9-docker-runner
RUNNER_DEFAULT_IMAGE=${RUNNER_DEFAULT_IMAGE}
RUNNER_CONCURRENT=1
RUNNER_CPUS=2
RUNNER_MEMORY=4g
EOF_ENV
chmod 0600 "$STACK_DIR/.env"

if [[ "$SKIP_FIREWALL" != "true" ]] && systemctl is-active --quiet firewalld; then
  log "Opening firewalld ports ${HTTP_PORT}/tcp and ${SSH_PORT}/tcp"
  firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp"
  firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
  firewall-cmd --reload
elif [[ "$SKIP_FIREWALL" != "true" ]]; then
  warn "firewalld is not active; no firewall rules were changed."
fi

cd "$STACK_DIR"
log "Validating Docker Compose configuration"
docker compose config >/dev/null

COMPOSE_UP_ARGS=(-d)
if [[ "$INSTALL_MODE" == "offline" ]]; then
  COMPOSE_UP_ARGS+=(--pull never)
  log "Loading container images from the offline bundle"
  mapfile -d '' IMAGE_ARCHIVES < <(find "$OFFLINE_BUNDLE/images" -maxdepth 1 -type f -name '*.tar' -print0 | sort -z)
  (( ${#IMAGE_ARCHIVES[@]} > 0 )) || die "No image archives were found in the offline bundle."
  for archive in "${IMAGE_ARCHIVES[@]}"; do
    log "Loading image archive: $(basename "$archive")"
    docker load --input "$archive"
  done
  for image in "$GITLAB_IMAGE" "$POSTGRES_IMAGE" "$RUNNER_IMAGE" "$RUNNER_DEFAULT_IMAGE"; do
    docker image inspect "$image" >/dev/null 2>&1 || die "Required image was not loaded: $image"
  done
else
  log "Pulling container images"
  docker compose pull
fi

log "Starting PostgreSQL"
docker compose up "${COMPOSE_UP_ARGS[@]}" postgres
for attempt in $(seq 1 60); do
  PG_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' gitlab-postgres 2>/dev/null || true)"
  if [[ "$PG_HEALTH" == "healthy" ]]; then
    break
  fi
  if (( attempt % 6 == 0 )); then
    log "Waiting for PostgreSQL (${attempt}/60), status=${PG_HEALTH:-unknown}"
  fi
  sleep 5
done
[[ "${PG_HEALTH:-}" == "healthy" ]] || {
  docker compose logs --tail=200 postgres >&2 || true
  die "PostgreSQL did not become healthy."
}

log "Creating and validating the GitLab database"
STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/ensure-gitlab-db.sh"

log "Starting GitLab"
docker compose up "${COMPOSE_UP_ARGS[@]}" gitlab
log "Waiting for GitLab readiness; first startup can take 5-20 minutes"
STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/wait-gitlab.sh"
log "Verifying GitLab, PostgreSQL, and core services"
STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/verify-install.sh"

log "Starting GitLab Runner"
docker compose up "${COMPOSE_UP_ARGS[@]}" gitlab-runner

ROOT_PASSWORD="$(docker compose exec -T gitlab sh -lc "sed -n 's/^Password:[[:space:]]*//p' /etc/gitlab/initial_root_password 2>/dev/null" | tr -d '\r' | head -n 1 || true)"
CREDENTIAL_FILE="$STACK_DIR/secrets/initial_admin.txt"
if [[ -n "$ROOT_PASSWORD" ]]; then
  umask 077
  cat > "$CREDENTIAL_FILE" <<EOF_CREDS
URL: ${EXTERNAL_URL}
Username: root
Password: ${ROOT_PASSWORD}
Git SSH port: ${SSH_PORT}
EOF_CREDS
  chmod 0600 "$CREDENTIAL_FILE"
fi

install -d -m 0755 "$SYSTEMD_UNIT_DIR"
install -m 0644 "$SCRIPT_DIR/systemd/gitlab-backup.service" "$SYSTEMD_UNIT_DIR/gitlab-backup.service"
install -m 0644 "$SCRIPT_DIR/systemd/gitlab-backup.timer" "$SYSTEMD_UNIT_DIR/gitlab-backup.timer"
sed -i "s|^Environment=STACK_DIR=.*|Environment=STACK_DIR=${STACK_DIR}|" "$SYSTEMD_UNIT_DIR/gitlab-backup.service"
sed -i "s|^ExecStart=.*|ExecStart=${STACK_DIR}/scripts/backup.sh|" "$SYSTEMD_UNIT_DIR/gitlab-backup.service"
systemctl daemon-reload
systemctl enable --now gitlab-backup.timer

if [[ -n "$RUNNER_TOKEN" ]]; then
  log "Registering GitLab Runner"
  "$STACK_DIR/scripts/register-runner.sh" "$RUNNER_TOKEN"
else
  warn "Runner is running but not registered. After creating a glrt- token, run:"
  printf '  sudo %q %q\n' "$STACK_DIR/scripts/register-runner.sh" 'glrt-xxxxxxxxxxxxxxxx'
fi

printf '\n============================================================\n'
printf 'GitLab deployment completed.\n'
printf 'URL:          %s\n' "$EXTERNAL_URL"
printf 'Username:     root\n'
if [[ -n "$ROOT_PASSWORD" ]]; then
  printf 'Password:     %s\n' "$ROOT_PASSWORD"
  printf 'Credentials:  %s\n' "$CREDENTIAL_FILE"
else
  printf 'Password:     cd %s && docker compose exec gitlab cat /etc/gitlab/initial_root_password\n' "$STACK_DIR"
fi
printf 'Git SSH port: %s\n' "$SSH_PORT"
printf 'Stack path:   %s\n' "$STACK_DIR"
printf 'Status:       sudo %s/scripts/status.sh\n' "$STACK_DIR"
printf 'Backup:       sudo %s/scripts/backup.sh\n' "$STACK_DIR"
printf '============================================================\n'
