#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

printf '[TEST] Bash syntax\n'
while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(find "$ROOT" -type f -name '*.sh' -print0)

printf '[TEST] YAML parse and required services\n'
python3 - "$ROOT/compose.yaml" <<'PY'
import sys, yaml
p=sys.argv[1]
with open(p, encoding='utf-8') as f:
    doc=yaml.safe_load(f)
assert set(doc['services']) == {'postgres','gitlab','gitlab-runner'}
assert doc['services']['gitlab']['healthcheck']['test'][1] == '/opt/gitlab/bin/gitlab-healthcheck'
assert 'statement_timeout=60000' not in open(p, encoding='utf-8').read()
PY

printf '[TEST] No legacy host-mismatched readiness loop\n'
if grep -R --line-number --fixed-strings 'http://127.0.0.1:${GITLAB_HTTP_PORT}/-/health' "$ROOT"/*.sh "$ROOT"/scripts 2>/dev/null; then
  echo 'Legacy health probe found.' >&2
  exit 1
fi

printf '[TEST] Host-sensitive HTTP probe behavior\n'
mkdir -p "$TMP/bin" "$TMP/stack/scripts"
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
joined=" $* "
# Simulate GitLab strict host routing: correct Host returns 200; raw IP returns 404.
if [[ "$joined" == *" Host: gitlab.test:18080 "* ]]; then
  printf '200'
else
  printf '404'
fi
MOCK
chmod 0755 "$TMP/bin/curl"
cat > "$TMP/stack/.env" <<'ENV'
GITLAB_HOSTNAME=gitlab.test
GITLAB_HTTP_PORT=18080
ENV
cp "$ROOT/scripts/lib-gitlab.sh" "$TMP/stack/scripts/"
PATH="$TMP/bin:$PATH"
export PATH
# shellcheck disable=SC1090
source "$TMP/stack/scripts/lib-gitlab.sh"
load_gitlab_stack_env "$TMP/stack"

wrong_code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/-/health)"
[[ "$wrong_code" == "404" ]]
right_code="$(gitlab_http_code '/-/health')"
[[ "$right_code" == "200" ]]
ui_code="$(gitlab_http_code '/users/sign_in')"
[[ "$ui_code" == "200" ]]
[[ "$(gitlab_host_header)" == "gitlab.test:18080" ]]

printf '[TEST] Root password extraction quoting regression
'
if grep -R --line-number --fixed-strings 'print \\$2' "$ROOT/install.sh" "$ROOT/resume.sh"; then
  echo 'Unsafe nested-shell password extraction found.' >&2
  exit 1
fi
grep -q "sed -n 's/^Password:\[\[:space:\]\]\*//p'" "$ROOT/install.sh"
grep -q "sed -n 's/^Password:\[\[:space:\]\]\*//p'" "$ROOT/resume.sh"

printf '[TEST] Runner registration must not restart the container\n'
REG_TMP="$TMP/runner-register"
mkdir -p "$REG_TMP/bin" "$REG_TMP/stack/runner/config"
cat > "$REG_TMP/stack/.env" <<'ENV'
GITLAB_EXTERNAL_URL=http://gitlab.test
RUNNER_DEFAULT_IMAGE=alpine:3.23
RUNNER_DESCRIPTION=test-runner
RUNNER_CONCURRENT=1
RUNNER_CPUS=2
RUNNER_MEMORY=4g
ENV
cat > "$REG_TMP/stack/runner/config/config.toml" <<'TOML'
concurrent = 1
[[runners]]
  executor = "docker"
  [runners.docker]
    image = "alpine:3.23"
    shm_size = 0
TOML
mkdir -p "$REG_TMP/stack/scripts"
cp "$ROOT/scripts/normalize-runner-config.sh" "$REG_TMP/stack/scripts/normalize-runner-config.sh"
chmod 0750 "$REG_TMP/stack/scripts/normalize-runner-config.sh"
cat > "$REG_TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"
exit 0
MOCK
chmod 0755 "$REG_TMP/bin/docker"
GITLAB_INSTALLER_TEST_MODE=1 \
DOCKER_CALL_LOG="$REG_TMP/docker.calls" \
STACK_DIR="$REG_TMP/stack" \
PATH="$REG_TMP/bin:$PATH" \
if ! GITLAB_INSTALLER_TEST_MODE=1 \
  DOCKER_CALL_LOG="$REG_TMP/docker.calls" \
  STACK_DIR="$REG_TMP/stack" \
  PATH="$REG_TMP/bin:$PATH" \
  bash "$ROOT/scripts/register-runner.sh" glrt-test-token \
    > "$REG_TMP/output.log" 2>&1
then
  echo "Runner registration mock test failed:" >&2
  cat "$REG_TMP/output.log" >&2
  exit 1
fi
grep -q 'compose exec -T gitlab-runner gitlab-runner register' "$REG_TMP/docker.calls"
grep -q 'compose exec -T gitlab-runner gitlab-runner verify' "$REG_TMP/docker.calls"
if grep -q 'compose restart gitlab-runner' "$REG_TMP/docker.calls"; then
  echo 'Runner registration still restarts the container.' >&2
  exit 1
fi
grep -q 'Runner registration completed and verified successfully.' "$REG_TMP/output.log"

printf '[TEST] Runner TOML duplicate-key normalization\n'
bash "$ROOT/tests/test-runner-normalize.sh"

printf '[TEST] Registration script invokes the normalizer and has no append-based shm_size patch\n'
grep -q 'normalize-runner-config.sh' "$ROOT/scripts/register-runner.sh"
if grep -q 'sed -i .*shm_size' "$ROOT/scripts/register-runner.sh"; then
  echo 'Unsafe append-based shm_size mutation is still present.' >&2
  exit 1
fi

printf '[TEST] Explicit online/offline mode validation
'
bash "$ROOT/tests/test-install-mode.sh"

printf '[TEST] GitHub workflow YAML parse
'
python3 - "$ROOT/.github/workflows/ci.yml" <<'PYMODE'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    doc = yaml.safe_load(f)
assert doc['name'] == 'CI'
assert 'jobs' in doc and 'test' in doc['jobs']
PYMODE

printf '[TEST] Offline installation must disable repositories and pulls
'
grep -q -- "--disablerepo='\*'" "$ROOT/install.sh"
grep -q -- '--pull never' "$ROOT/install.sh"
grep -q 'docker load --input' "$ROOT/install.sh"
grep -q 'prepare-offline-bundle.sh' "$ROOT/README.md"

printf '[TEST] Mocked end-to-end installer and resume flow
'
bash "$ROOT/tests/mock-install-test.sh"


printf '[TEST] Offline bundle preparation and verification
'
bash "$ROOT/tests/test-offline-bundle.sh"

printf '[TEST] Mocked offline installation flow
'
bash "$ROOT/tests/mock-offline-install-test.sh"

printf '[PASS] All static and behavioral tests passed.\n'
