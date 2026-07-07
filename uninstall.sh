#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="/srv/gitlab-stack"
PURGE_DATA="false"
ASSUME_YES="false"
REMOVE_FIREWALL="false"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash uninstall.sh [options]

Options:
  --stack-dir PATH       Stack directory, default: /srv/gitlab-stack
  --purge-data           Permanently delete GitLab, PostgreSQL, secrets, and backups.
  --remove-firewall      Remove the HTTP and Git SSH firewalld ports from .env.
  --yes                  Skip destructive confirmation.
  -h, --help             Show help.

Without --purge-data, containers and systemd timer are removed but data remains.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-dir) STACK_DIR="${2:-}"; shift 2 ;;
    --purge-data) PURGE_DATA="true"; shift ;;
    --remove-firewall) REMOVE_FIREWALL="true"; shift ;;
    --yes) ASSUME_YES="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root or with sudo." >&2; exit 1; }

HTTP_PORT=""
SSH_PORT=""
if [[ -f "$STACK_DIR/.env" ]]; then
  HTTP_PORT="$(awk -F= '/^GITLAB_HTTP_PORT=/{print $2}' "$STACK_DIR/.env" | tail -n1)"
  SSH_PORT="$(awk -F= '/^GITLAB_SSH_PORT=/{print $2}' "$STACK_DIR/.env" | tail -n1)"
fi

if [[ "$PURGE_DATA" == "true" && "$ASSUME_YES" != "true" ]]; then
  echo "This will permanently delete: $STACK_DIR"
  read -r -p "Type DELETE to continue: " answer
  [[ "$answer" == "DELETE" ]] || { echo "Cancelled."; exit 1; }
fi

systemctl disable --now gitlab-backup.timer 2>/dev/null || true
rm -f /etc/systemd/system/gitlab-backup.timer /etc/systemd/system/gitlab-backup.service
systemctl daemon-reload

if [[ -f "$STACK_DIR/compose.yaml" ]]; then
  (cd "$STACK_DIR" && docker compose down --remove-orphans) || true
else
  docker rm -f gitlab gitlab-postgres gitlab-runner 2>/dev/null || true
  docker network rm gitlab-network 2>/dev/null || true
fi

if [[ "$REMOVE_FIREWALL" == "true" ]] && systemctl is-active --quiet firewalld; then
  [[ -z "$HTTP_PORT" ]] || firewall-cmd --permanent --remove-port="${HTTP_PORT}/tcp" || true
  [[ -z "$SSH_PORT" ]] || firewall-cmd --permanent --remove-port="${SSH_PORT}/tcp" || true
  firewall-cmd --reload || true
fi

if [[ "$PURGE_DATA" == "true" ]]; then
  [[ "$STACK_DIR" == /* && "$STACK_DIR" != "/" ]] || { echo "Unsafe stack path: $STACK_DIR" >&2; exit 1; }
  rm -rf --one-file-system "$STACK_DIR"
  echo "Containers and all stack data were deleted."
else
  echo "Containers were removed; data remains in $STACK_DIR."
fi
