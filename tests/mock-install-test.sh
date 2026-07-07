#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/systemd"

cat > "$TMP/bin/dnf" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TMP/bin/rpm" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
joined=" $* "
# The installer must send the configured virtual host, including a non-default port.
if [[ "$joined" == *" Host: gitlab.test:18081 "* ]]; then
  printf '200'
  exit 0
fi
printf '404'
exit 0
MOCK
cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "

if [[ "$args" == *" version "* ]] || [[ "$args" == *" compose version "* ]]; then
  exit 0
fi
if [[ "$args" == *" ps -a --format "* ]]; then
  exit 0
fi
if [[ "$1" == "inspect" ]]; then
  if [[ "$args" == *" gitlab-postgres "* ]]; then
    printf 'healthy\n'
  elif [[ "$args" == *" status={{.State.Status}} "* ]]; then
    printf 'status=running health=healthy restarts=0 oom=false\n'
  else
    printf 'healthy\n'
  fi
  exit 0
fi
if [[ "$args" == *" compose ps --status running --services "* ]]; then
  printf 'postgres\ngitlab\ngitlab-runner\n'
  exit 0
fi
if [[ "$args" == *" compose exec -T gitlab gitlab-ctl status "* ]]; then
  for s in gitaly gitlab-workhorse nginx puma redis sidekiq sshd; do
    printf 'run: %s: (pid 1) 1s\n' "$s"
  done
  exit 0
fi
if [[ "$args" == *" compose exec -T gitlab sh -lc "* ]]; then
  printf 'MockRootPassword\n'
  exit 0
fi
if [[ "$args" == *" SELECT current_user, current_database(); "* ]]; then
  printf 'gitlab|gitlabhq_production\n'
  exit 0
fi
if [[ "$args" == *" compose ps "* ]]; then
  printf 'NAME STATUS\ngitlab healthy\ngitlab-postgres healthy\n'
  exit 0
fi
# All remaining mocked compose operations succeed, including psql heredocs.
exit 0
MOCK
chmod 0755 "$TMP/bin"/*

if ! GITLAB_INSTALLER_TEST_MODE=1 \
  SYSTEMD_UNIT_DIR="$TMP/systemd" \
  PATH="$TMP/bin:$PATH" \
  bash "$ROOT/install.sh" \
    --mode online \
    --host gitlab.test \
    --http-port 18081 \
    --ssh-port 12222 \
    --stack-dir "$TMP/stack" \
    --skip-firewall > "$TMP/install.log" 2>&1
then
  echo "Mock install failed:" >&2
  cat "$TMP/install.log" >&2
  exit 1
fi

grep -q 'GitLab deployment completed.' "$TMP/install.log"
grep -q 'MockRootPassword' "$TMP/stack/secrets/initial_admin.txt"
test -x "$TMP/stack/scripts/wait-gitlab.sh"
test -x "$TMP/stack/scripts/verify-install.sh"
grep -q '^GITLAB_HOSTNAME=gitlab.test$' "$TMP/stack/.env"
grep -q '^GITLAB_HTTP_PORT=18081$' "$TMP/stack/.env"

# Regression: resume.sh must recreate initial_admin.txt without expanding an
# unset positional parameter from the nested password extraction command.
rm -f "$TMP/stack/secrets/initial_admin.txt"
if ! GITLAB_INSTALLER_TEST_MODE=1 \
  SYSTEMD_UNIT_DIR="$TMP/systemd" \
  PATH="$TMP/bin:$PATH" \
  bash "$ROOT/resume.sh" \
    --stack-dir "$TMP/stack" > "$TMP/resume.log" 2>&1
then
  echo "Mock resume failed:" >&2
  cat "$TMP/resume.log" >&2
  exit 1
fi
grep -q 'Deployment resumed successfully.' "$TMP/resume.log"
grep -q 'MockRootPassword' "$TMP/stack/secrets/initial_admin.txt"

printf '[PASS] Mocked end-to-end installer and resume flow passed.\n'
