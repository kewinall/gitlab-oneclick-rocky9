#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"
NEW_GITLAB_VERSION="${1:-}"
NEW_RUNNER_VERSION="${2:-}"
NEW_POSTGRES_VERSION="${3:-}"

[[ $EUID -eq 0 ]] || { echo "Run as root or with sudo." >&2; exit 1; }
[[ -n "$NEW_GITLAB_VERSION" ]] || {
  echo "Usage: sudo $0 <gitlab-version> [runner-version] [postgres-17-minor]" >&2
  exit 1
}

cd "$STACK_DIR"
[[ -f .env ]] || { echo "$STACK_DIR/.env not found." >&2; exit 1; }

echo "Review the official GitLab upgrade path before crossing a major or minor version."
"$STACK_DIR/scripts/backup.sh"

sed -i -E "s|^GITLAB_IMAGE=.*|GITLAB_IMAGE=gitlab/gitlab-ce:${NEW_GITLAB_VERSION}-ce.0|" .env
[[ -z "$NEW_RUNNER_VERSION" ]] || sed -i -E "s|^RUNNER_IMAGE=.*|RUNNER_IMAGE=gitlab/gitlab-runner:alpine-v${NEW_RUNNER_VERSION}|" .env
if [[ -n "$NEW_POSTGRES_VERSION" ]]; then
  [[ "$NEW_POSTGRES_VERSION" == 17.* ]] || { echo "Only PostgreSQL 17 minor updates are allowed." >&2; exit 1; }
  sed -i -E "s|^POSTGRES_IMAGE=.*|POSTGRES_IMAGE=postgres:${NEW_POSTGRES_VERSION}-bookworm|" .env
fi

docker compose config >/dev/null
docker compose pull
docker compose up -d postgres
STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/ensure-gitlab-db.sh"
docker compose up -d
docker compose ps
