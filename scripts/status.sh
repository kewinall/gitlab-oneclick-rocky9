#!/usr/bin/env bash
set -Eeuo pipefail
STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"
cd "$STACK_DIR"
# shellcheck disable=SC1091
source "$STACK_DIR/scripts/lib-gitlab.sh"
load_gitlab_stack_env "$STACK_DIR"

echo "=== Docker Compose ==="
docker compose ps

echo
echo "=== Container states ==="
for c in gitlab gitlab-postgres gitlab-runner; do
  docker inspect "$c" --format '{{.Name}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} oom={{.State.OOMKilled}}' 2>/dev/null || true
done

echo
echo "=== GitLab services ==="
docker compose exec -T gitlab gitlab-ctl status || true

echo
echo "=== GitLab HTTP routing ==="
printf 'Host header: %s\n' "$(gitlab_host_header)"
printf '/users/sign_in: HTTP %s\n' "$(gitlab_http_code '/users/sign_in')"
printf '/-/health: HTTP %s\n' "$(gitlab_http_code '/-/health')"
printf '/-/readiness?all=1: HTTP %s\n' "$(gitlab_http_code '/-/readiness?all=1')"

echo
echo "=== PostgreSQL ==="
docker compose exec -T postgres pg_isready -U postgres -d gitlabhq_production || true
DB_PASS="$(tr -d '\r\n' < secrets/gitlab_db_password.txt)"
docker compose exec -T -e PGPASSWORD="$DB_PASS" postgres \
  psql -h 127.0.0.1 -U gitlab -d gitlabhq_production \
  -tA -F '|' -c 'SELECT current_user, current_database();' || true
unset DB_PASS

echo
echo "=== Runner ==="
docker compose exec -T gitlab-runner gitlab-runner list || true

echo
echo "=== Disk usage ==="
df -h "$STACK_DIR"
du -sh "$STACK_DIR"/* 2>/dev/null | sort -h
