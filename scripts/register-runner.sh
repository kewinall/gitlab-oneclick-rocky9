#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/srv/gitlab-stack}"
TOKEN="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Run as root or with sudo." >&2; exit 1; }
[[ -n "$TOKEN" ]] || { echo "Usage: sudo $0 glrt-xxxxxxxxxxxxxxxx" >&2; exit 1; }
[[ "$TOKEN" == glrt-* ]] || echo "Warning: token does not use the glrt- prefix." >&2

cd "$STACK_DIR"
# shellcheck disable=SC1091
source ./.env

if [[ -s runner/config/config.toml ]] && grep -q 'token = "glrt-' runner/config/config.toml; then
  echo "A Runner is already registered in runner/config/config.toml" >&2
  exit 1
fi

UP_ARGS=(-d)
[[ "${INSTALL_MODE:-online}" == "offline" ]] && UP_ARGS+=(--pull never)
docker compose up "${UP_ARGS[@]}" gitlab-runner

docker compose exec -T gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "$GITLAB_EXTERNAL_URL" \
  --token "$TOKEN" \
  --executor docker \
  --docker-image "$RUNNER_DEFAULT_IMAGE" \
  --docker-volumes /cache \
  --description "$RUNNER_DESCRIPTION"

CONFIG="$STACK_DIR/runner/config/config.toml"
if [[ -f "$CONFIG" ]]; then
  sed -i -E "s/^concurrent = .*/concurrent = ${RUNNER_CONCURRENT}/" "$CONFIG"
  STACK_DIR="$STACK_DIR" CONFIG="$CONFIG" "$STACK_DIR/scripts/normalize-runner-config.sh"
fi

# The register command creates shm_size = 0 by default. The normalizer above
# replaces executor resource keys atomically instead of appending duplicate
# TOML keys. GitLab Runner automatically reloads a valid config.toml.
# Do not restart the container here: an immediate docker exec during restart can
# "procReady not received" even though registration succeeded.
echo "Waiting for GitLab Runner to reload its configuration..."
sleep 4

verified=0
for attempt in $(seq 1 10); do
  if docker compose exec -T gitlab-runner gitlab-runner verify; then
    verified=1
    break
  fi
  echo "Runner verification is not ready yet (${attempt}/10); retrying in 2 seconds..." >&2
  sleep 2
done

if [[ "$verified" -ne 1 ]]; then
  echo "Runner was registered, but verification did not succeed." >&2
  echo "Check: docker compose logs --tail=100 gitlab-runner" >&2
  exit 1
fi

echo "Runner registration completed and verified successfully."
