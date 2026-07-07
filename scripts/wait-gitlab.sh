#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"
TIMEOUT_SECONDS="${GITLAB_WAIT_TIMEOUT_SECONDS:-1800}"
INTERVAL_SECONDS="${GITLAB_WAIT_INTERVAL_SECONDS:-10}"

[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || { echo "Invalid GITLAB_WAIT_TIMEOUT_SECONDS" >&2; exit 1; }
[[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || { echo "Invalid GITLAB_WAIT_INTERVAL_SECONDS" >&2; exit 1; }

# shellcheck disable=SC1091
source "$STACK_DIR/scripts/lib-gitlab.sh"
load_gitlab_stack_env "$STACK_DIR"
cd "$STACK_DIR"

start_epoch="$(date +%s)"
attempt=0
last_ui_code="000"
last_health_code="000"

while true; do
  attempt=$((attempt + 1))
  container_health="$(gitlab_container_health)"
  state="$(gitlab_container_state)"

  last_ui_code="$(gitlab_http_code '/users/sign_in')"
  last_health_code="$(gitlab_http_code '/-/health')"

  # The image's internal healthcheck validates GitLab from inside the container.
  # The regular UI probe validates host port publishing and hostname routing.
  if [[ "$container_health" == "healthy" ]] && [[ "$last_ui_code" =~ ^(200|302|303)$ ]]; then
    printf '[INFO] GitLab is ready: %s ui_http=%s health_http=%s host=%s\n' \
      "$state" "$last_ui_code" "$last_health_code" "$(gitlab_host_header)"
    exit 0
  fi

  now_epoch="$(date +%s)"
  elapsed=$((now_epoch - start_epoch))
  if (( elapsed >= TIMEOUT_SECONDS )); then
    printf '[ERROR] GitLab did not become ready within %s seconds. %s ui_http=%s health_http=%s host=%s\n' \
      "$TIMEOUT_SECONDS" "$state" "$last_ui_code" "$last_health_code" "$(gitlab_host_header)" >&2
    docker compose ps >&2 || true
    docker compose logs --tail=300 gitlab >&2 || true
    exit 1
  fi

  if (( attempt == 1 || attempt % 6 == 0 )); then
    printf '[INFO] Waiting for GitLab: elapsed=%ss %s ui_http=%s health_http=%s host=%s\n' \
      "$elapsed" "$state" "$last_ui_code" "$last_health_code" "$(gitlab_host_header)"
  fi
  sleep "$INTERVAL_SECONDS"
done
