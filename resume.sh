#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="/srv/gitlab-stack"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
RUNNER_TOKEN=""

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\n\033[1;31mResume failed at line %s (exit %s).\033[0m\n' "${BASH_LINENO[0]}" "$rc" >&2
  if command -v docker >/dev/null 2>&1 && [[ -d "$STACK_DIR" ]]; then
    (cd "$STACK_DIR" && docker compose ps) || true
  fi
  exit "$rc"
}
trap on_error ERR

usage() {
  cat <<'USAGE'
Usage:
  sudo bash resume.sh [options]

Options:
  --stack-dir PATH       Existing stack directory, default: /srv/gitlab-stack
  --runner-token TOKEN   Optional Runner authentication token (glrt-...).
  -h, --help             Show this help.

This command updates helper scripts in an incomplete v1.1.x/v1.2.x deployment
and resumes without deleting existing data. It also fixes false 404 readiness
failures caused by probing 127.0.0.1 without the configured GitLab Host header.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-dir) STACK_DIR="${2:-}"; shift 2 ;;
    --runner-token) RUNNER_TOKEN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 || "${GITLAB_INSTALLER_TEST_MODE:-}" == "1" ]] || die "Run this script as root or with sudo."
[[ -f "$STACK_DIR/compose.yaml" ]] || die "$STACK_DIR/compose.yaml was not found."
[[ -f "$STACK_DIR/.env" ]] || die "$STACK_DIR/.env was not found."
[[ -f "$STACK_DIR/secrets/gitlab_db_password.txt" ]] || die "GitLab DB password file was not found."

log "Updating deployment helper scripts"
install -d -m 0750 "$STACK_DIR/scripts"
for script in backup.sh ensure-gitlab-db.sh lib-gitlab.sh normalize-runner-config.sh repair-runner.sh register-runner.sh status.sh upgrade.sh verify-install.sh wait-gitlab.sh; do
  install -m 0750 "$SCRIPT_DIR/scripts/$script" "$STACK_DIR/scripts/$script"
done
install -m 0640 "$SCRIPT_DIR/README.md" "$STACK_DIR/README.md"

cd "$STACK_DIR"
# shellcheck disable=SC1091
source ./.env
UP_ARGS=(-d)
[[ "${INSTALL_MODE:-online}" == "offline" ]] && UP_ARGS+=(--pull never)

log "Validating Docker Compose configuration"
docker compose config >/dev/null

log "Starting PostgreSQL"
docker compose up "${UP_ARGS[@]}" postgres
PG_HEALTH=""
for attempt in $(seq 1 60); do
  PG_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' gitlab-postgres 2>/dev/null || true)"
  [[ "$PG_HEALTH" == "healthy" ]] && break
  if (( attempt % 6 == 0 )); then
    log "Waiting for PostgreSQL (${attempt}/60), status=${PG_HEALTH:-unknown}"
  fi
  sleep 5
done
[[ "$PG_HEALTH" == "healthy" ]] || {
  docker compose logs --tail=200 postgres >&2 || true
  die "PostgreSQL did not become healthy."
}

log "Creating and validating the GitLab database"
STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/ensure-gitlab-db.sh"

log "Starting GitLab"
docker compose up "${UP_ARGS[@]}" gitlab
log "Waiting for GitLab readiness; first startup can take 5-20 minutes"
STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/wait-gitlab.sh"
log "Verifying GitLab, PostgreSQL, and core services"
STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/verify-install.sh"

log "Starting GitLab Runner"
docker compose up "${UP_ARGS[@]}" gitlab-runner

ROOT_PASSWORD="$(docker compose exec -T gitlab sh -lc "sed -n 's/^Password:[[:space:]]*//p' /etc/gitlab/initial_root_password 2>/dev/null" | tr -d '\r' | head -n 1 || true)"
CREDENTIAL_FILE="$STACK_DIR/secrets/initial_admin.txt"
if [[ -n "$ROOT_PASSWORD" ]]; then
  umask 077
  cat > "$CREDENTIAL_FILE" <<EOF_CREDS
URL: ${GITLAB_EXTERNAL_URL}
Username: root
Password: ${ROOT_PASSWORD}
Git SSH port: ${GITLAB_SSH_PORT}
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
elif [[ -s "$STACK_DIR/runner/config/config.toml" ]] && grep -q 'token = "glrt-' "$STACK_DIR/runner/config/config.toml"; then
  log "GitLab Runner is already registered; normalizing and validating its configuration."
  STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/repair-runner.sh"
else
  warn "Runner is running but not registered. After creating a glrt- token, run:"
  printf '  sudo %q %q\n' "$STACK_DIR/scripts/register-runner.sh" 'glrt-xxxxxxxxxxxxxxxx'
fi

printf '\nDeployment resumed successfully.\n'
printf 'URL:          %s\n' "$GITLAB_EXTERNAL_URL"
printf 'Username:     root\n'
if [[ -n "$ROOT_PASSWORD" ]]; then
  printf 'Password:     %s\n' "$ROOT_PASSWORD"
  printf 'Saved at:     %s\n' "$CREDENTIAL_FILE"
else
  printf 'Password:     check /etc/gitlab/initial_root_password inside the GitLab container\n'
fi
printf 'Git SSH port: %s\n' "$GITLAB_SSH_PORT"
printf 'Stack path:   %s\n' "$STACK_DIR"
