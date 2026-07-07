#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"

if [[ "${GITLAB_INSTALLER_TEST_MODE:-0}" != "1" && $EUID -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi
[[ -f "$STACK_DIR/secrets/gitlab_db_password.txt" ]] || {
  echo "Missing $STACK_DIR/secrets/gitlab_db_password.txt" >&2
  exit 1
}

cd "$STACK_DIR"
DB_PASS="$(tr -d '\r\n' < secrets/gitlab_db_password.txt)"
[[ -n "$DB_PASS" ]] || { echo "GitLab database password is empty." >&2; exit 1; }

if ! docker compose ps --status running --services | grep -qx postgres; then
  echo "PostgreSQL container is not running." >&2
  exit 1
fi

# Run as the PostgreSQL superuser through the container-local Unix socket.
# This is deliberately idempotent: it creates missing objects and always
# reconciles the GitLab role password with the current secret file.
docker compose exec -T postgres \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  --set=gitlab_db_password="$DB_PASS" <<'SQL'
SELECT 'CREATE ROLE gitlab WITH LOGIN CREATEDB'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = 'gitlab'
) \gexec

ALTER ROLE gitlab
  WITH LOGIN CREATEDB
  PASSWORD :'gitlab_db_password';

SELECT 'CREATE DATABASE gitlabhq_production OWNER gitlab ENCODING ''UTF8'' LC_COLLATE ''C.UTF-8'' LC_CTYPE ''C.UTF-8'' TEMPLATE template0'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'gitlabhq_production'
) \gexec

ALTER DATABASE gitlabhq_production OWNER TO gitlab;
SQL

docker compose exec -T postgres \
  psql -U postgres -d gitlabhq_production -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS amcheck;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS plpgsql;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL

# Verify the exact credentials GitLab will use, over TCP and password auth.
docker compose exec -T \
  -e PGPASSWORD="$DB_PASS" \
  postgres \
  psql -h 127.0.0.1 -U gitlab -d gitlabhq_production \
  -v ON_ERROR_STOP=1 \
  -tA -F '|' -c 'SELECT current_user, current_database();' \
  | grep -qx 'gitlab|gitlabhq_production'

unset DB_PASS
echo "GitLab database role, password, database, and extensions are ready."
