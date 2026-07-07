#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$STACK_DIR/backups/$STAMP"

[[ $EUID -eq 0 ]] || { echo "Run as root or with sudo." >&2; exit 1; }
cd "$STACK_DIR"
mkdir -p "$BACKUP_DIR"
chmod 0750 "$STACK_DIR/backups" "$BACKUP_DIR"

docker compose ps --status running --services | grep -qx gitlab || { echo "GitLab is not running." >&2; exit 1; }
docker compose ps --status running --services | grep -qx postgres || { echo "PostgreSQL is not running." >&2; exit 1; }

echo "[1/3] Creating GitLab application and repository backup"
docker compose exec -T gitlab gitlab-backup create
LATEST_GITLAB_BACKUP="$(find "$STACK_DIR/gitlab/data/backups" -maxdepth 1 -type f -name '*_gitlab_backup.tar' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$LATEST_GITLAB_BACKUP" ]] || { echo "GitLab backup archive was not found." >&2; exit 1; }
cp -a "$LATEST_GITLAB_BACKUP" "$BACKUP_DIR/"

echo "[2/3] Creating an additional PostgreSQL dump"
docker compose exec -T postgres pg_dump -U postgres -d gitlabhq_production -Fc > "$BACKUP_DIR/gitlab-db-${STAMP}.dump"

echo "[3/3] Archiving configuration, secrets, and Runner settings"
tar -C "$STACK_DIR" -czf "$BACKUP_DIR/gitlab-config-${STAMP}.tar.gz" compose.yaml .env secrets gitlab/config runner/config
sha256sum "$BACKUP_DIR"/* > "$BACKUP_DIR/SHA256SUMS"
find "$STACK_DIR/backups" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} +

echo "Backup completed: $BACKUP_DIR"
