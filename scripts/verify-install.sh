#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"
if [[ "${GITLAB_INSTALLER_TEST_MODE:-0}" != "1" && $EUID -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$STACK_DIR/scripts/lib-gitlab.sh"
load_gitlab_stack_env "$STACK_DIR"
cd "$STACK_DIR"

failures=0
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; failures=$((failures + 1)); }

pg_health="$(docker inspect gitlab-postgres --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
[[ "$pg_health" == "healthy" ]] && pass "PostgreSQL container is healthy" || fail "PostgreSQL container health: ${pg_health:-missing}"

gitlab_health="$(gitlab_container_health)"
[[ "$gitlab_health" == "healthy" ]] && pass "GitLab container is healthy" || fail "GitLab container health: ${gitlab_health:-missing}"

ui_code="$(gitlab_http_code '/users/sign_in')"
[[ "$ui_code" =~ ^(200|302|303)$ ]] \
  && pass "GitLab UI responds through host port with Host=$(gitlab_host_header), HTTP $ui_code" \
  || fail "GitLab UI probe returned HTTP $ui_code with Host=$(gitlab_host_header)"

health_code="$(gitlab_http_code '/-/health')"
if [[ "$health_code" == "200" ]]; then
  pass "GitLab /-/health endpoint returned HTTP 200"
else
  printf '[WARN] /-/health returned HTTP %s; UI and container health remain authoritative for installation validation.\n' "$health_code" >&2
fi

services="$(docker compose exec -T gitlab gitlab-ctl status 2>/dev/null || true)"
for service in gitaly gitlab-workhorse nginx puma redis sidekiq sshd; do
  if grep -qE "^run: ${service}:" <<<"$services"; then
    pass "GitLab service is running: $service"
  else
    fail "GitLab service is not running: $service"
  fi
done

DB_PASS="$(tr -d '\r\n' < secrets/gitlab_db_password.txt)"
if docker compose exec -T -e PGPASSWORD="$DB_PASS" postgres \
  psql -h 127.0.0.1 -U gitlab -d gitlabhq_production \
  -v ON_ERROR_STOP=1 -tA -F '|' \
  -c 'SELECT current_user, current_database();' 2>/dev/null \
  | grep -qx 'gitlab|gitlabhq_production'; then
  pass "GitLab database credentials are valid"
else
  fail "GitLab database credential validation failed"
fi
unset DB_PASS

if (( failures > 0 )); then
  printf '[FAIL] Installation verification failed with %s issue(s).\n' "$failures" >&2
  exit 1
fi
printf '[PASS] Installation verification completed successfully.\n'
