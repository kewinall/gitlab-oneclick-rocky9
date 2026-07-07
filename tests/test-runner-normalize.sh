#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/stack/runner/config"
cat > "$TMP/stack/.env" <<'ENV'
RUNNER_CPUS=2
RUNNER_MEMORY=4g
ENV

cat > "$TMP/stack/runner/config/config.toml" <<'TOML'
concurrent = 1
check_interval = 3

[[runners]]
  name = "test-runner"
  url = "http://gitlab.test"
  token = "glrt-test"
  executor = "docker"
  [runners.docker]
    tls_verify = false
    image = "alpine:3.23"
    cpus = "1"
    memory = "2g"
    memory_swap = "2g"
    shm_size = 268435456
    pull_policy = "always"
    privileged = false
    volumes = ["/cache"]
    shm_size = 0
    network_mtu = 0
TOML

STACK_DIR="$TMP/stack" bash "$ROOT/scripts/normalize-runner-config.sh" >/dev/null

python3 - "$TMP/stack/runner/config/config.toml" <<'PY'
import sys
import tomllib
from pathlib import Path

p = Path(sys.argv[1])
raw = p.read_text(encoding="utf-8")
for key in ("cpus", "memory", "memory_swap", "shm_size", "pull_policy"):
    count = sum(1 for line in raw.splitlines() if line.strip().startswith(f"{key} ="))
    assert count == 1, (key, count, raw)

doc = tomllib.loads(raw)
docker = doc["runners"][0]["docker"]
assert docker["cpus"] == "2"
assert docker["memory"] == "4g"
assert docker["memory_swap"] == "4g"
assert docker["shm_size"] == 268435456
assert docker["pull_policy"] == "if-not-present"
PY

# Running the normalizer a second time must remain valid and idempotent.
STACK_DIR="$TMP/stack" bash "$ROOT/scripts/normalize-runner-config.sh" >/dev/null
python3 - "$TMP/stack/runner/config/config.toml" <<'PY'
import sys
import tomllib
from pathlib import Path
raw = Path(sys.argv[1]).read_text(encoding="utf-8")
tomllib.loads(raw)
for key in ("cpus", "memory", "memory_swap", "shm_size", "pull_policy"):
    assert sum(1 for line in raw.splitlines() if line.strip().startswith(f"{key} =")) == 1
PY

echo "[PASS] Runner TOML normalization is valid and idempotent."
