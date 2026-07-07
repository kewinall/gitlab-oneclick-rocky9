#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"
[[ $EUID -eq 0 ]] || { echo "Run as root or with sudo." >&2; exit 1; }
[[ -f "$STACK_DIR/compose.yaml" ]] || { echo "$STACK_DIR/compose.yaml was not found." >&2; exit 1; }

STACK_DIR="$STACK_DIR" "$STACK_DIR/scripts/normalize-runner-config.sh"

cd "$STACK_DIR"
# shellcheck disable=SC1091
source ./.env
UP_ARGS=(-d --force-recreate)
[[ "${INSTALL_MODE:-online}" == "offline" ]] && UP_ARGS+=(--pull never)
docker compose up "${UP_ARGS[@]}" gitlab-runner

state=""
for attempt in $(seq 1 30); do
  state="$(docker inspect -f '{{.State.Status}}' gitlab-runner 2>/dev/null || true)"
  if [[ "$state" == "running" ]]; then
    if docker compose exec -T gitlab-runner gitlab-runner list >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 2
done

if [[ "$state" != "running" ]]; then
  docker compose logs --tail=100 gitlab-runner >&2 || true
  echo "GitLab Runner did not reach running state." >&2
  exit 1
fi

if ! docker compose exec -T gitlab-runner gitlab-runner verify; then
  docker compose logs --tail=100 gitlab-runner >&2 || true
  echo "Runner configuration is readable, but server verification failed." >&2
  exit 1
fi

echo "GitLab Runner configuration repaired and verified."
