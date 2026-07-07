#!/usr/bin/env bash
# Shared helpers for GitLab HTTP probes.
# GitLab routes by the configured external hostname. Probing 127.0.0.1
# without the matching Host header can return 404 even when GitLab is healthy.

load_gitlab_stack_env() {
  local stack_dir="${1:-/srv/gitlab-stack}"
  [[ -f "$stack_dir/.env" ]] || {
    echo "Missing $stack_dir/.env" >&2
    return 1
  }
  # shellcheck disable=SC1090
  source "$stack_dir/.env"
  : "${GITLAB_HOSTNAME:?GITLAB_HOSTNAME is not set}"
  : "${GITLAB_HTTP_PORT:?GITLAB_HTTP_PORT is not set}"
}

gitlab_host_header() {
  if [[ "${GITLAB_HTTP_PORT}" == "80" ]]; then
    printf '%s' "${GITLAB_HOSTNAME}"
  else
    printf '%s:%s' "${GITLAB_HOSTNAME}" "${GITLAB_HTTP_PORT}"
  fi
}

gitlab_local_url() {
  local path="${1:-/users/sign_in}"
  printf 'http://127.0.0.1:%s%s' "${GITLAB_HTTP_PORT}" "$path"
}

gitlab_http_code() {
  local path="${1:-/users/sign_in}"
  local code
  code="$(curl \
    --silent \
    --show-error \
    --connect-timeout 3 \
    --max-time 15 \
    --header "Host: $(gitlab_host_header)" \
    --output /dev/null \
    --write-out '%{http_code}' \
    "$(gitlab_local_url "$path")" 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s' "$code"
}

gitlab_container_state() {
  docker inspect gitlab \
    --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} oom={{.State.OOMKilled}}' \
    2>/dev/null || true
}

gitlab_container_health() {
  docker inspect gitlab \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    2>/dev/null || true
}
