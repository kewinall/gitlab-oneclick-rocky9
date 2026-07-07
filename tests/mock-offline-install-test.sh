#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/systemd" "$TMP/bundle"/{installer,rpms,images,keys,manifests}
cat > "$TMP/os-release" <<'OS'
ID=rocky
VERSION_ID=9.8
PRETTY_NAME="Rocky Linux 9.8"
OS

cp -a "$ROOT/." "$TMP/bundle/installer/"
: > "$TMP/bundle/rpms/mock-docker.rpm"
for name in gitlab postgres runner alpine; do
  tar -cf "$TMP/bundle/images/${name}.tar" --files-from /dev/null
done
printf 'mock key\n' > "$TMP/bundle/keys/docker-ce.gpg"
printf 'mock rpm\n' > "$TMP/bundle/manifests/rpms.txt"
printf '%s\n' \
  'gitlab/gitlab-ce:19.1.1-ce.0' \
  'postgres:17.10-bookworm' \
  'gitlab/gitlab-runner:alpine-v19.1.1' \
  'alpine:3.23' > "$TMP/bundle/manifests/images.txt"
cat > "$TMP/bundle/bundle.env" <<'ENV'
BUNDLE_FORMAT_VERSION=1
INSTALLER_VERSION=1.4.0
TARGET_OS_MAJOR=9
TARGET_ARCH=x86_64
CREATED_AT=2026-07-07T00:00:00Z
GITLAB_IMAGE=gitlab/gitlab-ce:19.1.1-ce.0
POSTGRES_IMAGE=postgres:17.10-bookworm
RUNNER_IMAGE=gitlab/gitlab-runner:alpine-v19.1.1
RUNNER_DEFAULT_IMAGE=alpine:3.23
ENV
cat > "$TMP/bundle/install-offline.sh" <<'WRAP'
#!/usr/bin/env bash
BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$BUNDLE_DIR/installer/install.sh" --mode offline --offline-bundle "$BUNDLE_DIR" "$@"
WRAP
chmod 0755 "$TMP/bundle/install-offline.sh"
cp "$ROOT/verify-offline-bundle.sh" "$TMP/bundle/verify-offline-bundle.sh"
chmod 0755 "$TMP/bundle/verify-offline-bundle.sh"
(
  cd "$TMP/bundle"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

cat > "$TMP/bin/dnf" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DNF_CALL_LOG"
exit 0
MOCK
cat > "$TMP/bin/rpm" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-q" ]]; then exit 1; fi
exit 0
MOCK
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
joined=" $* "
if [[ "$joined" == *" Host: gitlab.test:18082 "* ]]; then
  printf '200'
else
  printf '404'
fi
MOCK
cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"
args=" $* "
if [[ "$args" == *" version "* ]] || [[ "$args" == *" compose version "* ]]; then exit 0; fi
if [[ "$args" == *" ps -a --format "* ]]; then exit 0; fi
if [[ "$1" == "load" ]]; then exit 0; fi
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then exit 0; fi
if [[ "$1" == "inspect" ]]; then
  if [[ "$args" == *" gitlab-postgres "* ]]; then printf 'healthy\n';
  elif [[ "$args" == *" status={{.State.Status}} "* ]]; then printf 'status=running health=healthy restarts=0 oom=false\n';
  else printf 'healthy\n'; fi
  exit 0
fi
if [[ "$args" == *" compose ps --status running --services "* ]]; then printf 'postgres\ngitlab\ngitlab-runner\n'; exit 0; fi
if [[ "$args" == *" compose exec -T gitlab gitlab-ctl status "* ]]; then
  for s in gitaly gitlab-workhorse nginx puma redis sidekiq sshd; do printf 'run: %s: (pid 1) 1s\n' "$s"; done
  exit 0
fi
if [[ "$args" == *" compose exec -T gitlab sh -lc "* ]]; then printf 'MockRootPassword\n'; exit 0; fi
if [[ "$args" == *" SELECT current_user, current_database(); "* ]]; then printf 'gitlab|gitlabhq_production\n'; exit 0; fi
if [[ "$args" == *" compose ps "* ]]; then printf 'NAME STATUS\ngitlab healthy\ngitlab-postgres healthy\n'; exit 0; fi
exit 0
MOCK
chmod 0755 "$TMP/bin"/*

if ! GITLAB_INSTALLER_TEST_MODE=1 \
  SYSTEMD_UNIT_DIR="$TMP/systemd" \
  DNF_CALL_LOG="$TMP/dnf.calls" \
  DOCKER_CALL_LOG="$TMP/docker.calls" \
  OS_RELEASE_FILE="$TMP/os-release" \
  PATH="$TMP/bin:$PATH" \
  bash "$TMP/bundle/install-offline.sh" \
    --host gitlab.test \
    --http-port 18082 \
    --ssh-port 12223 \
    --stack-dir "$TMP/stack" \
    --skip-firewall > "$TMP/install.log" 2>&1
then
  echo "Mock offline install failed:" >&2
  cat "$TMP/install.log" >&2
  exit 1
fi

grep -q 'GitLab deployment completed.' "$TMP/install.log"
grep -q '^INSTALL_MODE=offline$' "$TMP/stack/.env"
grep -q -- "--disablerepo=\*" "$TMP/dnf.calls"
grep -q '^load --input ' "$TMP/docker.calls"
grep -q 'compose up -d --pull never postgres' "$TMP/docker.calls"
grep -q 'compose up -d --pull never gitlab' "$TMP/docker.calls"
grep -q 'compose up -d --pull never gitlab-runner' "$TMP/docker.calls"
if grep -q 'compose pull' "$TMP/docker.calls"; then
  echo 'Offline installation attempted docker compose pull.' >&2
  exit 1
fi

printf '[PASS] Mocked offline installation flow passed.\n'
